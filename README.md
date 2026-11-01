# Lucida iOS SDK (Swift package)

iOS 15+ / macOS 12+, no third-party dependencies. `swift test` runs on a Mac.

```swift
import Lucida

var cfg = LucidaConfig(apiKey: "lc_pk_...", apiHost: URL(string: "https://ingest.example.com")!)
cfg.appVersion = "1.4.0"
let lucida = LucidaClient(config: cfg)

lucida.identify("user-42", set: ["plan": "pro"])
lucida.capture("checkout_started", ["items": 3])
lucida.screen("Settings")                       // swizzle-free; call from viewDidAppear
if lucida.isFeatureEnabled("new-onboarding") { ... }
```

SwiftUI: `.lucidaScreen("Home", client: lucida)` records `$screen` on appear.

## What it does

- **Capture**: `POST /v1/batch` (`{api_key, batch, sent_at}`), 20 events / 5 s, gzip over 1 KB
  (`Content-Encoding: gzip`), retry with jittered exponential backoff (network, 408, 429, 5xx;
  other 4xx drop the batch). The queue is persisted (one JSON file under Application Support) and is
  only cleared on gateway acknowledgement, so offline periods and crashes lose nothing. Delivery is
  at-least-once; event `uuid` (UUIDv7) dedupes server-side.
- **Lifecycle** (no swizzling, NotificationCenter): `$app_opened`, `$app_backgrounded` (also flushes),
  `$app_installed`, `$app_updated` (needs `appVersion`).
- **Identity**: `identify`, `alias`, `reset`, `register`/`registerOnce`/`unregister`, `group`, sessions
  (rotate after 30 min idle or 24 h).
- **Consent**: `consentMode = .optIn` writes nothing to storage and sends nothing until `optIn()` /
  `setConsent(...)`; `queueBeforeConsent` holds events in memory instead of dropping them. Replay
  additionally needs the `replay` category.
- **Flags**: `POST /v1/flags` plus on-device evaluation (`localFlags`) that passes all of
  `testdata/flags` (`swift test` loads the files by relative path). `$feature_flag_called` / `$exposure`
  fire on first read.
- **Wireframe replay** (opt in: `cfg.replay.enabled = true`): every `snapshotInterval` (5 s) the key
  window's view hierarchy becomes an rrweb Meta + FullSnapshot (positioned `div`s) posted to
  `/v1/replay` as `{api_key, session_id, window_id, seq, events}`, plus a `navigation` custom event
  (`app://<screen>`) on screen change. Unchanged hierarchies are skipped. Privacy: text is masked
  (`*`) by default, text/secure inputs never include text, `view.lucidaMarkSensitive()` drops a view's
  text even when `maskText = false`.

## Hooks, person profiles, flags, privacy (config)

- `cfg.beforeSend = [hook, ...]`: ordered `(WireEvent) throws -> WireEvent?`; return a changed event to amend, `nil` to drop.
  A hook that throws is logged (when `debug`) and skipped: the event continues as it was before that hook.
  `sampleHook(0.1)` keeps ~10% and adds `$sample_rate`.
- `cfg.personProfiles`: `.always` (default), `.identifiedOnly` (events carry `$process_person_profile: false` until identify,
  alias, group or a person-property write; persisted, cleared by `reset()`), `.never` (identify/alias/setPersonProperties are
  no-ops with a debug warning).
- Flags: `cfg.bootstrap = Bootstrap(distinctId:, isIdentified:, flags:, payloads:)`; `cfg.flagOptions` (`sendFeatureFlagEvent`,
  `preload`, `evaluationContexts`); `onFlags`; `setPersonPropertiesForFlags(_:reload:)`, `setGroupPropertiesForFlags`, reset variants.
- Queue/network: `flushAt`, `flushInterval`, `maxQueueSize`, `maxBatchSize`, `maxRetries`, `retryBaseDelay`,
  `URLSessionTransport(timeout:)`, `dataMode = .wifi` (+ `networkPolicy`, default NWPathMonitor), `sessionIdleTimeout` / `sessionMaxAge`,
  `disableGeoip`, `disabled`, `client.debug(true)`, `queueCipher` (a `QueueCipher` port that encrypts only the persisted queue),
  `appGroupIdentifier` (App Group file store so extensions share identity and the queue; set before assigning a custom `store`).
- Person helpers: `setPersonProperties`, `capture(_:_:set:setOnce:)`, `anonymousId`, `reuseAnonymousId`, `anonymousIdProvider`, `isOptedOut`.
- `client.openURL(url, referrer:)` records `$deep_link_opened` (url, query, referrer); call it from your URL-open handlers.
- Tracing headers: `cfg.tracingHeaders = ["api.example.com", ".corp.io"]`, then `client.tracedRequest(request)` adds
  `X-Lucida-Distinct-Id` / `X-Lucida-Session-Id` (never to the Lucida host; analytics consent required).
- Autocapture (`cfg.autocapture.enabled = true`): `$autocapture` taps (`$event_type` touch, plus change for switches/segments/steppers) from a
  non-intrusive tap recognizer on the key window, `ignoreLabels`, `maxElements`, `propsAllowList`, `rageTap` (`$rageclick`).
  `view.lucidaNoCapture()` excludes a view and its subviews. Text-field values are never read.
- Replay: `maskAllTextInputs` (default on), `maskAllImages`, `maskSandboxedViews` (WKWebView, MKMapView: frame only), `sampleRate`
  (per session), `throttleDelay`, `view.lucidaUnmask()`; secure fields and `lucidaMarkSensitive()` views are never readable.
  `client.startReplay()` / `stopReplay()` / `isReplayActive`.

Not built: push registration (needs a scope decision), queue encryption adapter (only the port), screenshot-mode replay.
The UIKit adapters type-check for the iOS simulator SDK but are not exercised by `swift test`.

## Ports and adapters

`HTTPTransport` (`URLSessionTransport`), `KeyValueStore` (`FileKeyValueStore`,
`MemoryKeyValueStore`), `LucidaClock`, `LifecycleSource` (`NotificationLifecycleSource`),
`ViewHierarchySource` (`UIKitViewHierarchy`), `NetworkPolicy` (`NWPathNetworkPolicy`), `QueueCipher` (bring your own). Tests use fakes for all of them.

## Gaps

Wireframes are full snapshots, not
incremental mutations; no screenshot mode; the UIKit hierarchy walker type-checks against the iOS SDK
but is not exercised by `swift test`; no automatic UIKit screen tracking (manual `screen()` only).

---

This repository is a read-only mirror of the Lucida monorepo (synced by a script, never edited by hand); releases and provenance attestations are built here by GitHub Actions. Issues are welcome, changes land upstream.
