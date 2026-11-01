#if canImport(UIKit)
import UIKit

/// Screenshot adapter: draws the key window, restores `unmask` regions over `mask` regions, paints `sensitive` regions
/// last, and only then encodes JPEG, so masked pixels never exist in the output.
public final class UIKitScreenshot: ScreenshotSource {
    public init() {}

    public func screenshot(plan: ScreenshotMaskPlan, quality: Double) -> ScreenshotFrame? {
        var result: ScreenshotFrame?
        let work = {
            guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows).first(where: \.isKeyWindow)
            else { return }
            let b = window.bounds
            let fmt = UIGraphicsImageRendererFormat()
            fmt.scale = 1  // replay does not need retina pixels
            let raw = UIGraphicsImageRenderer(bounds: b, format: fmt).image { _ in window.drawHierarchy(in: b, afterScreenUpdates: false) }
            let masked = UIGraphicsImageRenderer(bounds: b, format: fmt).image { ctx in
                raw.draw(in: b)
                UIColor.black.setFill()
                for r in plan.mask { ctx.fill(r.cgRect) }
                for r in plan.unmask {
                    ctx.cgContext.saveGState()
                    ctx.cgContext.clip(to: r.cgRect)
                    raw.draw(in: b)
                    ctx.cgContext.restoreGState()
                }
                UIColor.black.setFill()
                for r in plan.sensitive { ctx.fill(r.cgRect) }
            }
            if let jpeg = masked.jpegData(compressionQuality: CGFloat(quality)) { result = ScreenshotFrame(jpeg: jpeg, width: b.width, height: b.height) }
        }
        if Thread.isMainThread { work() } else { DispatchQueue.main.sync(execute: work) }
        return result
    }
}

private extension MaskRect {
    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}
#endif
