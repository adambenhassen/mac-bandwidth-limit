import Foundation
import AppKit

struct AppUsage {
    let name: String       // process name as nettop reports it
    let bundleID: String?  // resolved best-effort for setting per-app limits
    let isTunnel: Bool     // VPN/tunnel extension — excluded from totals to avoid double-count
    let mbpsDown: Double
    let mbpsUp: Double
}

/// Samples `nettop` over a short interval to get per-process throughput.
/// Mirrors the reference app's "Process → parse stdout" pattern (pingOnce/parseRTT).
enum Monitor {
    /// Runs nettop for two samples `seconds` apart and returns per-process throughput, busiest first.
    static func sample(seconds: Int = 1) -> [AppUsage] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        // -P per-process, -x raw cumulative bytes, -J pick cols, -l 2 two samples, -s N seconds apart.
        p.arguments = ["-P", "-x", "-J", "bytes_in,bytes_out", "-l", "2", "-s", "\(seconds)"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return [] }
        let out = String(data: data, encoding: .utf8) ?? ""
        return aggregate(parse(out, seconds: seconds))
    }

    /// Collapse per-process rates into one row per app: every process resolving to the same app
    /// (bundle id) is summed, so an app's many helper processes show as one complete row instead of
    /// overwriting each other. Unresolved processes group by name (so e.g. all `ssh` sum, not clobber).
    static func aggregate(_ rates: [Rate]) -> [AppUsage] {
        var groups: [String: (name: String, bid: String?, isTunnel: Bool, down: Double, up: Double)] = [:]
        for r in rates {
            // Resolve via PID → parent app so helper processes map to their app; fall back to name.
            let info = AppIdentity.resolve(pid: r.pid)
            let bid = info?.bundleID ?? BundleResolver.bundleID(forProcessName: r.name)
            let key = bid ?? r.name
            var g = groups[key] ?? (info?.name ?? r.name, bid, false, 0, 0)
            g.down += r.mbpsDown
            g.up += r.mbpsUp
            g.isTunnel = g.isTunnel || (info?.isExtension ?? false)
            if let appName = info?.name { g.name = appName }   // prefer the resolved app name
            groups[key] = g
        }
        return groups.values
            .map { AppUsage(name: $0.name, bundleID: $0.bid, isTunnel: $0.isTunnel,
                            mbpsDown: $0.down, mbpsUp: $0.up) }
            // Low floor (~250 B/s) so light streamers like CLIs show; noise below that is dropped.
            .filter { $0.mbpsDown + $0.mbpsUp > 0.002 }
            .sorted { ($0.mbpsDown + $0.mbpsUp) > ($1.mbpsDown + $1.mbpsUp) }
    }

    struct Rate { let name: String; let pid: pid_t; let mbpsDown: Double; let mbpsUp: Double }

    /// Pure parser (no AppKit) so it's testable. nettop `-x -l 2` prints two blocks of cumulative
    /// byte counters; the per-process delta between the last two blocks over `seconds` is the rate.
    /// Row shape: `HH:MM:SS.micros  <proc name>.<pid>  <bytes_in>  <bytes_out>` (space-columned;
    /// process name may contain spaces). Header/`bytes_in` lines and IP-only rows are ignored.
    static func parse(_ output: String, seconds: Int) -> [Rate] {
        // Keyed by the full "name.pid" identifier so distinct processes (incl. same-named ones like
        // many `node`/`ssh`) stay separate and the two sample blocks align per process.
        struct Cell { let bin: Double; let bout: Double; let name: String; let pid: pid_t }
        var blocks: [[String: Cell]] = []
        var current: [String: Cell] = [:]
        for raw in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(raw)
            if line.contains("bytes_in") && line.contains("bytes_out") { // header => new block
                if !current.isEmpty { blocks.append(current); current = [:] }
                continue
            }
            let tok = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            // need: time, id(>=1 token), bytes_in, bytes_out
            guard tok.count >= 4,
                  let bin = Double(tok[tok.count - 2]),
                  let bout = Double(tok[tok.count - 1]) else { continue }
            let identifier = tok[1..<(tok.count - 2)].joined(separator: " ") // "proc name.pid"
            guard let dot = identifier.lastIndex(of: ".") else { continue }
            let name = String(identifier[..<dot])
            if name.isEmpty || name.range(of: #"^[0-9.]+$"#, options: .regularExpression) != nil { continue }
            let pid = pid_t(identifier[identifier.index(after: dot)...]) ?? 0
            current[identifier] = Cell(bin: bin, bout: bout, name: name, pid: pid)
        }
        if !current.isEmpty { blocks.append(current) }
        guard let last = blocks.last else { return [] }
        let prev = blocks.count >= 2 ? blocks[blocks.count - 2] : [:]
        let dt = Double(max(seconds, 1))
        var out: [Rate] = []
        for (id, cur) in last {
            let base = prev[id]
            let dIn = max(0, cur.bin - (base?.bin ?? cur.bin)), dOut = max(0, cur.bout - (base?.bout ?? cur.bout))
            let down = dIn * 8 / 1_000_000 / dt, up = dOut * 8 / 1_000_000 / dt
            if down + up > 0 { out.append(Rate(name: cur.name, pid: cur.pid, mbpsDown: down, mbpsUp: up)) }
        }
        return out.sorted { ($0.mbpsDown + $0.mbpsUp) > ($1.mbpsDown + $1.mbpsUp) }
    }
}

/// Best-effort process-name → bundle-identifier lookup via running applications.
enum BundleResolver {
    static func bundleID(forProcessName name: String) -> String? {
        for app in NSWorkspace.shared.runningApplications {
            if let ln = app.localizedName, name.hasPrefix(ln) || ln.hasPrefix(name) {
                return app.bundleIdentifier
            }
        }
        return nil
    }
}
