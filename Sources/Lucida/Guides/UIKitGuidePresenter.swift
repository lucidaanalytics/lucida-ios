#if canImport(UIKit)
import UIKit

/// Guide steps as a UIAlertController on the top view controller (banners and announcements as an
/// action sheet). Text is set as plain strings, never markup. VoiceOver reads it like any alert.
final class UIKitGuidePresenter: GuidePresenter {
    func present(_ guide: MobileGuide, step: Int, buttons: [GuideButton], onAction: @escaping (GuideButton?) -> Void) {
        let s = guide.steps[step]
        let sheet = guide.kind == "banner" || guide.kind == "announcement"
        let a = UIAlertController(title: s.title ?? guide.name, message: s.body, preferredStyle: sheet ? .actionSheet : .alert)
        for b in buttons {
            a.addAction(UIAlertAction(title: b.label, style: b.action == "dismiss" ? .cancel : .default) { _ in onAction(b) })
        }
        guard let top = Self.top() else { return onAction(nil) }
        if let pop = a.popoverPresentationController {  // iPad action sheets need an anchor
            pop.sourceView = top.view
            pop.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.maxY, width: 0, height: 0)
        }
        top.present(a, animated: true)
    }

    func open(_ url: URL) { UIApplication.shared.open(url) }

    private static func top() -> UIViewController? {
        let w = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow)
        var vc = w?.rootViewController
        while let next = vc?.presentedViewController { vc = next }
        return vc
    }
}
#endif
