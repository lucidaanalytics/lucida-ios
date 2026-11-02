import Foundation

/// Port: where first-open install attribution comes from. Must always return (store-only props on failure).
/// Adapter: `AdServicesAttributionSource`.
public protocol InstallAttributionSource: Sendable {
    func fetch() async -> Props
}

/// Maps an Apple Search Ads attribution response (AdServices Attribution API) to `$app_installed` props.
func appStoreInstallProps(responseJSON: Data?) -> Props {
    var p: Props = ["$install_store": .string("app_store")]
    guard let data = responseJSON, let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return p }
    let attributed = o["attribution"] as? Bool ?? false
    p["$install_adservices_attribution"] = .bool(attributed)
    guard attributed else { return p }
    func s(_ k: String) -> String? {
        if let v = o[k] as? String, !v.isEmpty { return v }
        if let n = o[k] as? NSNumber { return n.stringValue }
        return nil
    }
    p["$utm_source"] = .string("apple_search_ads")
    p["$utm_medium"] = .string("cpc")
    let map: [(String, String, String?)] = [
        ("campaignId", "$asa_campaign_id", "$utm_campaign"), ("keywordId", "$asa_keyword_id", "$utm_term"),
        ("adGroupId", "$asa_ad_group_id", "$utm_content"), ("orgId", "$asa_org_id", nil),
        ("adId", "$asa_ad_id", nil), ("conversionType", "$asa_conversion_type", nil),
    ]
    for (src, asa, utm) in map {
        guard let v = s(src) else { continue }
        p[asa] = .string(v)
        if let utm { p[utm] = .string(v) }
    }
    return p
}
