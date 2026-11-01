import Foundation

/// Local flag evaluation: port of go/internal/flageval (reference) and testdata/flags/README.md.
public enum FlagEvaluator {
    /// Hash in [0,1): sha256("{key}.{salt}.{id}") first 13 hex chars / 16^13.
    public static func hash(flagKey: String, salt: String, bucketingKey: String, variant: Bool = false) -> Double {
        Hashing.unit(variant ? "\(flagKey).\(salt).variant.\(bucketingKey)" : "\(flagKey).\(salt).\(bucketingKey)")
    }

    private static func off(_ reason: String, _ index: Int = -1) -> EvalResult {
        EvalResult(value: .bool(false), variant: nil, payload: nil, reason: reason, conditionIndex: index)
    }

    private static func valueMatches(_ got: FlagValue, _ want: JSONValue) -> Bool {
        if case .bool(let w) = want {
            if case .bool(let g) = got { return g == w }
            return w  // a variant counts as "on"
        }
        return got.json == want
    }

    private static func filterMatches(_ f: PropertyFilter, _ c: EvalContext, _ resolved: [String: EvalResult]) -> Bool {
        let now = FlagOpsV2.parseNow(c.now)
        let bag: Props?
        switch f.type {
        case "person": bag = c.personProperties
        case "group": bag = c.groupProperties?[f.groupType ?? ""]
        case "device": bag = c.deviceProperties
        case "geo": bag = c.geoProperties
        case "app_version":
            let v = c.appVersion.flatMap { $0.isEmpty ? nil : JSONValue.string($0) }
            return FlagOps.match(op: f.op, prop: v, present: v != nil, want: f.value, semver: true, now: now)
        case "flag":
            guard let r = resolved[f.key] else { return false }
            return FlagOps.match(op: f.op, prop: r.value.json, present: true, want: f.value, semver: false, now: now)
        default: return false
        }
        return FlagOps.match(op: f.op, prop: bag?[f.key], present: bag?[f.key] != nil, want: f.value, semver: false, now: now)
    }

    private static func pickVariant(_ f: FlagDefinition, _ cond: ConditionGroup, _ key: String) -> FlagVariant {
        let vs = f.variants ?? []
        if let o = cond.variantOverride, let v = vs.first(where: { $0.key == o }) { return v }
        let h = hash(flagKey: f.key, salt: f.salt, bucketingKey: key, variant: true) * 100
        var cum = 0.0
        for v in vs {
            cum += v.rolloutPct
            if h < cum { return v }
        }
        return vs[vs.count - 1]  // totals < 100: the last variant takes the remainder
    }

    /// A stored value of a sticky flag decides once a condition's filters passed (LC-EXT-29).
    private static func sticky(_ f: FlagDefinition, _ cond: ConditionGroup, _ i: Int, _ c: EvalContext) -> EvalResult? {
        guard f.sticky == true, let stored = c.stickyAssignments?[f.key] else { return nil }
        var res = EvalResult(value: .bool(true), variant: nil, payload: nil, reason: "sticky_bucket", conditionIndex: i)
        if f.type == "multivariate", let vs = f.variants, !vs.isEmpty {
            if vs.contains(where: { $0.key == cond.variantOverride }) { return nil }  // the override wins
            guard let k = stored.stringValue, let v = vs.first(where: { $0.key == k }) else { return nil }
            res.value = .variant(v.key)
            res.variant = v.key
            res.payload = v.payload
            return res
        }
        guard stored.boolValue == true else { return nil }
        if f.type == "json" { res.payload = f.payload }
        return res
    }

    /// The bucketing unit of an aggregation (a flag's, or one condition's own); nil when absent.
    private static func unitKey(_ agg: FlagAggregation, _ c: EvalContext) -> String? {
        switch agg.kind {
        case "group": return c.groups?[agg.groupType ?? ""]
        case "device": return c.deviceId
        default: return (c.bucketingKey?.isEmpty == false) ? c.bucketingKey : c.distinctId
        }
    }

    /// A flag scoped to app contexts is dropped when the request declares contexts and shares none.
    private static func appContextAllowed(_ f: FlagDefinition, _ c: EvalContext) -> Bool {
        guard let want = f.appContexts, !want.isEmpty, let have = c.appContexts, !have.isEmpty else { return true }
        return want.contains(where: have.contains)
    }

    /// Evaluate one flag; prerequisites and `flag` filters read `resolved` (see `evaluateAll`).
    public static func evaluate(_ f: FlagDefinition, _ c: EvalContext, resolved: [String: EvalResult] = [:]) -> EvalResult {
        if !appContextAllowed(f, c) { return off("app_context_excluded") }
        if !f.active { return off("inactive") }
        if f.killSwitch == true { return off("kill_switch") }
        var server = false
        for p in f.prerequisites ?? [] {
            guard let r = resolved[p.flag] else { return off("prerequisite_missing") }
            if r.requiresServer { server = true }
            else if r.reason == "prerequisite_cycle" || !valueMatches(r.value, p.value) { return off("prerequisite_failed") }
        }
        if server { return off("requires_server") }
        let key = unitKey(f.aggregation, c) ?? ""
        let perCondition = f.conditions.contains { $0.aggregation != nil }
        if key.isEmpty && (!perCondition || f.holdout != nil || f.namespace != nil) { return off("no_bucketing_key") }
        if let h = f.holdout, hash(flagKey: "holdout", salt: h.salt, bucketingKey: key) * 100 < h.percentage { return off("holdout") }
        if let ns = f.namespace, ns.total > 0 {
            let b = (hash(flagKey: "namespace", salt: ns.salt, bucketingKey: key) * ns.total).rounded(.down)
            if b < ns.start || b >= ns.end { return off("namespace_excluded") }
        }
        var skipped = 0
        for (i, cond) in f.conditions.enumerated() {
            let ckey = cond.aggregation.map { unitKey($0, c) ?? "" } ?? key
            if ckey.isEmpty { skipped += 1; continue }
            var cohort = false
            var ok = true
            for fl in cond.filters ?? [] {
                // a flag filter on a requires_server flag is undecidable locally, like a cohort filter
                if fl.type == "cohort" || (fl.type == "flag" && resolved[fl.key]?.requiresServer == true) { cohort = true }
                else if !filterMatches(fl, c, resolved) { ok = false; break }
            }
            if !ok { continue }
            if cohort { return off("requires_server", i) }
            // the sticky store keys on the flag-level unit
            if cond.aggregation == nil, let r = sticky(f, cond, i, c) { return r }
            if hash(flagKey: f.key, salt: f.salt, bucketingKey: ckey) * 100 >= cond.rolloutPct {
                if f.earlyExit == true { return off("out_of_rollout", i) }
                continue
            }
            var res = EvalResult(value: .bool(true), variant: nil, payload: nil, reason: "condition_match", conditionIndex: i)
            if f.type == "multivariate", let vs = f.variants, !vs.isEmpty {
                let v = pickVariant(f, cond, ckey)
                res.value = .variant(v.key)
                res.variant = v.key
                res.payload = v.payload
            } else if f.type == "json" { res.payload = f.payload }
            return res
        }
        return off(!f.conditions.isEmpty && skipped == f.conditions.count ? "no_bucketing_key" : "no_condition_match")
    }

    private static func deps(_ f: FlagDefinition) -> [String] {
        (f.prerequisites ?? []).map(\.flag) + f.conditions.flatMap { ($0.filters ?? []).filter { $0.type == "flag" }.map(\.key) }
    }

    /// Evaluates all flags, resolving prerequisites depth-first; cycles get `prerequisite_cycle`.
    public static func evaluateAll(_ flags: [FlagDefinition], _ c: EvalContext) -> [String: EvalResult] {
        let byKey = Dictionary(flags.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [String: EvalResult] = [:]
        var state: [String: Int] = [:]  // 1 = visiting, 2 = done
        func visit(_ key: String) {
            guard let f = byKey[key], state[key] == nil else { return }
            state[key] = 1
            var cyc = false
            for d in deps(f) {
                visit(d)
                if state[d] == 1 || out[d]?.reason == "prerequisite_cycle" { cyc = true }
            }
            out[key] = cyc ? off("prerequisite_cycle") : evaluate(f, c, resolved: out)
            state[key] = 2
        }
        for f in flags { visit(f.key) }
        return out
    }
}
