import Foundation

public struct RageTapConfig: Sendable {
    public var enabled = true
    public var minTaps = 3
    public var window: TimeInterval = 1
    public var radius: Double = 30
    public init() {}
}

/// Element autocapture (`$autocapture` taps and changes). Off by default.
/// Privacy: text-field values are never collected; `propsAllowList` is the only way extra element props leave the device.
public struct AutocaptureConfig: Sendable {
    public var enabled = false
    public var ignoreLabels: Set<String> = []
    public var maxElements = 10
    public var propsAllowList: Set<String> = []
    /// A view marked with this identifier (and its subviews) is never captured; see `UIView.lucidaNoCapture()`.
    public var noCaptureMarker = "lucida-no-capture"
    public var rageTap = RageTapConfig()
    public init() {}
}

/// One entry in the tapped view's ancestor chain (platform-neutral; the UIKit adapter builds it).
public struct AutocaptureElement: Sendable {
    public var name: String
    public var label: String?
    public var tag: String?
    public var isInput: Bool
    public var props: [String: String]

    public init(name: String, label: String? = nil, tag: String? = nil, isInput: Bool = false, props: [String: String] = [:]) {
        self.name = name; self.label = label; self.tag = tag; self.isInput = isInput; self.props = props
    }
}

final class Autocapture {
    let config: AutocaptureConfig
    private let core: Core
    private let clock: LucidaClock
    private var taps: [(t: Date, x: Double, y: Double)] = []

    init(core: Core, config: AutocaptureConfig, clock: LucidaClock) {
        self.core = core; self.config = config; self.clock = clock
    }

    /// `chain` runs from the tapped view up to the root. Returns the `$autocapture` event, or nil when skipped.
    @discardableResult
    func tap(_ chain: [AutocaptureElement], x: Double, y: Double) -> WireEvent? { emit("touch", chain, point: (x, y)) }

    @discardableResult
    func change(_ chain: [AutocaptureElement]) -> WireEvent? { emit("change", chain, point: nil) }

    private func emit(_ type: String, _ chain: [AutocaptureElement], point: (Double, Double)?) -> WireEvent? {
        guard config.enabled, !chain.contains(where: { $0.tag == config.noCaptureMarker }) else { return nil }
        let kept = chain.filter { !config.ignoreLabels.contains($0.name) && !($0.label.map(config.ignoreLabels.contains) ?? false) }
            .prefix(config.maxElements)
        guard !kept.isEmpty else { return nil }
        let els: [JSONValue] = kept.map { el in
            var o: Props = ["tag_name": .string(el.name)]
            // Inputs never expose label text: it can echo what the user typed.
            if !el.isInput, let l = el.label, !l.isEmpty { o["text"] = .string(String(l.prefix(255))) }
            for (k, v) in el.props where config.propsAllowList.contains(k) { o["attr__\(k)"] = .string(v) }
            return .object(o)
        }
        let text = els.compactMap { $0.objectValue?["text"] }.first ?? .string("")
        let r = core.capture("$autocapture", ["$event_type": .string(type), "$elements": .array(els), "$el_text": text])
        if type == "touch", let (x, y) = point, let top = els.first { rage(top, x: x, y: y) }
        return r
    }

    private func rage(_ top: JSONValue, x: Double, y: Double) {
        let rc = config.rageTap
        guard rc.enabled else { return }
        let now = clock.now()
        taps.append((now, x, y))
        taps.removeAll { now.timeIntervalSince($0.t) > rc.window }
        let near = taps.filter { (($0.x - x) * ($0.x - x) + ($0.y - y) * ($0.y - y)).squareRoot() <= rc.radius }.count
        if near >= rc.minTaps {
            taps = []
            core.capture("$rageclick", ["$event_type": "touch", "$tap_count": .number(Double(near)), "$elements": .array([top])])
        }
    }
}
