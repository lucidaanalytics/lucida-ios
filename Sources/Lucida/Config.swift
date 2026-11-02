import Foundation

public struct LucidaConfig {
    public var apiKey: String
    public var apiHost: URL
    public var consentMode: ConsentMode = .optOut
    /// Hold events in memory (never stored or sent) until analytics consent is granted. Default: drop.
    public var queueBeforeConsent = false
    public var flushAt = 20
    public var flushInterval: TimeInterval = 5
    public var maxQueueSize = 1000
    public var appVersion: String?
    public var appBuild: String?
    public var debug = false
    /// Everything is a no-op (tests, previews).
    public var disabled = false
    /// Definitions for on-device flag evaluation; flags needing the server still use POST /v1/flags.
    public var localFlags: [FlagDefinition] = []
    public var localFlagsContext = EvalContext(distinctId: "")
    /// `{flagKey: value}` served with reason `fallback` when a flag has no value (missing, failed load, cold start). No exposure events.
    public var fallbacks: [String: JSONValue] = [:]
    public var replay = ReplayConfig()
    public var guides = GuidesConfig()

    /// Ordered hooks run on every event before it is queued; return nil to drop. A throwing hook is logged and skipped.
    public var beforeSend: [BeforeSend] = []
    public var personProfiles: PersonProfiles = .always
    /// Ask the server not to geolocate events (`$geoip_disable`).
    public var disableGeoip = false
    public var bootstrap: Bootstrap?
    public var flagOptions = FlagOptions()
    public var autocapture = AutocaptureConfig()
    /// Keep the anonymous id across `reset()`.
    public var reuseAnonymousId = false
    /// Custom anonymous id generator.
    public var anonymousIdProvider: (() -> String)?
    /// Encrypt the persisted queue at rest (optional).
    public var queueCipher: QueueCipher?
    /// Own-backend hosts that receive `X-Lucida-*` headers via `LucidaClient.tracedRequest(_:)`.
    public var tracingHeaders: [String] = []
    /// Send Apple Search Ads (AdServices) attribution on the first-open `$app_installed`.
    public var installAttribution = true
    /// Override the install attribution source (default: `AdServicesAttributionSource`).
    public var installAttributionSource: InstallAttributionSource?
    public var maxBatchSize = 100
    public var maxRetries = 5
    public var retryBaseDelay: TimeInterval = 1
    public var sessionIdleTimeout: TimeInterval = 30 * 60
    public var sessionMaxAge: TimeInterval = 24 * 3600
    /// `.wifi`: flush only on an unmetered path (`networkPolicy`); events wait in the queue otherwise.
    public var dataMode: DataMode = .any
    /// Defaults to an `NWPathNetworkPolicy` when `dataMode` is `.wifi`.
    public var networkPolicy: NetworkPolicy?
    /// Share storage with app extensions (widgets, share sheets): uses the App Group container. Set before `store`.
    public var appGroupIdentifier: String? {
        didSet { if let id = appGroupIdentifier, let s = FileKeyValueStore.appGroup(id) { store = s } }
    }

    // Ports; defaults are the real adapters.
    public var transport: HTTPTransport = URLSessionTransport()
    public var store: KeyValueStore = FileKeyValueStore()
    public var clock: LucidaClock = SystemClock()
    public var lifecycle: LifecycleSource? = NotificationLifecycleSource()

    public init(apiKey: String, apiHost: URL = URL(string: "https://app.lucida.dev")!) {
        self.apiKey = apiKey
        self.apiHost = apiHost
    }
}

let libName = "lucida-ios"
let libVersion = "0.1.0"
