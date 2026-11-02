import Foundation

/// Flags: last cached response, then on-device evaluation (shared vectors), then POST /v1/flags for
/// what needs the server. Reads record `$feature_flag_called` once per (flag, value) and `$exposure`
/// once per flag per session.
final class FlagsService: @unchecked Sendable {
    private let core: Core
    private let config: LucidaConfig
    private let lock = NSLock()
    private var values: [String: FlagValue] = [:]
    private var payloads: [String: JSONValue] = [:]
    private var localValues: [String: FlagValue] = [:]
    private var requestId: String?
    private var loaded = false
    private var seq = 0
    private var called = Set<String>()
    private var exposed = Set<String>()
    private var calledSession = ""
    private var observers: [([String: FlagValue]) -> Void] = []
    private var statusObservers: [(FlagsStatus) -> Void] = []
    private var meta: [String: (reason: String, conditionIndex: Int, local: Bool)] = [:]
    private var personProps: Props = [:]
    private var groupProps: [String: Props] = [:]
    private static let cacheKey = "lc_flags"

    init(core: Core, config: LucidaConfig) {
        self.core = core
        self.config = config
        if let raw = core.gated.get(Self.cacheKey), let c = try? JSONDecoder().decode([String: JSONValue].self, from: Data(raw.utf8)) {
            for (k, v) in c["values"]?.objectValue ?? [:] { if let f = Self.flagValue(v) { values[k] = f } }
            payloads = c["payloads"]?.objectValue ?? [:]
        }
        if config.flagOptions.sendFeatureFlags {
            core.enricher = { [weak self] event in event == "$snapshot" ? [:] : (self?.eventProps() ?? [:]) }
        }
        // Bootstrap wins over the cache until the first reload replaces it.
        if let boot = config.bootstrap {
            for (k, v) in boot.flags { if let f = Self.flagValue(v) { values[k] = f } }
            payloads.merge(boot.payloads) { _, n in n }
        }
    }

    /// Person properties used for flag evaluation only (no `$set` event, so no ingestion race).
    func setPersonProperties(_ p: Props, reload: Bool) async {
        lock.locked { personProps.merge(p) { _, n in n } }
        if reload { await self.reload() }
    }

    func resetPersonProperties(reload: Bool) async {
        lock.locked { personProps = [:] }
        if reload { await self.reload() }
    }

    func setGroupProperties(_ type: String, _ p: Props, reload: Bool) async {
        lock.locked { groupProps[type, default: [:]].merge(p) { _, n in n } }
        if reload { await self.reload() }
    }

    func resetGroupProperties(reload: Bool) async {
        lock.locked { groupProps = [:] }
        if reload { await self.reload() }
    }

    static func flagValue(_ v: JSONValue) -> FlagValue? {
        switch v {
        case .bool(let b): return .bool(b)
        case .string(let s): return .variant(s)
        default: return nil
        }
    }

    func onChange(_ cb: @escaping ([String: FlagValue]) -> Void) {
        lock.lock(); observers.append(cb); let snap = loaded ? values : nil; lock.unlock()
        if let snap { cb(snap) }
    }

    /// Lifecycle notices for providers: `.changed` after a definitions/flags reload, `.stale` / `.error` when a reload fails.
    func onStatus(_ cb: @escaping (FlagsStatus) -> Void) { lock.locked { statusObservers.append(cb) } }

    private func notify(_ s: FlagsStatus) { for o in lock.locked({ statusObservers }) { o(s) } }

    private func apply(_ v: [String: FlagValue], _ p: [String: JSONValue]) {
        lock.lock(); values = v; payloads = p; loaded = true; let obs = observers; lock.unlock()
        for o in obs { o(v) }
    }

    /// Returns true when the server must still be asked.
    private func evalLocal() -> Bool {
        guard !config.localFlags.isEmpty else { return true }
        var ctx = config.localFlagsContext
        ctx.distinctId = core.distinctId
        ctx.groups = core.groups ?? ctx.groups
        let (pp, gp) = lock.locked { (personProps, groupProps) }
        if !pp.isEmpty { ctx.personProperties = (ctx.personProperties ?? [:]).merging(pp) { _, n in n } }
        if !gp.isEmpty { ctx.groupProperties = gp }
        var v: [String: FlagValue] = [:]
        var p: [String: JSONValue] = [:]
        var server = false
        for (k, r) in FlagEvaluator.evaluateAll(config.localFlags, ctx) {
            if r.requiresServer { server = true } else {
                v[k] = r.value
                lock.locked { meta[k] = (r.reason, r.conditionIndex, true) }
                if let pl = r.payload { p[k] = pl }
            }
        }
        lock.lock()
        localValues = v
        let mergedV = values.merging(v) { _, n in n }
        let mergedP = payloads.merging(p) { _, n in n }
        lock.unlock()
        apply(mergedV, mergedP)
        return server
    }

    func reload() async {
        let mine = lock.locked { seq += 1; return seq }
        guard evalLocal(), core.consent.analytics else { return }
        struct Req: Encodable {
            let api_key: String; let distinct_id: String; let groups: [String: String]; let person_properties: Props
            let group_properties: [String: Props]?; let evaluation_contexts: [String]?
            let anon_distinct_id: String?
        }
        let (pp, gp) = lock.locked { (personProps, groupProps) }
        let ctxs = config.flagOptions.evaluationContexts
        guard let body = try? JSONEncoder().encode(Req(
            api_key: config.apiKey, distinct_id: core.distinctId, groups: core.groups ?? [:], person_properties: pp,
            group_properties: gp.isEmpty ? nil : gp, evaluation_contexts: ctxs.isEmpty ? nil : ctxs,
            anon_distinct_id: core.anonDistinctId)) else { return }
        let r = await config.transport.send(HTTPRequest(
            url: config.apiHost.appendingPathComponent("v1/flags"), headers: ["Content-Type": "application/json"], body: body))
        guard (200..<300).contains(r.status), let j = try? JSONDecoder().decode([String: JSONValue].self, from: r.body) else {
            let had = lock.locked { loaded }
            notify(had ? .stale : .error)
            return
        }
        let (stale, local) = lock.locked { (mine != seq, localValues) }
        if stale { return }  // a newer request superseded this one
        var v: [String: FlagValue] = [:]
        var p: [String: JSONValue] = [:]
        for (k, x) in j["flags"]?.objectValue ?? [:] {
            if let o = x.objectValue {
                let raw = o["value"] ?? o["variant"] ?? .bool(o["enabled"]?.boolValue ?? false)
                v[k] = Self.flagValue(raw) ?? .bool(false)
                if let pl = o["payload"] { p[k] = pl }
                lock.locked { meta[k] = (o["reason"]?.stringValue ?? "", Int(o["condition_index"]?.numberValue ?? -1), false) }
            } else if let f = Self.flagValue(x) { v[k] = f }
        }
        lock.locked { requestId = j["request_id"]?.stringValue }
        apply(local.merging(v) { _, n in n }, p)
        notify(.changed)
        let cache: JSONValue = .object([
            "values": .object(v.mapValues(\.json)),
            "payloads": .object(p),
        ])
        if let d = try? JSONEncoder().encode(cache) { core.gated.set(Self.cacheKey, String(decoding: d, as: UTF8.self)) }
    }

    /// Fallback served when the key has no value (missing flag, failed load): no events, nothing was assigned.
    private func fallback(_ key: String) -> FlagValue? { config.fallbacks[key].flatMap(Self.flagValue) }

    func details(_ key: String) -> FlagDetails? {
        let v = get(key)
        let (m, rid, pl) = lock.locked { (meta[key], requestId, payloads[key]) }
        if !lock.locked({ values[key] != nil }) {
            guard let fb = config.fallbacks[key] else { return nil }
            return FlagDetails(value: fb, payload: nil, variant: nil, reason: "fallback", conditionIndex: -1, requestId: nil, evaluatedLocally: false)
        }
        guard let v else { return nil }
        var variant: String?
        if case .variant(let s) = v { variant = s }
        return FlagDetails(value: v.json, payload: pl, variant: variant, reason: m?.reason ?? "", conditionIndex: m?.conditionIndex ?? -1,
                           requestId: rid, evaluatedLocally: m?.local ?? false)
    }

    func get(_ key: String) -> FlagValue? {
        lock.lock(); let v = values[key]; let rid = requestId; lock.unlock()
        guard let v else { return fallback(key) }
        guard config.flagOptions.sendFeatureFlagEvent else { return v }
        let sid = core.sessionId
        lock.lock()
        if sid != calledSession { called.removeAll(); exposed.removeAll(); calledSession = sid }
        let firstExposure = exposed.insert(key).inserted
        let shown = v.json
        let firstCall = called.insert("\(key):\(shown)").inserted
        lock.unlock()
        var extra: Props = ["$feature_flag": .string(key), "$feature_flag_response": shown]
        if let rid { extra["$feature_flag_request_id"] = .string(rid) }
        if firstExposure {
            var e = extra
            if case .variant(let s) = v { e["$feature_flag_variant"] = .string(s) }
            core.capture("$exposure", e)
        }
        if firstCall { core.capture("$feature_flag_called", extra) }
        return v
    }

    /// `$feature/<key>` per flag plus sorted `$active_feature_flags`; empty when no flag is known.
    func eventProps() -> Props {
        let v = lock.locked { values }
        return Self.flagEventProps(v)
    }

    static func flagEventProps(_ v: [String: FlagValue]) -> Props {
        guard !v.isEmpty else { return [:] }
        var out: Props = [:]
        for (k, x) in v { out["$feature/\(k)"] = x.json }
        out["$active_feature_flags"] = .array(v.filter { $0.value.isOn }.keys.sorted().map { .string($0) })
        return out
    }

    func payload(_ key: String) -> JSONValue? { lock.lock(); defer { lock.unlock() }; return payloads[key] }
}
