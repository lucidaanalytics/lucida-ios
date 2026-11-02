import Foundation
import Security

/// A view-hierarchy source that reads listed, non-secure text fields during its walk (P-L12 controlled exposure).
/// The values only feed `$sensitive_capture`; their wireframe nodes are marked sensitive and never carry text.
protocol ExposureReading: AnyObject {
    func setExposureFields(_ fields: Set<String>)
    /// Values read by the last walk (field id, value); cleared by the call.
    func takeExposed() -> [(field: String, value: String)]
}

/// P-L12: a listed field's value, RSA-OAEP-SHA256 encrypted with the project key, so only an audited reveal on the
/// server can read it. Identical values are sent once per session (an in-memory SHA-256 set that is never persisted
/// or sent). Encryption failure sends nothing.
final class SensitiveCapture {
    static let maxPlainBytes = 190
    private let lock = NSLock()
    private var seen = Set<String>()
    private var seenSession: String?

    /// UTF-8 bytes of `value`, cut to at most `max` bytes on a character (scalar) boundary; true when cut.
    static func truncate(_ value: String, max: Int = maxPlainBytes) -> (Data, Bool) {
        var out = Data()
        for s in value.unicodeScalars {
            let b = Data(String(s).utf8)
            if out.count + b.count > max { return (out, true) }
            out.append(b)
        }
        return (out, false)
    }

    /// Standard base64 of the RSA-OAEP (SHA-256 hash and MGF1, empty label) ciphertext, or nil.
    static func encrypt(_ plain: Data, key: ExposureKey) -> String? {
        guard let der = Data(base64Encoded: key.pkcs1) else { return nil }
        let attrs: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeyClass as String: kSecAttrKeyClassPublic]
        guard let pub = SecKeyCreateWithData(der as CFData, attrs as CFDictionary, nil),
              SecKeyIsAlgorithmSupported(pub, .encrypt, .rsaEncryptionOAEPSHA256),
              let out = SecKeyCreateEncryptedData(pub, .rsaEncryptionOAEPSHA256, plain as CFData, nil) else { return nil }
        return (out as Data).base64EncodedString()
    }

    /// `$sensitive_capture` properties, or nil when this value was already sent this session or encryption failed.
    func properties(field: String, value: String, screen: String, key: ExposureKey, sessionId: String) -> Props? {
        let digest = Hashing.hex(Data((field + "\u{0}" + value).utf8))
        let fresh = lock.locked { () -> Bool in
            if seenSession != sessionId { seen = []; seenSession = sessionId }
            return seen.insert(digest).inserted
        }
        guard fresh else { return nil }
        let (plain, truncated) = Self.truncate(value)
        guard let ct = Self.encrypt(plain, key: key) else {
            lock.locked { _ = seen.remove(digest) }
            return nil
        }
        var p: Props = [
            "$exposure_field": .string(field), "$exposure_kid": .string(key.kid), "$exposure_ciphertext": .string(ct),
            "$screen_name": .string(screen),
        ]
        if truncated { p["$exposure_truncated"] = .bool(true) }
        return p
    }
}
