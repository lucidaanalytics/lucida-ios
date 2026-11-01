import XCTest
@testable import Lucida

/// LC-ENG-15: guides from GET /v1/guides, targeted by screen, drawn through the presenter port.
final class GuidesTests: XCTestCase {
    final class FakePresenter: GuidePresenter {
        var shown: [(guide: String, step: Int, buttons: [String])] = []
        var tap: (([GuideButton]) -> GuideButton?)?
        var opened: [URL] = []
        func present(_ guide: MobileGuide, step: Int, buttons: [GuideButton], onAction: @escaping (GuideButton?) -> Void) {
            shown.append((guide.id, step, buttons.map(\.label)))
            if let tap { onAction(tap(buttons)) }
        }
        func open(_ url: URL) { opened.append(url) }
    }

    private let guidesJSON = #"""
    {"guides":[
      {"id":"g-tour","name":"Tour","kind":"tour","conditions":{"url":"Home","person_filters":[]},"steps":[{"id":"s1","title":"Hi"},{"id":"s2","body":"Last","buttons":[{"label":"Docs","action":"link","url":"https://docs.test/x"}]}]},
      {"id":"g-person","name":"P","kind":"modal","conditions":{"person_filters":[{"key":"plan","op":"eq","value":"pro"}]},"steps":[{"id":"a"}]},
      {"id":"g-hotspot","name":"H","kind":"hotspot","conditions":{},"steps":[{"id":"a","selector":"#x"}]},
      {"id":"g-flag","name":"F","kind":"banner","conditions":{"flag_key":"beta","url":"Set","url_match":"regex"},"steps":[{"id":"b"}]}
    ]}
    """#

    private func setup(_ flags: Set<String> = []) -> (GuidesService, FakePresenter, FakeTransport, Core) {
        let t = FakeTransport()
        let body = Data(guidesJSON.utf8)
        t.responder = { r in r.url.path.hasSuffix("/v1/guides") ? HTTPResponse(status: 200, body: body) : HTTPResponse(status: 200) }
        let p = FakePresenter()
        let cfg = makeConfig(transport: t) { $0.guides.enabled = true; $0.guides.presenter = p }
        let core = Core(config: cfg) { _ in }
        let g = GuidesService(core: core, config: cfg) { flags.contains($0) }
        g.onMain = { $0() }
        return (g, p, t, core)
    }

    func testTourOnItsScreenWithEventsAndShowOnce() async throws {
        let (g, p, t, core) = setup()
        g.show(on: "Settings")  // nothing loaded yet
        await g.reload()
        XCTAssertTrue(p.shown.isEmpty, "Settings: the tour wants Home, the banner's flag is off")
        let req = t.requests.first { $0.url.path.hasSuffix("/v1/guides") }!
        XCTAssertEqual(req.method, "GET")
        XCTAssertTrue(req.url.query!.contains("api_key=lc_pk_test"))
        XCTAssertTrue(req.url.query!.contains("distinct_id="))

        p.tap = { $0.first }  // Next, then the link button
        g.show(on: "HomeScreen")
        XCTAssertEqual(p.shown.map(\.guide), ["g-tour", "g-tour"])
        XCTAssertEqual(p.shown.map(\.step), [0, 1])
        XCTAssertEqual(p.shown[0].buttons, ["Next", "Dismiss"])
        XCTAssertEqual(p.shown[1].buttons, ["Docs"])
        XCTAssertEqual(p.opened, [URL(string: "https://docs.test/x")!])
        await core.queue.flush()
        let names = t.names()
        XCTAssertEqual(names.filter { $0.hasPrefix("$guide") }, ["$guide_shown", "$guide_step", "$guide_step", "$guide_completed"])

        p.shown = []
        g.show(on: "HomeScreen")
        XCTAssertTrue(p.shown.isEmpty, "shown once; person-targeted and hotspot guides never show on mobile")
    }

    func testFlagAndRegexTargetingAndDismiss() async {
        let (g, p, t, core) = setup(["beta"])
        await g.reload()
        p.tap = { _ in nil }  // closed without a button
        g.show(on: "Settings")
        XCTAssertEqual(p.shown.map(\.guide), ["g-flag"])
        XCTAssertEqual(p.shown[0].buttons, ["Dismiss"])
        await core.queue.flush()
        XCTAssertTrue(t.names().contains("$guide_dismissed"))
    }

    func testMatchModes() {
        XCTAssertTrue(GuidesService.matches("Checkout", "Check", "contains"))
        XCTAssertFalse(GuidesService.matches("Checkout", "Check", "exact"))
        XCTAssertTrue(GuidesService.matches("Checkout", "^Check.*t$", "regex"))
        XCTAssertFalse(GuidesService.matches("Checkout", "(", "regex"))
    }
}
