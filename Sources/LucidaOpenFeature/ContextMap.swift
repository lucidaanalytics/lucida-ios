import Foundation
import Lucida
import OpenFeature

/// OpenFeature `Value` <-> Lucida `JSONValue`, and the evaluation context split into identity, groups and person properties.
enum ContextMap {
    static func json(_ v: Value) -> JSONValue {
        switch v {
        case .boolean(let b): return .bool(b)
        case .string(let s): return .string(s)
        case .integer(let i): return .number(Double(i))
        case .double(let d): return .number(d)
        case .date(let d): return .string(ISO8601DateFormatter().string(from: d))
        case .list(let l): return .array(l.map(json))
        case .structure(let m): return .object(m.mapValues(json))
        case .null: return .null
        }
    }

    static func value(_ j: JSONValue) -> Value {
        switch j {
        case .null: return .null
        case .bool(let b): return .boolean(b)
        case .number(let n): return .double(n)
        case .string(let s): return .string(s)
        case .array(let a): return .list(a.map(value))
        case .object(let o): return .structure(o.mapValues(value))
        }
    }

    struct Split {
        var targetingKey: String
        var groups: [String: String] = [:]
        var groupProperties: [String: Props] = [:]
        var personProperties: Props = [:]
    }

    /// `groups` (type -> key) and `groupProperties` (type -> map) are reserved; every other attribute is a person property.
    static func split(_ ctx: EvaluationContext?) -> Split {
        var out = Split(targetingKey: ctx?.getTargetingKey() ?? "")
        for (k, v) in ctx?.asMap() ?? [:] {
            switch (k, v) {
            case ("groups", .structure(let m)):
                for (t, key) in m { if case .string(let s) = key { out.groups[t] = s } }
            case ("groupProperties", .structure(let m)):
                for (t, props) in m { if case .structure(let p) = props { out.groupProperties[t] = p.mapValues(json) } }
            default:
                out.personProperties[k] = json(v)
            }
        }
        return out
    }
}
