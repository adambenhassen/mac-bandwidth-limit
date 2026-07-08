import Foundation

// Privileged helper daemon (runs as root via SMAppService). Exposes an XPC service that
// shapes total bandwidth with pfctl + dnctl (dummynet) — the Network Link Conditioner approach.

/// Runs `/bin/sh -c`-free: exact executable + args, so a caller-supplied Mbps can't inject a shell.
@discardableResult
func run(_ path: String, _ args: [String], input: String? = nil) -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let out = Pipe(); p.standardOutput = out; p.standardError = out
    if let input {
        let inPipe = Pipe(); p.standardInput = inPipe
        do { try p.run() } catch { return (-1, "\(error)") }
        inPipe.fileHandleForWriting.write(input.data(using: .utf8)!)
        inPipe.fileHandleForWriting.closeFile()
    } else {
        do { try p.run() } catch { return (-1, "\(error)") }
    }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

enum Shaper {
    static let pfctl = "/sbin/pfctl"
    static let dnctl = "/usr/sbin/dnctl"

    /// Apply a total cap of `mbps` (both directions) by routing all traffic through dummynet pipes.
    /// ponytail: takes over the pf ruleset while active; disable restores /etc/pf.conf. Assumes pf
    /// isn't otherwise in use (true on stock macOS). Per-interface/anchor split only if needed.
    static func setCap(mbps: Int) -> (Bool, String) {
        guard (1...10_000).contains(mbps) else { return (false, "mbps out of range") }
        run(dnctl, ["-q", "flush"])
        let (c1, o1) = run(dnctl, ["pipe", "1", "config", "bw", "\(mbps)Mbit/s"])
        let (c2, o2) = run(dnctl, ["pipe", "2", "config", "bw", "\(mbps)Mbit/s"])
        guard c1 == 0, c2 == 0 else { return (false, "dnctl failed: \(o1)\(o2)") }
        let rules = "dummynet in all pipe 1\ndummynet out all pipe 2\n"
        let (c3, o3) = run(pfctl, ["-f", "-", "-E"], input: rules)
        // pfctl -E prints a token to stderr even on success; treat nonzero-with-no-"Syntax" as ok-ish.
        guard c3 == 0 else { return (false, "pfctl failed: \(o3)") }
        return (true, "cap \(mbps) Mbit/s applied")
    }

    static func clear() -> (Bool, String) {
        run(pfctl, ["-f", "/etc/pf.conf"])
        run(pfctl, ["-d"])
        run(dnctl, ["-q", "flush"])
        return (true, "cap cleared")
    }
}

final class Service: NSObject, HelperProtocol {
    func setGlobalCap(mbps: Int, reply: @escaping (Bool, String) -> Void) {
        let (ok, msg) = mbps <= 0 ? Shaper.clear() : Shaper.setCap(mbps: mbps)
        reply(ok, msg)
    }
    func clearGlobalCap(reply: @escaping (Bool, String) -> Void) {
        let (ok, msg) = Shaper.clear()
        reply(ok, msg)
    }
}

final class Delegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection c: NSXPCConnection) -> Bool {
        // ponytail: identity check only. Ad-hoc dev signing keeps a stable designated identifier;
        // tighten to `anchor apple generic and ...` once signed with a Team ID.
        c.setCodeSigningRequirement("identifier \"com.local.bandwidthlimit\"")
        c.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        c.exportedObject = Service()
        c.resume()
        return true
    }
}

let delegate = Delegate()
let listener = NSXPCListener(machServiceName: "com.local.bandwidthlimit.helper")
listener.delegate = delegate
listener.resume()
RunLoop.main.run()
