import Foundation

/// In-app guides on mobile (LC-ENG-15): the guides the gateway serves at `GET /v1/guides`, drawn
/// natively one step at a time through a `GuidePresenter`.
///
/// Mobile subset of the browser rules: kinds modal, banner, announcement, slideout, carousel (slides with
/// Back / Next) and tour (steps shown in order), plus tooltip and hotspot when the presenter can anchor
/// (`AnchoredGuidePresenter`). Anchored steps point at the view whose accessibilityIdentifier is the step's
/// `native_id` (N-DAP-10); a missing view emits `$guide_target_missing` and the step shows unanchored. A step's
/// web `selector` is ignored. Targeting: `url` (matched against the screen
/// name, `url_match` exact / contains / regex), `flag_key`, `sample_pct`, `devices` (must include
/// mobile or tablet), `seen_guides` / `not_seen_guides`, `schedule` (window plus weekday / hour
/// recurrence), `frequency`, and A/B `ab_group` / `holdout_pct` (G241: the gateway picks the
/// variant and the holdout for this distinct id and decides recurrence in the zone sent as `tz`).
/// A guide using any other targeting key is skipped rather than shown to the wrong people. Without
/// `frequency` a guide shows once per device; one at a time. Shows are synced to the guide-state
/// store, so a frequency cap counts this person's shows on every device. Events: `$guide_shown`,
/// `$guide_step`, `$guide_completed`, `$guide_dismissed`, `$guide_holdout` with `$guide_id`.
final class GuidesService: @unchecked Sendable {
    static let kinds: Set<String> = ["modal", "banner", "announcement", "slideout", "tour", "carousel", "tooltip", "hotspot"]
    /// Kinds whose steps may point at a native view.
    static let anchorable: Set<String> = ["tooltip", "hotspot", "tour"]
    static let handled: Set<String> = ["url", "url_match", "flag_key", "sample_pct", "devices", "seen_guides", "not_seen_guides", "delay_seconds", "goal",
                                       "schedule", "frequency", "ab_group", "ab_weight", "holdout_pct", "holdout_scope", "exclude_url_patterns"]
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
    private var views: [String: [Double]]
    private var held: Set<String>
    /// Guides shown since the app moved to the current screen (a repeatable guide shows once per visit).
    private var shownHere = Set<String>()
    var now: () -> Date = { Date() }
    var random: () -> Double = { Double.random(in: 0..<1) }
    /// UI work hops to the main thread; tests run it inline.
    var onMain: (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }

    init(core: Core, config: LucidaConfig, flag: @escaping (String) -> Bool) {
        self.core = core
        self.config = config
        self.flag = flag
        seen = Set((core.gated.get(Self.seenKey)).flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? [])
        views = core.gated.get(GuideRules.viewsKey).flatMap { try? JSONDecoder().decode([String: [Double]].self, from: Data($0.utf8)) } ?? [:]
        held = Set(core.gated.get(GuideRules.heldKey).flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? [])
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
        c.queryItems = [URLQueryItem(name: "api_key", value: config.apiKey), URLQueryItem(name: "distinct_id", value: core.distinctId),
                        URLQueryItem(name: "tz", value: TimeZone.current.identifier)]
        guard let url = c.url else { return }
        let r = await config.transport.send(HTTPRequest(url: url, method: "GET"))
        struct Body: Decodable { let guides: [MobileGuide]? }
        guard (200..<300).contains(r.status), let b = try? JSONDecoder().decode(Body.self, from: r.body) else { return }
        let all = b.guides ?? []
        let newlyHeld = lock.locked { () -> [MobileGuide] in
            let fresh = all.filter { $0.heldOut == true && !held.contains($0.id) }
            held.formUnion(fresh.map(\.id))
            return fresh
        }
        if !newlyHeld.isEmpty { saveHeld() }
        for g in newlyHeld {
            var extra: Props = [:]
            if let grp = g.conditions["ab_group"]?.stringValue, !grp.isEmpty { extra["$guide_group"] = .string(grp) }
            core.capture("$guide_holdout", props(g, extra))
        }
        let at = lock.locked { guides = all; return screen }
        if let at { show(on: at) }
    }

    /// The app moved to `name`: show the first eligible guide, if none is on screen.
    func show(on name: String) {
        let pick: MobileGuide? = lock.locked {
            if screen != name { shownHere = [] }
            screen = name
            // workflow-queued guides go first
            let ordered = guides.filter { $0.queued == true } + guides.filter { $0.queued != true }
            guard !showing, let g = ordered.first(where: { eligible($0, name) }) else { return nil }
            showing = true
            shownHere.insert(g.id)
            if g.preview == true { previewed.insert(g.id) }
            return g
        }
        guard let g = pick else { return }
        guard let p = presenter else { lock.locked { showing = false }; return }
        if g.preview != true {
            markSeen(g.id)
            recordView(g.id)
            core.capture("$guide_shown", props(g))
        }
        onMain { self.present(p, g, 0) }
    }

    private func eligible(_ g: MobileGuide, _ name: String) -> Bool {
        guard Self.kinds.contains(g.kind), !g.steps.isEmpty else { return false }
        // tooltip / hotspot exist only next to a view: they need an anchor and a presenter that can draw one
        if g.kind == "tooltip" || g.kind == "hotspot" {
            guard !(g.steps[0].nativeId ?? "").isEmpty, presenter is AnchoredGuidePresenter else { return false }
        }
        if g.preview == true { return !previewed.contains(g.id) }
        let c = g.conditions
        // null, "" and [] are the editor's "not set"
        let used = c.filter { !($0.value.isNull || $0.value.stringValue == "" || $0.value.arrayValue?.isEmpty == true) }.keys
        guard g.heldOut != true, !shownHere.contains(g.id), used.allSatisfy(Self.handled.contains) else { return false }
        if let f = c["frequency"]?.objectValue {
            if !GuideRules.frequencyOk(f, views: views[g.id] ?? [], now: now()) { return false }
        } else if seen.contains(g.id) {
            return false
        }
        if !GuideRules.scheduleOk(c["schedule"]?.objectValue, now: now()) { return false }
        if let u = c["url"]?.stringValue, !u.isEmpty, !Self.matches(name, u, c["url_match"]?.stringValue ?? "contains") { return false }
        if let f = c["flag_key"]?.stringValue, !f.isEmpty, !flag(f) { return false }
        if let pats = c["exclude_url_patterns"]?.arrayValue, Self.excluded(name, pats.compactMap(\.stringValue)) { return false }
        if g.queued != true, let pct = c["sample_pct"]?.numberValue, random() * 100 >= pct { return false }
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

    /// Project-wide exclusions matched against the screen name: `*` globs, the same patterns the web matches against URLs.
    static func excluded(_ screen: String, _ patterns: [String]) -> Bool {
        patterns.contains { p in
            guard !p.isEmpty else { return false }
            let body = p.components(separatedBy: "*").map(NSRegularExpression.escapedPattern(for:)).joined(separator: ".*")
            return screen.range(of: "^" + body + "$", options: .regularExpression) != nil
        }
    }

    static func buttons(_ g: MobileGuide, _ i: Int) -> [GuideButton] {
        if let b = g.steps[i].buttons, !b.isEmpty { return b }
        if g.kind == "banner" || g.kind == "announcement" { return [GuideButton(label: "Dismiss", action: "dismiss")] }
        if g.kind == "carousel" {
            let last = i == g.steps.count - 1
            return (i > 0 ? [GuideButton(label: "Back", action: "back")] : []) + [GuideButton(label: last ? "Done" : "Next", action: "next"), GuideButton(label: "Dismiss", action: "dismiss")]
        }
        return [GuideButton(label: i == g.steps.count - 1 ? "Done" : "Next", action: "next"), GuideButton(label: "Dismiss", action: "dismiss")]
    }

    /// The anchor of step `i`, when its guide kind anchors and the step names a view.
    static func anchor(_ g: MobileGuide, _ i: Int) -> GuideAnchor? {
        let s = g.steps[i]
        guard anchorable.contains(g.kind), let id = s.nativeId, !id.isEmpty else { return nil }
        let wait = min(max(s.waitMs ?? 3000, 0), 15_000) / 1000
        return GuideAnchor(nativeId: id, placement: s.placement, wait: wait, hotspot: g.kind == "hotspot")
    }

    private func present(_ p: GuidePresenter, _ g: MobileGuide, _ i: Int) {
        let onAction: (GuideButton?) -> Void = { [weak self] b in self?.handle(p, g, i, b) }
        if let a = Self.anchor(g, i), let ap = p as? AnchoredGuidePresenter {
            let step = g.steps[i].id
            let quiet = g.preview == true
            return ap.presentAnchored(g, step: i, buttons: Self.buttons(g, i), anchor: a, onMissing: { [weak self] in
                guard let self, !quiet else { return }
                self.core.capture("$guide_target_missing", self.props(g, ["guide_id": .string(g.id), "step_id": .string(step), "$guide_step_id": .string(step), "selector": .string(a.nativeId)]))
            }, onAction: onAction)
        }
        p.present(g, step: i, buttons: Self.buttons(g, i), onAction: onAction)
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
        case "back":
            return present(p, g, max(i - 1, 0))
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

    private func recordView(_ id: String) {
        let all = lock.locked { views[id] = GuideRules.adding(views[id] ?? [], now()); return views }
        if let d = try? JSONEncoder().encode(all) { core.gated.set(GuideRules.viewsKey, String(decoding: d, as: UTF8.self)) }
        Task { await syncViews(all) }
    }

    private func saveHeld() {
        let list = lock.locked { Array(held).sorted() }
        if let d = try? JSONEncoder().encode(list) { core.gated.set(GuideRules.heldKey, String(decoding: d, as: UTF8.self)) }
    }

    /// Read-modify-write of the person's guide state (`POST /v1/guide-state`, analytics consent
    /// only): this device's views are merged in and every other key the browser SDK wrote is kept.
    func syncViews(_ local: [String: [Double]]) async {
        guard core.consent.analytics else { return }
        let url = config.apiHost.appendingPathComponent("v1/guide-state")
        let base: [String: JSONValue] = ["api_key": .string(config.apiKey), "distinct_id": .string(core.distinctId)]
        let send = { (body: [String: JSONValue]) async -> HTTPResponse in
            await self.config.transport.send(HTTPRequest(url: url, method: "POST", headers: ["Content-Type": "application/json"], body: try? JSONEncoder().encode(body)))
        }
        let r = await send(base)
        struct Body: Decodable { let state: [String: JSONValue]? }
        guard (200..<300).contains(r.status), let b = try? JSONDecoder().decode(Body.self, from: r.body) else { return }
        var put = base
        put["state"] = .object(GuideRules.merged(b.state ?? [:], views: local))
        _ = await send(put)
    }

    private func props(_ g: MobileGuide, _ extra: Props = [:]) -> Props {
        extra.merging(["$guide_id": .string(g.id), "$guide_kind": .string(g.kind)]) { a, _ in a }
    }
}
