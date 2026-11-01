import XCTest
@testable import Lucida

final class ReplayGatingTests: XCTestCase {
    final class Src: ViewHierarchySource {
        var text = "Hello"
        func snapshot(screen: String) -> WireframeSnapshot? {
            WireframeSnapshot(screen: screen, width: 100, height: 200, root: WireframeNode(kind: .view, x: 0, y: 0, width: 100, height: 200, children: [
                WireframeNode(kind: .label, x: 10, y: 10, width: 50, height: 20, text: text),
                WireframeNode(kind: .input, x: 10, y: 40, width: 50, height: 20, text: "pw"),
                WireframeNode(kind: .label, x: 10, y: 70, width: 50, height: 20, text: "card", sensitive: true),
                WireframeNode(kind: .label, x: 10, y: 100, width: 50, height: 20, text: "open", unmask: true),
            ]))
        }
    }

    final class Shots: ScreenshotSource {
        var plans: [ScreenshotMaskPlan] = []
        func screenshot(plan: ScreenshotMaskPlan, quality: Double) -> ScreenshotFrame? {
            plans.append(plan)
            return ScreenshotFrame(jpeg: Data([0xff, 0xd8, UInt8(plans.count)]), width: 100, height: 200)
        }
    }

    func replayPosts(_ t: FakeTransport) -> [[String: Any]] {
        t.requests.filter { $0.url.path.hasSuffix("/v1/replay") }.map { try! JSONSerialization.jsonObject(with: FakeTransport.plain($0)) as! [String: Any] }
    }

    func recorder(_ t: FakeTransport, clock: TestClock = TestClock(), flag: @escaping (String) -> Bool = { _ in false },
                  _ tweak: (inout LucidaConfig) -> Void = { _ in }) -> (ReplayRecorder, Src) {
        let src = Src()
        let cfg = makeConfig(transport: t, clock: clock) { $0.replay.enabled = true; $0.replay.source = src; $0.replay.snapshotInterval = 3600; tweak(&$0) }
        return (ReplayRecorder(core: Core(config: cfg) { _ in }, config: cfg, flagEnabled: flag)!, src)
    }

    func configResponder(_ t: FakeTransport, _ json: String) {
        t.responder = { r in r.url.path.hasSuffix("/v1/config") ? HTTPResponse(status: 200, body: Data(json.utf8)) : HTTPResponse(status: 200) }
    }

    func testScreenListsDenyWins() {
        XCTAssertTrue(ReplayPolicy.screenAllowed("A", allow: [], deny: []))
        XCTAssertFalse(ReplayPolicy.screenAllowed("A", allow: ["B"], deny: []))
        XCTAssertFalse(ReplayPolicy.screenAllowed("A", allow: ["A"], deny: ["A"]))
        XCTAssertTrue(ReplayPolicy.screenAllowed("A", allow: [], deny: ["B"]))
    }

    func testRemoteConfigCanOnlyTighten() {
        var r = RemoteReplayConfig(); r.sampleRate = 0.5; r.minDurationMs = 3000
        XCTAssertEqual(ReplayPolicy.sampleRate(local: 1, remote: r), 0.5)
        XCTAssertEqual(ReplayPolicy.sampleRate(local: 0.1, remote: r), 0.1)
        XCTAssertEqual(ReplayPolicy.minDurationMs(local: 5000, remote: r), 5000)
        XCTAssertEqual(ReplayPolicy.minDurationMs(local: 0, remote: r), 3000)
        r.sessionRecording = false
        XCTAssertEqual(ReplayPolicy.sampleRate(local: 1, remote: r), 0)
        XCTAssertEqual(ReplayPolicy.sampleRate(local: 1, remote: nil), 1)
    }

    func testRemoteKillSwitchStopsRecording() async {
        let t = FakeTransport()
        configResponder(t, #"{"session_recording":false}"#)
        let (rec, _) = recorder(t)
        await rec.tick()
        XCTAssertEqual(replayPosts(t).count, 0)
        XCTAssertEqual(t.requests.filter { $0.url.path.hasSuffix("/v1/config") }.count, 1)
        XCTAssertEqual(t.requests.first { $0.url.path.hasSuffix("/v1/config") }?.url.query, "api_key=lc_pk_test")
    }

    func testRemoteConfigOptOutAndUnreachableKeepLocal() async {
        let t = FakeTransport()
        t.responder = { _ in HTTPResponse(status: 500) }
        let (rec, _) = recorder(t)
        await rec.tick()
        XCTAssertEqual(replayPosts(t).count, 1)
        let t2 = FakeTransport()
        configResponder(t2, #"{"session_recording":false}"#)
        let (rec2, _) = recorder(t2) { $0.replay.useRemoteConfig = false }
        await rec2.tick()
        XCTAssertEqual(replayPosts(t2).count, 1)
    }

    func testMinDurationHoldsThenFlushesInOrder() async {
        let t = FakeTransport(), clock = TestClock()
        let (rec, src) = recorder(t, clock: clock) { $0.replay.minDurationMs = 10_000 }
        await rec.tick()
        src.text = "Changed"
        clock.advance(4)
        await rec.tick()
        XCTAssertEqual(replayPosts(t).count, 0, "held until the session is long enough")
        src.text = "Again"
        clock.advance(7)
        await rec.tick()
        XCTAssertEqual(replayPosts(t).map { $0["seq"] as? Int }, [0, 1, 2])
    }

    func testMinDurationDropsWhenStoppedEarly() async {
        let t = FakeTransport(), clock = TestClock()
        let (rec, src) = recorder(t, clock: clock) { $0.replay.minDurationMs = 10_000 }
        await rec.tick()
        rec.stop()
        src.text = "x"
        clock.advance(20)
        await rec.tick()
        XCTAssertEqual(replayPosts(t).count, 1, "only the fresh snapshot after stop; the held chunk was dropped")
        XCTAssertEqual(replayPosts(t).first?["seq"] as? Int, 0)
    }

    func testRemoteMinDurationApplies() async {
        let t = FakeTransport()
        configResponder(t, #"{"session_recording":true,"replay_min_duration_ms":5000}"#)
        let (rec, _) = recorder(t)
        await rec.tick()
        XCTAssertEqual(replayPosts(t).count, 0)
    }

    func testLinkedFlagGatesRecording() async {
        let t = FakeTransport()
        nonisolated(unsafe) var on = false
        let (rec, _) = recorder(t, flag: { $0 == "replay-flag" && on }) { $0.replay.linkedFlag = "replay-flag" }
        await rec.tick()
        XCTAssertEqual(replayPosts(t).count, 0)
        on = true
        await rec.tick()
        XCTAssertEqual(replayPosts(t).count, 1)
        let (rec2, _) = recorder(FakeTransport(), flag: { _ in on }) { $0.replay.linkedFlag = "f" }
        rec2.start()
        defer { rec2.stop() }
        XCTAssertTrue(rec2.isActive)
        on = false
        XCTAssertFalse(rec2.isActive)
    }

    func testScreenDenyPausesAndResumesFresh() async {
        let t = FakeTransport(), clock = TestClock()
        let (rec, _) = recorder(t, clock: clock) { $0.replay.screenDenyList = ["Checkout"]; $0.replay.screenAllowList = ["Home", "Checkout"] }
        rec.setScreen("Home")
        await rec.tick()
        rec.setScreen("Checkout")
        await rec.tick()
        XCTAssertEqual(replayPosts(t).count, 1)
        rec.setScreen("Home")
        await rec.tick()
        XCTAssertEqual(replayPosts(t).count, 2, "re-entering an allowed screen sends a fresh snapshot")
        rec.setScreen("Other")
        await rec.tick()
        XCTAssertEqual(replayPosts(t).count, 2, "not on the allow list")
    }

    func testPauseResume() async {
        let t = FakeTransport()
        let (rec, _) = recorder(t)
        rec.start()
        defer { rec.stop() }
        XCTAssertTrue(rec.isActive)
        rec.pause()
        XCTAssertFalse(rec.isActive)
        await rec.tick()
        XCTAssertEqual(replayPosts(t).count, 0)
        rec.resume()
        XCTAssertTrue(rec.isActive)
    }

    func testScreenshotModeMasksBeforeEncodingAndEmitsImageNode() async throws {
        let t = FakeTransport(), shots = Shots()
        let (rec, _) = recorder(t) { $0.replay.mode = .screenshot; $0.replay.screenshotSource = shots }
        rec.setScreen("Home")
        await rec.tick()
        let plan = try XCTUnwrap(shots.plans.first)
        XCTAssertEqual(plan.sensitive, [MaskRect(x: 10, y: 70, width: 50, height: 20)])
        XCTAssertEqual(plan.unmask, [MaskRect(x: 10, y: 100, width: 50, height: 20)])
        XCTAssertTrue(plan.mask.contains(MaskRect(x: 10, y: 10, width: 50, height: 20)), "label text masked by default")
        XCTAssertTrue(plan.mask.contains(MaskRect(x: 10, y: 40, width: 50, height: 20)), "input masked by default")
        let evs = try XCTUnwrap(replayPosts(t).first?["events"] as? [[String: Any]])
        XCTAssertEqual(evs.map { $0["type"] as? Int }, [4, 5, 2])
        let json = String(decoding: try JSONSerialization.data(withJSONObject: evs[2]), as: UTF8.self)
        XCTAssertTrue(json.replacingOccurrences(of: "\\/", with: "/").contains("data:image/jpeg;base64,/9gB"))
        XCTAssertFalse(json.contains("Hello"), "no wireframe text in screenshot mode")
    }

    func testMarkerRegionsPrecedence() {
        let inner = WireframeNode(kind: .label, x: 5, y: 5, width: 10, height: 10, text: "secret")
        let free = WireframeNode(kind: .label, x: 80, y: 80, width: 10, height: 10, text: "free")
        let both = WireframeNode(kind: .label, x: 30, y: 30, width: 5, height: 5, text: "both")
        let root = WireframeNode(kind: .view, x: 0, y: 0, width: 100, height: 100, children: [
            WireframeNode(kind: .marker, x: 0, y: 0, width: 40, height: 40, sensitive: true),
            WireframeNode(kind: .marker, x: 20, y: 20, width: 60, height: 60, unmask: true),
            inner, free, both,
        ])
        let out = MarkerRegions.apply(root).children
        XCTAssertTrue(out[2].sensitive); XCTAssertNil(out[2].text)
        XCTAssertFalse(out[3].sensitive); XCTAssertFalse(out[3].unmask)
        XCTAssertTrue(out[4].sensitive, "mask wins over unmask")
        XCTAssertFalse(out[4].unmask)
    }
}
