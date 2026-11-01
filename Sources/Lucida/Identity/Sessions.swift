import Foundation

/// UUIDv7 session rotated after 30 min idle or 24 h total. Window id is per process launch.
final class SessionManager {
    private struct State: Codable { var id: String; var start: Double; var last: Double }
    let windowId: String
    private let store: KeyValueStore
    private let clock: LucidaClock
    private let idle: TimeInterval
    private let maxAge: TimeInterval
    private static let key = "lc_session"

    init(store: KeyValueStore, clock: LucidaClock, idle: TimeInterval = 30 * 60, maxAge: TimeInterval = 24 * 3600) {
        self.store = store
        self.clock = clock
        self.idle = idle
        self.maxAge = maxAge
        windowId = UUIDv7.make(nowMs: UInt64(clock.now().timeIntervalSince1970 * 1000))
    }

    /// Records activity and returns the current session id, rotating when needed.
    @discardableResult
    func touch() -> (sessionId: String, isNew: Bool) {
        let now = clock.now().timeIntervalSince1970
        var cur = store.get(Self.key).flatMap { try? JSONDecoder().decode(State.self, from: Data($0.utf8)) }
        let isNew = cur == nil || now - cur!.last > idle || now - cur!.start > maxAge
        if isNew || cur == nil { cur = State(id: UUIDv7.make(nowMs: UInt64(now * 1000)), start: now, last: now) }
        cur!.last = now
        if let d = try? JSONEncoder().encode(cur!) { store.set(Self.key, String(decoding: d, as: UTF8.self)) }
        return (cur!.id, isNew)
    }

    func reset() { store.remove(Self.key) }
}

/// Super properties merged into every event; persisted.
final class SuperProps {
    private var p: Props
    private let store: KeyValueStore
    private static let key = "lc_props"

    init(store: KeyValueStore) {
        self.store = store
        p = store.get(Self.key).flatMap { try? JSONDecoder().decode(Props.self, from: Data($0.utf8)) } ?? [:]
    }

    private func save() {
        if let d = try? JSONEncoder().encode(p) { store.set(Self.key, String(decoding: d, as: UTF8.self)) }
    }

    var all: Props { p }
    func register(_ props: Props) { p.merge(props) { _, new in new }; save() }
    func registerOnce(_ props: Props) { p.merge(props) { old, _ in old }; save() }
    func unregister(_ key: String) { p[key] = nil; save() }
    func clear() { p = [:]; store.remove(Self.key) }
}

/// Group memberships (type -> key) attached to every event as `$groups`.
final class Groups {
    private var g: [String: String]
    private let store: KeyValueStore
    private static let key = "lc_groups"

    init(store: KeyValueStore) {
        self.store = store
        g = store.get(Self.key).flatMap { try? JSONDecoder().decode([String: String].self, from: Data($0.utf8)) } ?? [:]
    }

    func set(_ type: String, _ key: String) {
        g[type] = key
        if let d = try? JSONEncoder().encode(g) { store.set(Self.key, String(decoding: d, as: UTF8.self)) }
    }

    var all: [String: String]? { g.isEmpty ? nil : g }
    func clear() { g = [:]; store.remove(Self.key) }
}
