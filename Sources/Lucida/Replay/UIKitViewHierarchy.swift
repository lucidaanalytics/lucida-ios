#if canImport(UIKit)
import MapKit
import UIKit
import WebKit

/// Walks the key window's view tree into a wireframe. Never reads input values: text fields and
/// secure fields contribute geometry only, and `lucidaSensitive` views drop their text.
public final class UIKitViewHierarchy: ViewHierarchySource {
    private let captureInputText: Bool
    private let maskSandboxed: Bool

    /// `captureInputText` reads non-secure text field values (off by default; secure fields and sensitive views are never read).
    public init(captureInputText: Bool = false, maskSandboxedViews: Bool = true) {
        self.captureInputText = captureInputText
        maskSandboxed = maskSandboxedViews
    }

    public func snapshot(screen: String) -> WireframeSnapshot? {
        var result: WireframeSnapshot?
        let work = {
            guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows).first(where: \.isKeyWindow)
            else { return }
            let b = window.bounds
            result = WireframeSnapshot(screen: screen, width: b.width, height: b.height, root: MarkerRegions.apply(self.node(window, depth: 0, unmask: false)))
        }
        if Thread.isMainThread { work() } else { DispatchQueue.main.sync(execute: work) }
        return result
    }

    func node(_ v: UIView, depth: Int, unmask parentUnmask: Bool) -> WireframeNode {
        let kind: WireframeKind
        var text: String?
        let marker = v as? LucidaMarkerView
        let unmask = parentUnmask || v.accessibilityIdentifier == "lucida-unmask" || marker?.role == .unmask
        let readInputs = captureInputText || unmask  // secure fields are dropped below, whatever this says
        switch v {
        case is LucidaMarkerView: kind = .marker
        case let l as UILabel: kind = .label; text = l.text
        case let b as UIButton: kind = .button; text = b.currentTitle
        case let f as UITextField: kind = .input; if readInputs { text = f.text }
        case let t as UITextView: kind = .input; if readInputs { text = t.text }
        case is UIImageView: kind = .image
        case is UIScrollView: kind = .scroll
        default: kind = .view
        }
        let secure = (v as? UITextField)?.isSecureTextEntry == true || (v as? UITextView)?.isSecureTextEntry == true
        let sandboxed = maskSandboxed && (v is WKWebView || v is MKMapView)
        let sensitive = v.accessibilityIdentifier == "lucida-sensitive" || secure || sandboxed || marker?.role == .mask
        let opaque = String(describing: type(of: v)).contains("HostingView")  // SwiftUI content is not walkable
        let kids: [WireframeNode] = depth > 40 || sandboxed ? [] : v.subviews.filter { !$0.isHidden && $0.alpha > 0.01 }.map { node($0, depth: depth + 1, unmask: unmask) }
        return WireframeNode(
            kind: kind, x: v.frame.origin.x, y: v.frame.origin.y, width: v.frame.width, height: v.frame.height,
            text: sensitive ? nil : text, background: v.backgroundColor.flatMap(Self.hex), sensitive: sensitive, unmask: unmask, opaque: opaque, children: kids)
    }

    private static func hex(_ c: UIColor) -> String? {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard c.getRed(&r, green: &g, blue: &b, alpha: &a), a > 0 else { return nil }
        return String(format: "#%02x%02x%02x", Int(r * 255), Int(g * 255), Int(b * 255))
    }
}

public extension UIView {
    /// Marks a view whose text must never appear in replay, even with `maskText = false`.
    func lucidaMarkSensitive() { accessibilityIdentifier = "lucida-sensitive" }

    /// Shows this view's text, input value and image in replay even when the global masks are on (never for secure fields).
    func lucidaUnmask() { accessibilityIdentifier = "lucida-unmask" }

    /// Excludes this view and its subviews from `$autocapture`.
    func lucidaNoCapture() { accessibilityIdentifier = "lucida-no-capture" }
}
#endif
