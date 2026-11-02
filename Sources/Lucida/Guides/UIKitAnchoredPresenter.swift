#if canImport(UIKit)
import UIKit

/// Anchored guide steps on iOS (N-DAP-10): the step points at the view whose `accessibilityIdentifier` is its
/// `native_id`. The presenter waits for the view (it may appear after a push or a network load), then draws a
/// bubble next to it in a pass-through overlay on the key window and follows the view every 100 ms (scroll,
/// rotation, relayout). A hotspot draws a pulsing dot on the view that opens the bubble. When the view never
/// appears the step shows as an alert and `onMissing` reports `$guide_target_missing`.
extension UIKitGuidePresenter: AnchoredGuidePresenter {
    func presentAnchored(_ guide: MobileGuide, step: Int, buttons: [GuideButton], anchor: GuideAnchor, onMissing: @escaping () -> Void, onAction: @escaping (GuideButton?) -> Void) {
        let deadline = Date().addingTimeInterval(anchor.wait)
        func attempt() {
            guard let w = Self.keyWindow() else { return onAction(nil) }
            if let v = UIKitAnchors.find(anchor.nativeId, in: w) {
                AnchoredStepView.show(guide, step: step, buttons: buttons, anchor: anchor, target: v, in: w, onAction: onAction)
            } else if Date() >= deadline {
                onMissing()
                present(guide, step: step, buttons: buttons, onAction: onAction)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { attempt() }
            }
        }
        attempt()
    }
}

enum UIKitAnchors {
    /// The front-most visible view with this accessibility identifier.
    static func find(_ id: String, in root: UIView) -> UIView? {
        for v in root.subviews.reversed() where !(v is AnchoredStepView) {
            if let hit = find(id, in: v) { return hit }
        }
        return root.accessibilityIdentifier == id && !root.isHidden && root.alpha > 0.01 ? root : nil
    }

    /// The view's frame in window coordinates; nil when it left the window, is hidden or is fully off screen.
    static func frame(_ v: UIView, in w: UIWindow) -> CGRect? {
        guard v.window === w, !v.isHidden else { return nil }
        let r = v.convert(v.bounds, to: w)
        return r.intersects(w.bounds) ? r : nil
    }
}

/// Full-window overlay that only takes touches on its bubble and dot; everything else reaches the app.
final class AnchoredStepView: UIView {
    private let bubble = UIView()
    private let dot = UIButton(type: .custom)
    private weak var target: UIView?
    private let anchor: GuideAnchor
    private var onAction: ((GuideButton?) -> Void)?
    private var timer: Timer?
    private var goneSince: Date?

    static func show(_ g: MobileGuide, step: Int, buttons: [GuideButton], anchor: GuideAnchor, target: UIView, in w: UIWindow, onAction: @escaping (GuideButton?) -> Void) {
        let v = AnchoredStepView(g, step: step, buttons: buttons, anchor: anchor, target: target, traits: w.traitCollection, onAction: onAction)
        v.frame = w.bounds
        v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        w.addSubview(v)
        v.start()
    }

    private init(_ g: MobileGuide, step: Int, buttons: [GuideButton], anchor: GuideAnchor, target: UIView, traits: UITraitCollection, onAction: @escaping (GuideButton?) -> Void) {
        self.anchor = anchor
        self.target = target
        self.onAction = onAction
        super.init(frame: .zero)
        backgroundColor = .clear
        let t = UIKitGuidePresenter.tokens(g, traits)
        let s = g.steps[step]
        bubble.backgroundColor = UIKitGuidePresenter.color(t.background) ?? .systemBackground
        bubble.layer.cornerRadius = CGFloat(t.radius ?? 10)
        bubble.layer.shadowOpacity = 0.25
        bubble.layer.shadowRadius = 8
        bubble.layer.shadowOffset = CGSize(width: 0, height: 2)
        let text = UIKitGuidePresenter.color(t.text) ?? .label
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        // first family of the CSS font list, when the app bundles it
        let family = t.font?.split(separator: ",").first.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"'")) }
        let font = family.flatMap { UIFont(name: $0, size: 15) }
        if let title = s.title ?? (step == 0 ? g.name : nil) {
            let l = UILabel()
            l.text = title  // plain text, never markup
            l.font = font.map { UIFont(descriptor: $0.fontDescriptor.withSymbolicTraits(.traitBold) ?? $0.fontDescriptor, size: 16) } ?? .boldSystemFont(ofSize: 16)
            l.textColor = text
            l.numberOfLines = 0
            l.accessibilityTraits = .header
            stack.addArrangedSubview(l)
        }
        if let body = s.body {
            let l = UILabel()
            l.text = body
            l.font = font ?? .systemFont(ofSize: 15)
            l.textColor = text
            l.numberOfLines = 0
            stack.addArrangedSubview(l)
        }
        let row = UIStackView()
        row.spacing = 8
        row.alignment = .center
        let accent = UIKitGuidePresenter.color(t.accent) ?? tintColor
        for b in buttons {
            let x = UIButton(type: .system)
            x.setTitle(b.label, for: .normal)
            x.tintColor = accent
            x.addAction(UIAction { [weak self] _ in self?.finish(b) }, for: .touchUpInside)
            row.addArrangedSubview(x)
        }
        stack.addArrangedSubview(row)
        bubble.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -12),
        ])
        bubble.accessibilityViewIsModal = false
        addSubview(bubble)
        if anchor.hotspot {
            dot.backgroundColor = UIKitGuidePresenter.color(t.accent) ?? .systemRed
            dot.layer.cornerRadius = 8
            dot.layer.borderWidth = 2
            dot.layer.borderColor = UIColor.white.cgColor
            dot.accessibilityLabel = s.title ?? g.name
            dot.addAction(UIAction { [weak self] _ in self?.openBubble() }, for: .touchUpInside)
            addSubview(dot)
            bubble.isHidden = true
        } else {
            dot.isHidden = true
        }
    }

    required init?(coder: NSCoder) { nil }

    override func point(inside p: CGPoint, with event: UIEvent?) -> Bool {
        (!bubble.isHidden && bubble.frame.contains(p)) || (!dot.isHidden && dot.frame.contains(p))
    }

    private func start() {
        follow()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.follow() }
        if anchor.hotspot {
            if !UIAccessibility.isReduceMotionEnabled {
                let pulse = CABasicAnimation(keyPath: "transform.scale")
                pulse.fromValue = 1
                pulse.toValue = 1.35
                pulse.duration = 0.8
                pulse.autoreverses = true
                pulse.repeatCount = .infinity
                dot.layer.add(pulse, forKey: "pulse")
            }
        } else {
            UIAccessibility.post(notification: .screenChanged, argument: bubble)
        }
    }

    private func openBubble() {
        bubble.isHidden = false
        follow()
        UIAccessibility.post(notification: .screenChanged, argument: bubble)
    }

    /// Re-position on the target; a target gone for 2 s (the screen changed) ends the step as closed.
    private func follow() {
        guard let w = window, let t = target, let r = UIKitAnchors.frame(t, in: w) else {
            bubble.alpha = 0
            dot.alpha = 0
            if goneSince == nil { goneSince = Date() }
            if let g = goneSince, Date().timeIntervalSince(g) > 2 { finish(nil) }
            return
        }
        goneSince = nil
        bubble.alpha = 1
        dot.alpha = 1
        let width = min(300, w.bounds.width - 24)
        let size = bubble.systemLayoutSizeFitting(CGSize(width: width, height: UIView.layoutFittingCompressedSize.height), withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        let safe = w.bounds.inset(by: w.safeAreaInsets)
        bubble.frame = CGRect(origin: GuidePlacement.origin(bubble: size, target: r, bounds: safe, placement: anchor.placement), size: size)
        if anchor.hotspot {
            let c = GuidePlacement.hotspot(target: r, bounds: safe)
            dot.frame = CGRect(x: c.x - 8, y: c.y - 8, width: 16, height: 16)
        }
    }

    private func finish(_ b: GuideButton?) {
        timer?.invalidate()
        timer = nil
        removeFromSuperview()
        let f = onAction
        onAction = nil
        f?(b)
    }
}
#endif
