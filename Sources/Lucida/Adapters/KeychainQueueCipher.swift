import CryptoKit
import Foundation
import Security

/// Where the 256-bit queue key lives. Adapter: `KeychainKeyStore`.
public protocol QueueKeyStore: AnyObject, Sendable {
    func load() -> Data?
    func save(_ key: Data)
}

/// Keychain-backed key: a generic password item, readable after first unlock, never synced or migrated to another device.
public final class KeychainKeyStore: QueueKeyStore, @unchecked Sendable {
    private let service: String, account: String
    public init(service: String = "dev.lucida.queue", account: String = "queue-key") { self.service = service; self.account = account }

    private var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    public func load() -> Data? {
        var q = base
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
    }

    public func save(_ key: Data) {
        SecItemDelete(base as CFDictionary)
        var q = base
        q[kSecValueData as String] = key
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }
}

/// `QueueCipher` (config.queueCipher): AES-256-GCM, key generated on first use and kept in the Keychain.
/// Ciphertext is base64 of nonce + ciphertext + tag. A lost or rotated key makes `decrypt` return nil, so the queue starts empty.
public final class KeychainQueueCipher: QueueCipher, @unchecked Sendable {
    private let key: SymmetricKey

    public init(keyStore: QueueKeyStore = KeychainKeyStore()) {
        if let existing = keyStore.load(), existing.count == 32 {
            key = SymmetricKey(data: existing)
        } else {
            key = SymmetricKey(size: .bits256)
            keyStore.save(key.withUnsafeBytes { Data($0) })
        }
    }

    public func encrypt(_ plain: String) -> String {
        guard let box = try? AES.GCM.seal(Data(plain.utf8), using: key), let combined = box.combined else { return "" }
        return combined.base64EncodedString()
    }

    public func decrypt(_ cipher: String) -> String? {
        guard let data = Data(base64Encoded: cipher), let box = try? AES.GCM.SealedBox(combined: data),
              let plain = try? AES.GCM.open(box, using: key) else { return nil }
        return String(data: plain, encoding: .utf8)
    }
}
