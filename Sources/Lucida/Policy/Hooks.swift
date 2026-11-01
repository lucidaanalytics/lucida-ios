import Foundation

/// A `beforeSend` hook: return the (possibly amended) event, or nil to drop it.
public typealias BeforeSend = (WireEvent) throws -> WireEvent?

/// Ordered hook chain. Each hook sees the previous hook's output; nil stops the chain and drops the event.
/// A hook that throws is logged and skipped: the event continues unchanged (as it was before that hook).
struct HookChain {
    let hooks: [BeforeSend]
    let log: (String) -> Void

    func run(_ event: WireEvent) -> WireEvent? {
        var cur = event
        for h in hooks {
            do {
                guard let next = try h(cur) else { return nil }
                cur = next
            } catch {
                log("beforeSend hook threw, keeping event: \(error)")
            }
        }
        return cur
    }
}

/// Keep roughly `rate` (0...1) of events and stamp survivors with `$sample_rate`. Compose it with your own filter hook.
public func sampleHook(_ rate: Double, random: @escaping () -> Double = { .random(in: 0..<1) }) -> BeforeSend {
    { e in
        if rate >= 1 { return e }
        if rate <= 0 || random() >= rate { return nil }
        var out = e
        out.properties["$sample_rate"] = .number(rate)
        return out
    }
}

public enum PersonProfiles: Sendable { case always, identifiedOnly, never }

/// `personProfiles` state: `.identifiedOnly` flips to processing on the first identify/alias/group/person-property write.
final class PersonMode {
    let mode: PersonProfiles
    private let store: KeyValueStore
    private var identified: Bool
    private static let key = "lc_person_identified"
    private static let alwaysProcessed: Set<String> = ["$identify", "$create_alias", "$groupidentify"]

    init(store: KeyValueStore, mode: PersonProfiles) {
        self.store = store
        self.mode = mode
        identified = store.get(Self.key) == "1"
    }

    var blocksPersonWrites: Bool { mode == .never }

    func markIdentified() {
        guard mode == .identifiedOnly, !identified else { return }
        identified = true
        store.set(Self.key, "1")
    }

    /// True when an event of this name should carry `$process_person_profile: false`.
    func personless(_ event: String) -> Bool {
        switch mode {
        case .always: return false
        case .never: return !Self.alwaysProcessed.contains(event)
        case .identifiedOnly: return !identified && !Self.alwaysProcessed.contains(event)
        }
    }

    func reset() {
        identified = false
        store.remove(Self.key)
    }
}
