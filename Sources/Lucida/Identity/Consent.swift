import Foundation

public enum ConsentMode: String, Sendable { case optIn, optOut }

public struct ConsentState: Codable, Equatable, Sendable {
    public var analytics: Bool
    public var replay: Bool
    public var marketing: Bool

    public init(analytics: Bool, replay: Bool, marketing: Bool) {
        self.analytics = analytics
        self.replay = replay
        self.marketing = marketing
    }
}

/// opt-in: every category starts denied and nothing is persisted until `set` is called.
/// opt-out: categories start granted unless a stored decision says otherwise.
final class Consent {
    let mode: ConsentMode
    let queueBeforeConsent: Bool
    private(set) var state: ConsentState
    private let store: KeyValueStore
    private static let key = "lc_consent"

    init(mode: ConsentMode, queueBeforeConsent: Bool, store: KeyValueStore) {
        self.mode = mode
        self.queueBeforeConsent = queueBeforeConsent
        self.store = store
        let open = mode == .optOut
        state = ConsentState(analytics: open, replay: open, marketing: open)
        // Reading is allowed; only writes are gated.
        if let raw = store.get(Self.key), let s = try? JSONDecoder().decode(ConsentState.self, from: Data(raw.utf8)) {
            state = s
        }
    }

    var analytics: Bool { state.analytics }
    var replay: Bool { state.replay }
    /// True while an opt-in app is still waiting for an analytics decision.
    var pending: Bool { mode == .optIn && !state.analytics }

    func set(analytics: Bool? = nil, replay: Bool? = nil, marketing: Bool? = nil) {
        if let a = analytics { state.analytics = a }
        if let r = replay { state.replay = r }
        if let m = marketing { state.marketing = m }
        if let d = try? JSONEncoder().encode(state) { store.set(Self.key, String(decoding: d, as: UTF8.self)) }
    }
}

/// Keeps writes in memory until `allowed()` is true; guarantees no storage before consent.
final class GatedStore: KeyValueStore, @unchecked Sendable {
    private let inner: KeyValueStore
    private let allowed: () -> Bool
    private var mem: [String: String?] = [:]
    private let lock = NSLock()

    init(_ inner: KeyValueStore, allowed: @escaping () -> Bool) {
        self.inner = inner
        self.allowed = allowed
    }

    func get(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        if let v = mem[key] { return v }
        return inner.get(key)
    }

    func set(_ key: String, _ value: String) {
        if allowed() { inner.set(key, value); lock.lock(); mem[key] = nil; lock.unlock() }
        else { lock.lock(); mem[key] = .some(value); lock.unlock() }
    }

    func remove(_ key: String) {
        if allowed() { inner.remove(key); lock.lock(); mem[key] = nil; lock.unlock() }
        else { lock.lock(); mem[key] = .some(nil); lock.unlock() }
    }

    func flushBuffered() {
        lock.lock(); let pending = mem; mem = [:]; lock.unlock()
        for (k, v) in pending { if let v { inner.set(k, v) } else { inner.remove(k) } }
    }

    func discardBuffered() { lock.lock(); mem = [:]; lock.unlock() }
}
