import Foundation

/// Identity and flag values known before the first network response (server-rendered, or from a previous launch).
public struct Bootstrap: Sendable {
    public var distinctId: String?
    public var isIdentified = false
    public var flags: [String: JSONValue] = [:]
    public var payloads: [String: JSONValue] = [:]
    public init(distinctId: String? = nil, isIdentified: Bool = false, flags: [String: JSONValue] = [:], payloads: [String: JSONValue] = [:]) {
        self.distinctId = distinctId; self.isIdentified = isIdentified; self.flags = flags; self.payloads = payloads
    }
}

public struct FlagOptions: Sendable {
    /// Emit `$feature_flag_called` / `$exposure` when a flag is read.
    public var sendFeatureFlagEvent = true
    /// false: flags are not loaded at launch or on identity changes until `reloadFlags()` is called.
    public var preload = true
    /// Environment tags sent with the flag request; the server returns only flags whose tags match.
    public var evaluationContexts: [String] = []
    /// Attach `$feature/<key>` and `$active_feature_flags` to every event (never `$snapshot`); the caller's properties win.
    public var sendFeatureFlags = true
    public init() {}
}

public enum DataMode: Sendable { case any, wifi }

/// Port: is the current network path acceptable for flushing under `DataMode.wifi`? Adapter: `NWPathNetworkPolicy`.
public protocol NetworkPolicy: Sendable {
    var isUnmetered: Bool { get }
}

/// Port: at-rest encryption for the persisted queue (plug in CryptoKit / Keychain-backed keys).
public protocol QueueCipher: Sendable {
    func encrypt(_ plain: String) -> String
    /// nil when the value cannot be decrypted (key rotated, corrupt): the queue then starts empty.
    func decrypt(_ cipher: String) -> String?
}

/// Decorator: values under `keys` (or a key starting with one of `prefixes`) are stored encrypted, everything else passes through.
final class EncryptedStore: KeyValueStore, @unchecked Sendable {
    private let inner: KeyValueStore
    private let cipher: QueueCipher
    private let keys: Set<String>
    private let prefixes: [String]

    init(_ inner: KeyValueStore, cipher: QueueCipher, keys: Set<String>, prefixes: [String] = []) {
        self.inner = inner; self.cipher = cipher; self.keys = keys; self.prefixes = prefixes
    }

    private func covers(_ key: String) -> Bool { keys.contains(key) || prefixes.contains { key.hasPrefix($0) } }
    func get(_ key: String) -> String? { inner.get(key).flatMap { covers(key) ? cipher.decrypt($0) : $0 } }
    func set(_ key: String, _ value: String) { inner.set(key, covers(key) ? cipher.encrypt(value) : value) }
    func remove(_ key: String) { inner.remove(key) }
}

/// Adds `X-Lucida-Distinct-Id` / `X-Lucida-Session-Id` to requests for your own backend hosts so server events
/// join this device's session. `hosts` entries match exactly, or as a suffix when they start with a dot
/// (`.example.com`). Never added for the Lucida api host, and only while analytics consent is granted.
/// Servers must treat these headers as client-controlled, never as authentication.
/// The same requests carry W3C `baggage: lucida.session_id=<id>` (merged into the app's own baggage) so Watchtower links
/// its spans, network timings and logs to this session: the Watchtower seam, Lucida captures no network or log data.
struct TracingHeaders {
    let hosts: [String]
    let apiHost: String?
    let consent: () -> Bool
    let ids: () -> (distinctId: String, sessionId: String)

    /// `baggage` is the request's existing `baggage` value, kept (minus a stale Lucida entry) in the returned one.
    func headers(for url: URL, baggage: String? = nil) -> [String: String] {
        guard let host = url.host?.lowercased(), !hosts.isEmpty, host != apiHost, consent(),
              hosts.contains(where: { h in let x = h.lowercased(); return x.hasPrefix(".") ? host.hasSuffix(x) : host == x })
        else { return [:] }
        let i = ids()
        return ["X-Lucida-Distinct-Id": i.distinctId, "X-Lucida-Session-Id": i.sessionId, "baggage": Self.withBaggage(baggage, i.sessionId)]
    }

    /// `lucida.session_id=<id>` appended to `existing` W3C baggage, replacing a stale Lucida entry.
    static func withBaggage(_ existing: String?, _ sessionId: String) -> String {
        let kept = (existing ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("lucida.session_id=") }
        return (kept + ["lucida.session_id=\(sessionId)"]).joined(separator: ",")
    }
}
