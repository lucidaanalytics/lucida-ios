import XCTest
@testable import Lucida
#if canImport(SwiftUI)
import SwiftUI
#endif

private final class MemKeys: QueueKeyStore, @unchecked Sendable {
    var key: Data?
    func load() -> Data? { key }
    func save(_ key: Data) { self.key = key }
}

final class KeychainCipherTests: XCTestCase {
    func testRoundTripAndKeyIsReusedAcrossInstances() {
        let keys = MemKeys()
        let a = KeychainQueueCipher(keyStore: keys)
        let enc = a.encrypt(#"{"event":"x"}"#)
        XCTAssertFalse(enc.contains("event"))
        XCTAssertNotEqual(enc, a.encrypt(#"{"event":"x"}"#), "fresh nonce per call")
        XCTAssertEqual(KeychainQueueCipher(keyStore: keys).decrypt(enc), #"{"event":"x"}"#)
    }

    func testWrongKeyOrGarbageDecryptsToNil() {
        let enc = KeychainQueueCipher(keyStore: MemKeys()).encrypt("secret")
        XCTAssertNil(KeychainQueueCipher(keyStore: MemKeys()).decrypt(enc))
        XCTAssertNil(KeychainQueueCipher(keyStore: MemKeys()).decrypt("not base64 !!"))
    }

    func testCorruptStoredKeyIsReplaced() {
        let keys = MemKeys()
        keys.key = Data([1, 2, 3])
        _ = KeychainQueueCipher(keyStore: keys)
        XCTAssertEqual(keys.key?.count, 32)
    }

    #if canImport(SwiftUI)
    func testSwiftUIModifiersCompile() {
        _ = Text("x").lucidaMask()
        _ = Text("y").lucidaUnmask()
    }
    #endif
}
