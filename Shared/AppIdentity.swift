import Foundation
import Darwin

/// Maps a process to the app the user thinks of it as. A helper like "Google Chrome Helper" lives
/// inside "Google Chrome.app", so we resolve its executable path up to the *outermost* `.app` and
/// read that bundle's identifier. Used by BOTH the monitor and the proxy (keyed on PID) so a limit
/// set on an app catches all of its helper processes.
enum AppIdentity {
    static func bundleID(forPID pid: pid_t) -> String? { resolve(pid: pid)?.bundleID }
    static func appInfo(forPID pid: pid_t) -> (bundleID: String, name: String)? {
        resolve(pid: pid).map { ($0.bundleID, $0.name) }
    }

    /// Parent-app bundle id, display name, and whether the process is a network extension
    /// (a VPN/tunnel/proxy provider). Name comes from the outermost `.app` folder — no AppKit, so it
    /// works in the extension too. `isExtension` marks tunnel processes so the UI can avoid
    /// double-counting their bytes (they re-emit other apps' traffic).
    static func resolve(pid: pid_t) -> (bundleID: String, name: String, isExtension: Bool)? {
        var buf = [CChar](repeating: 0, count: 4096)   // PROC_PIDPATHINFO_MAXSIZE
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        let path = String(cString: buf)
        // First ".app/" from the left is the outermost bundle (the parent app, not a nested helper).
        guard let r = path.range(of: ".app/") else { return nil }
        let appPath = String(path[path.startIndex..<r.lowerBound]) + ".app"
        guard let bid = Bundle(path: appPath)?.bundleIdentifier else { return nil }
        let folder = (appPath as NSString).lastPathComponent
        let name = folder.hasSuffix(".app") ? String(folder.dropLast(4)) : folder
        let isExtension = path.contains(".appex/") || path.contains(".systemextension/")
        return (bid, name, isExtension)
    }

    /// Extract the sending process's pid from an NEAppProxyFlow's `sourceAppAuditToken`.
    /// `audit_token_to_pid()` is `val[5]`; we read it directly to avoid linking libbsm.
    static func pid(fromAuditToken data: Data?) -> pid_t? {
        guard let data, data.count == MemoryLayout<audit_token_t>.size else { return nil }
        let token = data.withUnsafeBytes { $0.load(as: audit_token_t.self) }
        return pid_t(bitPattern: token.val.5)
    }
}
