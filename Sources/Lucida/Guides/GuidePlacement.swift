import Foundation

/// Where an anchored guide bubble goes (N-DAP-10), shared by the presenters and unit-testable without UIKit:
/// below the target when it fits (or `placement` is not "top"), else above; horizontally centred on the target and
/// clamped to the `margin` inside `bounds`.
public enum GuidePlacement {
    public static func origin(bubble size: CGSize, target r: CGRect, bounds: CGRect, placement: String?, margin: CGFloat = 12, gap: CGFloat = 8) -> CGPoint {
        let below = CGPoint(x: r.midX - size.width / 2, y: r.maxY + gap)
        let above = CGPoint(x: below.x, y: r.minY - gap - size.height)
        let fitsBelow = below.y + size.height <= bounds.maxY - margin
        let fitsAbove = above.y >= bounds.minY + margin
        var p = placement == "top" ? (fitsAbove || !fitsBelow ? above : below) : (fitsBelow || !fitsAbove ? below : above)
        p.x = min(max(p.x, bounds.minX + margin), bounds.maxX - margin - size.width)
        p.y = min(max(p.y, bounds.minY + margin), bounds.maxY - margin - size.height)
        return p
    }

    /// Hotspot dot centre: the target's top-right corner, kept inside `bounds`.
    public static func hotspot(target r: CGRect, bounds: CGRect, size: CGFloat = 16) -> CGPoint {
        CGPoint(x: min(max(r.maxX - size / 2, bounds.minX + size / 2), bounds.maxX - size / 2), y: min(max(r.minY + size / 2, bounds.minY + size / 2), bounds.maxY - size / 2))
    }
}
