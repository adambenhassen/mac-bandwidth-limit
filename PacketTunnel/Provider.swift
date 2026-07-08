import NetworkExtension
import Network
import os.log

/// Transparent proxy that throttles per-app download bandwidth.
/// Flows whose source app has no limit are declined (return false) so the kernel handles them with
/// zero overhead. Flows from a limited app are proxied through a real connection and paced by a
/// per-app TokenBucket on the download direction.
final class Provider: NETransparentProxyProvider {
    static let log = OSLog(subsystem: "com.local.bandwidthlimit.proxy", category: "provider")

    private let bucketsLock = NSLock()
    private var buckets: [String: TokenBucket] = [:]
    private let tracker = FlowTracker()
    private var statsTimer: DispatchSourceTimer?

    private func bucket(for bundleID: String) -> TokenBucket {
        bucketsLock.lock(); defer { bucketsLock.unlock() }
        if let b = buckets[bundleID] { return b }
        let b = TokenBucket(bundleID: bundleID)
        buckets[bundleID] = b
        return b
    }

    override func startProxy(options: [String: Any]?, completionHandler: @escaping (Error?) -> Void) {
        let settings = NETransparentProxyNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        settings.includedNetworkRules = [
            NENetworkRule(remoteNetwork: nil, remotePrefix: 0, localNetwork: nil, localPrefix: 0,
                          protocol: .TCP, direction: .outbound),
            NENetworkRule(remoteNetwork: nil, remotePrefix: 0, localNetwork: nil, localPrefix: 0,
                          protocol: .UDP, direction: .outbound),
        ]
        setTunnelNetworkSettings(settings) { error in
            if let error {
                os_log("startProxy failed: %{public}@", log: Self.log, type: .error, "\(error)")
            } else {
                self.startStatsTimer()
            }
            completionHandler(error)
        }
    }

    override func stopProxy(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        statsTimer?.cancel(); statsTimer = nil
        Config.flowStats = []
        completionHandler()
    }

    /// Every 2s publish which real apps opened connections recently, so the app can reveal what's
    /// behind tunnel/VPN traffic.
    private func startStatsTimer() {
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
        t.schedule(deadline: .now() + 2, repeating: 2)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            Config.flowStats = self.tracker.snapshot()
        }
        t.resume()
        statsTimer = t
    }

    private static func remoteHost(_ flow: NEAppProxyFlow) -> String {
        if let tcp = flow as? NEAppProxyTCPFlow, let ep = tcp.remoteEndpoint as? NWHostEndpoint {
            return ep.hostname
        }
        return "—"
    }

    override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        // Resolve the parent-app bundle id from the flow's PID (matches how the UI keys limits, so a
        // limit on an app catches its helper processes too).
        guard let pid = AppIdentity.pid(fromAuditToken: flow.metaData.sourceAppAuditToken),
              let info = AppIdentity.appInfo(forPID: pid) else {
            return false
        }
        // Record every flow's real app + destination for attribution (before we decide to decline).
        tracker.record(bundleID: info.bundleID, name: info.name, host: Self.remoteHost(flow))
        let bundleID = info.bundleID
        guard Config.limit(forBundleID: bundleID) != nil else {
            return false // no limit for this app → let the kernel handle it directly
        }
        let bucket = bucket(for: bundleID)
        if let tcp = flow as? NEAppProxyTCPFlow {
            TCPPump(flow: tcp, bucket: bucket).start()
            return true
        }
        if let udp = flow as? NEAppProxyUDPFlow {
            UDPPump(flow: udp, bucket: bucket).start()
            return true
        }
        return false
    }
}

// MARK: - TCP

/// Bridges one throttled TCP flow to a real outbound connection and paces the download side.
private final class TCPPump {
    private let flow: NEAppProxyTCPFlow
    private let bucket: TokenBucket
    private let conn: NWConnection?
    private let queue = DispatchQueue(label: "tcp-pump")

    init(flow: NEAppProxyTCPFlow, bucket: TokenBucket) {
        self.flow = flow
        self.bucket = bucket
        if let ep = flow.remoteEndpoint as? NWHostEndpoint,
           let port = NWEndpoint.Port(ep.port) {
            conn = NWConnection(host: NWEndpoint.Host(ep.hostname), port: port, using: .tcp)
        } else {
            conn = nil
        }
    }

    func start() {
        guard let conn else { close(); return }
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.flow.open(withLocalEndpoint: nil) { err in
                    if err != nil { self.close(); return }
                    self.pumpUpload()      // app → remote
                    self.pumpDownload()    // remote → app (throttled)
                }
            case .failed, .cancelled:
                self.close()
            default: break
            }
        }
        conn.start(queue: queue)
    }

    private func pumpUpload() {
        flow.readData { [weak self] data, error in
            guard let self, let data, !data.isEmpty, error == nil else { self?.close(); return }
            self.conn?.send(content: data, completion: .contentProcessed { err in
                if err != nil { self.close() } else { self.pumpUpload() }
            })
        }
    }

    private func pumpDownload() {
        conn?.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isDone, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                let delay = self.bucket.take(data.count)
                self.queue.asyncAfter(deadline: .now() + delay) {
                    self.flow.write(data) { err in
                        if err != nil { self.close() } else { self.pumpDownload() }
                    }
                }
            } else if isDone || error != nil {
                self.close()
            } else {
                self.pumpDownload()
            }
        }
    }

    private func close() {
        conn?.cancel()
        flow.closeReadWithError(nil)
        flow.closeWriteWithError(nil)
    }
}

// MARK: - UDP

/// Bridges one throttled UDP flow. Keeps a connection per remote endpoint; paces inbound datagrams.
private final class UDPPump {
    private let flow: NEAppProxyUDPFlow
    private let bucket: TokenBucket
    private let queue = DispatchQueue(label: "udp-pump")
    private var conns: [String: NWConnection] = [:]

    init(flow: NEAppProxyUDPFlow, bucket: TokenBucket) {
        self.flow = flow
        self.bucket = bucket
    }

    func start() {
        flow.open(withLocalEndpoint: nil) { [weak self] err in
            if err != nil { self?.close(); return }
            self?.pumpUpload()
        }
    }

    private func connection(to ep: NWHostEndpoint) -> NWConnection? {
        let key = "\(ep.hostname):\(ep.port)"
        if let c = conns[key] { return c }
        guard let port = NWEndpoint.Port(ep.port) else { return nil }
        let c = NWConnection(host: NWEndpoint.Host(ep.hostname), port: port, using: .udp)
        conns[key] = c
        c.start(queue: queue)
        pumpDownload(from: c, replyTo: ep)
        return c
    }

    private func pumpUpload() {
        flow.readDatagrams { [weak self] datagrams, endpoints, error in
            guard let self, let datagrams, let endpoints, error == nil, !datagrams.isEmpty else {
                self?.close(); return
            }
            for (data, ep) in zip(datagrams, endpoints) {
                guard let host = ep as? NWHostEndpoint, let c = self.connection(to: host) else { continue }
                c.send(content: data, completion: .idempotent)
            }
            self.pumpUpload()
        }
    }

    private func pumpDownload(from conn: NWConnection, replyTo ep: NWHostEndpoint) {
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                let delay = self.bucket.take(data.count)
                self.queue.asyncAfter(deadline: .now() + delay) {
                    self.flow.writeDatagrams([data], sentBy: [ep]) { _ in }
                    self.pumpDownload(from: conn, replyTo: ep)
                }
            } else if error != nil {
                // stop this sub-connection; the flow stays open for other endpoints
            } else {
                self.pumpDownload(from: conn, replyTo: ep)
            }
        }
    }

    private func close() {
        conns.values.forEach { $0.cancel() }
        flow.closeReadWithError(nil)
        flow.closeWriteWithError(nil)
    }
}
