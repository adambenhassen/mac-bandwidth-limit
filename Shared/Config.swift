import Foundation

/// Shared config between the menu-bar app and the proxy extension, via App Group defaults.
/// SSOT for the global cap and the per-app limit table.
enum Config {
    static let appGroup = "group.com.local.bandwidthlimit"
    static let machServiceName = "com.local.bandwidthlimit.proxy"
    static let helperMachServiceName = "com.local.bandwidthlimit.helper"
    static let extensionBundleID = "com.local.bandwidthlimit.proxy"

    private static let kGlobalMbps = "globalMbps"     // 0 == off
    private static let kAppLimits = "appLimitsMbps"   // [bundleID: Mbps]
    private static let kHidden = "hiddenIDs"          // [row.id] hidden from the list
    private static let kOnlyLimitable = "onlyLimitable"
    private static let kFlowStats = "flowStats"       // proxy → app: real-app connection attribution

    static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroup) ?? .standard
    }

    /// Global cap in Mbps; 0 means disabled.
    static var globalMbps: Int {
        get { defaults.integer(forKey: kGlobalMbps) }
        set { defaults.set(newValue, forKey: kGlobalMbps) }
    }

    /// Per-app download limits keyed by bundle identifier (Mbps).
    static var appLimits: [String: Int] {
        get { (defaults.dictionary(forKey: kAppLimits) as? [String: Int]) ?? [:] }
        set { defaults.set(newValue, forKey: kAppLimits) }
    }

    static func limit(forBundleID id: String) -> Int? {
        let v = appLimits[id]
        return (v ?? 0) > 0 ? v : nil
    }

    static func setLimit(_ mbps: Int?, forBundleID id: String) {
        var map = appLimits
        if let mbps, mbps > 0 { map[id] = mbps } else { map.removeValue(forKey: id) }
        appLimits = map
    }

    /// Row ids (bundleID or process name) the user chose to hide from the list.
    static var hiddenIDs: Set<String> {
        get { Set((defaults.array(forKey: kHidden) as? [String]) ?? []) }
        set { defaults.set(Array(newValue), forKey: kHidden) }
    }

    /// When true, only show apps that can actually be limited (have a bundle id).
    static var onlyLimitable: Bool {
        get { defaults.bool(forKey: kOnlyLimitable) }
        set { defaults.set(newValue, forKey: kOnlyLimitable) }
    }

    /// Written by the proxy extension, read by the app: which real apps opened connections recently
    /// (reveals apps behind VPN/tunnel traffic that nettop attributes to the tunnel process).
    static var flowStats: [FlowStat] {
        get { (defaults.data(forKey: kFlowStats)).flatMap { try? JSONDecoder().decode([FlowStat].self, from: $0) } ?? [] }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: kFlowStats) }
    }
}

/// One real app's recent connection activity, as seen by the proxy.
struct FlowStat: Codable, Identifiable {
    let bundleID: String
    let name: String
    let connections: Int   // flows opened in the recent window
    let topHost: String?   // most common destination host
    var id: String { bundleID }
}
