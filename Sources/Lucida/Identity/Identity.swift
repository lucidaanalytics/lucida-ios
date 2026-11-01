import Foundation

/// Anonymous UUIDv7 until `identify`; persisted through the (gated) store.
final class Identity {
    private struct State: Codable { var distinct_id: String; var anon_id: String; var identified: Bool
        /// True once an `$identify` this device sent linked the anonymous id; nil in states saved before this field.
        var anon_linked: Bool? = nil }
    private var s: State
    private let store: KeyValueStore
    private let clock: LucidaClock
    private static let key = "lc_identity"

    private let newId: () -> String
    private let reuseAnonymousId: Bool

    init(store: KeyValueStore, clock: LucidaClock, newId: (() -> String)? = nil, bootstrap: Bootstrap? = nil, reuseAnonymousId: Bool = false) {
        self.store = store
        self.clock = clock
        self.reuseAnonymousId = reuseAnonymousId
        self.newId = newId ?? { UUIDv7.make(nowMs: UInt64(clock.now().timeIntervalSince1970 * 1000)) }
        if let raw = store.get(Self.key), let p = try? JSONDecoder().decode(State.self, from: Data(raw.utf8)), !p.distinct_id.isEmpty {
            s = p
        } else if let boot = bootstrap?.distinctId, !boot.isEmpty {
            let identified = bootstrap?.isIdentified ?? false
            s = State(distinct_id: boot, anon_id: identified ? self.newId() : boot, identified: identified, anon_linked: false)
            save()
        } else {
            let id = self.newId()
            s = State(distinct_id: id, anon_id: id, identified: false)
            save()
        }
    }

    /// The device's anonymous id; survives `reset()` only with `reuseAnonymousId`.
    var anonymousId: String { s.anon_id }

    /// Pre-identify id, sent as `anon_distinct_id` to /v1/flags so continuity flags keep their bucket (LC-FLG-34).
    var priorAnonId: String? { s.identified && (s.anon_linked ?? true) && !s.anon_id.isEmpty && s.anon_id != s.distinct_id ? s.anon_id : nil }

    private func save() {
        if let d = try? JSONEncoder().encode(s) { store.set(Self.key, String(decoding: d, as: UTF8.self)) }
    }

    var distinctId: String { s.distinct_id }

    /// Returns the previous anonymous id to link (`$anon_distinct_id`) when an `$identify` event is due.
    /// An already-identified user switching ids sends `$identify` without the anon link.
    func identify(_ id: String) -> (event: Bool, anon: String?) {
        if id.isEmpty || id == s.distinct_id {
            if !id.isEmpty && !s.identified { s.identified = true; save() }
            return (false, nil)
        }
        let prev = s.distinct_id
        let wasAnon = !s.identified
        s.distinct_id = id
        s.identified = true
        if wasAnon { s.anon_linked = true }
        save()
        return (true, wasAnon ? prev : nil)
    }

    func reset() {
        let id = reuseAnonymousId ? s.anon_id : newId()
        s = State(distinct_id: id, anon_id: id, identified: false, anon_linked: false)
        save()
    }
}
