import Foundation

public enum ReplayMode: String, Sendable { case wireframe, screenshot }

/// The slice of `GET /v1/config` that governs replay (the same document the browser SDK reads).
struct RemoteReplayConfig: Equatable {
    var sessionRecording = true
    var sampleRate: Double?
    var minDurationMs: Int?

    init() {}

    init?(json data: Data) {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let b = o["session_recording"] as? Bool { sessionRecording = b }
        sampleRate = (o["replay_sample_rate"] as? NSNumber)?.doubleValue
        minDurationMs = (o["replay_min_duration_ms"] as? NSNumber)?.intValue
    }
}

/// Pure replay gating rules. Remote config can only tighten what the app configured locally.
enum ReplayPolicy {
    /// Deny wins; an empty allow list allows every screen.
    static func screenAllowed(_ screen: String, allow: [String], deny: [String]) -> Bool {
        !deny.contains(screen) && (allow.isEmpty || allow.contains(screen))
    }

    static func sampleRate(local: Double, remote: RemoteReplayConfig?) -> Double {
        guard let r = remote else { return local }
        return r.sessionRecording ? min(local, r.sampleRate ?? 1) : 0
    }

    static func minDurationMs(local: Int, remote: RemoteReplayConfig?) -> Int { max(local, remote?.minDurationMs ?? 0) }
}
