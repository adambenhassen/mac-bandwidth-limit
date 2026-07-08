import Foundation

/// Records recent flow opens (real app + destination) in a sliding window and summarizes them.
/// Cheap: one append per new connection; no byte pumping. Thread-safe.
final class FlowTracker {
    private let lock = NSLock()
    private var events: [(t: Date, bid: String, name: String, host: String)] = []
    private let window: TimeInterval = 12

    func record(bundleID: String, name: String, host: String) {
        lock.lock(); defer { lock.unlock() }
        events.append((Date(), bundleID, name, host))
        if events.count > 2000 { events.removeFirst(events.count - 2000) } // safety cap
    }

    func snapshot() -> [FlowStat] {
        lock.lock(); defer { lock.unlock() }
        let cutoff = Date().addingTimeInterval(-window)
        events.removeAll { $0.t < cutoff }
        var byBid: [String: (name: String, count: Int, hosts: [String: Int])] = [:]
        for e in events {
            var cur = byBid[e.bid] ?? (e.name, 0, [:])
            cur.count += 1
            if e.host != "—" { cur.hosts[e.host, default: 0] += 1 }
            byBid[e.bid] = cur
        }
        return byBid.map { bid, v in
            FlowStat(bundleID: bid, name: v.name, connections: v.count,
                     topHost: v.hosts.max { $0.value < $1.value }?.key)
        }
        .sorted { $0.connections > $1.connections }
    }
}

/// Per-app rate limiter. `take(n)` returns how long the caller must wait before sending `n` bytes
/// so the long-run average stays at the app's limit. Rate is re-read live from shared config, so
/// changing an app's limit takes effect on the next chunk. Thread-safe via an internal lock.
final class TokenBucket {
    private let bundleID: String
    private let lock = NSLock()
    private var tokens: Double = 0          // available bytes
    private var lastRefill = Date()

    init(bundleID: String) { self.bundleID = bundleID }

    /// Bytes/sec from the current limit; nil (no limit) → treated as effectively unlimited.
    private var ratePerSec: Double {
        guard let mbps = Config.limit(forBundleID: bundleID) else { return .greatestFiniteMagnitude }
        return Double(mbps) * 1_000_000 / 8
    }

    /// Returns the delay (seconds) to wait before sending `byteCount` bytes.
    func take(_ byteCount: Int) -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        let rate = ratePerSec
        if rate == .greatestFiniteMagnitude { return 0 }
        let now = Date()
        let capacity = rate * 0.5          // ~0.5s burst window
        tokens = min(capacity, tokens + now.timeIntervalSince(lastRefill) * rate)
        lastRefill = now
        let n = Double(byteCount)
        if tokens >= n { tokens -= n; return 0 }
        let deficit = n - tokens
        tokens = 0
        return deficit / rate
    }
}
