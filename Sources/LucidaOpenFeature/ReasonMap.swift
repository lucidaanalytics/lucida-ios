import Lucida

/// Lucida reason -> OpenFeature reason; mirrors testdata/openfeature/reasons.json (the tests read that file).
enum ReasonMap {
    private static let table: [String: String] = [
        "condition_match": "TARGETING_MATCH", "sticky_bucket": "CACHED", "no_condition_match": "DEFAULT",
        "out_of_rollout": "DEFAULT", "holdout": "DEFAULT", "namespace_excluded": "DEFAULT", "no_bucketing_key": "DEFAULT",
        "prerequisite_failed": "DEFAULT", "prerequisite_missing": "DEFAULT", "prerequisite_cycle": "ERROR",
        "inactive": "DISABLED", "kill_switch": "DISABLED", "app_context_excluded": "DISABLED",
        "preview": "STATIC", "user_preview": "STATIC", "fallback": "DEFAULT",
    ]

    /// `condition_match` resolving to a variant string is a SPLIT; unknown reasons are UNKNOWN.
    static func openFeature(_ lucidaReason: String, variantValue: Bool) -> String {
        if lucidaReason == "condition_match" && variantValue { return "SPLIT" }
        return table[lucidaReason] ?? "UNKNOWN"
    }
}
