import Foundation

/// XPC contract between the app and the privileged helper daemon.
@objc protocol HelperProtocol {
    /// Shape total bandwidth to `mbps` (both directions) via pfctl/dnctl. `mbps <= 0` clears it.
    func setGlobalCap(mbps: Int, reply: @escaping (Bool, String) -> Void)
    func clearGlobalCap(reply: @escaping (Bool, String) -> Void)
}
