import Foundation
#if canImport(AdServices)
import AdServices
#endif

/// AdServices (iOS 14.3+) adapter: token from `AAAttribution`, resolved against Apple's attribution endpoint.
/// Network runs off the caller (async), each request has a timeout, and 404 (record not ready yet), 408, 429, 5xx and network failures are retried.
public struct AdServicesAttributionSource: InstallAttributionSource {
    private let transport: HTTPTransport
    private let tokenProvider: @Sendable () -> String?
    private let retryDelay: TimeInterval
    private let attempts: Int
    static let endpoint = URL(string: "https://api-adservices.apple.com/api/v1/")!

    public init(
        transport: HTTPTransport = URLSessionTransport(timeout: 10), retryDelay: TimeInterval = 5, attempts: Int = 3,
        tokenProvider: @escaping @Sendable () -> String? = AdServicesAttributionSource.systemToken
    ) {
        self.transport = transport
        self.tokenProvider = tokenProvider
        self.retryDelay = retryDelay
        self.attempts = attempts
    }

    @Sendable public static func systemToken() -> String? {
        #if canImport(AdServices)
        if #available(iOS 14.3, macOS 11.1, *) { return try? AAAttribution.attributionToken() }
        #endif
        return nil
    }

    /// Apple: 404 means the record is not ready yet; 5xx, 408, 429 and a network failure (0) are transient.
    /// Other statuses (400/401: a bad token) will not change on retry.
    static func retryable(_ status: Int) -> Bool { status == 0 || status == 404 || status == 408 || status == 429 || status >= 500 }

    public func fetch() async -> Props {
        guard let token = tokenProvider(), !token.isEmpty else { return appStoreInstallProps(responseJSON: nil) }
        let req = HTTPRequest(url: Self.endpoint, method: "POST", headers: ["Content-Type": "text/plain"], body: Data(token.utf8))
        for i in 0..<max(attempts, 1) {
            let r = await transport.send(req)
            if r.status == 200 { return appStoreInstallProps(responseJSON: r.body) }
            guard Self.retryable(r.status), i + 1 < attempts else { break }
            try? await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
        }
        return appStoreInstallProps(responseJSON: nil)
    }
}
