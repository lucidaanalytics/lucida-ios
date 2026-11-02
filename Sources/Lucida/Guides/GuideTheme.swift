import Foundation

/// Guide appearance on mobile (N-DAP-9, P-M41): the gateway resolves the project theme into `appearance`, so this
/// only picks the light or dark tokens (dark when `theme_mode` is dark, or auto and the device is in dark mode) and
/// re-checks the values the same way the browser SDK does (#hex colors, radius 0...32).
public struct GuideTokens: Equatable, Sendable {
    public var background: String?
    public var text: String?
    public var accent: String?
    public var radius: Double?
    public var font: String?

    /// `#rgb` / `#rrggbb` as 0...1 components, nil for anything else.
    public static func rgb(_ hex: String?) -> (r: Double, g: Double, b: Double)? {
        guard var h = hex, h.hasPrefix("#") else { return nil }
        h.removeFirst()
        if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
        guard h.count == 6, let v = Int(h, radix: 16) else { return nil }
        return (Double((v >> 16) & 0xff) / 255, Double((v >> 8) & 0xff) / 255, Double(v & 0xff) / 255)
    }
}

public enum GuideTheme {
    /// True when the dark variant applies.
    public static func wantsDark(_ a: [String: JSONValue]?, systemDark: Bool) -> Bool {
        guard a?["dark"]?.objectValue?["tokens"]?.objectValue != nil else { return false }
        let mode = a?["theme_mode"]?.stringValue ?? "auto"
        return mode == "dark" || (mode == "auto" && systemDark)
    }

    public static func tokens(_ a: [String: JSONValue]?, systemDark: Bool) -> GuideTokens {
        var t = GuideTokens()
        t.font = a?["font_family"]?.stringValue
        let layers = [a?["tokens"]?.objectValue] + (wantsDark(a, systemDark: systemDark) ? [a?["dark"]?.objectValue?["tokens"]?.objectValue] : [])
        for layer in layers.compactMap({ $0 }) {
            if let c = layer["background"]?.stringValue, GuideTokens.rgb(c) != nil { t.background = c }
            if let c = layer["text"]?.stringValue, GuideTokens.rgb(c) != nil { t.text = c }
            if let c = layer["accent"]?.stringValue, GuideTokens.rgb(c) != nil { t.accent = c }
            if let r = layer["radius"]?.numberValue, (0...32).contains(r) { t.radius = r }
            if let f = layer["font"]?.stringValue, !f.isEmpty { t.font = f }
        }
        return t
    }
}
