import Foundation

/// Durable, ordered spill for replay chunks that cannot be sent yet (min duration, offline, upload backoff).
/// Layout: `lc_replay` is the index (JSON list of entries), `lc_replay.<id>` holds one chunk body (no api key). Hand it a
/// store wrapped in `EncryptedStore(prefixes: [ReplaySpool.key])` to encrypt at rest. Over `budget` bytes the oldest
/// whole session is dropped (never single chunks, so a kept session has no hole) and `onDrop` reports it.
final class ReplaySpool: @unchecked Sendable {
    static let key = "lc_replay"

    struct Entry: Codable, Equatable {
        var id: Int
        var sid: String
        var seq: Int
        /// Waiting for the minimum session duration (dropped if the session ends first); false = waiting for upload.
        var held: Bool
        var n: Int
    }

    private let store: KeyValueStore
    private let budget: Int
    private let onDrop: ((_ sid: String, _ chunks: Int, _ bytes: Int) -> Void)?
    private let lock = NSLock()
    private var items: [Entry] = []
    private var nextId = 0

    init(store: KeyValueStore, budget: Int, onDrop: ((String, Int, Int) -> Void)? = nil) {
        self.store = store; self.budget = budget; self.onDrop = onDrop
        let loaded = store.get(Self.key).flatMap { try? JSONDecoder().decode([Entry].self, from: Data($0.utf8)) } ?? []
        items = loaded.filter { store.get("\(Self.key).\($0.id)") != nil }
        nextId = (items.map(\.id).max() ?? -1) + 1
    }

    var entries: [Entry] { lock.locked { items } }
    var totalBytes: Int { lock.locked { items.reduce(0) { $0 + $1.n } } }

    private func save() {
        if items.isEmpty { store.remove(Self.key) }
        else if let d = try? JSONEncoder().encode(items) { store.set(Self.key, String(decoding: d, as: UTF8.self)) }
    }

    func add(sid: String, seq: Int, held: Bool, body: Data) {
        let dropped: [(String, Int, Int)] = lock.locked {
            let e = Entry(id: nextId, sid: sid, seq: seq, held: held, n: body.count)
            nextId += 1
            store.set("\(Self.key).\(e.id)", String(decoding: body, as: UTF8.self))
            items.append(e)
            var out: [(String, Int, Int)] = []
            while items.reduce(0, { $0 + $1.n }) > budget, let first = items.first {
                let gone = items.filter { $0.sid == first.sid }
                for g in gone { store.remove("\(Self.key).\(g.id)") }
                items.removeAll { $0.sid == first.sid }
                out.append((first.sid, gone.count, gone.reduce(0) { $0 + $1.n }))
            }
            save()
            return out
        }
        for d in dropped { onDrop?(d.0, d.1, d.2) }
    }

    func read(_ e: Entry) -> Data? { store.get("\(Self.key).\(e.id)").map { Data($0.utf8) } }

    func remove(_ e: Entry) {
        lock.locked { store.remove("\(Self.key).\(e.id)"); items.removeAll { $0.id == e.id }; save() }
    }

    /// Held chunks of every session except `keep` (that session ended short).
    @discardableResult
    func removeHeld(except keep: String? = nil) -> [Entry] {
        lock.locked {
            let gone = items.filter { $0.held && $0.sid != keep }
            for e in gone { store.remove("\(Self.key).\(e.id)") }
            items.removeAll { $0.held && $0.sid != keep }
            save()
            return gone
        }
    }

    /// The session reached its minimum duration: its held chunks become plain pending uploads.
    func release(_ sid: String) {
        lock.locked { for i in items.indices where items[i].held && items[i].sid == sid { items[i].held = false }; save() }
    }

    func nextSeq(_ sid: String) -> Int { lock.locked { (items.filter { $0.sid == sid }.map(\.seq).max() ?? -1) + 1 } }

    func clear() {
        lock.locked { for e in items { store.remove("\(Self.key).\(e.id)") }; items = []; save() }
    }
}
