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
    /// Chunks held back until the session reaches the minimum duration.
    private var held: [[JSONValue]] = []
    private static let maxHeld = 20  // shortcut: bounded memory, oldest chunks beyond this are dropped; raise with a size budget if needed
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

    init?(core: Core, config: LucidaConfig, flagEnabled: @escaping (String) -> Bool = { _ in false }) {
        guard config.replay.enabled, let src = config.replay.source ?? Self.platformSource(config.replay) else { return nil }
        self.core = core
        self.config = config
        self.flagEnabled = flagEnabled
        source = src
        screenshots = config.replay.mode == .screenshot ? (config.replay.screenshotSource ?? Self.platformScreenshots()) : nil
        transport = config.replay.replayTransport ?? config.transport
    }

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

    func stop() { lock.lock(); task?.cancel(); task = nil; held = []; lock.unlock() }

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
        if (200..<300).contains(r.status) { remote = RemoteReplayConfig(json: r.body) }  // unreachable config: local settings stand
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
            lock.locked { lastSnap = nil; touches = []; held = [] }
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
        guard let snap = source.snapshot(screen: name) else { return }
        let ms = Int64(now.timeIntervalSince1970 * 1000)
        let frame = screenshots.flatMap { s in
            s.screenshot(plan: ScreenshotMasks.plan(snap, maskText: config.replay.maskText, maskInputs: config.replay.maskAllTextInputs, maskImages: config.replay.maskAllImages),
                         quality: config.replay.screenshotQuality)
        }
        if screenshots != nil && frame == nil { return }
        lastSnapAt = now
        let fp = frame.map { Hashing.hex($0.jpeg) } ?? Self.fingerprint(snap)
        let rotated = sid != lastSession
        if rotated { seq = 0; lastSession = sid; sessionStart = now; lock.locked { held = [] } }  // a session cut short is dropped
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
                events.append(RRWebWireframe.fullSnapshot(snap, maskText: config.replay.maskText, maskInputs: config.replay.maskAllTextInputs, maskImages: config.replay.maskAllImages, at: ms))
                lock.locked { lastSnap = snap }
            }
        }
        guard !events.isEmpty else { return }
        let minMs = ReplayPolicy.minDurationMs(local: config.replay.minDurationMs, remote: remote)
        if minMs > 0, now.timeIntervalSince(sessionStart) * 1000 < Double(minMs) {
            lock.locked { held.append(events); if held.count > Self.maxHeld { held.removeFirst() } }
            return
        }
        let backlog = lock.locked { () -> [[JSONValue]] in defer { held = [] }; return held }
        for chunk in backlog + [events] { await send(chunk, sessionId: sid) }
    }

    private static func fingerprint(_ snap: WireframeSnapshot) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys  // dictionary order is not stable; the fingerprint must be
        return (try? enc.encode(RRWebWireframe.fullSnapshot(snap, maskText: true, at: 0))).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    private func send(_ events: [JSONValue], sessionId: String) async {
        let body: JSONValue = .object([
            "api_key": .string(config.apiKey), "session_id": .string(sessionId), "window_id": .string(core.session.windowId),
            "seq": .number(Double(seq)), "events": .array(events),
        ])
        guard var data = try? JSONEncoder().encode(body), data.count <= config.replay.maxEventBytes else { return }
        var headers = ["Content-Type": "application/json"]
        if data.count >= 1024, let z = Gzip.compress(data) { data = z; headers["Content-Encoding"] = "gzip" }
        let r = await transport.send(HTTPRequest(url: config.apiHost.appendingPathComponent("v1/replay"), headers: headers, body: data))
        if (200..<300).contains(r.status) { seq += 1 } else { lastFingerprint = nil }  // retry as a fresh snapshot next tick
    }
}
