import XCTest
@testable import Lucida

final class CaptureTests: XCTestCase {
    func testBatchWireFormatAndLifecycleEvents() async throws {
        let t = FakeTransport()
        let life = FakeLifecycle()
        let c = LucidaClient(config: makeConfig(transport: t, lifecycle: life) { $0.appVersion = "1.0" })
        c.capture("hello", ["a": 1])
        life.bg?()
        life.fg?()
        await c.flush()
        let names = t.names()
        XCTAssertEqual(names.first, "$app_installed")
        for n in ["$app_opened", "hello", "$app_backgrounded"] { XCTAssertTrue(names.contains(n), n) }
        XCTAssertEqual(names.filter { $0 == "$app_opened" }.count, 2)
        let e = try XCTUnwrap(t.batchEvents().first { $0["event"] as? String == "hello" })
        let props = e["properties"] as! [String: Any]
        XCTAssertEqual(props["$lib"] as? String, "lucida-ios")
        XCTAssertNotNil(props["$session_id"])
        XCTAssertEqual(e["distinct_id"] as? String, c.distinctId)
        XCTAssertEqual((e["uuid"] as! String).count, 36)
        let body = try JSONSerialization.jsonObject(with: FakeTransport.plain(t.batchRequests[0])) as! [String: Any]
        XCTAssertEqual(body["api_key"] as? String, "lc_pk_test")
        XCTAssertNotNil(body["sent_at"])
        XCTAssertEqual(t.batchRequests[0].url.absoluteString, "https://ingest.test/v1/batch")
    }

    func testUpdateEventCarriesPreviousVersion() async {
        let store = MemoryKeyValueStore()
        let t1 = FakeTransport()
        let a = LucidaClient(config: makeConfig(transport: t1, store: store) { $0.appVersion = "1.0" })
        await a.flush()
        let t2 = FakeTransport()
        let b = LucidaClient(config: makeConfig(transport: t2, store: store) { $0.appVersion = "1.1" })
        await b.flush()
        let up = t2.batchEvents().first { $0["event"] as? String == "$app_updated" }
        XCTAssertEqual((up?["properties"] as? [String: Any])?["$previous_app_version"] as? String, "1.0")
    }

    func testLargeBatchIsGzipped() async {
        let t = FakeTransport()
        let c = LucidaClient(config: makeConfig(transport: t))
        for i in 0..<50 { c.capture("e\(i)", ["pad": .string(String(repeating: "x", count: 100))]) }
        await c.flush()
        XCTAssertEqual(t.batchRequests[0].headers["Content-Encoding"], "gzip")
        XCTAssertEqual(t.batchEvents().count, 51)  // 50 + $app_opened
    }

    func testRetryKeepsEventsThenDeliversAndNonRetryableDrops() async {
        let t = FakeTransport()
        let c = LucidaClient(config: makeConfig(transport: t))
        c.capture("x")
        t.responder = { _ in HTTPResponse(status: 503) }
        await c.flush()
        XCTAssertEqual(c.queuedEventCount, 2, "kept for retry")
        t.responder = { _ in HTTPResponse(status: 200) }
        await c.flush()
        XCTAssertEqual(c.queuedEventCount, 0)
        c.capture("bad")
        t.responder = { _ in HTTPResponse(status: 400) }
        await c.flush()
        XCTAssertEqual(c.queuedEventCount, 0, "400 is dropped, not retried forever")
    }

    func testQueueSurvivesRestartViaFileStore() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let t = FakeTransport()
        t.responder = { _ in HTTPResponse(status: 0) }  // offline
        let a = LucidaClient(config: makeConfig(transport: t, store: FileKeyValueStore(directory: dir)))
        a.capture("offline_event")
        await a.flush()
        XCTAssertGreaterThan(a.queuedEventCount, 0)
        let t2 = FakeTransport()
        let b = LucidaClient(config: makeConfig(transport: t2, store: FileKeyValueStore(directory: dir)))
        XCTAssertGreaterThan(b.queuedEventCount, 0, "persisted across launches")
        await b.flush()
        XCTAssertTrue(t2.names().contains("offline_event"))
        XCTAssertEqual(b.distinctId, a.distinctId, "identity persisted too")
    }

    func testBackoffGrowsAndIsJittered() {
        XCTAssertEqual(Backoff.delay(attempt: 0, random: 1), 1)
        XCTAssertEqual(Backoff.delay(attempt: 2, random: 0), 2)
        XCTAssertEqual(Backoff.delay(attempt: 20, random: 1), 30)
        XCTAssertTrue(Backoff.isRetryable(0) && Backoff.isRetryable(429) && Backoff.isRetryable(500))
        XCTAssertFalse(Backoff.isRetryable(400) || Backoff.isRetryable(401))
    }

    func testGzipRoundTripsThroughSystemGunzip() {
        let d = Data(String(repeating: "lucida ", count: 500).utf8)
        let z = Gzip.compress(d)!
        XCTAssertLessThan(z.count, d.count)
        XCTAssertEqual(FakeTransport.gunzip(z), d)
    }

    func testUUIDv7Shape() {
        let u = UUIDv7.make(nowMs: 1_800_000_000_000)
        XCTAssertTrue(u.range(of: "^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$", options: .regularExpression) != nil, u)
    }
}

final class IdentityTests: XCTestCase {
    func events(_ t: FakeTransport, _ name: String) -> [[String: Any]] { t.batchEvents().filter { $0["event"] as? String == name } }

    func testIdentifyLinksAnonOnceAliasGroupSuperPropsReset() async {
        let t = FakeTransport()
        let c = LucidaClient(config: makeConfig(transport: t))
        let anon = c.distinctId
        c.register(["plan": "pro"])
        c.identify("user-1", set: ["email_domain": "acme.com"])
        c.identify("user-1")
        c.alias("alias-1")
        c.group("company", "acme", properties: ["size": 5])
        c.capture("after")
        await c.flush()
        let ids = events(t, "$identify")
        XCTAssertEqual(ids.count, 1)
        XCTAssertEqual((ids[0]["properties"] as! [String: Any])["$anon_distinct_id"] as? String, anon)
        XCTAssertEqual((ids[0]["$set"] as! [String: Any])["email_domain"] as? String, "acme.com")
        XCTAssertEqual((events(t, "$create_alias")[0]["properties"] as! [String: Any])["alias"] as? String, "alias-1")
        let after = events(t, "after")[0]
        XCTAssertEqual((after["properties"] as! [String: Any])["plan"] as? String, "pro")
        XCTAssertEqual((after["$groups"] as! [String: String])["company"], "acme")
        XCTAssertEqual(after["distinct_id"] as? String, "user-1")
        c.reset()
        XCTAssertNotEqual(c.distinctId, "user-1")
        c.capture("post_reset")
        await c.flush()
        let post = events(t, "post_reset")[0]
        XCTAssertNil((post["properties"] as! [String: Any])["plan"])
        XCTAssertNil(post["$groups"])
    }

    func testSessionRotatesAfterIdle() {
        let clock = TestClock()
        let s = SessionManager(store: MemoryKeyValueStore(), clock: clock)
        let first = s.touch()
        clock.advance(60)
        XCTAssertEqual(s.touch().sessionId, first.sessionId)
        clock.advance(31 * 60)
        let next = s.touch()
        XCTAssertNotEqual(next.sessionId, first.sessionId)
        XCTAssertTrue(next.isNew)
    }
}

final class ConsentTests: XCTestCase {
    func testOptInWritesNothingAndSendsNothingUntilGranted() async {
        let store = MemoryKeyValueStore()
        let t = FakeTransport()
        let c = LucidaClient(config: makeConfig(transport: t, store: store) { $0.consentMode = .optIn })
        c.capture("x")
        c.identify("u1")
        await c.flush()
        XCTAssertEqual(store.count, 0, "no storage before consent")
        XCTAssertTrue(t.requests.isEmpty)
        c.optIn()
        XCTAssertNotNil(store.get("lc_identity"), "buffered state persisted on grant")
        c.capture("y")
        await c.flush()
        XCTAssertTrue(t.names().contains("y"))
        XCTAssertFalse(t.names().contains("x"), "pre-consent events are dropped by default")
    }

    func testQueueBeforeConsentReleasesHeldEvents() async {
        let t = FakeTransport()
        let c = LucidaClient(config: makeConfig(transport: t) { $0.consentMode = .optIn; $0.queueBeforeConsent = true })
        c.capture("held")
        await c.flush()
        XCTAssertTrue(t.requests.isEmpty)
        c.optIn()
        await c.flush()
        XCTAssertTrue(t.names().contains("held"))
        XCTAssertTrue(t.names().contains("$opt_in"))
    }

    func testOptOutClearsQueueAndStopsCapture() async {
        let t = FakeTransport()
        let c = LucidaClient(config: makeConfig(transport: t))
        c.capture("a")
        c.optOut()
        await c.flush()
        c.capture("b")
        await c.flush()
        XCTAssertFalse(t.names().contains("b"))
        XCTAssertFalse(c.consent.analytics)
    }

    func testDisabledIsInert() async {
        let t = FakeTransport()
        let c = LucidaClient(config: makeConfig(transport: t) { $0.disabled = true })
        c.capture("a")
        await c.flush()
        XCTAssertTrue(t.requests.isEmpty)
    }
}
