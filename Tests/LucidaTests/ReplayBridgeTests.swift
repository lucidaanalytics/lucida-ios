import XCTest
@testable import Lucida

final class ReplayBridgeTests: XCTestCase {
    private final class Source: ViewHierarchySource {
        func snapshot(screen: String) -> WireframeSnapshot? {
            WireframeSnapshot(screen: screen, width: 390, height: 844, root: WireframeNode(
                kind: .view, x: 0, y: 0, width: 390, height: 844, children: [
                    WireframeNode(kind: .label, x: 10, y: 20, width: 100, height: 20, text: "Hello Ann"),
                    WireframeNode(kind: .input, x: 10, y: 60, width: 200, height: 30, text: "secret@x.com"),
                ]))
        }
    }

    func testCaptureReturnsMetaAndMaskedFullSnapshotAsJSON() throws {
        let json = try XCTUnwrap(ReplayBridge.capture(screen: "Cart", source: Source(), at: 5))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(obj["width"] as? Double, 390)
        let events = try XCTUnwrap(obj["events"] as? [[String: Any]])
        XCTAssertEqual(events.map { $0["type"] as? Int }, [4, 2])
        XCTAssertEqual((events[0]["data"] as? [String: Any])?["href"] as? String, "app://Cart")
        XCTAssertFalse(json.contains("Hello Ann"))  // starred by default
        XCTAssertFalse(json.contains("secret"))
    }

    func testMaskingCanBeRelaxedButNotForInputs() throws {
        let json = try XCTUnwrap(ReplayBridge.capture(screen: "Cart", maskText: false, source: Source()))
        XCTAssertTrue(json.contains("Hello Ann"))
        XCTAssertFalse(json.contains("secret"))
    }
}
