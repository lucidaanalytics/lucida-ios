import XCTest
@testable import Lucida

private func props(_ e: WireEvent?) -> Props { e?.properties ?? [:] }

private func makeCore(_ tweak: (inout LucidaConfig) -> Void = { _ in }, store: KeyValueStore = MemoryKeyValueStore(), t: FakeTransport = FakeTransport()) -> Core {
    Core(config: makeConfig(transport: t, store: store, tweak)) { _ in }
}

private struct Reverse: QueueCipher {
    func encrypt(_ plain: String) -> String { "enc:" + String(plain.reversed()) }
    func decrypt(_ cipher: String) -> String? { cipher.hasPrefix("enc:") ? String(cipher.dropFirst(4).reversed()) : nil }
}

private struct StubPolicy: NetworkPolicy { var isUnmetered: Bool }

final class HooksTests: XCTestCase {
    struct Boom: Error {}

    func testChainAmendsDropsAndKeepsEventWhenAHookThrows() {
        var logs: [String] = []
        let cfg = makeConfig(transport: FakeTransport()) {
            $0.beforeSend = [
                { var e = $0; e.properties["a"] = 1; return e },
                { _ in throw Boom() },
                { $0.event == "drop" ? nil : $0 },
                { var e = $0; e.properties["b"] = $0.properties["a"]; return e },
            ]
        }
        let core = Core(config: cfg) { logs.append($0) }
        let e = core.capture("keep")
        XCTAssertEqual(props(e)["a"], 1)
        XCTAssertEqual(props(e)["b"], 1)
        XCTAssertEqual(logs.count, 1)
        XCTAssertNil(core.capture("drop"))
        XCTAssertEqual(core.queue.count, 1)
    }

    func testSampleHookStampsSurvivors() throws {
        let ev = WireEvent(uuid: "u", event: "x", distinctId: "d", timestamp: "t", properties: ["p": 1])
        let keep = try XCTUnwrap(try sampleHook(0.5, random: { 0.1 })(ev))
        XCTAssertEqual(keep.properties["$sample_rate"], .number(0.5))
        XCTAssertEqual(keep.properties["p"], 1)
        XCTAssertNil(try sampleHook(0.5, random: { 0.9 })(ev))
        XCTAssertNil(try sampleHook(0, random: { 0 })(ev))
        XCTAssertEqual(try sampleHook(1, random: { 0.99 })(ev), ev)
    }
}

final class PersonProfilesTests: XCTestCase {
    func testAlwaysIsUnchanged() {
        XCTAssertNil(props(makeCore().capture("a"))["$process_person_profile"])
    }

    func testIdentifiedOnlyFlipsOnIdentifyPersistsAndResetClears() {
        let store = MemoryKeyValueStore()
        let c = makeCore({ $0.personProfiles = .identifiedOnly }, store: store)
        XCTAssertEqual(props(c.capture("a"))["$process_person_profile"], .bool(false))
        c.identify("u1")
        XCTAssertNil(props(c.capture("b"))["$process_person_profile"])
        let again = makeCore({ $0.personProfiles = .identifiedOnly }, store: store)
        XCTAssertNil(props(again.capture("c"))["$process_person_profile"])
        again.reset()
        XCTAssertEqual(props(again.capture("d"))["$process_person_profile"], .bool(false))
    }

    func testAnonDistinctIdIsSetOnlyAfterIdentify() {
        let c = makeCore()
        XCTAssertNil(c.anonDistinctId)
        let anon = c.distinctId
        c.identify("u1")
        XCTAssertEqual(c.anonDistinctId, anon)
    }

    func testIdentifiedOnlyFlipsOnPersonPropertyWrite() {
        let c = makeCore { $0.personProfiles = .identifiedOnly }
        c.capture("a", set: ["x": 1])
        XCTAssertNil(props(c.capture("b"))["$process_person_profile"])
    }

    func testNeverBlocksIdentityAndPersonWrites() throws {
        let c = makeCore { $0.personProfiles = .never }
        let id = c.distinctId
        c.identify("u1", set: ["a": 1])
        XCTAssertEqual(c.distinctId, id)
        c.alias("z")
        c.setPersonProperties(set: ["a": 1])
        let e = try XCTUnwrap(c.capture("a", set: ["a": 1]))
        XCTAssertNil(e.set)
        XCTAssertEqual(e.properties["$process_person_profile"], .bool(false))
        XCTAssertEqual(c.queue.count, 1)
    }
}

final class CoreOptionsTests: XCTestCase {
    func testBootstrapReuseAnonymousIdAndProvider() {
        let b = makeCore { $0.bootstrap = Bootstrap(distinctId: "boot-1", isIdentified: true) }
        XCTAssertEqual(b.distinctId, "boot-1")
        XCTAssertNil(b.anonDistinctId) // a bootstrap-identified user never linked its generated anon id
        b.reset()
        XCTAssertEqual(b.distinctId, b.anonymousId)
        let r = makeCore { $0.reuseAnonymousId = true; $0.anonymousIdProvider = { "anon-fixed" } }
        XCTAssertEqual(r.anonymousId, "anon-fixed")
        r.identify("u")
        r.reset()
        XCTAssertEqual(r.distinctId, "anon-fixed")
    }

    func testGeoipSessionExpiryAndPersonHelpers() throws {
        let clock = TestClock()
        let c = Core(config: makeConfig(transport: FakeTransport(), clock: clock) { $0.disableGeoip = true; $0.sessionIdleTimeout = 10 }) { _ in }
        XCTAssertEqual(props(c.capture("a"))["$geoip_disable"], .bool(true))
        let s1 = props(c.capture("b"))["$session_id"]
        clock.advance(11)
        XCTAssertNotEqual(props(c.capture("c"))["$session_id"], s1)
        c.setPersonProperties(set: ["a": 1], setOnce: ["b": 2])
        let batch = c.queue.count
        XCTAssertEqual(batch, 4)
    }

    func testClientHelpers() async throws {
        let t = FakeTransport()
        let c = LucidaClient(config: makeConfig(transport: t))
        c.setPersonProperties(set: ["a": 1], setOnce: ["b": 2])
        c.capture("x", set: ["k": "v"])
        XCTAssertFalse(c.isOptedOut)
        XCTAssertFalse(c.anonymousId.isEmpty)
        c.openURL(URL(string: "myapp://item/3?ref=a%20b&x=1")!, referrer: "ref://x")
        await c.flush()
        let evs = t.batchEvents()
        let set = try XCTUnwrap(evs.first { $0["event"] as? String == "$set" })
        XCTAssertEqual((set["$set"] as? [String: Any])?["a"] as? Int, 1)
        XCTAssertEqual((set["$set_once"] as? [String: Any])?["b"] as? Int, 2)
        let x = try XCTUnwrap(evs.first { $0["event"] as? String == "x" })
        XCTAssertEqual((x["$set"] as? [String: Any])?["k"] as? String, "v")
        let d = try XCTUnwrap(evs.first { $0["event"] as? String == "$deep_link_opened" })
        let p = d["properties"] as! [String: Any]
        XCTAssertEqual(p["query"] as? [String: String], ["ref": "a b", "x": "1"])
        XCTAssertEqual(p["referrer"] as? String, "ref://x")
        c.optOut()
        XCTAssertTrue(c.isOptedOut)
    }

    func testBatchSizeAndWifiGate() async {
        let t = FakeTransport()
        var wifi = false
        let c = Core(config: makeConfig(transport: t) {
            $0.maxBatchSize = 2
            $0.dataMode = .wifi
            $0.networkPolicy = StubPolicy(isUnmetered: false)
        }) { _ in }
        for i in 0..<5 { c.capture("e\(i)") }
        await c.queue.flush()
        XCTAssertTrue(t.batchRequests.isEmpty, "cellular must not flush in wifi-only mode")
        XCTAssertEqual(c.queue.count, 5)
        wifi = true
        let c2 = Core(config: makeConfig(transport: t) {
            $0.maxBatchSize = 2
            $0.dataMode = .wifi
            $0.networkPolicy = StubPolicy(isUnmetered: wifi)
        }) { _ in }
        for i in 0..<5 { c2.capture("e\(i)") }
        await c2.queue.flush()
        XCTAssertEqual(t.batchRequests.count, 3)  // 2 + 2 + 1
        XCTAssertEqual(c2.queue.count, 0)
    }

    func testEncryptedQueueAtRest() throws {
        let store = MemoryKeyValueStore()
        let c = makeCore({ $0.queueCipher = Reverse() }, store: store)
        c.capture("secret-event")
        let raw = try XCTUnwrap(store.get("lc_queue"))
        XCTAssertTrue(raw.hasPrefix("enc:"))
        XCTAssertFalse(raw.contains("secret-event"))
        XCTAssertEqual(makeCore({ $0.queueCipher = Reverse() }, store: store).queue.count, 1)
        store.set("lc_queue", "garbage")
        XCTAssertEqual(makeCore({ $0.queueCipher = Reverse() }, store: store).queue.count, 0)
    }

    func testTracingHeaders() {
        let c = LucidaClient(config: makeConfig(transport: FakeTransport()) { $0.tracingHeaders = ["api.example.com", ".corp.io", "ingest.test"] })
        func headers(_ u: String) -> [String: String] { c.tracedRequest(URLRequest(url: URL(string: u)!)).allHTTPHeaderFields ?? [:] }
        let h = headers("https://api.example.com/v1/x")
        XCTAssertEqual(h["X-Lucida-Distinct-Id"], c.distinctId)
        XCTAssertFalse((h["X-Lucida-Session-Id"] ?? "").isEmpty)
        XCTAssertEqual(h["baggage"], "lucida.session_id=\(h["X-Lucida-Session-Id"] ?? "")")
        var withApp = URLRequest(url: URL(string: "https://api.example.com/v1/x")!)
        withApp.setValue("a=1, lucida.session_id=old,b=2", forHTTPHeaderField: "baggage")
        XCTAssertEqual(c.tracedRequest(withApp).value(forHTTPHeaderField: "baggage"), "a=1,b=2,lucida.session_id=\(h["X-Lucida-Session-Id"] ?? "")")
        XCTAssertFalse(headers("https://a.corp.io/x").isEmpty)
        XCTAssertTrue(headers("https://corp.io/x").isEmpty)
        XCTAssertTrue(headers("https://other.com/x").isEmpty)
        XCTAssertTrue(headers("https://ingest.test/v1/batch").isEmpty, "never to the Lucida host")
        c.optOut()
        XCTAssertTrue(headers("https://api.example.com/v1/x").isEmpty)
    }
}

final class FlagOptionsTests: XCTestCase {
    private func client(_ tweak: @escaping (inout LucidaConfig) -> Void = { _ in }) -> (LucidaClient, FakeTransport) {
        let t = FakeTransport()
        t.responder = { r in r.url.path.hasSuffix("/v1/flags") ? HTTPResponse(status: 200, body: Data(#"{"flags":{"f":true}}"#.utf8)) : HTTPResponse(status: 200) }
        return (LucidaClient(config: makeConfig(transport: t, tweak)), t)
    }

    func testExposureToggleAndBootstrap() async {
        let (c, t) = client {
            $0.flagOptions.sendFeatureFlagEvent = false
            $0.flagOptions.preload = false
            $0.bootstrap = Bootstrap(flags: ["b": "v1"], payloads: ["b": ["k": 1]])
        }
        XCTAssertEqual(c.flag("b"), .variant("v1"))
        XCTAssertEqual(c.flagPayload("b"), ["k": 1])
        await c.flush()
        XCTAssertFalse(t.names().contains("$feature_flag_called"))
        XCTAssertTrue(t.requests.filter { $0.url.path.hasSuffix("/v1/flags") }.isEmpty, "preload=false must not load flags")
        let (c2, t2) = client { $0.flagOptions.preload = false }
        await c2.reloadFlags()
        _ = c2.flag("f")
        await c2.flush()
        XCTAssertTrue(t2.names().contains("$feature_flag_called"))
    }

    func testEvaluationPropertiesAndContexts() async throws {
        let (c, t) = client { $0.flagOptions.evaluationContexts = ["prod"]; $0.flagOptions.preload = false }
        var seen: [String: FlagValue] = [:]
        c.onFlags { seen = $0 }
        await c.setPersonPropertiesForFlags(["plan": "pro"], reload: false)
        XCTAssertTrue(t.requests.filter { $0.url.path.hasSuffix("/v1/flags") }.isEmpty)
        await c.setGroupPropertiesForFlags("company", ["tier": 2])
        let req = try XCTUnwrap(t.requests.last { $0.url.path.hasSuffix("/v1/flags") })
        let body = try JSONSerialization.jsonObject(with: req.body!) as! [String: Any]
        XCTAssertEqual((body["person_properties"] as? [String: Any])?["plan"] as? String, "pro")
        XCTAssertEqual(((body["group_properties"] as? [String: Any])?["company"] as? [String: Any])?["tier"] as? Int, 2)
        XCTAssertEqual(body["evaluation_contexts"] as? [String], ["prod"])
        XCTAssertEqual(seen["f"], .bool(true))
        await c.resetPersonPropertiesForFlags()
        let last = try XCTUnwrap(t.requests.last { $0.url.path.hasSuffix("/v1/flags") })
        XCTAssertTrue(((try JSONSerialization.jsonObject(with: last.body!) as! [String: Any])["person_properties"] as? [String: Any])?.isEmpty == true)
    }
}

final class AutocaptureTests: XCTestCase {
    private let btn = AutocaptureElement(name: "b", label: "Buy", props: ["id": "b", "secret": "s"])

    private func engine(_ cfg: AutocaptureConfig, _ core: Core = makeCore()) -> Autocapture {
        Autocapture(core: core, config: cfg, clock: TestClock())
    }

    func testDisabledByDefaultAndExclusionMarker() {
        XCTAssertNil(engine(AutocaptureConfig()).tap([btn], x: 0, y: 0))
        var on = AutocaptureConfig(); on.enabled = true
        let e = engine(on)
        XCTAssertNil(e.tap([btn, AutocaptureElement(name: "root", tag: "lucida-no-capture")], x: 0, y: 0))
        XCTAssertNotNil(e.tap([btn], x: 0, y: 0))
    }

    func testIgnoreLabelsMaxElementsAllowListAndNoInputValues() throws {
        var cfg = AutocaptureConfig()
        cfg.enabled = true; cfg.ignoreLabels = ["skip"]; cfg.maxElements = 2; cfg.propsAllowList = ["id"]
        let a = engine(cfg)
        let e = try XCTUnwrap(a.tap([btn, AutocaptureElement(name: "skip"), AutocaptureElement(name: "c"), AutocaptureElement(name: "d")], x: 1, y: 1))
        let els = try XCTUnwrap(e.properties["$elements"]?.arrayValue)
        XCTAssertEqual(els.count, 2)
        XCTAssertEqual(els[0].objectValue?["tag_name"], "b")
        XCTAssertEqual(els[0].objectValue?["attr__id"], "b")
        XCTAssertNil(els[0].objectValue?["attr__secret"])
        XCTAssertEqual(e.properties["$el_text"], "Buy")
        let input = try XCTUnwrap(a.tap([AutocaptureElement(name: "field", label: "hunter2", isInput: true)], x: 1, y: 1))
        XCTAssertEqual(input.properties["$el_text"], "")
        XCTAssertEqual(a.change([AutocaptureElement(name: "sw")])?.properties["$event_type"], "change")
    }

    func testRageTapsFireOnceAfterMinTaps() {
        let core = makeCore()
        var names: [String] = []
        core.onCaptured.append { names.append($0.event) }
        var cfg = AutocaptureConfig(); cfg.enabled = true
        let a = engine(cfg, core)
        for _ in 0..<3 { a.tap([btn], x: 10, y: 10) }
        XCTAssertEqual(names.filter { $0 == "$autocapture" }.count, 3)
        XCTAssertEqual(names.filter { $0 == "$rageclick" }.count, 1)
        let far = engine(cfg, core)
        for i in 0..<3 { far.tap([btn], x: Double(i) * 100, y: 0) }
        var off = cfg; off.rageTap.enabled = false
        let o = engine(off, core)
        for _ in 0..<4 { o.tap([btn], x: 1, y: 1) }
        XCTAssertEqual(names.filter { $0 == "$rageclick" }.count, 1)
    }
}

final class ReplayPrivacyTests: XCTestCase {
    private func tree(unmask: Bool = false) -> WireframeSnapshot {
        WireframeSnapshot(screen: "S", width: 10, height: 10, root: WireframeNode(kind: .view, x: 0, y: 0, width: 10, height: 10, children: [
            WireframeNode(kind: .input, x: 0, y: 0, width: 5, height: 5, text: "typed"),
            WireframeNode(kind: .input, x: 0, y: 0, width: 5, height: 5, text: "shown", unmask: true),
            WireframeNode(kind: .input, x: 0, y: 0, width: 5, height: 5, text: "pw", sensitive: true, unmask: true),
            WireframeNode(kind: .image, x: 0, y: 0, width: 5, height: 5),
            WireframeNode(kind: .image, x: 0, y: 0, width: 5, height: 5, unmask: true),
        ]))
    }

    private func json(_ v: JSONValue) -> String { String(decoding: try! JSONEncoder().encode(v), as: UTF8.self) }

    func testInputAndImageMasking() {
        let def = json(RRWebWireframe.fullSnapshot(tree(), maskText: true, at: 0))
        XCTAssertFalse(def.contains("typed"))
        XCTAssertTrue(def.contains("shown"), "explicit unmask")
        XCTAssertFalse(def.contains("\"pw\""))
        XCTAssertEqual(def.components(separatedBy: "data-lc-mask").count - 1, 1)
        let open = json(RRWebWireframe.fullSnapshot(tree(), maskText: true, maskInputs: false, at: 0))
        XCTAssertTrue(open.contains("typed"))
        XCTAssertFalse(open.contains("\"pw\""))
        XCTAssertFalse(json(RRWebWireframe.fullSnapshot(tree(), maskText: true, maskImages: false, at: 0)).contains("data-lc-mask"))
    }

    func testStartStopSamplingAndThrottle() async {
        let t = FakeTransport()
        var cfg = makeConfig(transport: t) { $0.replay.enabled = true; $0.replay.source = ReplayTests.FakeSource(); $0.replay.snapshotInterval = 3600 }
        let core = Core(config: cfg) { _ in }
        let rec = ReplayRecorder(core: core, config: cfg)!
        XCTAssertFalse(rec.isActive)
        rec.start()
        XCTAssertTrue(rec.isActive)
        rec.stop()
        XCTAssertFalse(rec.isActive)

        cfg.replay.sampleRate = 0
        let none = ReplayRecorder(core: core, config: cfg)!
        none.start()
        XCTAssertFalse(none.isActive)
        await none.tick()
        XCTAssertTrue(t.requests.filter { $0.url.path.hasSuffix("/v1/replay") }.isEmpty)
        none.stop()

        cfg.replay.sampleRate = 1
        cfg.replay.throttleDelay = 3600
        let src = ReplayTests.FakeSource()
        cfg.replay.source = src
        let t2 = FakeTransport()
        cfg.transport = t2
        let core2 = Core(config: cfg) { _ in }
        let thr = ReplayRecorder(core: core2, config: cfg)!
        await thr.tick()
        src.text = "Changed"
        await thr.tick()  // changed layout, but inside the throttle window
        XCTAssertEqual(t2.requests.filter { $0.url.path.hasSuffix("/v1/replay") }.count, 1)
    }
}
