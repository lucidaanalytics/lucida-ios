import Foundation

struct QueueOptions {
    var flushAt = 20
    var flushInterval: TimeInterval = 5
    var maxQueueSize = 1000
    var maxRetries = 5
    var maxBatchSize = 100
    var retryBaseDelay: TimeInterval = 1
    /// Wi-Fi-only data mode hook: false keeps events queued.
    var networkAllowed: @Sendable () -> Bool = { true }
    var gzipThreshold = 1024
}

/// Persistent batching queue. Events stay on disk (via the store) until the gateway acknowledges
/// them, so a crash or offline period loses nothing; delivery is at-least-once (uuid dedupes).
/// Callers enqueue only after consent, so persisting here respects the consent gate.
final class EventQueue: @unchecked Sendable {
    private let store: KeyValueStore
    private let transport: HTTPTransport
    private let url: URL
    private let apiKey: String
    private let opts: QueueOptions
    private let clock: LucidaClock
    private let lock = NSLock()
    private var items: [WireEvent]
    private var timer: Task<Void, Never>?
    private var attempt = 0
    private var running: Task<Void, Never>?
    private let onDrop: (([WireEvent], String) -> Void)?
    private let sleeper: (TimeInterval) async -> Void
    static let key = "lc_queue"

    init(
        store: KeyValueStore, transport: HTTPTransport, host: URL, apiKey: String, options: QueueOptions,
        clock: LucidaClock, onDrop: (([WireEvent], String) -> Void)? = nil,
        sleeper: @escaping (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1e9)) }
    ) {
        self.store = store
        self.transport = transport
        url = host.appendingPathComponent("v1/batch")
        self.apiKey = apiKey
        opts = options
        self.clock = clock
        self.onDrop = onDrop
        self.sleeper = sleeper
        items = store.get(Self.key).flatMap { try? JSONDecoder().decode([WireEvent].self, from: Data($0.utf8)) } ?? []
        if !items.isEmpty { arm(after: 0) } // events left by a previous launch
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return items.count }

    private func persist() {
        if items.isEmpty { store.remove(Self.key) }
        else if let d = try? JSONEncoder().encode(items) { store.set(Self.key, String(decoding: d, as: UTF8.self)) }
    }

    func enqueue(_ e: WireEvent) {
        lock.lock()
        items.append(e)
        var dropped: [WireEvent] = []
        if items.count > opts.maxQueueSize { dropped = Array(items.prefix(items.count - opts.maxQueueSize)); items.removeFirst(dropped.count) }
        persist()
        let full = items.count >= opts.flushAt
        lock.unlock()
        if !dropped.isEmpty { onDrop?(dropped, "queue_full") }
        if full { Task { await self.flush() } } else { arm(after: opts.flushInterval) }
    }

    private func arm(after: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        guard timer == nil else { return }
        timer = Task { [weak self] in
            await self?.sleeper(after)
            guard let self, !Task.isCancelled else { return }
            self.clearTimer()
            await self.flush()
        }
    }

    private func clearTimer() { lock.lock(); timer = nil; lock.unlock() }

    /// Next batch to send (up to 1000), or nil when idle/empty. Cancels any pending timer.
    private func beginBatch() -> [WireEvent]? {
        lock.lock(); defer { lock.unlock() }
        timer?.cancel(); timer = nil
        if items.isEmpty { return nil }
        return Array(items.prefix(max(1, opts.maxBatchSize)))
    }

    private enum Next { case more, stop }

    /// Applies the outcome of sending `batch`: remove on success/non-retryable, keep and back off otherwise.
    private func finish(_ batch: [WireEvent], status: Int) -> Next {
        lock.lock()
        let ids = Set(batch.map(\.uuid))
        if (200..<300).contains(status) {
            attempt = 0
            items.removeAll { ids.contains($0.uuid) }
            persist()
            let more = !items.isEmpty
            lock.unlock()
            return more ? .more : .stop
        }
        if !Backoff.isRetryable(status) || attempt >= opts.maxRetries {
            items.removeAll { ids.contains($0.uuid) }
            persist()
            attempt = 0
            lock.unlock()
            onDrop?(batch, "status_\(status)")
            return .more
        }
        let delay = Backoff.delay(attempt: attempt, base: opts.retryBaseDelay)
        attempt += 1
        lock.unlock()
        arm(after: delay)
        return .stop
    }

    /// Sends everything queued, one batch at a time. Retryable failures keep the events and re-arm
    /// the timer with backoff; non-retryable ones (or too many retries) drop the batch.
    /// Concurrent callers join the drain already running instead of racing it.
    func flush() async {
        let task: Task<Void, Never> = lock.locked {
            if let r = running { return r }
            let t = Task {
                await self.drain()
                self.lock.locked { self.running = nil }
            }
            running = t
            return t
        }
        await task.value
    }

    private func drain() async {
        guard opts.networkAllowed() else {
            if count > 0 { arm(after: opts.flushInterval) }
            return
        }
        while let batch = beginBatch() {
            if finish(batch, status: await send(batch)) == .stop { return }
        }
    }

    private func send(_ batch: [WireEvent]) async -> Int {
        struct Body: Encodable { let api_key: String; let batch: [WireEvent]; let sent_at: String }
        guard let json = try? JSONEncoder().encode(Body(api_key: apiKey, batch: batch, sent_at: ISO8601.string(clock.now()))) else {
            return 400
        }
        var headers = ["Content-Type": "application/json"]
        var body = json
        if json.count >= opts.gzipThreshold, let z = Gzip.compress(json) {
            body = z
            headers["Content-Encoding"] = "gzip"
        }
        return await transport.send(HTTPRequest(url: url, headers: headers, body: body)).status
    }

    /// Discards everything queued (consent revoked).
    func clear() {
        lock.lock()
        items = []
        timer?.cancel(); timer = nil
        persist()
        lock.unlock()
    }
}
