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
}

public struct GuideStep: Decodable, Sendable, Equatable {
    public var id: String
    public var title: String?
    public var body: String?
    public var buttons: [GuideButton]?
}

public struct GuideButton: Decodable, Sendable, Equatable {
    public var label: String
    /// next | dismiss | link | event (start_tour behaves like next on mobile).
    public var action: String
    public var url: String?
    public var event: String?

    public init(label: String, action: String, url: String? = nil, event: String? = nil) {
        self.label = label; self.action = action; self.url = url; self.event = event
    }
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
