import Foundation

/// The schedule, frequency and holdout rules on mobile (G241). The gateway already decides them
/// for this person (recurrence in the zone sent as `tz`, frequency from the views synced to the
/// guide-state store, A/B variant and holdout from the distinct id); these local checks keep a
/// guide fetched earlier from showing after its hours or over its cap on this device.
enum GuideRules {
    static let viewsKey = "lc_guide_views"
    static let heldKey = "lc_guide_held"
    /// Views kept per guide (the browser SDK keeps the newest 50 too).
    static let maxViews = 50

    /// Inside `schedule` (RFC 3339 window, weekdays 0 = Sunday, hours [from, to) in `timezone`
    /// or the device zone).
    static func scheduleOk(_ s: [String: JSONValue]?, now: Date) -> Bool {
        guard let s else { return true }
        if let a = s["start"]?.stringValue, let t = date(a), now < t { return false }
        if let b = s["end"]?.stringValue, let t = date(b), now >= t { return false }
        var cal = Calendar(identifier: .gregorian)
        if let z = s["timezone"]?.stringValue, let tz = TimeZone(identifier: z) { cal.timeZone = tz }
        let day = cal.component(.weekday, from: now) - 1  // Calendar: 1 = Sunday
        if let days = s["days"]?.arrayValue, !days.isEmpty, !days.contains(where: { $0.numberValue == Double(day) }) { return false }
        guard let h = s["hours"]?.objectValue else { return true }
        let hour = Double(cal.component(.hour, from: now))
        return hour >= (h["from"]?.numberValue ?? 0) && hour < (h["to"]?.numberValue ?? 24)
    }

    /// RFC 3339, with or without fractions of a second (the web editor writes milliseconds).
    static func date(_ s: String) -> Date? {
        let iso = ISO8601DateFormatter()
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return iso.date(from: s)
    }

    /// Under `frequency` (`max_views` per rolling `per_days`, lifetime when omitted).
    static func frequencyOk(_ f: [String: JSONValue], views: [Double], now: Date) -> Bool {
        let ms = now.timeIntervalSince1970 * 1000
        let since = f["per_days"]?.numberValue.map { ms - $0 * 86_400_000 } ?? 0
        return views.filter { $0 >= since }.count < Int(f["max_views"]?.numberValue ?? 1)
    }

    /// `views` with `now` appended, newest `maxViews` kept.
    static func adding(_ views: [Double], _ now: Date) -> [Double] {
        Array((views + [now.timeIntervalSince1970 * 1000]).suffix(maxViews))
    }

    /// Merges this device's views into the stored guide state (other keys kept untouched).
    static func merged(_ state: [String: JSONValue], views: [String: [Double]]) -> [String: JSONValue] {
        var out = state
        var stored = state[viewsKey]?.objectValue ?? [:]
        for (id, v) in views {
            let old = stored[id]?.arrayValue?.compactMap(\.numberValue) ?? []
            stored[id] = .array(Array(Set(old + v)).sorted().suffix(maxViews).map { .number($0) })
        }
        out[viewsKey] = .object(stored)
        return out
    }
}
