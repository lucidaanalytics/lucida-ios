#if canImport(UIKit)
import UIKit

/// Guide steps as a UIAlertController on the top view controller (banners and announcements as an
/// action sheet). Text is set as plain strings, never markup. VoiceOver reads it like any alert.
/// The guide's resolved accent token tints the buttons; a carousel shows its slide position.
/// Anchored steps (tooltip, hotspot, tour with `native_id`) are drawn by `presentAnchored`.
final class UIKitGuidePresenter: GuidePresenter {
    func present(_ guide: MobileGuide, step: Int, buttons: [GuideButton], onAction: @escaping (GuideButton?) -> Void) {
        let s = guide.steps[step]
        let sheet = guide.kind == "banner" || guide.kind == "announcement"
        let pager = guide.kind == "carousel" ? Self.dots(step, guide.steps.count) : nil
        let message = [s.body, pager].compactMap { $0 }.joined(separator: "\n\n")
        let a = UIAlertController(title: s.title ?? guide.name, message: message.isEmpty ? nil : message, preferredStyle: sheet ? .actionSheet : .alert)
        for b in buttons {
            a.addAction(UIAlertAction(title: b.label, style: b.action == "dismiss" ? .cancel : .default) { _ in onAction(b) })
        }
        guard let top = Self.top() else { return onAction(nil) }
        if let accent = Self.color(Self.tokens(guide, top.traitCollection).accent) { a.view.tintColor = accent }
        if let pop = a.popoverPresentationController {  // iPad action sheets need an anchor
            pop.sourceView = top.view
            pop.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.maxY, width: 0, height: 0)
        }
        top.present(a, animated: true)
    }

    func open(_ url: URL) { UIApplication.shared.open(url) }

    /// Slide position as dots, e.g. "● ○ ○" (VoiceOver reads the alert text; the title carries the slide).
    static func dots(_ i: Int, _ n: Int) -> String {
        (0..<n).map { $0 == i ? "\u{25CF}" : "\u{25CB}" }.joined(separator: " ")
    }

    static func tokens(_ g: MobileGuide, _ traits: UITraitCollection) -> GuideTokens {
        GuideTheme.tokens(g.appearance, systemDark: traits.userInterfaceStyle == .dark)
    }

    static func color(_ hex: String?) -> UIColor? {
        GuideTokens.rgb(hex).map { UIColor(red: $0.r, green: $0.g, blue: $0.b, alpha: 1) }
    }

    static func keyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow)
    }

    private static func top() -> UIViewController? {
        var vc = keyWindow()?.rootViewController
        while let next = vc?.presentedViewController { vc = next }
        return vc
    }
}
#endif
