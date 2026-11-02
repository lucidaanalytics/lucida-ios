import Combine
import Foundation
import Lucida
import OpenFeature

/// OpenFeature provider over the Lucida iOS SDK (static-context paradigm).
/// `initialize` / `onContextSet` identify the targeting key, apply attributes as person properties and reload flags;
/// reads are synchronous over the loaded flags. Written against open-feature/swift-sdk 0.7.x.
public final class LucidaProvider: FeatureProvider, @unchecked Sendable {
    public static let name = "Lucida"
    public let hooks: [any Hook] = []
    public let metadata: ProviderMetadata = LucidaMetadata()
    private let client: LucidaClient
    // keeps `status` in step with the events sent, and replays the current status to late subscribers
    private let tracker = ProviderStatusTracker()

    public struct LucidaMetadata: ProviderMetadata { public var name: String? = LucidaProvider.name }

    public init(client: LucidaClient) {
        self.client = client
        client.onFlagsStatus { [tracker] status in
            switch status {
            case .changed: tracker.send(.configurationChanged(nil))
            case .stale: tracker.send(.stale(nil))
            case .error: tracker.send(.error(ProviderEventDetails(message: "Lucida flag load failed", errorCode: .general)))
            }
        }
    }

    public var status: ProviderStatus { tracker.status }

    public func observe() -> AnyPublisher<ProviderEvent, Never> { tracker.observe() }

    public func initialize(initialContext: EvaluationContext?) -> Future<Void, Never> {
        Future { [self] promise in
            Task {
                await apply(initialContext)
                tracker.send(.ready(nil))
                promise(.success(()))
            }
        }
    }

    public func onContextSet(oldContext: EvaluationContext?, newContext: EvaluationContext) -> Future<Void, Never> {
        tracker.send(.reconciling(nil))
        return Future { [self] promise in
            Task {
                await apply(newContext)
                tracker.send(.contextChanged(nil))
                promise(.success(()))
            }
        }
    }

    private func apply(_ ctx: EvaluationContext?) async {
        let s = ContextMap.split(ctx)
        if !s.targetingKey.isEmpty && s.targetingKey != client.distinctId { client.identify(s.targetingKey) }
        for (t, key) in s.groups { client.group(t, key, properties: s.groupProperties[t] ?? [:]) }
        await client.setPersonPropertiesForFlags(s.personProperties, reload: false)
        for (t, props) in s.groupProperties where s.groups[t] == nil { await client.setGroupPropertiesForFlags(t, props, reload: false) }
        await client.reloadFlags()
    }

    // MARK: Evaluations

    public func getBooleanEvaluation(key: String, defaultValue: Bool, context: EvaluationContext?) throws -> ProviderEvaluation<Bool> {
        resolve(key, defaultValue) { $0.boolValue }
    }

    public func getStringEvaluation(key: String, defaultValue: String, context: EvaluationContext?) throws -> ProviderEvaluation<String> {
        resolve(key, defaultValue) { $0.stringValue }
    }

    public func getIntegerEvaluation(key: String, defaultValue: Int64, context: EvaluationContext?) throws -> ProviderEvaluation<Int64> {
        resolve(key, defaultValue) { $0.numberValue.map { Int64($0) } }
    }

    public func getDoubleEvaluation(key: String, defaultValue: Double, context: EvaluationContext?) throws -> ProviderEvaluation<Double> {
        resolve(key, defaultValue) { $0.numberValue }
    }

    public func getObjectEvaluation(key: String, defaultValue: Value, context: EvaluationContext?) throws -> ProviderEvaluation<Value> {
        // A json flag's value is its payload; boolean/variant flags read as their value.
        guard let d = client.flagDetails(key) else { return missing(key, defaultValue) }
        return ProviderEvaluation(
            value: ContextMap.value(d.payload ?? d.value), flagMetadata: Self.metadata(d), variant: d.variant,
            reason: ReasonMap.openFeature(d.reason, variantValue: d.variant != nil))
    }

    private func resolve<T>(_ key: String, _ def: T, _ pick: (JSONValue) -> T?) -> ProviderEvaluation<T> {
        guard let d = client.flagDetails(key) else { return missing(key, def) }
        guard let v = pick(d.value) ?? d.payload.flatMap(pick) else {
            return ProviderEvaluation(
                value: def, flagMetadata: Self.metadata(d), reason: "ERROR", errorCode: .typeMismatch,
                errorMessage: "flag \(key) is not of the requested type")
        }
        return ProviderEvaluation(
            value: v, flagMetadata: Self.metadata(d), variant: d.variant,
            reason: ReasonMap.openFeature(d.reason, variantValue: d.variant != nil))
    }

    private func missing<T>(_ key: String, _ def: T) -> ProviderEvaluation<T> {
        ProviderEvaluation(value: def, reason: "ERROR", errorCode: .flagNotFound, errorMessage: "flag \(key) not found")
    }

    static func metadata(_ d: FlagDetails) -> [String: FlagMetadataValue] {
        var m: [String: FlagMetadataValue] = ["lucidaReason": .string(d.reason), "evaluatedLocally": .boolean(d.evaluatedLocally)]
        if d.conditionIndex >= 0 { m["conditionIndex"] = .integer(Int64(d.conditionIndex)) }
        if let r = d.requestId { m["requestId"] = .string(r) }
        return m
    }

    // MARK: Tracking

    /// Event name = `key`; properties = the details' fields plus `$value`. The identity is the one set by the context.
    public func track(key: String, context: (any EvaluationContext)?, details: (any TrackingEventDetails)?) throws {
        var props: Props = (details?.asMap() ?? [:]).mapValues(ContextMap.json)
        if let v = details?.getValue() { props["$value"] = .number(v) }
        client.capture(key, props)
    }
}
