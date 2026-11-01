import Foundation

/// The public SDK surface. Thread-safe: calls may come from any thread.
public final class LucidaClient: @unchecked Sendable {
    private let core: Core
    private let config: LucidaConfig
    private let flagsService: FlagsService
    private let replay: ReplayRecorder?
    private let guides: GuidesService
    private let autocapture: Autocapture
    private let debugOn: DebugBox
    private let lock = NSRecursiveLock()
    #if canImport(UIKit)
    private lazy var autocaptureTap = UIKitAutocaptureTap(engine: autocapture)
    #endif

    public init(config: LucidaConfig) {
        self.config = config
        let dbg = DebugBox(config.debug)
        debugOn = dbg
        core = Core(config: config) { if dbg.on { print("[lucida]", $0) } }
        autocapture = Autocapture(core: core, config: config.autocapture, clock: config.clock)
        let flags = FlagsService(core: core, config: config)
        flagsService = flags
        guides = GuidesService(core: core, config: config) { flags.get($0)?.isOn ?? false }
        replay = config.disabled ? nil : ReplayRecorder(core: core, config: config) { flags.get($0)?.isOn ?? false }
        guard !config.disabled else { return }
        core.onChange.append { [weak self] c in
            guard let self else { return }
            if c == .identify || c == .reset || c == .group, self.config.flagOptions.preload { Task { await self.flagsService.reload(); await self.guides.reload() } }
            if c == .consent && self.core.consent.analytics { self.afterConsent() }
        }
        trackInstallOrUpdate()
        capture("$app_opened")
        config.lifecycle?.start(
            onForeground: { [weak self] in
                self?.capture("$app_opened")
                self?.attachAutocapture()
            },
            onBackground: { [weak self] in
                self?.capture("$app_backgrounded")
                Task { await self?.flush() }
            })
        if core.consent.analytics { afterConsent() }
        replay?.start()
        attachAutocapture()
    }

    private func attachAutocapture() {
        #if canImport(UIKit)
        if config.autocapture.enabled { autocaptureTap.attach() }
        #endif
    }

    private func afterConsent() {
        Task {
            if config.flagOptions.preload { await flagsService.reload() }
            await guides.reload()  // after flags: `flag_key` targeting reads them
        }
    }

    /// `$app_installed` on first run, `$app_updated` when the version changed since the last run.
    private func trackInstallOrUpdate() {
        guard let v = config.appVersion else { return }
        let prev = core.gated.get("lc_app_version")
        guard prev != v else { return }
        var p: Props = ["$app_version": .string(v)]
        if let b = config.appBuild { p["$app_build"] = .string(b) }
        if let prev { p["$previous_app_version"] = .string(prev) }
        capture(prev == nil ? "$app_installed" : "$app_updated", p)
        core.gated.set("lc_app_version", v)
    }

    private func withLock<T>(_ f: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return f() }

    // MARK: Capture

    public var distinctId: String { withLock { core.distinctId } }
    public var sessionId: String { withLock { core.sessionId } }
    public var queuedEventCount: Int { core.queue.count }

    /// `set` / `setOnce` ride on this event as `$set` / `$set_once` (person properties).
    public func capture(_ event: String, _ properties: Props = [:], set: Props? = nil, setOnce: Props? = nil) {
        guard !config.disabled else { return }
        var p = properties
        if let v = config.appVersion, p["$app_version"] == nil { p["$app_version"] = .string(v) }
        withLock { _ = core.capture(event, p, set: set, setOnce: setOnce) }
    }

    /// Anonymous id of this device; survives `reset()` with `reuseAnonymousId`.
    public var anonymousId: String { withLock { core.anonymousId } }
    public var isOptedOut: Bool { withLock { !core.consent.analytics } }

    /// Runtime debug toggle.
    public func debug(_ on: Bool) { debugOn.on = on }

    /// Update person properties without an event of your own (sends a `$set` event).
    public func setPersonProperties(set: Props? = nil, setOnce: Props? = nil) {
        guard !config.disabled else { return }
        withLock { core.setPersonProperties(set: set, setOnce: setOnce) }
    }

    /// Record `$deep_link_opened` for a URL the app was opened with. Call from `application(_:open:options:)`,
    /// `scene(_:openURLContexts:)` or SwiftUI `.onOpenURL`.
    public func openURL(_ url: URL, referrer: String? = nil) {
        guard !config.disabled else { return }
        withLock { _ = core.deepLink(url, referrer: referrer) }
    }

    /// Returns `request` with `X-Lucida-Distinct-Id` / `X-Lucida-Session-Id` added when its host is in
    /// `config.tracingHeaders` (never for the Lucida host; requires analytics consent). Use for your own backend calls.
    public func tracedRequest(_ request: URLRequest) -> URLRequest {
        guard let url = request.url else { return request }
        var r = request
        for (k, v) in withLock({ core.tracing.headers(for: url) }) { r.setValue(v, forHTTPHeaderField: k) }
        return r
    }

    /// Manual, swizzle-free screen view: `$screen` with `$screen_name`.
    public func screen(_ name: String, _ properties: Props = [:]) {
        guard !config.disabled else { return }
        replay?.setScreen(name)
        guides.show(on: name)
        var p = properties
        p["$screen_name"] = .string(name)
        capture("$screen", p)
    }

    // MARK: Identity

    public func identify(_ id: String, set: Props? = nil, setOnce: Props? = nil) {
        guard !config.disabled else { return }
        withLock { core.identify(id, set: set, setOnce: setOnce) }
    }

    public func alias(_ alias: String, original: String? = nil) { withLock { core.alias(alias, original: original) } }
    public func reset() { withLock { core.reset() } }
    public func register(_ props: Props) { withLock { core.register(props) } }
    public func registerOnce(_ props: Props) { withLock { core.registerOnce(props) } }
    public func unregister(_ key: String) { withLock { core.unregister(key) } }
    public func group(_ type: String, _ key: String, properties: Props = [:]) { withLock { core.group(type, key, properties: properties) } }

    // MARK: Consent

    public var consent: ConsentState { withLock { core.consent.state } }
    public func optIn() { withLock { core.setConsent(analytics: true, replay: true, marketing: true) } }
    public func optOut() { withLock { core.setConsent(analytics: false, replay: false, marketing: false) } }
    public func setConsent(analytics: Bool? = nil, replay: Bool? = nil, marketing: Bool? = nil) {
        withLock { core.setConsent(analytics: analytics, replay: replay, marketing: marketing) }
    }

    // MARK: Flags

    public func flag(_ key: String) -> FlagValue? { flagsService.get(key) }
    public func isFeatureEnabled(_ key: String) -> Bool { flagsService.get(key)?.isOn ?? false }
    public func flagPayload(_ key: String) -> JSONValue? { flagsService.payload(key) }
    public func reloadFlags() async { await flagsService.reload() }
    public func onFlags(_ cb: @escaping ([String: FlagValue]) -> Void) { flagsService.onChange(cb) }

    /// Person / group properties used only to evaluate flags (no `$set` event). `reload` re-evaluates right away.
    public func setPersonPropertiesForFlags(_ props: Props, reload: Bool = true) async { await flagsService.setPersonProperties(props, reload: reload) }
    public func resetPersonPropertiesForFlags(reload: Bool = true) async { await flagsService.resetPersonProperties(reload: reload) }
    public func setGroupPropertiesForFlags(_ type: String, _ props: Props, reload: Bool = true) async {
        await flagsService.setGroupProperties(type, props, reload: reload)
    }
    public func resetGroupPropertiesForFlags(reload: Bool = true) async { await flagsService.resetGroupProperties(reload: reload) }

    // MARK: Guides

    /// Re-fetch in-app guides (`config.guides.enabled`); they also load after consent and identify.
    public func reloadGuides() async { await guides.reload() }

    // MARK: Replay control

    /// Manual replay control (needs `config.replay.enabled`). Consent and sampling still apply.
    public func startReplay() { replay?.start() }
    public func stopReplay() { replay?.stop() }
    /// Keep the loop alive but capture nothing until `resumeReplay()`.
    public func pauseReplay() { replay?.pause() }
    public func resumeReplay() { replay?.resume() }
    public var isReplayActive: Bool { replay?.isActive ?? false }

    // MARK: Lifecycle

    public func flush() async { await core.queue.flush() }

    public func shutdown() async {
        config.lifecycle?.stop()
        replay?.stop()
        await core.queue.flush()
    }
}

final class DebugBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool
    init(_ v: Bool) { value = v }
    var on: Bool {
        get { lock.locked { value } }
        set { lock.locked { value = newValue } }
    }
}
