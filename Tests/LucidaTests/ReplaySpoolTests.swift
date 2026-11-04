import XCTest
@testable import Lucida

final class ReplaySpoolTests: XCTestCase {
    struct Rev: QueueCipher {
        func encrypt(_ plain: String) -> String { "enc:" + String(plain.reversed()) }
        func decrypt(_ cipher: String) -> String? { cipher.hasPrefix("enc:") ? String(cipher.dropFirst(4).reversed()) : nil }
    }

    func keys(_ s: MemoryKeyValueStore) -> Int { s.count }

    func recorder(_ t: FakeTransport, store: MemoryKeyValueStore, _ src: ReplayGatingTests.Src, _ tweak: (inout LucidaConfig) -> Void = { _ in }) -> ReplayRecorder {
        let cfg = makeConfig(transport: t, store: store) {
            $0.replay.enabled = true; $0.replay.source = src; $0.replay.snapshotInterval = 3600; $0.replay.useRemoteConfig = false; tweak(&$0)
        }
        return ReplayRecorder(core: Core(config: cfg) { _ in }, config: cfg)!
    }

    func posts(_ t: FakeTransport) -> [[String: Any]] {
        t.requests.filter { $0.url.path.hasSuffix("/v1/replay") }.map { try! JSONSerialization.jsonObject(with: FakeTransport.plain($0)) as! [String: Any] }
    }

    func testOfflineChunksSpillSurviveRestartAndUploadInOrder() async {
        let t = FakeTransport(), store = MemoryKeyValueStore(), src = ReplayGatingTests.Src()
        t.responder = { _ in HTTPResponse(status: 0) }
        let r1 = recorder(t, store: store, src)
        await r1.tick()
        src.text = "Two"
        await r1.tick()
        XCTAssertNotNil(store.get("lc_replay.0"))
        XCTAssertNotNil(store.get("lc_replay.1"))

        let t2 = FakeTransport()
        let r2 = recorder(t2, store: store, src)  // new process, same store
        await r2.tick()
        XCTAssertEqual(posts(t2).prefix(2).map { $0["seq"] as? Int }, [0, 1])
        XCTAssertNil(store.get("lc_replay"))
    }

    func testRejectedChunkIsDroppedNotRetried() async {
        let t = FakeTransport(), store = MemoryKeyValueStore()
        t.responder = { _ in HTTPResponse(status: 400) }
        await recorder(t, store: store, ReplayGatingTests.Src()).tick()
        XCTAssertNil(store.get("lc_replay"))
    }

    func testSpilledChunksAreEncryptedWithTheQueueCipher() async {
        let t = FakeTransport(), store = MemoryKeyValueStore()
        t.responder = { _ in HTTPResponse(status: 0) }
        await recorder(t, store: store, ReplayGatingTests.Src()) { $0.queueCipher = Rev() }.tick()
        let body = store.get("lc_replay.0") ?? ""
        XCTAssertTrue(body.hasPrefix("enc:"))
        XCTAssertFalse(body.contains("session_id"))
    }

    func testClearSpoolErasesEverything() async {
        let t = FakeTransport(), store = MemoryKeyValueStore()
        t.responder = { _ in HTTPResponse(status: 0) }
        let r = recorder(t, store: store, ReplayGatingTests.Src())
        await r.tick()
        r.clearSpool()
        XCTAssertNil(store.get("lc_replay")); XCTAssertNil(store.get("lc_replay.0"))
    }

    func testOverBudgetDropsTheOldestWholeSessionAndReportsIt() {
        let store = MemoryKeyValueStore()
        nonisolated(unsafe) var dropped: [String] = []
        let s = ReplaySpool(store: store, budget: 100) { dropped.append("\($0):\($1):\($2)") }
        let body = Data(repeating: 0x78, count: 40)
        s.add(sid: "a", seq: 0, held: false, body: body)
        s.add(sid: "a", seq: 1, held: false, body: body)
        s.add(sid: "b", seq: 0, held: false, body: body)  // 120 > 100: all of a goes, not one chunk
        XCTAssertEqual(dropped, ["a:2:80"])
        XCTAssertEqual(s.entries.map(\.sid), ["b"])
        XCTAssertEqual(store.count, 2)  // index + one body
    }

    func testReloadedSpoolResumesSeq() {
        let store = MemoryKeyValueStore()
        let a = ReplaySpool(store: store, budget: 1000)
        a.add(sid: "a", seq: 0, held: true, body: Data("{}".utf8))
        a.add(sid: "a", seq: 1, held: true, body: Data("{}".utf8))
        let b = ReplaySpool(store: store, budget: 1000)
        XCTAssertEqual(b.entries.count, 2)
        XCTAssertEqual(b.nextSeq("a"), 2)
        XCTAssertEqual(b.nextSeq("z"), 0)
    }
}
