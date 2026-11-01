import CryptoKit
import Foundation

enum Hashing {
    /// Flag hash in [0,1): first 13 hex chars of sha256 / 16^13 (exact in doubles).
    static func unit(_ input: String) -> Double {
        var n: UInt64 = 0
        for b in SHA256.hash(data: Data(input.utf8)).prefix(7) { n = n << 8 | UInt64(b) }
        return Double(n >> 4) / 4_503_599_627_370_496.0  // top 52 bits = first 13 hex chars
    }
}

extension Hashing {
    static func hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

enum UUIDv7 {
    static func make(nowMs: UInt64) -> String {
        var b = [UInt8](repeating: 0, count: 16)
        for i in 0..<6 { b[i] = UInt8((nowMs >> UInt64(8 * (5 - i))) & 0xff) }
        for i in 6..<16 { b[i] = UInt8.random(in: 0...255) }
        b[6] = (b[6] & 0x0f) | 0x70
        b[8] = (b[8] & 0x3f) | 0x80
        let h = b.map { String(format: "%02x", $0) }.joined()
        let c = Array(h)
        return "\(String(c[0..<8]))-\(String(c[8..<12]))-\(String(c[12..<16]))-\(String(c[16..<20]))-\(String(c[20..<32]))"
    }
}

/// Exponential backoff with jitter: 50%..100% of the capped exponential (same as sdk-core).
enum Backoff {
    static func delay(attempt: Int, base: TimeInterval = 1, cap: TimeInterval = 30, random: Double = .random(in: 0..<1)) -> TimeInterval {
        min(cap, base * pow(2, Double(attempt))) * (0.5 + 0.5 * random)
    }

    /// Network failure, timeout, rate limit, server errors.
    static func isRetryable(_ status: Int) -> Bool {
        status == 0 || status == 408 || status == 429 || status >= 500
    }
}

extension NSLock {
    /// Scoped locking (plain lock()/unlock() is unavailable from async contexts).
    func locked<T>(_ body: () -> T) -> T { lock(); defer { unlock() }; return body() }
}
