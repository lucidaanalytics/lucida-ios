import Foundation
#if canImport(Network)
import Network
#endif

public final class MemoryKeyValueStore: KeyValueStore, @unchecked Sendable {
    private var m: [String: String] = [:]
    private let lock = NSLock()

    public init() {}
    public func get(_ key: String) -> String? { lock.lock(); defer { lock.unlock() }; return m[key] }
    public func set(_ key: String, _ value: String) { lock.lock(); m[key] = value; lock.unlock() }
    public func remove(_ key: String) { lock.lock(); m[key] = nil; lock.unlock() }
    public var count: Int { lock.lock(); defer { lock.unlock() }; return m.count }
}

/// One file per key under `directory` (default: Application Support/Lucida), written atomically.
public final class FileKeyValueStore: KeyValueStore, @unchecked Sendable {
    private let dir: URL
    private let lock = NSLock()

    public init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lucida", isDirectory: true)
        dir = base
    }

    private func url(_ key: String) -> URL {
        let safe = key.map { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" ? String($0) : "_" }.joined()
        return dir.appendingPathComponent(safe + ".json")
    }

    /// Store inside an App Group container so an app and its extensions share identity and the queue; nil if the group is not entitled.
    public static func appGroup(_ identifier: String) -> FileKeyValueStore? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
            .map { FileKeyValueStore(directory: $0.appendingPathComponent("Library/Application Support/Lucida", isDirectory: true)) }
    }

    public func get(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return try? String(contentsOf: url(key), encoding: .utf8)
    }

    public func set(_ key: String, _ value: String) {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? Data(value.utf8).write(to: url(key), options: .atomic)
    }

    public func remove(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: url(key))
    }
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession
    private let timeout: TimeInterval

    /// `timeout` is the per-request timeout in seconds.
    public init(session: URLSession = .shared, timeout: TimeInterval = 20) {
        self.session = session
        self.timeout = timeout
    }

    public func send(_ request: HTTPRequest) async -> HTTPResponse {
        var r = URLRequest(url: request.url, timeoutInterval: timeout)
        r.httpMethod = request.method
        r.httpBody = request.body
        for (k, v) in request.headers { r.setValue(v, forHTTPHeaderField: k) }
        do {
            let (data, resp) = try await session.data(for: r)
            return HTTPResponse(status: (resp as? HTTPURLResponse)?.statusCode ?? 0, body: data)
        } catch {
            return HTTPResponse(status: 0)
        }
    }
}

/// `NetworkPolicy` over NWPathMonitor: unmetered = not expensive and not cellular. Defaults to true where Network is unavailable.
public final class NWPathNetworkPolicy: NetworkPolicy, @unchecked Sendable {
    private let lock = NSLock()
    private var unmetered = true
    #if canImport(Network)
    private let monitor = NWPathMonitor()
    #endif

    public init() {
        #if canImport(Network)
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.locked { self.unmetered = path.status == .satisfied && !path.isExpensive && !path.usesInterfaceType(.cellular) }
        }
        monitor.start(queue: DispatchQueue(label: "lucida.netpolicy"))
        #endif
    }

    public var isUnmetered: Bool { lock.locked { unmetered } }
}
