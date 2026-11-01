import Foundation

/// Spec v2 operators (testdata/flags/README.md, "Spec v2"); port of go/internal/flageval/ops_v2.go.
/// Instants are unix seconds. The evaluator passes its own number and version coercions so both agree.
enum FlagOpsV2 {
    private static let relRe = try! NSRegularExpression(pattern: #"^-?(\d{1,6})([hdwmy])$"#)
    private static let rfcRe = try! NSRegularExpression(pattern: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$"#)
    private static let dateRe = try! NSRegularExpression(pattern: #"^\d{4}-\d{2}-\d{2}$"#)

    private static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    /// Fixed unit lengths so every evaluator agrees: m = 30 days, y = 365 days.
    static func relativeSeconds(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard matches(relRe, t), let unit = t.last else { return nil }
        let digits = t.dropLast().drop(while: { $0 == "-" })
        let u: Double
        switch unit {
        case "h": u = 3600
        case "d": u = 86_400
        case "w": u = 7 * 86_400
        case "m": u = 30 * 86_400
        default: u = 365 * 86_400
        }
        return Double(digits).map { $0 * u }
    }

    /// Days since 1970-01-01 of a valid civil date (H. Hinnant).
    private static func daysFromCivil(_ y0: Int, _ m: Int, _ d: Int) -> Int? {
        let leap = (y0 % 4 == 0 && y0 % 100 != 0) || y0 % 400 == 0
        let dim = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard (1...12).contains(m), d >= 1, d <= dim[m - 1] else { return nil }
        let y = m <= 2 ? y0 - 1 : y0
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    private static func parseDays(_ s: String) -> Int? {
        let p = s.split(separator: "-", omittingEmptySubsequences: false)
        guard p.count == 3, let y = Int(p[0]), let m = Int(p[1]), let d = Int(p[2]) else { return nil }
        return daysFromCivil(y, m, d)
    }

    static func parseDate(_ s: String) -> Double? {
        guard matches(dateRe, s), let days = parseDays(s) else { return nil }
        return Double(days * 86_400)
    }

    /// RFC 3339 (`Z` or `+hh:mm` offset, optional fraction) as unix seconds.
    static func parseRFC3339(_ s: String) -> Double? {
        guard matches(rfcRe, s), let t = s.firstIndex(of: "T") else { return nil }
        let date = String(s[..<t])
        var rest = String(s[s.index(after: t)...])
        var offset = 0
        if rest.hasSuffix("Z") {
            rest.removeLast()
        } else {
            let tail = rest.suffix(6)  // +hh:mm
            rest = String(rest.dropLast(6))
            let hm = tail.dropFirst().split(separator: ":")
            guard hm.count == 2, let oh = Int(hm[0]), let om = Int(hm[1]) else { return nil }
            offset = (tail.first == "-" ? -1 : 1) * (oh * 3600 + om * 60)
        }
        var frac = 0.0
        if let dot = rest.firstIndex(of: ".") {
            frac = Double("0" + rest[dot...]) ?? 0
            rest = String(rest[..<dot])
        }
        let hms = rest.split(separator: ":")
        guard hms.count == 3, let h = Int(hms[0]), let m = Int(hms[1]), let sec = Int(hms[2]),
              h < 24, m < 60, sec < 60, let days = parseDays(date) else { return nil }
        return Double(days * 86_400 + h * 3600 + m * 60 + sec - offset) + frac
    }

    /// The evaluation clock: `EvalContext.now` (RFC 3339) when it parses, else the wall clock.
    static func parseNow(_ s: String?) -> Double {
        s.flatMap(parseRFC3339) ?? Date().timeIntervalSince1970
    }

    private static func instant(_ v: JSONValue, _ now: Double, rel: Bool) -> Double? {
        switch v {
        case .number(let n): return n
        case .string(let raw):
            let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if rel, let secs = relativeSeconds(s) { return now - secs }
            return parseRFC3339(s) ?? parseDate(s)
        default: return nil
        }
    }

    private static func cmpParts(_ a: [Int], _ b: [Int]) -> Int {
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x < y ? -1 : 1 }
        }
        return 0
    }

    /// Half-open [lo, hi) of a tilde, caret or wildcard value.
    private static func semverRange(_ op: String, _ want: JSONValue?, _ parse: (JSONValue?) -> [Int]?) -> ([Int], [Int])? {
        guard case .string(let raw)? = want else { return nil }
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("v") { s.removeFirst() }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        if op == "semver_wildcard" {
            guard let last = parts.last, ["*", "x", "X"].contains(last) else { return nil }
            if parts.count == 1 { return ([0], [1 << 30]) }
            guard let lo = parse(.string(parts.dropLast().joined(separator: "."))) else { return nil }
            var hi = lo
            hi[hi.count - 1] += 1
            return (lo, hi)
        }
        guard var p = parse(want) else { return nil }
        while p.count < 3 { p.append(0) }
        let hi: [Int]
        if op == "semver_tilde" && parts.count == 1 { hi = [p[0] + 1, 0, 0] }
        else if op == "semver_tilde" || (p[0] == 0 && p[1] > 0) { hi = [p[0], p[1] + 1, 0] }
        else if p[0] > 0 { hi = [p[0] + 1, 0, 0] }
        else { hi = [0, 0, p[2] + 1] }
        return (p, hi)
    }

    /// Applies a v2 operator to a set property. Unknown operators never match.
    static func match(
        op: String, prop: JSONValue, want: JSONValue?, now: Double,
        toFloat: (JSONValue?) -> Double?, parse: (JSONValue?) -> [Int]?, cmp: (JSONValue?, JSONValue?) -> Int?
    ) -> Bool {
        switch op {
        case "icontains", "not_icontains", "starts_with", "not_starts_with", "ends_with", "not_ends_with":
            guard case .string(let s) = prop, case .string(let w)? = want else { return false }
            if op.hasSuffix("icontains") { return s.lowercased().contains(w.lowercased()) == (op == "icontains") }
            if op.hasSuffix("starts_with") { return s.hasPrefix(w) == (op == "starts_with") }
            return s.hasSuffix(w) == (op == "ends_with")
        case "between", "not_between":
            guard let x = toFloat(prop), case .array(let b)? = want, b.count == 2,
                  case .number(let lo) = b[0], case .number(let hi) = b[1] else { return false }
            return (x >= lo && x <= hi) == (op == "between")
        case "is_date_before", "is_date_after":
            guard let p = instant(prop, now, rel: false), let w = want.flatMap({ instant($0, now, rel: true) }) else { return false }
            return op == "is_date_before" ? p < w : p > w
        case "semver_eq", "semver_neq", "semver_gt", "semver_gte", "semver_lt", "semver_lte":
            guard let c = cmp(prop, want) else { return false }
            switch op {
            case "semver_eq": return c == 0
            case "semver_neq": return c != 0
            case "semver_gt": return c > 0
            case "semver_gte": return c >= 0
            case "semver_lt": return c < 0
            default: return c <= 0
            }
        case "semver_tilde", "semver_caret", "semver_wildcard":
            guard let v = parse(prop), let (lo, hi) = semverRange(op, want, parse) else { return false }
            return cmpParts(v, lo) >= 0 && cmpParts(v, hi) < 0
        default: return false
        }
    }
}
