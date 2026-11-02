import XCTest
@testable import Lucida

/// N-DAP-10 / N-DAP-7 / N-DAP-9: anchored tooltip / hotspot / tour steps by native_id, carousel paging and themes.
final class GuidesAnchorTests: XCTestCase {
    final class FakeAnchored: AnchoredGuidePresenter {
        var plain: [(guide: String, step: Int, buttons: [String])] = []
        var anchored: [(guide: String, step: Int, anchor: GuideAnchor)] = []
        var missing = false
        var tap: (([GuideButton]) -> GuideButton?)?
        func present(_ guide: MobileGuide, step: Int, buttons: [GuideButton], onAction: @escaping (GuideButton?) -> Void) {
            plain.append((guide.id, step, buttons.map(\.label)))
            if let tap { onAction(tap(buttons)) }
        }
        func presentAnchored(_ guide: MobileGuide, step: Int, buttons: [GuideButton], anchor: GuideAnchor, onMissing: @escaping () -> Void, onAction: @escaping (GuideButton?) -> Void) {
            anchored.append((guide.id, step, anchor))
            if missing { onMissing(); return present(guide, step: step, buttons: buttons, onAction: onAction) }
            if let tap { onAction(tap(buttons)) }
        }
        func open(_ url: URL) {}
    }

    private func setup(_ json: String) -> (GuidesService, FakeAnchored, FakeTransport, Core) {
        let t = FakeTransport()
        let body = Data(json.utf8)
        t.responder = { r in r.url.path.hasSuffix("/v1/guides") ? HTTPResponse(status: 200, body: body) : HTTPResponse(status: 200) }
        let p = FakeAnchored()
        let cfg = makeConfig(transport: t) { $0.guides.enabled = true; $0.guides.presenter = p }
        let core = Core(config: cfg) { _ in }
        let g = GuidesService(core: core, config: cfg) { _ in false }
        g.onMain = { $0() }
        return (g, p, t, core)
    }

    func testTourStepsAnchorByNativeIdAndUnanchoredStepsShowPlain() async {
        let (g, p, _, _) = setup(#"{"guides":[{"id":"t","name":"T","kind":"tour","conditions":{},"steps":[{"id":"a","title":"A","native_id":"checkout","placement":"top","wait_ms":500},{"id":"b","title":"B"}]}]}"#)
        await g.reload()
        p.tap = { $0.first }
        g.show(on: "Home")
        XCTAssertEqual(p.anchored.map(\.step), [0])
        XCTAssertEqual(p.anchored[0].anchor, GuideAnchor(nativeId: "checkout", placement: "top", wait: 0.5, hotspot: false))
        XCTAssertEqual(p.plain.map(\.step), [1])
    }

    func testMissingTargetEmitsEventAndFallsBack() async {
        let (g, p, t, core) = setup(#"{"guides":[{"id":"tt","name":"T","kind":"tooltip","conditions":{},"steps":[{"id":"a","title":"A","native_id":"gone"}]}]}"#)
        p.missing = true
        await g.reload()
        g.show(on: "Home")
        XCTAssertEqual(p.plain.map(\.guide), ["tt"])
        await core.queue.flush()
        XCTAssertTrue(t.names().contains("$guide_target_missing"))
    }

    func testHotspotNeedsANativeIdAndAnchoredPresenter() async {
        let (g, p, _, _) = setup(##"{"guides":[{"id":"h0","name":"H","kind":"hotspot","conditions":{},"steps":[{"id":"a","selector":"#web"}]},{"id":"h1","name":"H","kind":"hotspot","conditions":{},"steps":[{"id":"a","native_id":"bell"}]}]}"##)
        await g.reload()
        g.show(on: "Home")
        XCTAssertEqual(p.anchored.map(\.guide), ["h1"])
        XCTAssertTrue(p.anchored[0].anchor.hotspot)
    }

    func testCarouselBackAndNext() async {
        let (g, p, _, _) = setup(#"{"guides":[{"id":"c","name":"C","kind":"carousel","conditions":{},"steps":[{"id":"1","title":"One"},{"id":"2","title":"Two"}]}]}"#)
        await g.reload()
        var taps = ["Next", "Back", "Next", "Done"]
        p.tap = { bs in let want = taps.removeFirst(); return bs.first { $0.label == want } }
        g.show(on: "Home")
        XCTAssertEqual(p.plain.map(\.step), [0, 1, 0, 1])
        XCTAssertEqual(p.plain[1].buttons, ["Back", "Done", "Dismiss"])
    }

    func testThemeTokensLightDarkAndValidation() {
        let a: [String: JSONValue] = [
            "tokens": .object(["background": .string("#ffffff"), "accent": .string("javascript:x"), "radius": .number(8)]),
            "dark": .object(["tokens": .object(["background": .string("#000")])]),
            "font_family": .string("Inter"),
        ]
        XCTAssertEqual(GuideTheme.tokens(a, systemDark: false).background, "#ffffff")
        XCTAssertEqual(GuideTheme.tokens(a, systemDark: true).background, "#000")
        XCTAssertNil(GuideTheme.tokens(a, systemDark: false).accent)
        XCTAssertEqual(GuideTheme.tokens(a, systemDark: false).font, "Inter")
        var light = a
        light["theme_mode"] = .string("light")
        XCTAssertEqual(GuideTheme.tokens(light, systemDark: true).background, "#ffffff")
        XCTAssertEqual(GuideTokens.rgb("#ff0000")?.r, 1)
    }

    func testQueuedFirstSkipsSamplingAndExclusionsMatchScreens() async {
        let (g, p, _, _) = setup(#"{"guides":[{"id":"plain","name":"P","kind":"modal","conditions":{},"steps":[{"id":"a"}]},{"id":"q","name":"Q","kind":"modal","queued":true,"conditions":{"sample_pct":1},"steps":[{"id":"a"}]},{"id":"x","name":"X","kind":"modal","conditions":{"exclude_url_patterns":["Check*"]},"steps":[{"id":"a"}]}]}"#)
        g.random = { 0.99 }
        await g.reload()
        p.tap = { _ in nil }
        g.show(on: "Checkout")
        XCTAssertEqual(p.plain.map(\.guide), ["q", "plain"], "queued first despite 1% sampling; x is excluded on Checkout")
        XCTAssertTrue(GuidesService.excluded("Checkout", ["Check*"]))
        XCTAssertFalse(GuidesService.excluded("Home", ["Check*", ""]))
        XCTAssertFalse(GuidesService.excluded("a.b", ["a?b"]))
        p.plain = []
        g.show(on: "Home")
        XCTAssertEqual(p.plain.map(\.guide), ["x"], "not excluded on Home")
    }

    func testPlacementBelowAboveAndClamped() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 800)
        let size = CGSize(width: 200, height: 100)
        XCTAssertEqual(GuidePlacement.origin(bubble: size, target: CGRect(x: 100, y: 100, width: 50, height: 40), bounds: bounds, placement: nil), CGPoint(x: 25, y: 148))
        XCTAssertEqual(GuidePlacement.origin(bubble: size, target: CGRect(x: 100, y: 740, width: 50, height: 40), bounds: bounds, placement: nil).y, 632)
        XCTAssertEqual(GuidePlacement.origin(bubble: size, target: CGRect(x: 380, y: 100, width: 20, height: 20), bounds: bounds, placement: nil).x, 188)
    }
}
