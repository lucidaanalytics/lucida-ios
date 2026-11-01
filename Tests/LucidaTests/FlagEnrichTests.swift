import XCTest
@testable import Lucida

/// Flag values on events (LC-FLG-28).
final class FlagEnrichTests: XCTestCase {
    private func flag(_ key: String, pct: Double) -> FlagDefinition {
        FlagDefinition(
            key: key, type: "boolean", active: true, killSwitch: nil, salt: "s", variants: nil,
            conditions: [ConditionGroup(filters: nil, rolloutPct: pct, variantOverride: nil)],
            aggregation: FlagAggregation(kind: "person", groupType: nil), prerequisites: nil, payload: nil, namespace: nil, holdout: nil)
    }

    private func props(_ t: FakeTransport, _ event: String) -> [String: Any] {
        (t.batchEvents().first { $0["event"] as? String == event }?["properties"] as? [String: Any]) ?? [:]
    }

    func testEventsCarryFlagValuesCallerWins() async {
        let t = FakeTransport()
        let c = LucidaClient(config: makeConfig(transport: t) { $0.localFlags = [flag("on", pct: 100), flag("off", pct: 0)] })
        await c.reloadFlags()
        c.capture("clicked", ["$feature/on": .string("mine")])
        await c.flush()
        let p = props(t, "clicked")
        XCTAssertEqual(p["$feature/on"] as? String, "mine")
        XCTAssertEqual(p["$feature/off"] as? Bool, false)
        XCTAssertEqual(p["$active_feature_flags"] as? [String], ["on"])
    }

    func testSendFeatureFlagsOffLeavesEventsAlone() async {
        let t = FakeTransport()
        let c = LucidaClient(config: makeConfig(transport: t) {
            $0.localFlags = [flag("on", pct: 100)]
            $0.flagOptions.sendFeatureFlags = false
        })
        await c.reloadFlags()
        c.capture("clicked")
        await c.flush()
        XCTAssertNil(props(t, "clicked")["$active_feature_flags"])
    }

    func testFlagEventPropsEmptyWithoutFlags() {
        XCTAssertTrue(FlagsService.flagEventProps([:]).isEmpty)
    }
}
