#if canImport(SwiftUI)
import SwiftUI

/// Which way a marker pushes the replay mask.
enum MarkerRole { case mask, unmask }

public extension View {
    /// Never show this view's content in replay (text is dropped; screenshot mode paints it over). Wins over `lucidaUnmask()`.
    func lucidaMask() -> some View { background(LucidaMarker(role: .mask)) }

    /// Show this view's content in replay even when global masks are on. A `lucidaMask()` inside or around it still wins.
    func lucidaUnmask() -> some View { background(LucidaMarker(role: .unmask)) }
}

#if canImport(UIKit)
import UIKit

/// Invisible UIKit view the wireframe walker reads (SwiftUI content itself is not in the UIKit tree); see `MarkerRegions`.
final class LucidaMarkerView: UIView {
    var role: MarkerRole = .mask
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        backgroundColor = .clear
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

private struct LucidaMarker: UIViewRepresentable {
    let role: MarkerRole
    func makeUIView(context: Context) -> LucidaMarkerView {
        let v = LucidaMarkerView()
        v.role = role
        return v
    }
    func updateUIView(_ v: LucidaMarkerView, context: Context) { v.role = role }
}
#else
private struct LucidaMarker: View {
    let role: MarkerRole
    var body: some View { Color.clear }  // no UIKit tree to read on this platform
}
#endif
#endif
