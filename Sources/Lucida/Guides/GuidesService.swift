import Foundation

/// In-app guides on mobile (LC-ENG-15): the guides the gateway serves at `GET /v1/guides`, drawn
/// natively one step at a time through a `GuidePresenter`.
///
/// Mobile subset of the browser rules: kinds modal, banner, announcement, slideout and tour (steps
/// shown in order); a step's `selector` is ignored. Targeting: `url` (matched against the screen
/// name, `url_match` exact / contains / regex), `flag_key`, `sample_pct`, `devices` (must include
/// mobile or tablet), `seen_guides` / `not_seen_guides`. A guide using any other targeting key is
/// skipped rather than shown to the wrong people. Each guide shows once per device; one at a time.
/// Events: `$guide_shown`, `$guide_step`, `$guide_completed`, `$guide_dismissed` with `$guide_id`.
final class GuidesService: @unchecked Sendable {
    static let kinds: Set<String> = ["modal", "banner", "announcement", "slideout", "tour"]
    static let handled: Set<String> = ["url", "url_match", "flag_key", "sample_pct", "devices", "seen_guides", "not_seen_guides", "delay_seconds", "goal"]
    private static let seenKey = "lc_guide_seen"

    private let core: Core
    private let config: LucidaConfig
    private let flag: (String) -> Bool
    private let lock = NSLock()
    private var guides: [MobileGuide] = []
    private var seen: Set<String>
    private var previewed = Set<String>()
    private var showing = false
    private var screen: String?
    var random: () -> Double = { Double.random(in: 0..<1) }
    /// UI work hops to the main thread; tests run it inline.
    var onMain: (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }

    init(core: Core, config: LucidaConfig, flag: @escaping (String) -> Bool) {
        self.core = core
        self.config = config
        self.flag = flag
        seen = Set((core.gated.get(Self.seenKey)).flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? [])
    }

    private var presenter: GuidePresenter? { config.guides.presenter ?? Self.platformPresenter }
    #if canImport(UIKit)
    private static let platformPresenter: GuidePresenter? = UIKitGuidePresenter()
    #else
    private static let platformPresenter: GuidePresenter? = nil
    #endif

    /// Fetches the project's live guides (needs analytics consent), then re-evaluates the current screen.
    func reload() async {
        guard config.guides.enabled, core.consent.analytics,
              var c = URLComponents(url: config.apiHost.appendingPathComponent("v1/guides"), resolvingAgainstBaseURL: false) else { return }
        c.queryItems = [URLQueryItem(name: "api_key", value: config.apiKey), URLQueryItem(name: "distinct_id", value: core.distinctId)]
        guard let url = c.url else { return }
        let r = await config.transport.send(HTTPRequest(url: url, method: "GET"))
        struct Body: Decodable { let guides: [MobileGuide]? }
        guard (200..<300).contains(r.status), let b = try? JSONDecoder().decode(Body.self, from: r.body) else { return }
        let at = lock.locked { guides = b.guides ?? []; return screen }
        if let at { show(on: at) }
    }

    /// The app moved to `name`: show the first eligible guide, if none is on screen.
    func show(on name: String) {
        let pick: MobileGuide? = lock.locked {
            screen = name
            guard !showing, let g = guides.first(where: { eligible($0, name) }) else { return nil }
            showing = true
            if g.preview == true { previewed.insert(g.id) }
            return g
        }
        guard let g = pick else { return }
        guard let p = presenter else { lock.locked { showing = false }; return }
        if g.preview != true {
            markSeen(g.id)
            core.capture("$guide_shown", props(g))
        }
        onMain { self.present(p, g, 0) }
    }

    private func eligible(_ g: MobileGuide, _ name: String) -> Bool {
        guard Self.kinds.contains(g.kind), !g.steps.isEmpty else { return false }
        if g.preview == true { return !previewed.contains(g.id) }
        let c = g.conditions
        // null, "" and [] are the editor's "not set"
        let used = c.filter { !($0.value.isNull || $0.value.stringValue == "" || $0.value.arrayValue?.isEmpty == true) }.keys
        guard !seen.contains(g.id), used.allSatisfy(Self.handled.contains) else { return false }
        if let u = c["url"]?.stringValue, !u.isEmpty, !Self.matches(name, u, c["url_match"]?.stringValue ?? "contains") { return false }
        if let f = c["flag_key"]?.stringValue, !f.isEmpty, !flag(f) { return false }
        if let pct = c["sample_pct"]?.numberValue, random() * 100 >= pct { return false }
        if let d = c["devices"]?.arrayValue, !d.isEmpty, !d.contains(where: { ["mobile", "tablet"].contains($0.stringValue ?? "") }) { return false }
        if let need = c["seen_guides"]?.arrayValue, !need.allSatisfy({ seen.contains($0.stringValue ?? "") }) { return false }
        if let not = c["not_seen_guides"]?.arrayValue, not.contains(where: { seen.contains($0.stringValue ?? "") }) { return false }
        return true
    }

    static func matches(_ screen: String, _ pattern: String, _ how: String) -> Bool {
        switch how {
        case "exact": return screen == pattern
        case "regex": return (try? NSRegularExpression(pattern: pattern)).map { $0.firstMatch(in: screen, range: NSRange(screen.startIndex..., in: screen)) != nil } ?? false
        default: return screen.contains(pattern)
        }
    }

    static func buttons(_ g: MobileGuide, _ i: Int) -> [GuideButton] {
        if let b = g.steps[i].buttons, !b.isEmpty { return b }
        if g.kind == "banner" || g.kind == "announcement" { return [GuideButton(label: "Dismiss", action: "dismiss")] }
        return [GuideButton(label: i == g.steps.count - 1 ? "Done" : "Next", action: "next"), GuideButton(label: "Dismiss", action: "dismiss")]
    }

    private func present(_ p: GuidePresenter, _ g: MobileGuide, _ i: Int) {
        p.present(g, step: i, buttons: Self.buttons(g, i)) { [weak self] b in self?.handle(p, g, i, b) }
    }

    private func handle(_ p: GuidePresenter, _ g: MobileGuide, _ i: Int, _ b: GuideButton?) {
        let quiet = g.preview == true
        let step = g.steps[i]
        switch b?.action {
        case nil, "dismiss":
            if !quiet { core.capture("$guide_dismissed", props(g, ["$guide_step_id": .string(step.id), "$guide_step_index": .number(Double(i))])) }
            return finish()
        case "link":
            if let s = b?.url, let u = URL(string: s), u.scheme == "https" { p.open(u) }
        case "event":
            if !quiet, let e = b?.event, !e.isEmpty { core.capture(e, ["$guide_id": .string(g.id)]) }
        default: break
        }
        if !quiet { core.capture("$guide_step", props(g, ["$guide_step_id": .string(step.id), "$guide_step_index": .number(Double(i))])) }
        if i + 1 < g.steps.count, b?.action != "link" { return present(p, g, i + 1) }
        if !quiet { core.capture("$guide_completed", props(g)) }
        finish()
    }

    private func finish() {
        let at = lock.locked { showing = false; return screen }
        if let at { show(on: at) }  // the next eligible guide, if any
    }

    private func markSeen(_ id: String) {
        let list = lock.locked { seen.insert(id); return Array(seen).sorted() }
        if let d = try? JSONEncoder().encode(list) { core.gated.set(Self.seenKey, String(decoding: d, as: UTF8.self)) }
    }

    private func props(_ g: MobileGuide, _ extra: Props = [:]) -> Props {
        extra.merging(["$guide_id": .string(g.id), "$guide_kind": .string(g.kind)]) { a, _ in a }
    }
}
