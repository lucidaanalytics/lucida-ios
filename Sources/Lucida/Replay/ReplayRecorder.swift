import Foundation

/// Periodic wireframe (or masked screenshot) recorder. Each tick takes a snapshot; when the structure changed since
/// the last one (or the session rotated) it emits Meta + FullSnapshot, and a `navigation` marker on a screen
/// change. Chunks go to `POST /v1/replay` as `{api_key, session_id, window_id, seq, events}`, gzipped
/// over 1 KB. `seq` is monotonic per window and resets when the session rotates.
///
/// Gates, in order: consent, project kill switch + sample rate (`GET /v1/config`, tightening only), linked flag,
/// pause, screen allow/deny list, then the minimum duration (chunks wait in memory; dropped if the session ends first).
final class ReplayRecorder: @unchecked Sendable {
    private let core: Core
    private let config: LucidaConfig
    private let source: ViewHierarchySource
    private let screenshots: ScreenshotSource?
    private let transport: HTTPTransport
    private let flagEnabled: (String) -> Bool
    /// Analytics events from the recorder (`$dead_swipe`, `$sensitive_capture`); the client routes them through its lock.
    private let emit: (String, Props) -> Void
    private let sensitive = SensitiveCapture()
    /// Local + remote `maskTextPatterns`, compiled once (again after the remote config loads).
    private var patterns: [NSRegularExpression]
    /// Pan start for `$dead_swipe`: the screen and the walked snapshot at that moment.
    private var swipeStart: (screen: String, snap: WireframeSnapshot)?
    private var lastDeadSwipeAt: Int64?
    /// How long after a swipe the screen must still look the same; tests shorten it.
    var deadSwipeSettle = DeadSwipe.settleSeconds
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var lastFingerprint: String?
    private var lastScreen: String?
    private var lastSession: String?
    private var seq = 0
    private var lastSnapAt: Date?
    private var paused = false
    private var remote: RemoteReplayConfig?
    private var remoteLoaded = false
    /// Chunks that cannot go out yet (min duration, offline, upload backoff): on disk, encrypted with the queue cipher.
    private let spool: ReplaySpool
    private var sessionStart = Date.distantPast
    private(set) var screen = "Unknown"
    /// Last snapshot sent: taps and swipes are hit-tested against it (a touch before any snapshot is dropped).
    private var lastSnap: WireframeSnapshot?
    /// Touch events since the last chunk; shipped on the next tick, after any new snapshot.
    private var touches: [JSONValue] = []
    private static let maxTouches = 500
    #if canImport(UIKit)
    private lazy var touchCapture = UIKitTouchCapture(recorder: self)
    #endif

    init?(core: Core, config: LucidaConfig, flagEnabled: @escaping (String) -> Bool = { _ in false }, capture: ((String, Props) -> Void)? = nil) {
        guard config.replay.enabled, let src = config.replay.source ?? Self.platformSource(config.replay) else { return nil }
        self.core = core
        self.config = config
        self.flagEnabled = flagEnabled
        emit = capture ?? { [core] e, p in _ = core.capture(e, p) }
        patterns = ReplayMasking.compile(config.replay.maskTextPatterns)
        source = src
        screenshots = config.replay.mode == .screenshot ? (config.replay.screenshotSource ?? Self.platformScreenshots()) : nil
        transport = config.replay.replayTransport ?? config.transport
        let log = core.debugLog
        spool = ReplaySpool(
            store: config.queueCipher.map { EncryptedStore(config.store, cipher: $0, keys: [ReplaySpool.key], prefixes: ["\(ReplaySpool.key)."]) } ?? config.store,
            budget: config.replay.spoolBudgetBytes
        ) { sid, chunks, bytes in log("replay spool over budget: dropped session \(sid) (\(chunks) chunks, \(bytes) bytes)") }
    }

    /// Erase every spilled chunk (opt-out, reset).
    func clearSpool() { spool.clear() }

    private static func platformSource(_ c: ReplayConfig) -> ViewHierarchySource? {
        #if canImport(UIKit)
        return UIKitViewHierarchy(captureInputText: !c.maskAllTextInputs, maskSandboxedViews: c.maskSandboxedViews)
        #else
        return nil
        #endif
    }

    private static func platformScreenshots() -> ScreenshotSource? {
        #if canImport(UIKit)
        return UIKitScreenshot()
        #else
        return nil
        #endif
    }

    func setScreen(_ name: String) { lock.lock(); screen = name; lock.unlock() }

    /// A tap at window point (x, y) (LC-EXP-35). Needs replay consent; never records what was typed.
    func tap(x: Double, y: Double) { addTouch { RRWebWireframe.tap($0, x: x, y: y, at: $1) } }

    /// A scroll / swipe finger path, in window points.
    func swipe(_ path: [TouchPoint]) {
        guard !path.isEmpty else { return }
        addTouch { RRWebWireframe.swipe($0, path: path, at: $1) }
    }

    private func addTouch(_ make: (WireframeSnapshot, Int64) -> JSONValue) {
        guard core.consent.analytics, core.consent.replay else { return }
        let ms = Int64(config.clock.now().timeIntervalSince1970 * 1000)
        lock.locked {
            guard let snap = lastSnap, touches.count < Self.maxTouches else { return }
            touches.append(make(snap, ms))
        }
    }

    func start() {
        lock.lock(); defer { lock.unlock() }
        guard task == nil else { return }
        let interval = config.replay.snapshotInterval
        let watchTouches = config.replay.captureTouches && config.replay.source == nil  // only with the real UIKit source
        task = Task { [weak self] in
            while !Task.isCancelled {
                #if canImport(UIKit)
                if watchTouches, let tc = self?.touchCapture { await tc.attach() }  // main actor hop; follows key-window changes, no-op when unchanged
                #endif
                await self?.tick()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1e9))
            }
        }
    }

    func stop() { lock.lock(); task?.cancel(); task = nil; lock.unlock()
        // Held chunks never went out: give their seq numbers back so the stream stays gapless. Pending uploads stay.
        if let m = spool.removeHeld().filter({ $0.sid == lastSession }).map(\.seq).min() { seq = m }
    }

    /// Pause keeps the loop alive but captures nothing until `resume()`.
    func pause() { lock.locked { paused = true } }
    func resume() { lock.locked { paused = false } }

    /// Loop running and not paused, consent allows it, this session is sampled in, the linked flag (if any) is on and the screen is allowed.
    var isActive: Bool {
        lock.locked { task != nil && !paused } && core.consent.analytics && core.consent.replay && sampled(core.sessionId) && gateOpen(lock.locked { screen })
    }

    private func gateOpen(_ screen: String) -> Bool {
        if let f = config.replay.linkedFlag, !flagEnabled(f) { return false }
        return ReplayPolicy.screenAllowed(screen, allow: config.replay.screenAllowList, deny: config.replay.screenDenyList)
    }

    private func loadRemote() async {
        guard config.replay.useRemoteConfig, !remoteLoaded else { return }
        remoteLoaded = true
        var comps = URLComponents(url: config.apiHost.appendingPathComponent("v1/config"), resolvingAgainstBaseURL: false)
        comps?.queryItems = [URLQueryItem(name: "api_key", value: config.apiKey)]
        guard let url = comps?.url else { return }
        let r = await config.transport.send(HTTPRequest(url: url, method: "GET"))
        guard (200..<300).contains(r.status), let rc = RemoteReplayConfig(json: r.body) else { return }  // unreachable config: local settings stand
        let compiled = ReplayMasking.compile(config.replay.maskTextPatterns + rc.maskTextPatterns)
        lock.locked { remote = rc; patterns = compiled }
    }

    /// P-M17: the local list plus the project's `replay_mask_screens`.
    private func screenMasked(_ name: String) -> Bool {
        ReplayPolicy.screenMasked(name, patterns: config.replay.maskScreens + (lock.locked { remote?.maskScreens } ?? []))
    }

    /// P-L12 field ids, empty unless the project sent both the list and its key.
    private var exposureFields: Set<String> {
        lock.locked { remote?.exposureKey == nil ? [] : Set(remote?.exposureFields ?? []) }
    }

    /// P-L12: encrypts a listed field's value and sends `$sensitive_capture` (needs analytics + replay consent and the
    /// project key). Identical values are sent once per session; nothing is sent when encryption fails.
    func captureSensitive(_ field: String, value: String) {
        guard core.consent.analytics, core.consent.replay, !value.isEmpty else { return }
        let (key, listed, name) = lock.locked { (remote?.exposureKey, remote?.exposureFields.contains(field) ?? false, screen) }
        guard let key, listed else { return }
        if let p = sensitive.properties(field: field, value: value, screen: name, key: key, sessionId: core.sessionId) { emit("$sensitive_capture", p) }
    }

    private var touchesRecording: Bool { core.consent.analytics && core.consent.replay && lock.locked { lastSnap != nil } }

    /// Pan began (main thread, before the content moves): remember what the swipe started on.
    func swipeBegan() {
        guard config.replay.captureDeadSwipes, touchesRecording else { return }
        let name = lock.locked { screen }
        let snap = source.snapshot(screen: name)
        lock.locked { swipeStart = snap.map { (screen: name, snap: $0) } }
    }

    /// Pan ended: after `deadSwipeSettle`, an unchanged structure on the same screen is a `$dead_swipe` (2 s cooldown).
    func swipeEnded(from a: TouchPoint, to b: TouchPoint) async {
        guard let start = lock.locked({ () -> (screen: String, snap: WireframeSnapshot)? in defer { swipeStart = nil }; return swipeStart }) else { return }
        let dx = b.x - a.x, dy = b.y - a.y
        guard (dx * dx + dy * dy).squareRoot() >= DeadSwipe.minDistance else { return }
        try? await Task.sleep(nanoseconds: UInt64(deadSwipeSettle * 1e9))
        guard touchesRecording else { return }
        let name = lock.locked { screen }
        guard let end = source.snapshot(screen: name) else { return }
        let (fa, fb) = (Self.fingerprint(start.snap), Self.fingerprint(end))
        let ms = Int64(config.clock.now().timeIntervalSince1970 * 1000)
        let props = lock.locked { () -> Props? in
            let p = DeadSwipe.decide(screen: name, startScreen: start.screen, startFingerprint: fa, endFingerprint: fb, dx: dx, dy: dy, nowMs: ms, lastAt: lastDeadSwipeAt)
            if p != nil { lastDeadSwipeAt = ms }
            return p
        }
        if let props { emit("$dead_swipe", props) }
    }

    /// Stable per session: the same session id always gets the same answer.
    func sampled(_ sessionId: String) -> Bool {
        let r = ReplayPolicy.sampleRate(local: config.replay.sampleRate, remote: remote)
        if r >= 1 { return true }
        if r <= 0 { return false }
        var h: UInt64 = 1469598103934665603  // FNV-1a
        for b in sessionId.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return Double(h % 10_000) / 10_000 < r
    }

    /// One capture pass; exposed to tests.
    func tick() async {
        // The replay category must be granted; revoking it drops state so a re-grant starts clean.
        guard core.consent.analytics, core.consent.replay else {
            lock.locked { lastSnap = nil; touches = [] }
            spool.clear()
            lastFingerprint = nil
            return
        }
        await loadRemote()
        let (name, isPaused) = lock.locked { (screen, paused) }
        let sid = core.sessionId
        guard sampled(sid) else { return }
        guard !isPaused, gateOpen(name) else {
            // Leaving a gated screen: the next allowed tick starts from a fresh snapshot; touches on it are dropped.
            lock.locked { lastSnap = nil; touches = [] }
            lastFingerprint = nil
            return
        }
        let now = config.clock.now()
        let throttle = screenshots == nil ? config.replay.throttleDelay : max(config.replay.throttleDelay, 1)
        if let last = lastSnapAt, now.timeIntervalSince(last) < throttle { return }
        let reader = source as? ExposureReading
        reader?.setExposureFields(exposureFields)
        guard let raw = source.snapshot(screen: name) else { return }
        for x in reader?.takeExposed() ?? [] { captureSensitive(x.field, value: x.value) }
        // A masked screen (P-M17) forces every switch on and ignores unmask markers; patterns (P-M46) star matches.
        let masked = screenMasked(name)
        let snap = ReplayMasking.apply(raw, maskScreen: masked, patterns: lock.locked { patterns }, screenshot: screenshots != nil)
        let maskText = masked || config.replay.maskText, maskInputs = masked || config.replay.maskAllTextInputs, maskImages = masked || config.replay.maskAllImages
        let ms = Int64(now.timeIntervalSince1970 * 1000)
        let frame = screenshots.flatMap { s in
            s.screenshot(plan: ScreenshotMasks.plan(snap, maskText: maskText, maskInputs: maskInputs, maskImages: maskImages), quality: config.replay.screenshotQuality)
        }
        if screenshots != nil && frame == nil { return }
        lastSnapAt = now
        let fp = frame.map { Hashing.hex($0.jpeg) } ?? Self.fingerprint(snap)
        let rotated = sid != lastSession
        if rotated { lastSession = sid; sessionStart = now; spool.removeHeld(except: sid); seq = spool.nextSeq(sid) }  // a session cut short is dropped; seq resumes after a restart
        let pending = lock.locked { () -> [JSONValue] in defer { touches = [] }; return touches }
        var events: [JSONValue] = pending
        if rotated || fp != lastFingerprint {
            lastFingerprint = fp
            if let f = frame {
                let shot = WireframeSnapshot(screen: snap.screen, width: f.width, height: f.height,
                                             root: WireframeNode(kind: .view, x: 0, y: 0, width: f.width, height: f.height))
                events.append(RRWebWireframe.meta(shot, at: ms))
                if snap.screen != lastScreen { events.append(RRWebWireframe.navigation(shot, at: ms)); lastScreen = snap.screen }
                events.append(RRWebWireframe.screenshotSnapshot(shot, jpeg: f.jpeg, at: ms))
                lock.locked { lastSnap = shot }
            } else {
                events.append(RRWebWireframe.meta(snap, at: ms))
                if snap.screen != lastScreen { events.append(RRWebWireframe.navigation(snap, at: ms)); lastScreen = snap.screen }
                events.append(RRWebWireframe.fullSnapshot(snap, maskText: maskText, maskInputs: maskInputs, maskImages: maskImages, at: ms))
                lock.locked { lastSnap = snap }
            }
        }
        let minMs = ReplayPolicy.minDurationMs(local: config.replay.minDurationMs, remote: remote)
        let holding = minMs > 0 && now.timeIntervalSince(sessionStart) * 1000 < Double(minMs)
        if !events.isEmpty { store(events, sessionId: sid, held: holding) }
        if holding { return }
        spool.release(sid)
        await drain()
    }

    private static func fingerprint(_ snap: WireframeSnapshot) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys  // dictionary order is not stable; the fingerprint must be
        return (try? enc.encode(RRWebWireframe.fullSnapshot(snap, maskText: true, at: 0))).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    private func store(_ events: [JSONValue], sessionId: String, held: Bool) {
        let body: JSONValue = .object([
            "session_id": .string(sessionId), "window_id": .string(core.session.windowId),
            "seq": .number(Double(seq)), "events": .array(events),
        ])
        guard let data = try? JSONEncoder().encode(body), data.count <= config.replay.maxEventBytes else { return }
        spool.add(sid: sessionId, seq: seq, held: held, body: data)
        seq += 1
    }

    /// Uploads spilled chunks in order; stops at the first retryable failure (the next tick is the backoff).
    private func drain() async {
        for e in spool.entries where !e.held {
            guard let raw = spool.read(e), case .object(var obj)? = try? JSONDecoder().decode(JSONValue.self, from: raw) else { spool.remove(e); continue }
            obj["api_key"] = .string(config.apiKey)
            guard var data = try? JSONEncoder().encode(JSONValue.object(obj)) else { spool.remove(e); continue }
            var headers = ["Content-Type": "application/json"]
            if data.count >= 1024, let z = Gzip.compress(data) { data = z; headers["Content-Encoding"] = "gzip" }
            let r = await transport.send(HTTPRequest(url: config.apiHost.appendingPathComponent("v1/replay"), headers: headers, body: data))
            if (200..<300).contains(r.status) { spool.remove(e) }
            else if r.status == 0 || r.status == 408 || r.status == 429 || r.status >= 500 { lastFingerprint = nil; return }  // fresh snapshot after the outage
            else { spool.remove(e); core.debugLog("replay chunk rejected with \(r.status); dropped") }
        }
    }
}
