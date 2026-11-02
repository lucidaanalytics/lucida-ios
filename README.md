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

### Session replay: privacy additions

Every remote value below arrives in `GET /v1/config` and only ever adds masking to what the app configured.

- **Masked screens** (P-M17): `cfg.replay.maskScreens = ["Checkout", "Pay*"]` plus the project's `replay_mask_screens`
  (case-insensitive, `*` = any run of characters, whole screen name). On a matching screen every text, input value and
  image is masked whatever `maskText` / `maskAllTextInputs` / `maskAllImages` or `lucidaUnmask()` say; screenshots paint
  them all over.
- **Text patterns** (P-M46): `cfg.replay.maskTextPatterns = [#"\d{4,}"#]` plus `replay_mask_text_patterns` (regular
  expressions; one that does not compile is ignored). Matches in any text the wireframe would show unmasked become `*`
  (whitespace kept); in screenshot mode a view whose text matches is painted over.
- **`$dead_swipe`** (P-M46, `cfg.replay.captureDeadSwipes`, default on, needs `captureTouches`): a pan of 48 pt or more
  after which the view hierarchy is unchanged ~700 ms later. Properties: `$screen_name`, `$swipe_direction`
  (`left|right|up|down`), `$swipe_distance` (pt). Never text or view content; at most one per 2 s.
- **Controlled exposure** (P-L12): when the project sends `replay_exposure_fields` and `replay_exposure_key`, a listed
  field's value is RSA-OAEP-SHA256 encrypted on device and sent as `$sensitive_capture` (`$exposure_field`,
  `$exposure_kid`, `$exposure_ciphertext`, `$screen_name`, `$exposure_truncated` when cut to 190 bytes). Only an audited
  reveal on the server can read it. Explicit: `client.captureSensitive("card_number", value: v)`. Automatic: a non-secure
  `UITextField` / `UITextView` whose `accessibilityIdentifier` is listed is read during the snapshot walk (it stays masked
  in the replay). Secure fields are never captured; identical values are sent once per session; nothing is persisted.

SwiftUI in replay: hosting views are walked through their accessibility elements (labels only, never values), so SwiftUI
text appears in wireframes starred like UIKit text; the hosting view itself is a masked placeholder (`data-lc-mask`) and is
painted over in screenshot mode unless `.lucidaUnmask()` covers it.

Not built: push registration (needs a scope decision), queue encryption adapter (only the port).
The UIKit adapters type-check for the iOS simulator SDK but are not exercised by `swift test`.

## In-app guides

Kinds `modal`, `banner`, `announcement`, `slideout`, `tour`, `carousel` (Back / Next with a slide pager) and, with an
anchoring presenter, `tooltip` / `hotspot`. A step's `native_id` anchors it to a native view by its `accessibilityIdentifier` (`UIKitGuidePresenter` implements `AnchoredGuidePresenter`): the bubble is drawn next
to the view and follows it on scroll and relayout; a hotspot is a pulsing dot that opens the step. When the view does not
appear within `wait_ms` (default 3 s, max 15 s) the SDK sends `$guide_target_missing {step_id, selector}` and shows the step
unanchored; a view gone for 2 s closes the step. The resolved `appearance` tokens (background, text, accent, radius,
font) apply, with `appearance.dark.tokens` when `theme_mode` is dark, or auto and the device is dark.

## Fallbacks and flag details

`config.fallbacks = ["new_nav": .bool(false)]` serves that value, with reason `fallback`, when a flag has no value
(missing, failed load, cold start). Fallback reads emit no `$feature_flag_called` / `$exposure`.
`client.flagDetails("key")` returns `FlagDetails` (value, payload, variant, raw `reason`, `conditionIndex`, `requestId`,
`evaluatedLocally`), or nil for an unknown key without a fallback. `client.onFlagsStatus { .changed/.stale/.error }` reports reloads.

## OpenFeature

Product `LucidaOpenFeature` (depends on open-feature/swift-sdk 0.3+, Apache-2.0):

```swift
let provider = LucidaProvider(client: client)
await OpenFeatureAPI.shared.setProviderAndWait(provider: provider, initialContext: ImmutableContext(targetingKey: "u1"))
let on = OpenFeatureAPI.shared.getClient().getBooleanValue(key: "new_nav", defaultValue: false)
```

Context attrs: `groups` (type -> key), `groupProperties` (type -> map), everything else becomes person properties.
Reads carry reason + `flagMetadata` (`lucidaReason`, `conditionIndex`, `requestId`, `evaluatedLocally`); `track()` maps to `capture`.
## Install attribution

On first open `$app_installed` carries Apple Search Ads attribution from AdServices (iOS 14.3+): the
`AAAttribution` token is POSTed (text/plain, 10 s timeout, 404 retried up to 3 times) to Apple's attribution API.
Props: `$install_store=app_store`, `$install_adservices_attribution`, and when attributed `$utm_source=apple_search_ads`,
`$utm_medium=cpc`, `$utm_campaign/$utm_term/$utm_content` (campaign/keyword/ad group id) and `$asa_*` ids. If the token
or request fails the event still goes out with `$install_store` only. Disable with `config.installAttribution = false`;
swap the source with `config.installAttributionSource`. Opted-out users send nothing.

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
