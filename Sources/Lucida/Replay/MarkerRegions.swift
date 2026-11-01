import Foundation

/// SwiftUI `.lucidaMask()` / `.lucidaUnmask()` drop an invisible `.marker` view behind the content (sensitive = mask,
/// unmask = unmask). SwiftUI content is not part of the UIKit tree, so a marker applies to every node whose frame lies
/// inside the marker's frame, with the same precedence as UIKit markers: mask (sensitive) always wins over unmask.
enum MarkerRegions {
    static func apply(_ root: WireframeNode) -> WireframeNode {
        var masks: [MaskRect] = [], unmasks: [MaskRect] = []
        collect(root, 0, 0, true, &masks, &unmasks)
        if masks.isEmpty && unmasks.isEmpty { return root }
        return mark(root, 0, 0, true, masks, unmasks)
    }

    private static func abs(_ n: WireframeNode, _ ox: Double, _ oy: Double, _ isRoot: Bool) -> MaskRect {
        MaskRect(x: isRoot ? 0 : ox + n.x, y: isRoot ? 0 : oy + n.y, width: n.width, height: n.height)
    }

    private static func collect(_ n: WireframeNode, _ ox: Double, _ oy: Double, _ isRoot: Bool, _ m: inout [MaskRect], _ u: inout [MaskRect]) {
        let r = abs(n, ox, oy, isRoot)
        if n.kind == .marker { if n.sensitive { m.append(r) } else if n.unmask { u.append(r) } }
        for c in n.children { collect(c, r.x, r.y, false, &m, &u) }
    }

    private static func inside(_ r: MaskRect, _ g: MaskRect) -> Bool {
        r.x >= g.x - 0.5 && r.y >= g.y - 0.5 && r.x + r.width <= g.x + g.width + 0.5 && r.y + r.height <= g.y + g.height + 0.5
    }

    private static func mark(_ n: WireframeNode, _ ox: Double, _ oy: Double, _ isRoot: Bool, _ m: [MaskRect], _ u: [MaskRect]) -> WireframeNode {
        let r = abs(n, ox, oy, isRoot)
        var out = n
        if n.kind != .marker {
            if m.contains(where: { inside(r, $0) }) { out.sensitive = true; out.text = nil }
            else if u.contains(where: { inside(r, $0) }) { out.unmask = true }
        }
        out.children = n.children.map { mark($0, r.x, r.y, false, m, u) }
        return out
    }
}
