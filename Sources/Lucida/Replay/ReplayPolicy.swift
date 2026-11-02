import Foundation

public enum ReplayMode: String, Sendable { case wireframe, screenshot }

/// The project's RSA public key for controlled exposure (P-L12): `n` / `e` base64url without padding, `pkcs1` standard
/// base64 of the PKCS#1 RSAPublicKey DER.
struct ExposureKey: Equatable, Sendable {
    var kid: String, n: String, e: String, pkcs1: String
}

/// The slice of `GET /v1/config` that governs replay (the same document the browser SDK reads).
struct RemoteReplayConfig: Equatable {
    var sessionRecording = true
    var sampleRate: Double?
    var minDurationMs: Int?
    /// Screen-name patterns whose snapshots mask everything (P-M17).
    var maskScreens: [String] = []
    /// Regular expressions starred in any text replay would show (P-M46); at most 20, each <= 200 characters.
    var maskTextPatterns: [String] = []
    /// Native ids of fields captured encrypted (P-L12); off unless `exposureKey` is present too.
    var exposureFields: [String] = []
    var exposureKey: ExposureKey?

    init() {}

    init?(json data: Data) {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let b = o["session_recording"] as? Bool { sessionRecording = b }
        sampleRate = (o["replay_sample_rate"] as? NSNumber)?.doubleValue
        minDurationMs = (o["replay_min_duration_ms"] as? NSNumber)?.intValue
        func strings(_ k: String) -> [String] { (o[k] as? [Any])?.compactMap { $0 as? String } ?? [] }
        maskScreens = strings("replay_mask_screens")
        maskTextPatterns = Array(strings("replay_mask_text_patterns").filter { $0.count <= 200 }.prefix(20))
        exposureFields = strings("replay_exposure_fields")
        if let k = o["replay_exposure_key"] as? [String: Any], let kid = k["kid"] as? String, let n = k["n"] as? String,
           let e = k["e"] as? String, let der = k["pkcs1"] as? String {
            exposureKey = ExposureKey(kid: kid, n: n, e: e, pkcs1: der)
        }
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

    /// P-M17: case-insensitive match of the whole screen name; `*` matches any run of characters. Empty list = false.
    static func screenMasked(_ screen: String, patterns: [String]) -> Bool {
        let s = Array(screen.lowercased())
        return patterns.contains { glob(s, Array($0.lowercased())) }
    }

    private static func glob(_ s: [Character], _ p: [Character]) -> Bool {
        var si = 0, pi = 0, star = -1, mark = 0
        while si < s.count {
            if pi < p.count, p[pi] == "*" { star = pi; mark = si; pi += 1 }
            else if pi < p.count, p[pi] == s[si] { si += 1; pi += 1 }
            else if star >= 0 { pi = star + 1; mark += 1; si = mark }
            else { return false }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }
}
