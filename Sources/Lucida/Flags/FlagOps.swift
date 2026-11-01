import Foundation

/// Operator semantics: port of go/internal/flageval/ops.go (the reference) via packages/sdk-core.
enum FlagOps {
    private static let numRe = try! NSRegularExpression(pattern: #"^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$"#)
    private static let intRe = try! NSRegularExpression(pattern: #"^[+-]?\d+$"#)

    private static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    static func toFloat(_ v: JSONValue?) -> Double? {
        switch v {
        case .number(let n): return n
        case .string(let s):
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return matches(numRe, t) ? Double(t) : nil
        default: return nil
        }
    }

    /// Two numbers compare numerically; a number never equals a string; containers never equal.
    private static func equal(_ a: JSONValue?, _ b: JSONValue?) -> Bool {
        guard let a, let b else { return false }
        switch (a, b) {
        case (.number(let x), .number(let y)): return x == y
        case (.string(let x), .string(let y)): return x == y
        case (.bool(let x), .bool(let y)): return x == y
        case (.null, .null): return true
        default: return false
        }
    }

    static func parseVersion(_ v: JSONValue?) -> [Int]? {
        guard case .string(let raw)? = v else { return nil }
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("v") { s.removeFirst() }
        if let i = s.firstIndex(where: { $0 == "-" || $0 == "+" }) { s = String(s[..<i]) }
        var out: [Int] = []
        for p in s.split(separator: ".", omittingEmptySubsequences: false) {
            guard matches(intRe, String(p)), let n = Int(p), n >= 0 else { return nil }
            out.append(n)
        }
        return out
    }

    static func cmpVersion(_ a: JSONValue?, _ b: JSONValue?) -> Int? {
        guard let pa = parseVersion(a), let pb = parseVersion(b) else { return nil }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x < y ? -1 : 1 }
        }
        return 0
    }

    /// Missing/null properties match only `is_not_set`; every other op (even negations) is false.
    static func match(op: String, prop: JSONValue?, present: Bool, want: JSONValue?, semver: Bool, now: Double? = nil) -> Bool {
        let isSet = present && prop != nil && !(prop?.isNull ?? true)
        if op == "is_set" { return isSet }
        if op == "is_not_set" { return !isSet }
        guard isSet, let prop else { return false }
        switch op {
        case "eq", "neq":
            let eq: Bool
            if semver {
                guard let c = cmpVersion(prop, want) else { return false }
                eq = c == 0
            } else { eq = equal(prop, want) }
            return eq == (op == "eq")
        case "contains", "ncontains", "regex", "nregex":
            guard case .string(let p) = prop, case .string(let w)? = want else { return false }
            if op == "contains" || op == "ncontains" { return p.contains(w) == (op == "contains") }
            guard let re = try? NSRegularExpression(pattern: w) else { return false }  // bad pattern never matches
            return matches(re, p) == (op == "regex")
        case "gt", "gte", "lt", "lte":
            let c: Int?
            if semver { c = cmpVersion(prop, want) }
            else if let a = toFloat(prop), let b = toFloat(want) { c = a < b ? -1 : (a > b ? 1 : 0) }
            else { c = nil }
            guard let c else { return false }
            switch op {
            case "gt": return c > 0
            case "gte": return c >= 0
            case "lt": return c < 0
            default: return c <= 0
            }
        case "in", "not_in":
            guard case .array(let list)? = want else { return false }
            return list.contains { equal(prop, $0) } == (op == "in")
        default:
            return FlagOpsV2.match(op: op, prop: prop, want: want, now: now ?? Date().timeIntervalSince1970,
                                   toFloat: toFloat, parse: parseVersion, cmp: cmpVersion)
        }
    }
}
