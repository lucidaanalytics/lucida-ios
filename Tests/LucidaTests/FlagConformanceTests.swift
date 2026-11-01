import XCTest
@testable import Lucida

/// Shared vectors in testdata/flags (the Go reference is go/internal/flageval).
final class FlagConformanceTests: XCTestCase {
    struct Expected: Decodable {
        var value: JSONValue
        var variant: String?
        var payload: JSONValue?
        var reason: String
        var conditionIndex: Int
        enum CodingKeys: String, CodingKey { case value, variant, payload, reason, conditionIndex = "condition_index" }
    }
    struct Vector: Decodable { var name: String; var flag: String; var context: EvalContext; var expected: Expected }
    struct HashVector: Decodable { var input: String; var numerator: Double; var hash: Double }
    struct File: Decodable { var hashVectors: [HashVector]?; var flags: [FlagDefinition]; var vectors: [Vector]
        enum CodingKeys: String, CodingKey { case hashVectors = "hash_vectors", flags, vectors }
    }

    static let dir = ProcessInfo.processInfo.environment["LUCIDA_TESTDATA"].map { URL(fileURLWithPath: $0).appendingPathComponent("flags") }
        ?? URL(fileURLWithPath: #filePath)  // Tests/LucidaTests/<this file>
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("testdata/flags")

    func run(_ name: String) throws {
        let data = try Data(contentsOf: Self.dir.appendingPathComponent(name))
        let file = try JSONDecoder().decode(File.self, from: data)
        for h in file.hashVectors ?? [] {
            XCTAssertEqual(Hashing.unit(h.input), h.hash, "hash \(h.input)")
        }
        var failures = 0
        for v in file.vectors {
            let got = FlagEvaluator.evaluateAll(file.flags, v.context)[v.flag]
            let wantValue: FlagValue = v.expected.value.boolValue.map { .bool($0) } ?? .variant(v.expected.value.stringValue ?? "")
            let ok = got?.value == wantValue && got?.reason == v.expected.reason && got?.conditionIndex == v.expected.conditionIndex
                && got?.variant == v.expected.variant && got?.payload == v.expected.payload
            if !ok {
                failures += 1
                if failures <= 5 { XCTFail("\(name) \(v.name): got \(String(describing: got)), want \(v.expected)") }
            }
        }
        XCTAssertEqual(failures, 0, "\(name): \(failures) of \(file.vectors.count) vectors failed")
        print("\(name): \(file.vectors.count) vectors, \(failures) failures")
    }

    func testBasic() throws { try run("vectors_basic.json") }
    func testG10() throws { try run("vectors_g10.json") }
    func testSticky() throws { try run("vectors_sticky.json") }
    func testSpecV2() throws { try run("vectors_ops.json") }
    func testGenerated() throws { try run("vectors.json") }
}
