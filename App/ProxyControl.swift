import Foundation
import NetworkExtension
import SystemExtensions

/// Installs/activates the system extension and starts/stops the transparent proxy.
final class ProxyControl: NSObject, OSSystemExtensionRequestDelegate {
    static let shared = ProxyControl()

    var onStateChange: (() -> Void)?
    private(set) var lastMessage: String = ""

    var isRunning: Bool {
        manager?.connection.status == .connected || manager?.connection.status == .connecting
    }

    private var manager: NETransparentProxyManager?
    private var pendingDeactivation = false

    // MARK: - System extension activation

    /// Activate the sysext, then load/start the proxy. User approval happens in System Settings.
    func enable() {
        pendingDeactivation = false
        let req = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: Config.extensionBundleID, queue: .main)
        req.delegate = self
        OSSystemExtensionManager.shared.submitRequest(req)
    }

    func disable() {
        stopProxy()
        pendingDeactivation = true
        let req = OSSystemExtensionRequest.deactivationRequest(
            forExtensionWithIdentifier: Config.extensionBundleID, queue: .main)
        req.delegate = self
        OSSystemExtensionManager.shared.submitRequest(req)
    }

    // MARK: - Proxy manager (starts once the sysext is active)

    private func startProxy() {
        NETransparentProxyManager.loadAllFromPreferences { managers, error in
            if let error { self.report("load prefs failed: \(error.localizedDescription)"); return }
            let mgr = managers?.first ?? NETransparentProxyManager()
            let proto = (mgr.protocolConfiguration as? NETunnelProviderProtocol) ?? NETunnelProviderProtocol()
            proto.providerBundleIdentifier = Config.extensionBundleID
            proto.serverAddress = "BandwidthLimit"
            mgr.protocolConfiguration = proto
            mgr.localizedDescription = "BandwidthLimit"
            mgr.isEnabled = true
            mgr.saveToPreferences { error in
                if let error { self.report("save prefs failed: \(error.localizedDescription)"); return }
                mgr.loadFromPreferences { _ in
                    self.manager = mgr
                    do { try mgr.connection.startVPNTunnel(); self.report("proxy started") }
                    catch { self.report("start failed: \(error.localizedDescription)") }
                    self.onStateChange?()
                }
            }
        }
    }

    private func stopProxy() {
        manager?.connection.stopVPNTunnel()
        report("proxy stopped")
        onStateChange?()
    }

    private func report(_ msg: String) {
        lastMessage = msg
        onStateChange?()
    }

    // MARK: - OSSystemExtensionRequestDelegate

    func request(_ request: OSSystemExtensionRequest,
                 actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        return .replace // always take the freshly built one during development
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        report("approve the extension in System Settings › General › Login Items & Extensions")
    }

    func request(_ request: OSSystemExtensionRequest,
                 didFinishWithResult result: OSSystemExtensionRequest.Result) {
        if pendingDeactivation {
            pendingDeactivation = false
            manager = nil
            report("extension deactivated")
        } else {
            report("extension active")
            startProxy()
        }
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        report("extension request failed: \(error.localizedDescription)")
    }
}
