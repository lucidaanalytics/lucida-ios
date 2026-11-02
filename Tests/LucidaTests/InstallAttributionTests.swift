import XCTest
@testable import Lucida

private struct StubSource: InstallAttributionSource {
    let props: Props
    func fetch() async -> Props { props }
}

private final class SeqTransport: HTTPTransport, @unchecked Sendable {
    var statuses: [Int]
    var bodies: [Data] = []
    var sent: [HTTPRequest] = []
    init(_ s: [Int]) { statuses = s }
    func send(_ request: HTTPRequest) async -> HTTPResponse {
        sent.append(request)
        let s = statuses.count > 1 ? statuses.removeFirst() : statuses[0]
        return HTTPResponse(status: s, body: Data(#"{"attribution":true,"orgId":1,"campaignId":2,"adGroupId":3,"keywordId":4,"adId":5,"conversionType":"Download"}"#.utf8))
    }
}

final class InstallAttributionTests: XCTestCase {
    func testMapsAttributedResponse() {
        let json = #"{"attribution":true,"orgId":40669820,"campaignId":542370539,"conversionType":"Download","adGroupId":542317095,"countryOrRegion":"US","keywordId":87675432,"adId":542317136}"#
        let p = appStoreInstallProps(responseJSON: Data(json.utf8))
        XCTAssertEqual(p["$install_store"], .string("app_store"))
        XCTAssertEqual(p["$install_adservices_attribution"], .bool(true))
        XCTAssertEqual(p["$utm_source"], .string("apple_search_ads"))
        XCTAssertEqual(p["$utm_medium"], .string("cpc"))
        XCTAssertEqual(p["$utm_campaign"], .string("542370539"))
        XCTAssertEqual(p["$utm_term"], .string("87675432"))
        XCTAssertEqual(p["$utm_content"], .string("542317095"))
        XCTAssertEqual(p["$asa_org_id"], .string("40669820"))
        XCTAssertEqual(p["$asa_conversion_type"], .string("Download"))
    }

    func testNotAttributedAndFailure() {
        let p = appStoreInstallProps(responseJSON: Data(#"{"attribution":false}"#.utf8))
        XCTAssertEqual(p["$install_adservices_attribution"], .bool(false))
        XCTAssertNil(p["$utm_source"])
        XCTAssertEqual(appStoreInstallProps(responseJSON: nil), ["$install_store": .string("app_store")])
    }

    func testAdServicesRetries404ThenMaps() async {
        let t = SeqTransport([404, 200])
        let s = AdServicesAttributionSource(transport: t, retryDelay: 0, attempts: 3) { "tok" }
        let p = await s.fetch()
        XCTAssertEqual(t.sent.count, 2)
        XCTAssertEqual(t.sent[0].headers["Content-Type"], "text/plain")
        XCTAssertEqual(p["$asa_campaign_id"], .string("2"))
    }

    func testNoTokenIsStoreOnly() async {
        let s = AdServicesAttributionSource(transport: SeqTransport([200]), retryDelay: 0) { nil }
        let p = await s.fetch()
        XCTAssertEqual(p, ["$install_store": .string("app_store")])
    }

    func testInstallSentOnceWithAttribution() async throws {
        let store = MemoryKeyValueStore()
        var counts: [Int] = []
        for run in 0..<2 {
            let t = FakeTransport()
            let c = LucidaClient(config: makeConfig(transport: t, store: store) {
                $0.appVersion = "1.0"
                $0.installAttribution = true
                $0.installAttributionSource = StubSource(props: ["$install_store": .string("app_store"), "$utm_source": .string("apple_search_ads")])
            })
            try await Task.sleep(nanoseconds: 200_000_000)
            await c.flush()
            let installs = t.batchEvents().filter { $0["event"] as? String == "$app_installed" }
            counts.append(installs.count)
            if run == 0 {
                let props = try XCTUnwrap(installs.first?["properties"] as? [String: Any])
                XCTAssertEqual(props["$utm_source"] as? String, "apple_search_ads")
            }
        }
        XCTAssertEqual(counts, [1, 0])
    }
}
