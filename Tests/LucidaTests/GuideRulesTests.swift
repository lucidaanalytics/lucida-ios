import XCTest
@testable import Lucida

/// G241: schedule recurrence, frequency caps, holdout and the guide-state view sync on iOS.
final class GuideRulesTests: XCTestCase {
    // Sunday 2026-11-01 12:00 UTC is Sunday 07:00 in New York.
    private let now = ISO8601DateFormatter().date(from: "2026-11-01T12:00:00Z")!

    func testScheduleRecurrenceInTheGuideZone() {
        let ny: [String: JSONValue] = ["days": .array([.number(0)]), "hours": .object(["from": .number(6), "to": .number(9)]), "timezone": .string("America/New_York")]
        XCTAssertTrue(GuideRules.scheduleOk(ny, now: now))
        XCTAssertFalse(GuideRules.scheduleOk(["days": .array([.number(1)]), "timezone": .string("UTC")], now: now))
        XCTAssertFalse(GuideRules.scheduleOk(["end": .string("2026-11-01T12:00:00Z")], now: now))
        XCTAssertTrue(GuideRules.scheduleOk(nil, now: now))
    }

    func testFrequencyAndMerge() {
        let ms = now.timeIntervalSince1970 * 1000
        let f: [String: JSONValue] = ["max_views": .number(2), "per_days": .number(7)]
        XCTAssertTrue(GuideRules.frequencyOk(f, views: [ms - 10 * 86_400_000, ms - 1000], now: now))
        XCTAssertFalse(GuideRules.frequencyOk(f, views: [ms - 2000, ms - 1000], now: now))
        XCTAssertFalse(GuideRules.frequencyOk([:], views: [1], now: now), "omitted: once per lifetime")
        let state: [String: JSONValue] = ["lc_guide_progress": .object(["t": .number(2)]), "lc_guide_views": .object(["g": .array([.number(1)])])]
        let m = GuideRules.merged(state, views: ["g": [1, 5], "h": [3]])
        XCTAssertEqual(m["lc_guide_progress"], state["lc_guide_progress"], "other keys are kept")
        XCTAssertEqual(m["lc_guide_views"]?.objectValue?["g"], .array([.number(1), .number(5)]))
        XCTAssertEqual(m["lc_guide_views"]?.objectValue?["h"], .array([.number(3)]))
    }

    func testHeldOutGuideNeverShowsAndFrequencyRepeats() async throws {
        let t = FakeTransport()
        let body = Data(#"""
        {"guides":[
          {"id":"g-held","name":"H","kind":"modal","held_out":true,"conditions":{"holdout_pct":50,"ab_group":"x"},"steps":[]},
          {"id":"g-twice","name":"T","kind":"modal","conditions":{"frequency":{"max_views":2}},"steps":[{"id":"a"}]}
        ]}
        """#.utf8)
        t.responder = { r in
            if r.url.path.hasSuffix("/v1/guides") { return HTTPResponse(status: 200, body: body) }
            if r.url.path.hasSuffix("/v1/guide-state") { return HTTPResponse(status: 200, body: Data(#"{"state":{"lc_guide_progress":{"t":1}}}"#.utf8)) }
            return HTTPResponse(status: 200)
        }
        let p = GuidesTests.FakePresenter()
        p.tap = { _ in nil }
        let cfg = makeConfig(transport: t) { $0.guides.enabled = true; $0.guides.presenter = p }
        let core = Core(config: cfg) { _ in }
        let g = GuidesService(core: core, config: cfg) { _ in false }
        g.onMain = { $0() }
        await g.reload()
        XCTAssertTrue(t.requests.first { $0.url.path.hasSuffix("/v1/guides") }!.url.query!.contains("tz="))
        g.show(on: "Home")
        g.show(on: "Home")  // once per screen visit
        g.show(on: "Settings")
        g.show(on: "Home")
        XCTAssertEqual(p.shown.map(\.guide), ["g-twice", "g-twice"], "shown up to its cap, the held-out guide never")
        await core.queue.flush()
        XCTAssertEqual(t.names().filter { $0 == "$guide_holdout" }.count, 1)
        await g.syncViews(["g-twice": [1]])
        let put = t.requests.last { $0.url.path.hasSuffix("/v1/guide-state") }!
        let sent = try JSONDecoder().decode([String: JSONValue].self, from: put.body!)
        XCTAssertEqual(sent["state"]?.objectValue?["lc_guide_progress"], .object(["t": .number(1)]))
        XCTAssertNotNil(sent["state"]?.objectValue?["lc_guide_views"]?.objectValue?["g-twice"])
    }
}
