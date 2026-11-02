import Foundation
import Lucida
import OpenFeature
import XCTest

@testable import LucidaOpenFeature

final class LucidaProviderTests: XCTestCase {
    func testReasonTableMatchesSharedJSON() throws {
        // #filePath: sdks/ios/Tests/LucidaOpenFeatureTests/<file>; the repo root is five components up.
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { url.deleteLastPathComponent() }
        let data = try Data(contentsOf: url.appendingPathComponent("testdata/openfeature/reasons.json"))
        let root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        for (raw, v) in root["reasons"] as! [String: [String: String]] {
            XCTAssertEqual(ReasonMap.openFeature(raw, variantValue: false), v["reason"], raw)
            if let vr = v["variant_reason"] { XCTAssertEqual(ReasonMap.openFeature(raw, variantValue: true), vr, raw) }
        }
        XCTAssertEqual(ReasonMap.openFeature("brand_new", variantValue: false), "UNKNOWN")
    }

    func testFallbackMapsToDefaultWithoutError() {
        XCTAssertEqual(ReasonMap.openFeature("fallback", variantValue: true), "DEFAULT")
        let d = FlagDetails(value: .bool(true), payload: nil, variant: nil, reason: "fallback", conditionIndex: -1,
                            requestId: nil, evaluatedLocally: false)
        let m = LucidaProvider.metadata(d)
        XCTAssertEqual(m["lucidaReason"], .string("fallback"))
        XCTAssertNil(m["conditionIndex"])
    }

    func testMetadataCarriesLucidaFields() {
        let d = FlagDetails(value: .string("b"), payload: nil, variant: "b", reason: "condition_match", conditionIndex: 2,
                            requestId: "r1", evaluatedLocally: false)
        let m = LucidaProvider.metadata(d)
        XCTAssertEqual(m["conditionIndex"], .integer(2))
        XCTAssertEqual(m["requestId"], .string("r1"))
        XCTAssertEqual(m["evaluatedLocally"], .boolean(false))
    }

    func testContextSplit() {
        let ctx = ImmutableContext(targetingKey: "u1", structure: ImmutableStructure(attributes: [
            "plan": .string("pro"),
            "groups": .structure(["org": .string("acme")]),
            "groupProperties": .structure(["org": .structure(["size": .integer(5)])]),
        ]))
        let s = ContextMap.split(ctx)
        XCTAssertEqual(s.targetingKey, "u1")
        XCTAssertEqual(s.groups, ["org": "acme"])
        XCTAssertEqual(s.groupProperties["org"]?["size"], .number(5))
        XCTAssertEqual(s.personProperties, ["plan": .string("pro")])
    }
}
