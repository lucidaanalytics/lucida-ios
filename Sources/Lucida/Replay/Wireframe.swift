import Foundation

public struct ReplayConfig {
    /// Off by default; also requires the `replay` consent category.
    public var enabled = false
    public var snapshotInterval: TimeInterval = 5
    /// Text is masked unless this is false AND the view is not marked sensitive.
    public var maskText = true
    /// Text-field values: masked by default. Secure fields and sensitive views are never read, whatever this says.
    public var maskAllTextInputs = true
    public var maskAllImages = true
    /// WKWebView / MKMapView content cannot be inspected: only the frame is recorded.
    public var maskSandboxedViews = true
    /// 0...1, decided once per session.
    public var sampleRate = 1.0
    /// Minimum seconds between snapshots, on top of `snapshotInterval`.
    public var throttleDelay: TimeInterval = 0
    /// Record tap and swipe positions (UIKit source only); never what was typed.
    public var captureTouches = true
    /// Largest single event sent (the gateway accepts 10 MB decompressed).
    public var maxEventBytes = 5_000_000
    /// Where view hierarchies come from. Default (iOS): the key window via UIKit.
    public var source: ViewHierarchySource?
    public var replayTransport: HTTPTransport?
    /// Hold chunks in memory until the session has been recorded this long; a session that ends sooner is never sent. 0 = off.
    public var minDurationMs = 0
    /// Fetch `GET /v1/config` and honour the project's kill switch, sample rate and minimum duration (tightening only).
    public var useRemoteConfig = true
    /// Start recording only while this flag is on.
    public var linkedFlag: String?
    /// Only these screens are recorded (empty = all). The deny list wins; recording pauses on a denied screen.
    public var screenAllowList: [String] = []
    public var screenDenyList: [String] = []
    /// `.screenshot` sends masked JPEG frames instead of wireframes (masks are painted before encoding, on device).
    public var mode: ReplayMode = .wireframe
    /// JPEG quality 0...1 for `.screenshot`.
    public var screenshotQuality = 0.4
    /// Where screenshots come from. Default (iOS): the key window via UIKit.
    public var screenshotSource: ScreenshotSource?

    public init() {}
}

public enum WireframeKind: String, Sendable { case view, label, button, image, input, scroll, marker }

/// One view in platform-neutral form. Frames are in the parent's coordinate space (points).
public struct WireframeNode: Sendable {
    public var kind: WireframeKind
    public var x: Double, y: Double, width: Double, height: Double
    public var text: String?
    /// CSS colour, e.g. "#ff8800".
    public var background: String?
    /// Secure text entry, or a view the app marked sensitive: text is never included.
    public var sensitive = false
    /// The app explicitly allowed this node's text / input value / image (never overrides `sensitive`).
    public var unmask = false
    /// Content the walker cannot read (a SwiftUI hosting view): screenshots mask it while text masking is on.
    public var opaque = false
    public var children: [WireframeNode]

    public init(kind: WireframeKind, x: Double, y: Double, width: Double, height: Double, text: String? = nil,
                background: String? = nil, sensitive: Bool = false, unmask: Bool = false, opaque: Bool = false, children: [WireframeNode] = []) {
        self.kind = kind; self.x = x; self.y = y; self.width = width; self.height = height
        self.text = text; self.background = background; self.sensitive = sensitive; self.unmask = unmask; self.opaque = opaque; self.children = children
    }
}

public struct WireframeSnapshot: Sendable {
    public var screen: String
    public var width: Double
    public var height: Double
    public var root: WireframeNode

    public init(screen: String, width: Double, height: Double, root: WireframeNode) {
        self.screen = screen; self.width = width; self.height = height; self.root = root
    }
}

/// One sample of a finger path (window points), `offsetMs` after the gesture began.
public struct TouchPoint: Sendable, Equatable {
    public var x: Double, y: Double, offsetMs: Int64
    public init(x: Double, y: Double, offsetMs: Int64) { self.x = x; self.y = y; self.offsetMs = offsetMs }
}

/// Port: produces the current view hierarchy. The UIKit adapter lives in `UIKitViewHierarchy.swift`.
public protocol ViewHierarchySource: AnyObject {
    func snapshot(screen: String) -> WireframeSnapshot?
}
