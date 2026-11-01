import XCTest
@testable import Lucida

/// LC-EXP-35: taps and swipes ride the next replay chunk, hit-tested against the last snapshot.
final class TouchTests: XCTestCase {
    private func chunks(_ t: FakeTransport) -> [[String: Any]] {
        t.requests.filter { $0.url.path.hasSuffix("/v1/replay") }.map { try! JSONSerialization.jsonObject(with: FakeTransport.plain($0)) as! [String: Any] }
    }

    func testTapsAndSwipesShipWithTheNextTick() async throws {
        let t = FakeTransport()
        let cfg = makeConfig(transport: t) { $0.replay.enabled = true; $0.replay.source = ReplayTests.FakeSource(); $0.replay.snapshotInterval = 3600 }
        let rec = ReplayRecorder(core: Core(config: cfg) { _ in }, config: cfg)!
        rec.tap(x: 1, y: 1)  // before any snapshot: nothing to hit-test against, dropped
        await rec.tick()
        rec.tap(x: 20, y: 25)  // the first label (id 4: body 3, label 4, its text 5, input 6)
        rec.tap(x: 20, y: 70)  // the input
        rec.swipe([TouchPoint(x: 200, y: 600, offsetMs: 0), TouchPoint(x: 200, y: 300, offsetMs: 120)])
        await rec.tick()  // layout unchanged: a chunk with the touches only
        await rec.tick()  // nothing new: nothing sent
        let cs = chunks(t)
        XCTAssertEqual(cs.count, 2)
        let evs = cs[1]["events"] as! [[String: Any]]
        XCTAssertEqual(evs.map { $0["type"] as? Int }, [3, 3, 3])
        let data = evs.map { $0["data"] as! [String: Any] }
        XCTAssertEqual(data[0]["source"] as? Int, 2)
        XCTAssertEqual(data[0]["type"] as? Int, 2)
        XCTAssertEqual(data[0]["id"] as? Int, 4)
        XCTAssertEqual(data[1]["id"] as? Int, 6)
        XCTAssertEqual(data[2]["source"] as? Int, 6)
        let pos = data[2]["positions"] as! [[String: Any]]
        XCTAssertEqual(pos.map { $0["y"] as? Int }, [600, 300])
        XCTAssertEqual(pos.map { $0["timeOffset"] as? Int }, [0, 120])
    }

    func testNoTouchesWithoutReplayConsent() async {
        let t = FakeTransport()
        let cfg = makeConfig(transport: t) { $0.replay.enabled = true; $0.replay.source = ReplayTests.FakeSource() }
        let core = Core(config: cfg) { _ in }
        let rec = ReplayRecorder(core: core, config: cfg)!
        await rec.tick()
        core.setConsent(replay: false)
        rec.tap(x: 20, y: 25)
        core.setConsent(replay: true)
        await rec.tick()  // the tap made while replay was revoked was dropped
        let evs = chunks(t).last!["events"] as! [[String: Any]]
        XCTAssertFalse(evs.contains { ($0["type"] as? Int) == 3 })
    }
}
