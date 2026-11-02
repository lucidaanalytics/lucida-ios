import Foundation
@testable import Lucida

final class FakeTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [HTTPRequest] = []
    var responder: @Sendable (HTTPRequest) -> HTTPResponse = { _ in HTTPResponse(status: 200) }

    var requests: [HTTPRequest] { lock.locked { _requests } }
    var batchRequests: [HTTPRequest] { requests.filter { $0.url.path.hasSuffix("/v1/batch") } }

    func send(_ request: HTTPRequest) async -> HTTPResponse {
        lock.locked { _requests.append(request) }
        return responder(request)
    }

    /// Decoded bodies of batch posts (gunzipped when needed).
    func batchEvents() -> [[String: Any]] {
        requests.filter { $0.url.path.hasSuffix("/v1/batch") }.flatMap { r -> [[String: Any]] in
            let o = (try? JSONSerialization.jsonObject(with: Self.plain(r))) as? [String: Any]
            return o?["batch"] as? [[String: Any]] ?? []
        }
    }

    func names() -> [String] { batchEvents().compactMap { $0["event"] as? String } }

    static func plain(_ r: HTTPRequest) -> Data {
        guard r.headers["Content-Encoding"] == "gzip", let b = r.body else { return r.body ?? Data() }
        return gunzip(b)
    }

    static func gunzip(_ d: Data) -> Data {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        p.arguments = ["-dc"]
        let i = Pipe(), o = Pipe()
        p.standardInput = i; p.standardOutput = o
        try? p.run()
        i.fileHandleForWriting.write(d)
        try? i.fileHandleForWriting.close()
        let out = o.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return out
    }
}

final class TestClock: LucidaClock, @unchecked Sendable {
    private let lock = NSLock()
    private var t: Date
    init(_ t: Date = Date(timeIntervalSince1970: 1_800_000_000)) { self.t = t }
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return t }
    func advance(_ s: TimeInterval) { lock.lock(); t = t.addingTimeInterval(s); lock.unlock() }
}

final class FakeLifecycle: LifecycleSource {
    var fg: (() -> Void)?
    var bg: (() -> Void)?
    func start(onForeground: @escaping () -> Void, onBackground: @escaping () -> Void) { fg = onForeground; bg = onBackground }
    func stop() { fg = nil; bg = nil }
}

func makeConfig(
    transport: FakeTransport, store: KeyValueStore = MemoryKeyValueStore(), clock: LucidaClock = TestClock(),
    lifecycle: LifecycleSource? = FakeLifecycle(), _ tweak: (inout LucidaConfig) -> Void = { _ in }
) -> LucidaConfig {
    var c = LucidaConfig(apiKey: "lc_pk_test", apiHost: URL(string: "https://ingest.test")!)
    c.transport = transport
    c.store = store
    c.clock = clock
    c.lifecycle = lifecycle
    c.installAttribution = false  // async install attribution has its own tests
    c.flushAt = 1000  // tests flush explicitly
    c.flushInterval = 3600
    tweak(&c)
    return c
}
