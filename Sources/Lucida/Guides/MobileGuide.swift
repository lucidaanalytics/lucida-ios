import Foundation

/// A guide as `GET /v1/guides` serves it (the same definitions the browser SDK renders).
public struct MobileGuide: Decodable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var kind: String
    public var steps: [GuideStep]
    public var conditions: [String: JSONValue]
    /// A draft served to one of its QA users: no targeting, shown once per launch, no events.
    public var preview: Bool?
    /// This person is in the guide's holdout (decided by the gateway): never shown, carries no steps.
    public var heldOut: Bool?
    /// Resolved appearance (the gateway merges the project theme in): `tokens`, `dark.tokens`, `theme_mode`, `font_family`.
    public var appearance: [String: JSONValue]?
    /// A workflow queued this guide for this person (gateway): it goes first and skips sampling.
    public var queued: Bool?

    enum CodingKeys: String, CodingKey {
        case id, name, kind, steps, conditions, preview, appearance, queued
        case heldOut = "held_out"
    }
}

public struct GuideStep: Decodable, Sendable, Equatable {
    public var id: String
    public var title: String?
    public var body: String?
    public var buttons: [GuideButton]?
    /// Anchor view: its `accessibilityIdentifier` (tooltip, hotspot and tour steps; web selectors are ignored).
    public var nativeId: String?
    /// top | bottom | left | right (mobile draws above or below).
    public var placement: String?
    /// How long to wait for the anchor view (ms, default 3000, max 15000) before showing the step unanchored.
    public var waitMs: Double?

    enum CodingKeys: String, CodingKey {
        case id, title, body, buttons, placement
        case nativeId = "native_id"
        case waitMs = "wait_ms"
    }
}

public struct GuideButton: Decodable, Sendable, Equatable {
    public var label: String
    /// next | back | dismiss | link | event (start_tour behaves like next on mobile).
    public var action: String
    public var url: String?
    public var event: String?

    public init(label: String, action: String, url: String? = nil, event: String? = nil) {
        self.label = label; self.action = action; self.url = url; self.event = event
    }
}

/// Where an anchored step points: the view with this accessibility identifier.
public struct GuideAnchor: Sendable, Equatable {
    public var nativeId: String
    public var placement: String?
    /// Seconds to wait for the view before giving up (clamped 0...15).
    public var wait: TimeInterval
    /// Hotspot: a pulsing dot on the view opens the step when tapped.
    public var hotspot: Bool
}

/// Optional port extension: a presenter that can point a step at a native view. Without it anchored steps show as
/// plain steps (and tooltip / hotspot guides are skipped). Adapter: `UIKitGuidePresenter`.
public protocol AnchoredGuidePresenter: GuidePresenter {
    /// Show `step` next to the anchor view, following it on scroll / relayout. When the view does not appear within
    /// `anchor.wait`, call `onMissing` and show the step unanchored (as `present` would).
    func presentAnchored(_ guide: MobileGuide, step: Int, buttons: [GuideButton], anchor: GuideAnchor, onMissing: @escaping () -> Void, onAction: @escaping (GuideButton?) -> Void)
}

/// Port: draws one guide step natively. `onAction` gets the tapped button, or nil when the person
/// closed the step without one (counts as a dismissal). Adapter: `UIKitGuidePresenter`.
public protocol GuidePresenter: AnyObject {
    func present(_ guide: MobileGuide, step: Int, buttons: [GuideButton], onAction: @escaping (GuideButton?) -> Void)
    func open(_ url: URL)
}

public struct GuidesConfig {
    /// Off by default: no `/v1/guides` request until the app opts in.
    public var enabled = false
    /// Default (iOS): UIAlertController on the top view controller.
    public var presenter: GuidePresenter?

    public init() {}
}
