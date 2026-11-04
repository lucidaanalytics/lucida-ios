import Foundation

/// Platform-agnostic client core: identity, sessions, consent gating, super props, groups, queue.
/// Not thread-safe by itself; `LucidaClient` serialises access.
final class Core {
    let consent: Consent
    let identity: Identity
    let session: SessionManager
    let queue: EventQueue
    /// Consent-gated store for everything except the queue (which only ever sees consented events).
    let gated: GatedStore
    private let props: SuperProps
    private let groupState: Groups
    private let clock: LucidaClock
    private let config: LucidaConfig
    private let person: PersonMode
    private let hooks: HookChain
    let debugLog: (String) -> Void
    let tracing: TracingHeaders
    private var pre: [WireEvent] = []
    /// Observers of every event that passed the consent gate (flags, replay markers).
    var onCaptured: [(WireEvent) -> Void] = []
    var onChange: [(Change) -> Void] = []
    /// Extra properties for an event name (flag values); super properties and the caller's own win.
    var enricher: ((String) -> Props)?

    enum Change { case identify, reset, group, consent }

    init(config: LucidaConfig, debugLog: @escaping (String) -> Void) {
        self.config = config
        clock = config.clock
        consent = Consent(mode: config.consentMode, queueBeforeConsent: config.queueBeforeConsent, store: config.store)
        let c = consent
        gated = GatedStore(config.store) { c.analytics }
        identity = Identity(store: gated, clock: clock, newId: config.anonymousIdProvider, bootstrap: config.bootstrap, reuseAnonymousId: config.reuseAnonymousId)
        session = SessionManager(store: gated, clock: clock, idle: config.sessionIdleTimeout, maxAge: config.sessionMaxAge)
        person = PersonMode(store: gated, mode: config.personProfiles)
        hooks = HookChain(hooks: config.beforeSend, log: debugLog)
        self.debugLog = debugLog
        props = SuperProps(store: gated)
        groupState = Groups(store: gated)
        queue = EventQueue(
            store: config.queueCipher.map { EncryptedStore(config.store, cipher: $0, keys: [EventQueue.key]) } ?? config.store,
            transport: config.transport, host: config.apiHost, apiKey: config.apiKey,
            options: QueueOptions(
                flushAt: config.flushAt, flushInterval: config.flushInterval, maxQueueSize: config.maxQueueSize,
                maxRetries: config.maxRetries, maxBatchSize: config.maxBatchSize, retryBaseDelay: config.retryBaseDelay,
                networkAllowed: Self.networkGate(config)),
            clock: clock, onDrop: { debugLog("dropped \($0.count) events: \($1)") }
        )
        let (s, id) = (session, identity)
        tracing = TracingHeaders(hosts: config.tracingHeaders, apiHost: config.apiHost.host?.lowercased(), consent: { c.analytics }) {
            (id.distinctId, s.touch().sessionId)
        }
        if !consent.analytics { queue.clear() } // consent revoked while the app was closed
    }

    private static func networkGate(_ config: LucidaConfig) -> @Sendable () -> Bool {
        guard config.dataMode == .wifi else { return { true } }
        let policy = config.networkPolicy ?? NWPathNetworkPolicy()
        return { policy.isUnmetered }
    }

    var distinctId: String { identity.distinctId }
    var anonymousId: String { identity.anonymousId }
    var anonDistinctId: String? { identity.priorAnonId }
    var groups: [String: String]? { groupState.all }
    var sessionId: String { session.touch().sessionId }

    @discardableResult
    func capture(_ event: String, _ extra: Props = [:], set: Props? = nil, setOnce: Props? = nil, unset: [String]? = nil) -> WireEvent? {
        let granted = consent.analytics
        guard granted || (consent.pending && consent.queueBeforeConsent) else { return nil }
        // Person writes are blocked in `.never` mode and mark the device identified in `.identifiedOnly` mode.
        let writes = !(set ?? [:]).isEmpty || !(setOnce ?? [:]).isEmpty || !(unset ?? []).isEmpty
        if writes && person.blocksPersonWrites { debugLog("personProfiles=never: ignoring $set/$set_once on \(event)") }
        if writes || ["$identify", "$create_alias", "$groupidentify"].contains(event) { person.markIdentified() }
        let now = clock.now()
        let s = session.touch()
        var p = enricher?(event) ?? [:]
        p.merge(props.all) { _, new in new }
        p.merge(extra) { _, new in new }
        p["$session_id"] = .string(s.sessionId)
        p["$window_id"] = .string(session.windowId)
        p["$lib"] = .string(libName)
        p["$lib_version"] = .string(libVersion)
        if person.personless(event) { p["$process_person_profile"] = .bool(false) }
        if config.disableGeoip { p["$geoip_disable"] = .bool(true) }
        let blocked = person.blocksPersonWrites
        var e = WireEvent(
            uuid: UUIDv7.make(nowMs: UInt64(now.timeIntervalSince1970 * 1000)), event: event, distinctId: identity.distinctId,
            timestamp: ISO8601.string(now), properties: p, set: blocked ? nil : set, setOnce: blocked ? nil : setOnce,
            unset: blocked ? nil : unset, groups: groupState.all
        )
        guard let out = hooks.run(e) else { return nil }
        e = out
        for l in onCaptured { l(e) }
        if granted { queue.enqueue(e) } else if pre.count < config.maxQueueSize { pre.append(e) }
        return e
    }

    func identify(_ id: String, set: Props? = nil, setOnce: Props? = nil) {
        guard !person.blocksPersonWrites else { return debugLog("personProfiles=never: identify ignored") }
        let r = identity.identify(id)
        if r.event || set != nil || setOnce != nil {
            capture("$identify", r.anon.map { ["$anon_distinct_id": .string($0)] } ?? [:], set: set, setOnce: setOnce)
        }
        emit(.identify)
    }

    func alias(_ alias: String, original: String? = nil) {
        guard !person.blocksPersonWrites else { return debugLog("personProfiles=never: alias ignored") }
        capture("$create_alias", ["alias": .string(alias), "distinct_id": .string(original ?? identity.distinctId)])
    }

    /// Update person properties without an event of your own (sends a `$set` event).
    func setPersonProperties(set: Props? = nil, setOnce: Props? = nil) {
        guard !person.blocksPersonWrites else { return debugLog("personProfiles=never: setPersonProperties ignored") }
        capture("$set", [:], set: set, setOnce: setOnce)
    }

    /// App opened through a URL / link: `$deep_link_opened` with the url, its query parameters and the referrer.
    @discardableResult
    func deepLink(_ url: URL, referrer: String? = nil) -> WireEvent? {
        var query: Props = [:]
        for q in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] { query[q.name] = .string(q.value ?? "") }
        var p: Props = ["url": .string(url.absoluteString), "query": .object(query)]
        if let referrer { p["referrer"] = .string(referrer) }
        return capture("$deep_link_opened", p)
    }

    func reset() {
        person.reset()
        identity.reset(); props.clear(); groupState.clear(); session.reset()
        emit(.reset)
    }

    func register(_ p: Props) { props.register(p) }
    func registerOnce(_ p: Props) { props.registerOnce(p) }
    func unregister(_ k: String) { props.unregister(k) }

    func group(_ type: String, _ key: String, properties: Props = [:]) {
        groupState.set(type, key)
        capture("$groupidentify", ["$group_type": .string(type), "$group_key": .string(key), "$group_set": .object(properties)])
        emit(.group)
    }

    /// Granting analytics releases buffered state and held events; revoking drops them.
    func setConsent(analytics: Bool? = nil, replay: Bool? = nil, marketing: Bool? = nil) {
        let was = consent.analytics
        let will = analytics ?? was
        if was && !will { capture("$opt_out"); Task { await queue.flush() } }
        consent.set(analytics: analytics, replay: replay, marketing: marketing)
        if !was && will {
            gated.flushBuffered()
            for e in pre { queue.enqueue(e) }
            pre = []
            capture("$opt_in")
        } else if was && !will {
            queue.clear()
            gated.discardBuffered()
        }
        if !will { pre = [] }
        emit(.consent)
    }

    private func emit(_ c: Change) { for l in onChange { l(c) } }
}
