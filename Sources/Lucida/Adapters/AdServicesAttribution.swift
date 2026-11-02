import Foundation
#if canImport(AdServices)
import AdServices
#endif

/// AdServices (iOS 14.3+) adapter: token from `AAAttribution`, resolved against Apple's attribution endpoint.
/// Network runs off the caller (async), each request has a timeout, and 404 (record not ready yet) is retried.
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

    public func fetch() async -> Props {
        guard let token = tokenProvider(), !token.isEmpty else { return appStoreInstallProps(responseJSON: nil) }
        let req = HTTPRequest(url: Self.endpoint, method: "POST", headers: ["Content-Type": "text/plain"], body: Data(token.utf8))
        for i in 0..<max(attempts, 1) {
            let r = await transport.send(req)
            if r.status == 200 { return appStoreInstallProps(responseJSON: r.body) }
            // shortcut: only 404 is retried (Apple: attribution record may lag); other failures are store-only.
            guard r.status == 404, i + 1 < attempts else { break }
            try? await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
        }
        return appStoreInstallProps(responseJSON: nil)
    }
}
