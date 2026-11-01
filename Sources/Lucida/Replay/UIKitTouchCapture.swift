#if canImport(UIKit)
import UIKit

/// Observes taps and pans on the key window for replay (LC-EXP-35) without swallowing them:
/// the recognizers never cancel or delay touches and recognise alongside the app's own.
/// Only positions are recorded; what the touch typed or hit is never read.
final class UIKitTouchCapture: NSObject, UIGestureRecognizerDelegate {
    private weak var recorder: ReplayRecorder?
    private weak var window: UIWindow?
    private var path: [TouchPoint] = []
    private var began = Date()
    private var recognizers: [UIGestureRecognizer] = []

    init(recorder: ReplayRecorder) { self.recorder = recorder }

    /// Attaches to the current key window (call again after the key window changes; idempotent per window).
    func attach() {
        DispatchQueue.main.async { [self] in
            guard let w = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows).first(where: \.isKeyWindow),
                  w !== window else { return }
            detach()
            window = w
            let tap = UITapGestureRecognizer(target: self, action: #selector(onTap(_:)))
            let pan = UIPanGestureRecognizer(target: self, action: #selector(onPan(_:)))
            for r in [tap, pan] as [UIGestureRecognizer] {
                r.cancelsTouchesInView = false
                r.delaysTouchesBegan = false
                r.delaysTouchesEnded = false
                r.delegate = self
                w.addGestureRecognizer(r)
            }
            recognizers = [tap, pan]
        }
    }

    func detach() {
        for r in recognizers { r.view?.removeGestureRecognizer(r) }
        recognizers = []
        window = nil
    }

    @objc private func onTap(_ g: UITapGestureRecognizer) {
        let p = g.location(in: g.view)
        recorder?.tap(x: p.x, y: p.y)
    }

    @objc private func onPan(_ g: UIPanGestureRecognizer) {
        let p = g.location(in: g.view)
        switch g.state {
        case .began:
            began = Date()
            path = [TouchPoint(x: p.x, y: p.y, offsetMs: 0)]
        case .changed:
            let ms = Int64(Date().timeIntervalSince(began) * 1000)
            // ~20 samples a second is enough to draw the swipe
            if ms - (path.last?.offsetMs ?? 0) >= 50, path.count < 200 { path.append(TouchPoint(x: p.x, y: p.y, offsetMs: ms)) }
        case .ended, .cancelled:
            path.append(TouchPoint(x: p.x, y: p.y, offsetMs: Int64(Date().timeIntervalSince(began) * 1000)))
            recorder?.swipe(path)
            path = []
        default: break
        }
    }

    func gestureRecognizer(_: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith _: UIGestureRecognizer) -> Bool { true }
}
#endif
