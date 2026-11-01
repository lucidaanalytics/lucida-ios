import Foundation

public struct MaskRect: Sendable, Equatable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) { self.x = x; self.y = y; self.width = width; self.height = height }
}

/// Paint order for a screenshot: `mask` first, then `unmask` regions are restored from the original pixels,
/// then `sensitive` regions are painted last so they always win.
public struct ScreenshotMaskPlan: Sendable, Equatable {
    public var mask: [MaskRect] = []
    public var unmask: [MaskRect] = []
    public var sensitive: [MaskRect] = []
    public init() {}
}

/// One screenshot already masked: JPEG bytes and the window size in points.
public struct ScreenshotFrame: Sendable {
    public var jpeg: Data
    public var width: Double, height: Double
    public init(jpeg: Data, width: Double, height: Double) { self.jpeg = jpeg; self.width = width; self.height = height }
}

/// Port: draws the window with `plan` applied BEFORE encoding, so masked pixels never exist in the output.
public protocol ScreenshotSource: AnyObject {
    func screenshot(plan: ScreenshotMaskPlan, quality: Double) -> ScreenshotFrame?
}

/// Derives the plan from a wireframe with the same rules the wireframe encoder uses for text.
enum ScreenshotMasks {
    static func plan(_ s: WireframeSnapshot, maskText: Bool, maskInputs: Bool, maskImages: Bool) -> ScreenshotMaskPlan {
        var p = ScreenshotMaskPlan()
        func walk(_ n: WireframeNode, ox: Double, oy: Double, isRoot: Bool) {
            let left = isRoot ? 0 : ox + n.x, top = isRoot ? 0 : oy + n.y
            let r = MaskRect(x: left, y: top, width: n.width, height: n.height)
            if n.sensitive {
                p.sensitive.append(r)
            } else {
                let hide: Bool
                switch n.kind {
                case .input: hide = maskInputs
                case .image: hide = maskImages
                default: hide = maskText && (!(n.text ?? "").isEmpty || n.opaque)
                }
                if n.unmask { p.unmask.append(r) } else if hide { p.mask.append(r) }
            }
            for c in n.children { walk(c, ox: left, oy: top, isRoot: false) }
        }
        walk(s.root, ox: 0, oy: 0, isRoot: true)
        return p
    }
}
