import AppKit
import Combine
import ServiceManagement

/// Backing model for the popover: drives the monitor loop and reflects/edits the throttle config.
/// One metric only — live throughput in Mbps — to keep the UI unambiguous.
final class AppModel: ObservableObject {
    struct Row: Identifiable {
        let bundleID: String?
        let name: String
        var icon: NSImage?
        var liveMbps: Double        // down + up, current
        var limitMbps: Int?         // nil == not limited
        var isTunnel: Bool          // VPN/tunnel process — excluded from totals
        var id: String { bundleID ?? name }
        var canLimit: Bool { bundleID != nil }
    }

    static let globalPresets = [20, 50, 100, 200]   // Mbps options for the whole-internet cap
    static let appPresets = [1, 2, 5, 10, 20, 50]   // Mbps options per app

    @Published var rows: [Row] = []
    @Published var enabled = false          // master: enforce limits or not
    @Published var loginEnabled = false
    @Published var sessionBytes: Double = 0 // total data since the app launched
    @Published var onlyLimitable = Config.onlyLimitable
    @Published var flowStats: [FlowStat] = []   // real apps behind traffic (from the proxy)

    /// Rows after applying the "only limitable" filter and the per-app hidden list.
    var visibleRows: [Row] {
        let hidden = Config.hiddenIDs
        return rows.filter { r in
            if onlyLimitable && !r.canLimit { return false }
            if hidden.contains(r.id) { return false }
            return true
        }
    }
    var hiddenNames: [(id: String, name: String)] {
        let byID = Dictionary(rows.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        return Config.hiddenIDs.sorted().map { ($0, byID[$0] ?? $0) }
    }

    /// Rows that count toward the total: visible and not a tunnel (avoids double-counting VPN bytes
    /// that are already represented by the app rows). Falls back to all visible if only tunnels show.
    var countedRows: [Row] {
        let nonTunnel = visibleRows.filter { !$0.isTunnel }
        return nonTunnel.isEmpty ? visibleRows : nonTunnel
    }
    var totalLiveMbps: Double { countedRows.reduce(0) { $0 + $1.liveMbps } }
    var globalCap: Int { Config.globalMbps } // 0 == off

    private var timer: Timer?
    private var sampling = false
    private var lastUpdate = Date()
    private var iconCache: [String: NSImage] = [:]

    func start() {
        enabled = ProxyControl.shared.isRunning
        loginEnabled = SMAppService.mainApp.status == .enabled
        tick()
        // 1s cadence with a 2s sample window: the guard skips overlaps, so sampling runs nearly
        // continuously and averages over ~2s — this catches bursty/light traffic that a 1s snapshot
        // every 2s would miss.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
    }

    private func tick() {
        if sampling { return }
        sampling = true
        DispatchQueue.global().async { [weak self] in
            let usage = Monitor.sample(seconds: 2)
            DispatchQueue.main.async { self?.ingest(usage) }
        }
    }

    private func ingest(_ usage: [AppUsage]) {
        sampling = false
        let now = Date()
        let dt = now.timeIntervalSince(lastUpdate)
        lastUpdate = now
        flowStats = enabled ? Config.flowStats : []
        rows = usage.map { u in
            Row(bundleID: u.bundleID, name: u.name, icon: icon(for: u.bundleID),
                liveMbps: u.mbpsDown + u.mbpsUp,
                limitMbps: u.bundleID.flatMap { Config.limit(forBundleID: $0) },
                isTunnel: u.isTunnel)
        }
        // Accumulate the session total from counted rows so a VPN's re-emitted bytes aren't added twice.
        sessionBytes += countedRows.reduce(0) { $0 + $1.liveMbps } * 1_000_000 / 8 * dt
    }

    private func icon(for bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        if let c = iconCache[bundleID] { return c }
        let img = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.icon
        if let img { iconCache[bundleID] = img }
        return img
    }

    var hasAnyAppLimit: Bool { !Config.appLimits.isEmpty }

    // MARK: - Actions

    /// Master switch: enforce everything currently configured, or lift all enforcement.
    func setMaster(_ on: Bool) {
        enabled = on
        if on {
            if hasAnyAppLimit { ProxyControl.shared.enable() }
            if globalCap > 0 { GlobalCap.shared.apply(mbps: globalCap) }
        } else {
            ProxyControl.shared.disable()
            GlobalCap.shared.apply(mbps: 0)
        }
    }

    /// Setting a limit auto-turns-on enforcement so the user never has to find the master switch.
    func setLimit(_ mbps: Int?, for row: Row) {
        guard let bid = row.bundleID else { return }
        Config.setLimit(mbps, forBundleID: bid)
        if let i = rows.firstIndex(where: { $0.id == row.id }) { rows[i].limitMbps = mbps }
        if mbps != nil && !enabled { setMaster(true) }
        else if enabled && hasAnyAppLimit { ProxyControl.shared.enable() }
    }

    func setGlobalCap(_ mbps: Int) {
        Config.globalMbps = mbps
        if mbps > 0 && !enabled { setMaster(true) }        // choosing a cap turns enforcement on
        else if enabled { GlobalCap.shared.apply(mbps: mbps) }
        objectWillChange.send()
    }

    /// Prompt for a custom per-app limit (blank/0 clears it).
    func promptCustomLimit(for row: Row) {
        guard let v = Prompt.mbps(title: "Limit \(row.name) to…", current: row.limitMbps) else { return }
        setLimit(v > 0 ? v : nil, for: row)
    }

    /// Prompt for a custom whole-internet cap (blank/0 turns it off).
    func promptCustomGlobal() {
        guard let v = Prompt.mbps(title: "Whole-internet limit", current: globalCap == 0 ? nil : globalCap)
        else { return }
        setGlobalCap(max(0, v))
    }

    func resetSession() { sessionBytes = 0 }

    func setOnlyLimitable(_ v: Bool) {
        onlyLimitable = v
        Config.onlyLimitable = v
    }

    func hide(_ row: Row) {
        var h = Config.hiddenIDs; h.insert(row.id); Config.hiddenIDs = h
        objectWillChange.send()
    }

    func unhide(_ id: String) {
        var h = Config.hiddenIDs; h.remove(id); Config.hiddenIDs = h
        objectWillChange.send()
    }

    func unhideAll() {
        Config.hiddenIDs = []
        objectWillChange.send()
    }

    func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { NSLog("login toggle failed: \(error)") }
        loginEnabled = SMAppService.mainApp.status == .enabled
    }
}

/// Modal prompt for a Mbps value. Returns the entered integer, or nil if cancelled/blank.
enum Prompt {
    static func mbps(title: String, current: Int?) -> Int? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "Enter a speed in Mbps."
        alert.addButton(withTitle: "Set")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        field.stringValue = current.map(String.init) ?? ""
        field.placeholderString = "e.g. 15"
        alert.accessoryView = field
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return Int(field.stringValue.trimmingCharacters(in: .whitespaces))
    }
}
