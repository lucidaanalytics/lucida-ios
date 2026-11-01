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

    private final class Shots: ScreenshotSource {
        var plan: ScreenshotMaskPlan?
        func screenshot(plan: ScreenshotMaskPlan, quality: Double) -> ScreenshotFrame? {
            self.plan = plan
            return ScreenshotFrame(jpeg: Data([0xff, 0xd8]), width: 390, height: 844)
        }
    }

    func testScreenshotModeMasksBeforeEncodingAndShipsTheJpeg() throws {
        let shots = Shots()
        let json = try XCTUnwrap(ReplayBridge.capture(screen: "Cart", screenshotQuality: 0.5, source: Source(), screenshots: shots, at: 5))
        XCTAssertTrue(json.contains("base64,") && json.contains("9g="))  // JSONEncoder may escape the slashes
        XCTAssertEqual(shots.plan?.mask.count, 2)  // the label and the input are painted over
        XCTAssertFalse(json.contains("Hello Ann"))
    }

    func testSwiftUIHostingViewIsAMaskedPlaceholder() throws {
        final class Hosted: ViewHierarchySource {
            func snapshot(screen: String) -> WireframeSnapshot? {
                WireframeSnapshot(screen: screen, width: 100, height: 100, root: WireframeNode(kind: .view, x: 0, y: 0, width: 100, height: 100, children: [
                    WireframeNode(kind: .view, x: 0, y: 0, width: 100, height: 50, opaque: true, children: [
                        WireframeNode(kind: .label, x: 4, y: 4, width: 60, height: 20, text: "Balance 42"),
                    ]),
                ]))
            }
        }
        let json = try XCTUnwrap(ReplayBridge.capture(screen: "S", source: Hosted()))
        XCTAssertTrue(json.contains("lc-wf-opaque"))
        XCTAssertTrue(json.contains("data-lc-mask"))
        XCTAssertFalse(json.contains("Balance 42"))
    }
}
