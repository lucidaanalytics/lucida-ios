import Foundation

/// Field names are the JSON wire format so the shared vectors (testdata/flags) decode directly.
public struct PropertyFilter: Codable, Equatable, Sendable {
    public var type: String  // person|group|cohort|device|geo|app_version|flag
    public var key: String
    public var op: String
    public var value: JSONValue?
    public var groupType: String?

    enum CodingKeys: String, CodingKey { case type, key, op, value, groupType = "group_type" }
}

public struct FlagVariant: Codable, Equatable, Sendable {
    public var key: String
    public var rolloutPct: Double
    public var payload: JSONValue?

    enum CodingKeys: String, CodingKey { case key, payload, rolloutPct = "rollout_pct" }
}

public struct ConditionGroup: Codable, Equatable, Sendable {
    public var filters: [PropertyFilter]?
    public var rolloutPct: Double
    public var variantOverride: String?
    /// Replaces the flag's bucketing unit for this condition's rollout and variant hash (spec v2).
    public var aggregation: FlagAggregation?

    enum CodingKeys: String, CodingKey {
        case filters, aggregation
        case rolloutPct = "rollout_pct"
        case variantOverride = "variant_override"
    }
}

public struct FlagAggregation: Codable, Equatable, Sendable {
    public var kind: String  // person|group|device
    public var groupType: String?

    enum CodingKeys: String, CodingKey { case kind, groupType = "group_type" }
}

public struct FlagPrerequisite: Codable, Equatable, Sendable {
    public var flag: String
    public var value: JSONValue
}

public struct FlagNamespace: Codable, Equatable, Sendable {
    public var salt: String
    public var start: Double
    public var end: Double
    public var total: Double
}

public struct FlagHoldout: Codable, Equatable, Sendable {
    public var salt: String
    public var percentage: Double
}

public struct FlagDefinition: Codable, Equatable, Sendable {
    public var key: String
    public var type: String  // boolean|multivariate|json
    public var active: Bool
    public var killSwitch: Bool?
    public var salt: String
    public var variants: [FlagVariant]?
    public var conditions: [ConditionGroup]
    public var aggregation: FlagAggregation
    public var prerequisites: [FlagPrerequisite]?
    public var payload: JSONValue?
    public var namespace: FlagNamespace?
    public var holdout: FlagHoldout?
    /// Keeps a unit's stored on-assignment (`EvalContext.stickyAssignments`) when allocation changes.
    public var sticky: Bool?
    /// Sealed remote-config payload (json flags); the evaluator ignores it.
    public var encryptedPayload: String?
    /// The first condition whose filters pass decides; a rollout miss there ends evaluation (spec v2).
    public var earlyExit: Bool?
    /// The flag is dropped for requests that declare app contexts and share none with this list.
    public var appContexts: [String]?

    enum CodingKeys: String, CodingKey {
        case key, type, active, salt, variants, conditions, aggregation, prerequisites, payload, namespace, holdout, sticky
        case earlyExit = "early_exit"
        case appContexts = "app_contexts"
        case killSwitch = "kill_switch"
        case encryptedPayload = "encrypted_payload"
    }
}

public struct EvalContext: Codable, Equatable, Sendable {
    public var distinctId: String
    public var bucketingKey: String?
    public var groups: [String: String]?
    public var personProperties: Props?
    public var groupProperties: [String: Props]?
    public var deviceProperties: Props?
    public var geoProperties: Props?
    public var appVersion: String?
    public var deviceId: String?
    /// Flag key -> the unit's stored value (true or a variant key) for sticky flags.
    public var stickyAssignments: [String: JSONValue]?
    /// Evaluation clock (RFC 3339) for relative date operators; nil means the wall clock.
    public var now: String?
    /// App contexts this request declares; flags scoped to none of them are dropped.
    public var appContexts: [String]?

    public init(distinctId: String) { self.distinctId = distinctId }

    /// A context may omit `distinct_id` (a request bucketed only by group or device); it reads as empty.
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        distinctId = try c.decodeIfPresent(String.self, forKey: .distinctId) ?? ""
        bucketingKey = try c.decodeIfPresent(String.self, forKey: .bucketingKey)
        groups = try c.decodeIfPresent([String: String].self, forKey: .groups)
        personProperties = try c.decodeIfPresent(Props.self, forKey: .personProperties)
        groupProperties = try c.decodeIfPresent([String: Props].self, forKey: .groupProperties)
        deviceProperties = try c.decodeIfPresent(Props.self, forKey: .deviceProperties)
        geoProperties = try c.decodeIfPresent(Props.self, forKey: .geoProperties)
        appVersion = try c.decodeIfPresent(String.self, forKey: .appVersion)
        deviceId = try c.decodeIfPresent(String.self, forKey: .deviceId)
        stickyAssignments = try c.decodeIfPresent([String: JSONValue].self, forKey: .stickyAssignments)
        now = try c.decodeIfPresent(String.self, forKey: .now)
        appContexts = try c.decodeIfPresent([String].self, forKey: .appContexts)
    }

    enum CodingKeys: String, CodingKey {
        case groups
        case distinctId = "distinct_id"
        case bucketingKey = "bucketing_key"
        case personProperties = "person_properties"
        case groupProperties = "group_properties"
        case deviceProperties = "device_properties"
        case geoProperties = "geo_properties"
        case appVersion = "app_version"
        case deviceId = "device_id"
        case stickyAssignments = "sticky_assignments"
        case now
        case appContexts = "app_contexts"
    }
}

public enum FlagValue: Equatable, Sendable {
    case bool(Bool)
    case variant(String)

    var json: JSONValue {
        switch self {
        case .bool(let b): return .bool(b)
        case .variant(let s): return .string(s)
        }
    }

    public var isOn: Bool { if case .bool(false) = self { return false } else { return true } }
}

public struct EvalResult: Equatable, Sendable {
    public var value: FlagValue
    public var variant: String?
    public var payload: JSONValue?
    public var reason: String
    /// -1 when no condition decided the result.
    public var conditionIndex: Int

    var requiresServer: Bool { reason == "requires_server" }
}
