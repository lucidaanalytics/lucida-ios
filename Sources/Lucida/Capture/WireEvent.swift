import Foundation

/// Wire event v1 (docs/plan/03-data-model.md).
public struct WireEvent: Codable, Equatable, Sendable {
    public var uuid: String
    public var event: String
    public var distinctId: String
    public var timestamp: String
    public var properties: Props
    public var set: Props?
    public var setOnce: Props?
    public var unset: [String]?
    public var groups: [String: String]?

    enum CodingKeys: String, CodingKey {
        case uuid, event, timestamp, properties
        case distinctId = "distinct_id"
        case set = "$set"
        case setOnce = "$set_once"
        case unset = "$unset"
        case groups = "$groups"
    }
}

enum ISO8601 {
    static func string(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d)
    }
}
