import Foundation

public struct HTTPRequest: Sendable {
    public var url: URL
    public var method: String
    public var headers: [String: String]
    public var body: Data?

    public init(url: URL, method: String = "POST", headers: [String: String] = [:], body: Data? = nil) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
    }
}

/// `status` 0 means the request never got a response (offline, DNS, timeout).
public struct HTTPResponse: Sendable {
    public var status: Int
    public var body: Data

    public init(status: Int, body: Data = Data()) {
        self.status = status
        self.body = body
    }
}

/// Port: how bytes leave the SDK. Adapter: `URLSessionTransport`; tests use fakes.
public protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequest) async -> HTTPResponse
}

/// Port: string key/value persistence. Adapters: `FileKeyValueStore`, `MemoryKeyValueStore`.
public protocol KeyValueStore: AnyObject, Sendable {
    func get(_ key: String) -> String?
    func set(_ key: String, _ value: String)
    func remove(_ key: String)
}

public protocol LucidaClock: Sendable {
    func now() -> Date
}

public struct SystemClock: LucidaClock {
    public init() {}
    public func now() -> Date { Date() }
}

/// Port: app foreground/background signals. Adapter: `NotificationLifecycleSource`.
public protocol LifecycleSource: AnyObject {
    func start(onForeground: @escaping () -> Void, onBackground: @escaping () -> Void)
    func stop()
}
