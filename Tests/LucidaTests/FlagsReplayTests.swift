import XCTest
@testable import Lucida

final class FlagsClientTests: XCTestCase {
    func testLocalEvalThenServerFallbackAndExposures() async throws {
        let t = FakeTransport()
        t.responder = { r in
            r.url.path.hasSuffix("/v1/flags")
                ? HTTPResponse(status: 200, body: Data(#"{"flags":{"remote":{"enabled":true,"value":"b","variant":"b","payload":{"k":1}}},"request_id":"r1"}"#.utf8))
                : HTTPResponse(status: 200)
        }
        let local = FlagDefinition(
            key: "on", type: "boolean", active: true, killSwitch: nil, salt: "s", variants: nil,
            conditions: [ConditionGroup(filters: nil, rolloutPct: 100, variantOverride: nil)],
            aggregation: FlagAggregation(kind: "person", groupType: nil), prerequisites: nil, payload: nil, namespace: nil, holdout: nil)
        var cohort = local
        cohort.key = "coh"
        cohort.conditions = [ConditionGroup(filters: [PropertyFilter(type: "cohort", key: "c", op: "in", value: nil, groupType: nil)], rolloutPct: 100, variantOverride: nil)]
        let c = LucidaClient(config: makeConfig(transport: t) { $0.localFlags = [local, cohort] })
        await c.reloadFlags()
        XCTAssertEqual(c.flag("on"), .bool(true))
        XCTAssertEqual(c.flag("remote"), .variant("b"))
        XCTAssertEqual(c.flagPayload("remote"), .object(["k": 1]))
        XCTAssertFalse(c.isFeatureEnabled("missing"))
        _ = c.flag("remote")  // deduped
        await c.flush()
        XCTAssertEqual(t.names().filter { $0 == "$feature_flag_called" }.count, 2)
        XCTAssertEqual(t.names().filter { $0 == "$exposure" }.count, 2)
        let req = t.requests.first { $0.url.path.hasSuffix("/v1/flags") }!
        let body = try JSONSerialization.jsonObject(with: req.body!) as! [String: Any]
        XCTAssertEqual(body["api_key"] as? String, "lc_pk_test")
        XCTAssertEqual(body["distinct_id"] as? String, c.distinctId)
    }
}

final class ReplayTests: XCTestCase {
    final class FakeSource: ViewHierarchySource {
        var text = "Hello Ann"
        func snapshot(screen: String) -> WireframeSnapshot? {
            WireframeSnapshot(screen: screen, width: 390, height: 844, root: WireframeNode(
                kind: .view, x: 0, y: 0, width: 390, height: 844, children: [
                    WireframeNode(kind: .label, x: 10, y: 20, width: 100, height: 20, text: text, background: "#ffffff"),
                    WireframeNode(kind: .input, x: 10, y: 60, width: 200, height: 30, text: "secret@x.com"),
                    WireframeNode(kind: .label, x: 10, y: 100, width: 100, height: 20, text: "4111 1111", sensitive: true),
                ]))
        }
    }

    func chunks(_ t: FakeTransport) -> [[String: Any]] {
        t.requests.filter { $0.url.path.hasSuffix("/v1/replay") }.map { try! JSONSerialization.jsonObject(with: FakeTransport.plain($0)) as! [String: Any] }
    }

    func testRrwebShapeMaskingAndSeq() async throws {
        let t = FakeTransport()
        let src = FakeSource()
        let cfg = makeConfig(transport: t) { $0.replay.enabled = true; $0.replay.source = src; $0.replay.snapshotInterval = 3600 }
        let rec = ReplayRecorder(core: Core(config: cfg) { _ in }, config: cfg)!
        rec.setScreen("Home")
        await rec.tick()
        await rec.tick()  // unchanged: nothing sent
        src.text = "Changed"
        await rec.tick()
        let cs = chunks(t)
        XCTAssertEqual(cs.count, 2, "second tick unchanged -> skipped")
        XCTAssertEqual(cs.map { $0["seq"] as? Int }, [0, 1])
        XCTAssertEqual(cs[0]["api_key"] as? String, "lc_pk_test")
        XCTAssertNotNil(cs[0]["session_id"]); XCTAssertNotNil(cs[0]["window_id"])
        let evs = cs[0]["events"] as! [[String: Any]]
        XCTAssertEqual(evs.map { $0["type"] as? Int }, [4, 5, 2])
        XCTAssertEqual((evs[0]["data"] as! [String: Any])["href"] as? String, "app://Home")
        XCTAssertEqual(((evs[1]["data"] as! [String: Any])["payload"] as! [String: Any])["url"] as? String, "app://Home")
        let json = String(data: try JSONSerialization.data(withJSONObject: evs[2]), encoding: .utf8)!
        XCTAssertFalse(json.contains("Hello"), "text masked by default")
        XCTAssertTrue(json.contains("**** ***"))
        XCTAssertFalse(json.contains("secret"), "input text never included")
        XCTAssertFalse(json.contains("4111"))
        let node = (evs[2]["data"] as! [String: Any])["node"] as! [String: Any]
        XCTAssertEqual(node["type"] as? Int, 0)
        let html = (node["childNodes"] as! [[String: Any]])[0]
        XCTAssertEqual(html["tagName"] as? String, "html")
    }

    func testNothingRecordedWithoutReplayConsent() async {
        let t = FakeTransport()
        let cfg = makeConfig(transport: t) { $0.replay.enabled = true; $0.replay.source = FakeSource() }
        let core = Core(config: cfg) { _ in }
        core.setConsent(analytics: true, replay: false)
        let rec = ReplayRecorder(core: core, config: cfg)!
        await rec.tick()
        XCTAssertTrue(chunks(t).isEmpty)
        core.setConsent(replay: true)
        await rec.tick()
        XCTAssertEqual(chunks(t).count, 1)
    }

    func testMaskingCanBeRelaxedButNotForInputs() {
        let s = FakeSource().snapshot(screen: "S")!
        let json = String(describing: RRWebWireframe.fullSnapshot(s, maskText: false, at: 0))
        XCTAssertTrue(json.contains("Hello Ann"))
        XCTAssertFalse(json.contains("secret"))
        XCTAssertFalse(json.contains("4111"))
    }
}

final class FlagFallbackTests: XCTestCase {
    private func client(status: Int, fallbacks: [String: JSONValue]) -> (LucidaClient, FakeTransport) {
        let t = FakeTransport()
        t.responder = { r in
            r.url.path.hasSuffix("/v1/flags")
                ? HTTPResponse(status: status, body: Data(#"{"flags":{"live":{"value":"b","reason":"condition_match","condition_index":2}},"request_id":"r9"}"#.utf8))
                : HTTPResponse(status: 200)
        }
        return (LucidaClient(config: makeConfig(transport: t) { $0.fallbacks = fallbacks }), t)
    }

    func testMissingFlagServesFallbackWithoutEvents() async {
        let (c, t) = client(status: 200, fallbacks: ["gone": .bool(true)])
        await c.reloadFlags()
        XCTAssertEqual(c.flag("gone"), .bool(true))
        let d = c.flagDetails("gone")
        XCTAssertEqual(d?.reason, "fallback")
        XCTAssertEqual(d?.value, .bool(true))
        await c.flush()
        XCTAssertFalse(t.names().contains("$feature_flag_called"))
        XCTAssertNil(c.flagDetails("nofb"))
    }

    func testNetworkFailureServesFallback() async {
        let (c, _) = client(status: 500, fallbacks: ["live": .string("fb")])
        await c.reloadFlags()
        XCTAssertEqual(c.flagDetails("live")?.reason, "fallback")
        XCTAssertEqual(c.flag("live"), .variant("fb"))
    }

    func testServedFlagKeepsRealReason() async {
        let (c, _) = client(status: 200, fallbacks: ["live": .string("fb")])
        await c.reloadFlags()
        let d = c.flagDetails("live")
        XCTAssertEqual(d?.value, .string("b"))
        XCTAssertEqual(d?.reason, "condition_match")
        XCTAssertEqual(d?.conditionIndex, 2)
        XCTAssertEqual(d?.requestId, "r9")
    }
}
