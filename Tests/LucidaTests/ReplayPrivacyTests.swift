import Security
import XCTest
@testable import Lucida

/// P-M17 masked screens, P-M46 text patterns and `$dead_swipe`, P-L12 controlled exposure.
final class ReplayPrivacyTests: XCTestCase {
    final class Src: ViewHierarchySource, ExposureReading {
        var label = "Order 1234"
        var fields: Set<String> = []
        var field = "4111 1111 1111 1111"
        private var taken: [(field: String, value: String)] = []
        func snapshot(screen: String) -> WireframeSnapshot? {
            if fields.contains("card") { taken = [(field: "card", value: field)] }
            return WireframeSnapshot(screen: screen, width: 100, height: 200, root: WireframeNode(kind: .view, x: 0, y: 0, width: 100, height: 200, children: [
                WireframeNode(kind: .label, x: 10, y: 10, width: 50, height: 20, text: label),
                WireframeNode(kind: .label, x: 10, y: 40, width: 50, height: 20, text: "open 42", unmask: true),
                WireframeNode(kind: .image, x: 10, y: 70, width: 50, height: 20, unmask: true),
            ]))
        }
        func setExposureFields(_ f: Set<String>) { fields = f }
        func takeExposed() -> [(field: String, value: String)] { defer { taken = [] }; return taken }
    }

    final class Shots: ScreenshotSource {
        var plans: [ScreenshotMaskPlan] = []
        func screenshot(plan: ScreenshotMaskPlan, quality: Double) -> ScreenshotFrame? {
            plans.append(plan)
            return ScreenshotFrame(jpeg: Data([0xff, 0xd8, UInt8(plans.count)]), width: 100, height: 200)
        }
    }

    final class Events: @unchecked Sendable {
        var list: [(String, Props)] = []
    }

    private func recorder(_ t: FakeTransport, clock: TestClock = TestClock(), _ tweak: (inout LucidaConfig) -> Void = { _ in }) -> (ReplayRecorder, Src, Events) {
        let src = Src(), ev = Events()
        let cfg = makeConfig(transport: t, clock: clock) { $0.replay.enabled = true; $0.replay.source = src; $0.replay.snapshotInterval = 3600; tweak(&$0) }
        let rec = ReplayRecorder(core: Core(config: cfg) { _ in }, config: cfg, capture: { ev.list.append(($0, $1)) })!
        return (rec, src, ev)
    }

    private func replayText(_ t: FakeTransport) -> String {
        t.requests.filter { $0.url.path.hasSuffix("/v1/replay") }.map { String(decoding: FakeTransport.plain($0), as: UTF8.self) }.joined()
    }

    private func respond(_ t: FakeTransport, _ json: String) {
        t.responder = { r in r.url.path.hasSuffix("/v1/config") ? HTTPResponse(status: 200, body: Data(json.utf8)) : HTTPResponse(status: 200) }
    }

    // MARK: P-M17

    func testScreenMaskedPatterns() {
        XCTAssertTrue(ReplayPolicy.screenMasked("Checkout", patterns: ["Checkout"]))
        XCTAssertFalse(ReplayPolicy.screenMasked("CheckoutDone", patterns: ["Checkout"]), "whole-name match")
        XCTAssertTrue(ReplayPolicy.screenMasked("PaymentSheet", patterns: ["pay*"]))
        XCTAssertTrue(ReplayPolicy.screenMasked("UserSettings", patterns: ["*settings"]))
        XCTAssertTrue(ReplayPolicy.screenMasked("a-b-c", patterns: ["a*c"]))
        XCTAssertTrue(ReplayPolicy.screenMasked("checkout", patterns: ["CHECKOUT"]))
        XCTAssertFalse(ReplayPolicy.screenMasked("Home", patterns: ["pay*"]))
        XCTAssertFalse(ReplayPolicy.screenMasked("Home", patterns: []))
        XCTAssertTrue(ReplayPolicy.screenMasked("", patterns: ["*"]))
    }

    func testRemoteConfigParsesPrivacyKeys() throws {
        let json = #"{"replay_mask_screens":["Pay*"],"replay_mask_text_patterns":["\\d+",7],"replay_exposure_fields":["card"],"replay_exposure_key":{"kid":"k1","n":"AQ","e":"AQAB","pkcs1":"AA=="}}"#
        let r = try XCTUnwrap(RemoteReplayConfig(json: Data(json.utf8)))
        XCTAssertEqual(r.maskScreens, ["Pay*"])
        XCTAssertEqual(r.maskTextPatterns, [#"\d+"#])
        XCTAssertEqual(r.exposureFields, ["card"])
        XCTAssertEqual(r.exposureKey?.kid, "k1")
        XCTAssertNil(RemoteReplayConfig(json: Data(#"{"replay_exposure_key":{"kid":"k"}}"#.utf8))?.exposureKey, "incomplete key = off")
    }

    func testMaskedScreenStarsUnmaskedTextLocalAndRemote() async {
        let t = FakeTransport()
        let (rec, _, _) = recorder(t) { $0.replay.maskText = false }
        rec.setScreen("Checkout")
        await rec.tick()
        XCTAssertTrue(replayText(t).contains("open 42"), "not masked without a pattern")

        let t2 = FakeTransport()
        respond(t2, #"{"replay_mask_screens":["check*"]}"#)
        let (rec2, _, _) = recorder(t2) { $0.replay.maskText = false }
        rec2.setScreen("Checkout")
        await rec2.tick()
        let text = replayText(t2)
        XCTAssertFalse(text.contains("open 42"))
        XCTAssertFalse(text.contains("Order"))
        XCTAssertTrue(text.contains("data-lc-mask"), "the unmasked image is masked too")

        let t3 = FakeTransport()
        let (rec3, _, _) = recorder(t3) { $0.replay.maskText = false; $0.replay.maskScreens = ["CHECKOUT"] }
        rec3.setScreen("Checkout")
        await rec3.tick()
        XCTAssertFalse(replayText(t3).contains("open 42"))
    }

    func testMaskedScreenScreenshotPlanMasksEverything() async {
        let t = FakeTransport(), shots = Shots()
        let (rec, _, _) = recorder(t) { $0.replay.mode = .screenshot; $0.replay.screenshotSource = shots; $0.replay.maskScreens = ["Pay*"] }
        rec.setScreen("Payment")
        await rec.tick()
        let plan = shots.plans[0]
        XCTAssertTrue(plan.unmask.isEmpty, "unmask markers do not count on a masked screen")
        XCTAssertEqual(plan.mask.count, 3)
    }

    // MARK: P-M46 text patterns

    func testMaskPatternsStarsMatchesKeepsWhitespace() {
        let res = ReplayMasking.compile([#"\d+"#, "(", #"\bsecret\b"#])
        XCTAssertEqual(res.count, 2, "the invalid pattern is ignored")
        XCTAssertEqual(ReplayMasking.maskPatterns("Order 1234 secret code", res), "Order **** ****** code")
        XCTAssertEqual(ReplayMasking.maskPatterns("card 4111 1111", ReplayMasking.compile([#"\d{4} \d{4}"#])), "card **** ****")
        XCTAssertEqual(ReplayMasking.maskPatterns("nothing", res), "nothing")
        XCTAssertEqual(ReplayMasking.maskPatterns("é 12", res), "é **")
        XCTAssertEqual(ReplayMasking.maskPatterns("abc", []), "abc")
    }

    func testPatternsStarUnmaskedWireframeTextAndPaintScreenshots() async {
        let t = FakeTransport()
        respond(t, #"{"replay_mask_text_patterns":["\\d+"]}"#)
        let (rec, _, _) = recorder(t) { $0.replay.maskText = false }
        await rec.tick()
        let text = replayText(t)
        XCTAssertTrue(text.contains("Order ****"))
        XCTAssertTrue(text.contains("open **"))

        let t2 = FakeTransport(), shots = Shots()
        let (rec2, _, _) = recorder(t2) { $0.replay.mode = .screenshot; $0.replay.screenshotSource = shots; $0.replay.maskTextPatterns = [#"\d+"#] }
        await rec2.tick()
        XCTAssertEqual(shots.plans[0].sensitive.count, 2, "both texts with digits are painted last")
    }

    // MARK: P-M46 dead swipe

    func testSwipeDirectionAndDecision() {
        XCTAssertEqual(DeadSwipe.direction(dx: -60, dy: 10), "left")
        XCTAssertEqual(DeadSwipe.direction(dx: 60, dy: -10), "right")
        XCTAssertEqual(DeadSwipe.direction(dx: 5, dy: -70), "up")
        XCTAssertEqual(DeadSwipe.direction(dx: 5, dy: 70), "down")
        let p = DeadSwipe.decide(screen: "A", startScreen: "A", startFingerprint: "x", endFingerprint: "x", dx: 0, dy: -100.4, nowMs: 5000, lastAt: nil)
        XCTAssertEqual(p?["$swipe_direction"], "up")
        XCTAssertEqual(p?["$swipe_distance"], 100)
        XCTAssertEqual(p?["$screen_name"], "A")
        XCTAssertNil(DeadSwipe.decide(screen: "A", startScreen: "A", startFingerprint: "x", endFingerprint: "x", dx: 30, dy: 30, nowMs: 0, lastAt: nil), "under 48 pt")
        XCTAssertNil(DeadSwipe.decide(screen: "A", startScreen: "A", startFingerprint: "x", endFingerprint: "y", dx: 100, dy: 0, nowMs: 0, lastAt: nil), "content moved")
        XCTAssertNil(DeadSwipe.decide(screen: "B", startScreen: "A", startFingerprint: "x", endFingerprint: "x", dx: 100, dy: 0, nowMs: 0, lastAt: nil), "navigated")
        XCTAssertNil(DeadSwipe.decide(screen: "A", startScreen: "A", startFingerprint: "x", endFingerprint: "x", dx: 100, dy: 0, nowMs: 1999, lastAt: 0), "cooldown")
        XCTAssertNotNil(DeadSwipe.decide(screen: "A", startScreen: "A", startFingerprint: "x", endFingerprint: "x", dx: 100, dy: 0, nowMs: 2000, lastAt: 0))
    }

    func testRecorderEmitsDeadSwipeOnlyWhenNothingChanged() async {
        let t = FakeTransport(), clock = TestClock()
        let (rec, src, ev) = recorder(t, clock: clock)
        rec.deadSwipeSettle = 0
        rec.setScreen("Feed")
        rec.swipeBegan()
        await rec.swipeEnded(from: TouchPoint(x: 200, y: 600, offsetMs: 0), to: TouchPoint(x: 200, y: 400, offsetMs: 100))
        XCTAssertTrue(ev.list.isEmpty, "no snapshot sent yet: not recording")
        await rec.tick()
        rec.swipeBegan()
        await rec.swipeEnded(from: TouchPoint(x: 200, y: 600, offsetMs: 0), to: TouchPoint(x: 200, y: 400, offsetMs: 100))
        XCTAssertEqual(ev.list.map { $0.0 }, ["$dead_swipe"])
        XCTAssertEqual(ev.list[0].1, ["$screen_name": "Feed", "$swipe_direction": "up", "$swipe_distance": 200])
        rec.swipeBegan()
        await rec.swipeEnded(from: TouchPoint(x: 0, y: 0, offsetMs: 0), to: TouchPoint(x: 100, y: 0, offsetMs: 100))
        XCTAssertEqual(ev.list.count, 1, "2 s cooldown")
        clock.advance(3)
        rec.swipeBegan()
        src.label = "Order 99999"  // the swipe scrolled / changed something
        await rec.swipeEnded(from: TouchPoint(x: 0, y: 0, offsetMs: 0), to: TouchPoint(x: 100, y: 0, offsetMs: 100))
        XCTAssertEqual(ev.list.count, 1)
    }

    func testNoDeadSwipeWhenDisabled() async {
        let t = FakeTransport()
        let (rec, _, ev) = recorder(t) { $0.replay.captureDeadSwipes = false }
        rec.deadSwipeSettle = 0
        await rec.tick()
        rec.swipeBegan()
        await rec.swipeEnded(from: TouchPoint(x: 0, y: 0, offsetMs: 0), to: TouchPoint(x: 100, y: 0, offsetMs: 100))
        XCTAssertTrue(ev.list.isEmpty)
    }

    // MARK: P-L12 controlled exposure

    private func keyPair() throws -> (SecKey, String) {
        let attrs: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048]
        let priv = try XCTUnwrap(SecKeyCreateRandomKey(attrs as CFDictionary, nil))
        let pub = try XCTUnwrap(SecKeyCopyPublicKey(priv))
        let der = try XCTUnwrap(SecKeyCopyExternalRepresentation(pub, nil)) as Data  // PKCS#1 RSAPublicKey for RSA keys
        return (priv, der.base64EncodedString())
    }

    private func decrypt(_ priv: SecKey, _ b64: String) throws -> String {
        let ct = try XCTUnwrap(Data(base64Encoded: b64))
        XCTAssertEqual(ct.count, 256)
        let plain = try XCTUnwrap(SecKeyCreateDecryptedData(priv, .rsaEncryptionOAEPSHA256, ct as CFData, nil)) as Data
        return String(decoding: plain, as: UTF8.self)
    }

    func testTruncateOnCharacterBoundary() {
        let (d, cut) = SensitiveCapture.truncate(String(repeating: "a", count: 189) + "é")
        XCTAssertEqual(d.count, 189)
        XCTAssertTrue(cut)
        let (d2, cut2) = SensitiveCapture.truncate("short")
        XCTAssertEqual(d2, Data("short".utf8))
        XCTAssertFalse(cut2)
    }

    func testEncryptRoundTripAndBadKey() throws {
        let (priv, pkcs1) = try keyPair()
        let ct = try XCTUnwrap(SensitiveCapture.encrypt(Data("4111".utf8), key: ExposureKey(kid: "k", n: "", e: "", pkcs1: pkcs1)))
        XCTAssertEqual(try decrypt(priv, ct), "4111")
        XCTAssertNil(SensitiveCapture.encrypt(Data("x".utf8), key: ExposureKey(kid: "k", n: "", e: "", pkcs1: "bm9wZQ==")))
    }

    func testCaptureSensitiveExplicitAndAutomaticWithDedupe() async throws {
        let (priv, pkcs1) = try keyPair()
        let t = FakeTransport()
        respond(t, #"{"replay_exposure_fields":["card","iban"],"replay_exposure_key":{"kid":"k1","n":"x","e":"AQAB","pkcs1":"\#(pkcs1)"}}"#)
        let (rec, _, ev) = recorder(t)
        rec.setScreen("Pay")
        rec.captureSensitive("card", value: "4111")
        XCTAssertTrue(ev.list.isEmpty, "remote config not loaded yet")
        await rec.tick()  // loads the config; the walk reads the listed field
        XCTAssertEqual(ev.list.map { $0.0 }, ["$sensitive_capture"])
        let p = ev.list[0].1
        XCTAssertEqual(p["$exposure_field"], "card")
        XCTAssertEqual(p["$exposure_kid"], "k1")
        XCTAssertEqual(p["$screen_name"], "Pay")
        XCTAssertNil(p["$exposure_truncated"])
        XCTAssertEqual(try decrypt(priv, try XCTUnwrap(p["$exposure_ciphertext"]?.stringValue)), "4111 1111 1111 1111")
        XCTAssertFalse(replayText(t).contains("4111"), "never in the replay")
        await rec.tick()
        XCTAssertEqual(ev.list.count, 1, "same value: not re-sent")
        rec.captureSensitive("iban", value: String(repeating: "x", count: 300))
        XCTAssertEqual(ev.list.last?.1["$exposure_truncated"], true)
        rec.captureSensitive("email", value: "a@b.c")
        XCTAssertEqual(ev.list.count, 2, "unlisted field: nothing sent")
    }
}
