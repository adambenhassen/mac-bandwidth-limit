import Foundation
import ServiceManagement

/// Registers the privileged helper daemon (SMAppService) and drives the global cap over XPC.
final class GlobalCap {
    static let shared = GlobalCap()

    private let plistName = "com.local.bandwidthlimit.helper.plist"
    var lastMessage = ""
    var onMessage: (() -> Void)?

    private var service: SMAppService { SMAppService.daemon(plistName: plistName) }

    /// Ensure the daemon is registered (installs on first use; user may be prompted once).
    private func ensureRegistered() -> Bool {
        switch service.status {
        case .enabled:
            return true
        case .requiresApproval:
            report("approve the helper in System Settings › General › Login Items")
            SMAppService.openSystemSettingsLoginItems()
            return false
        default:
            do { try service.register(); return service.status == .enabled }
            catch { report("helper register failed: \(error.localizedDescription)"); return false }
        }
    }

    /// Apply (mbps>0) or clear (mbps==0) the global cap.
    func apply(mbps: Int) {
        guard ensureRegistered() else { return }
        let conn = NSXPCConnection(machServiceName: Config.helperMachServiceName, options: .privileged)
        conn.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        conn.resume()
        let proxy = conn.remoteObjectProxyWithErrorHandler { [weak self] err in
            self?.report("helper connection error: \(err.localizedDescription)")
        } as? HelperProtocol
        proxy?.setGlobalCap(mbps: mbps) { [weak self] ok, msg in
            self?.report((ok ? "" : "cap error: ") + msg)
            conn.invalidate()
        }
    }

    private func report(_ msg: String) {
        lastMessage = msg
        DispatchQueue.main.async { self.onMessage?() }
    }
}
