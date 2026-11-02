import Foundation

/// Privacy passes applied to a walked snapshot before it is encoded (or turned into a screenshot mask plan):
/// P-M17 masked screens (unmask markers stop counting; the caller forces every mask switch on) and P-M46 text
/// patterns. Remote config adds to the local lists, so it can only tighten.
enum ReplayMasking {
    /// Patterns that fail to compile are dropped, never fatal. Built-in email / card / phone patterns are not added on
    /// device: the server masks those again.
    static func compile(_ patterns: [String]) -> [NSRegularExpression] {
        var seen = Set<String>()
        return patterns.filter { !$0.isEmpty && seen.insert($0).inserted }.compactMap { try? NSRegularExpression(pattern: $0) }
    }

    /// Every character inside a match of any pattern becomes `*` (whitespace kept), like `RRWebWireframe.mask`.
    static func maskPatterns(_ text: String, _ patterns: [NSRegularExpression]) -> String {
        let ns = text as NSString
        guard !patterns.isEmpty, ns.length > 0 else { return text }
        var hit = [Bool](repeating: false, count: ns.length)
        for re in patterns {
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) where m.range.location != NSNotFound {
                for i in m.range.location..<NSMaxRange(m.range) { hit[i] = true }
            }
        }
        guard hit.contains(true) else { return text }
        var out = "", i = 0
        for ch in text {
            let n = ch.utf16.count
            out.append(hit[i..<min(i + n, hit.count)].contains(true) && !ch.isWhitespace ? "*" : ch)
            i += n
        }
        return out
    }

    static func matches(_ text: String, _ patterns: [NSRegularExpression]) -> Bool {
        let r = NSRange(location: 0, length: (text as NSString).length)
        return patterns.contains { $0.firstMatch(in: text, range: r) != nil }
    }

    /// `maskScreen` clears every unmask marker. Patterns star matches in wireframe text (masked text is starred
    /// anyway, so applying them to all text is equivalent); in screenshot mode a matching node becomes sensitive, so
    /// its pixels are painted over last, after unmask regions are restored.
    static func apply(_ s: WireframeSnapshot, maskScreen: Bool, patterns: [NSRegularExpression], screenshot: Bool) -> WireframeSnapshot {
        guard maskScreen || !patterns.isEmpty else { return s }
        var out = s
        out.root = apply(s.root, maskScreen: maskScreen, patterns: patterns, screenshot: screenshot)
        return out
    }

    private static func apply(_ n: WireframeNode, maskScreen: Bool, patterns: [NSRegularExpression], screenshot: Bool) -> WireframeNode {
        var out = n
        if maskScreen { out.unmask = false }
        if let t = n.text, !t.isEmpty, !patterns.isEmpty {
            if !screenshot { out.text = maskPatterns(t, patterns) }
            else if matches(t, patterns) { out.sensitive = true; out.text = nil }
        }
        out.children = n.children.map { apply($0, maskScreen: maskScreen, patterns: patterns, screenshot: screenshot) }
        return out
    }
}
