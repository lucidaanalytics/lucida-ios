#if canImport(UIKit)
import UIKit

/// Feeds taps on the key window to `Autocapture` without swallowing them (the recognizer never cancels or delays
/// touches and recognises alongside the app's own). The chain is read from the hit-tested view's superviews; the
/// text of text fields is never read.
final class UIKitAutocaptureTap: NSObject, UIGestureRecognizerDelegate {
    private let engine: Autocapture
    private weak var window: UIWindow?
    private var recognizer: UITapGestureRecognizer?

    init(engine: Autocapture) { self.engine = engine }

    /// Attaches to the current key window (idempotent per window; call again after the key window changes).
    func attach() {
        DispatchQueue.main.async { [self] in
            guard let w = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows).first(where: \.isKeyWindow),
                  w !== window else { return }
            recognizer.map { $0.view?.removeGestureRecognizer($0) }
            let tap = UITapGestureRecognizer(target: self, action: #selector(onTap(_:)))
            tap.cancelsTouchesInView = false
            tap.delaysTouchesBegan = false
            tap.delaysTouchesEnded = false
            tap.delegate = self
            w.addGestureRecognizer(tap)
            recognizer = tap
            window = w
        }
    }

    @objc private func onTap(_ g: UITapGestureRecognizer) {
        guard let w = g.view as? UIWindow else { return }
        let p = g.location(in: w)
        guard let hit = w.hitTest(p, with: nil) else { return }
        let chain = Self.chain(from: hit)
        engine.tap(chain, x: p.x, y: p.y)
        if hit is UISwitch || hit is UISegmentedControl || hit is UIStepper { engine.change(chain) }
    }

    static func chain(from view: UIView) -> [AutocaptureElement] {
        var out: [AutocaptureElement] = []
        var cur: UIView? = view
        while let v = cur {
            out.append(element(v))
            cur = v.superview
        }
        return out
    }

    static func element(_ v: UIView) -> AutocaptureElement {
        let cls = String(describing: type(of: v))
        let id = v.accessibilityIdentifier
        let input = v is UITextField || v is UITextView
        var label: String?
        if !input {
            switch v {
            case let b as UIButton: label = b.currentTitle ?? b.accessibilityLabel
            case let l as UILabel: label = l.text
            default: label = v.accessibilityLabel
            }
        }
        var props = ["class": cls]
        if let id { props["id"] = id }
        return AutocaptureElement(name: id ?? cls, label: label, tag: id, isInput: input, props: props)
    }

    func gestureRecognizer(_: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith _: UIGestureRecognizer) -> Bool { true }
}
#endif
