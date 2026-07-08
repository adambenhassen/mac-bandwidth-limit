import SwiftUI

/// Straightforward layout built around the two things the user actually does:
///   1. cap the whole connection (hero control, up top)
///   2. limit a specific app (one clear control per row)
struct PopoverView: View {
    @ObservedObject var model: AppModel
    var onQuit: () -> Void

    typealias Row = AppModel.Row
    private var maxMbps: Double {
        let vis = model.visibleRows
        let m = vis.filter { !$0.isTunnel }.map(\.liveMbps).max() ?? vis.map(\.liveMbps).max() ?? 0
        return max(m, 0.0001)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            globalSection
            Divider()
            if !model.flowStats.isEmpty {
                connectionsSection
                Divider()
            }
            appsHeader
            appList
        }
        .frame(width: 340, height: 500)
        .background(VisualEffectBackground().ignoresSafeArea())
    }

    // MARK: header — master switch + big live speed + session total

    private var header: some View {
        VStack(spacing: 8) {
            HStack {
                Toggle("", isOn: Binding(get: { model.enabled }, set: { model.setMaster($0) }))
                    .toggleStyle(.switch).labelsHidden()
                Text(model.enabled ? "Limiting on" : "Paused")
                    .font(.subheadline).fontWeight(.medium)
                Spacer()
                Menu {
                    Button(model.onlyLimitable ? "✓ Only apps I can limit" : "Only apps I can limit") {
                        model.setOnlyLimitable(!model.onlyLimitable)
                    }
                    if !model.hiddenNames.isEmpty {
                        Menu("Hidden apps") {
                            ForEach(model.hiddenNames, id: \.id) { h in
                                Button("Show \(h.name)") { model.unhide(h.id) }
                            }
                            Divider()
                            Button("Show all") { model.unhideAll() }
                        }
                    }
                    Divider()
                    Button("Reset session total") { model.resetSession() }
                    Button(model.loginEnabled ? "✓ Launch at Login" : "Launch at Login") { model.toggleLogin() }
                    Divider()
                    Button("Quit", action: onQuit)
                } label: {
                    Image(systemName: "ellipsis.circle").font(.title3).foregroundStyle(.secondary)
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            }
            VStack(spacing: 1) {
                Text(String(format: "%.1f Mbps", model.totalLiveMbps))
                    .font(.system(size: 32, weight: .semibold)).monospacedDigit()
                Text("\(Format.bytes(model.sessionBytes)) this session")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 10)
    }

    // MARK: hero — whole-internet cap

    private var globalSegments: [Int] {
        var s = AppModel.globalPresets
        let c = model.globalCap
        if c > 0 && !s.contains(c) { s.append(c); s.sort() }
        return s
    }

    private var globalSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("WHOLE-INTERNET LIMIT")
                    .font(.caption2).fontWeight(.semibold).foregroundStyle(.secondary).kerning(0.5)
                Spacer()
                Button("Custom…") { model.promptCustomGlobal() }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(.blue)
            }
            Picker("", selection: Binding(get: { model.globalCap }, set: { model.setGlobalCap($0) })) {
                Text("Off").tag(0)
                ForEach(globalSegments, id: \.self) { Text("\($0)").tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            Text(model.globalCap == 0
                 ? "No overall cap — one app can use your whole connection."
                 : "Your whole connection is capped at \(model.globalCap) Mbps.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    // MARK: connections (proxy attribution — reveals real apps behind tunnel traffic)

    private var connectionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("REAL APPS OPENING CONNECTIONS")
                .font(.caption2).fontWeight(.semibold).foregroundStyle(.secondary).kerning(0.5)
            ForEach(model.flowStats.prefix(4)) { s in
                HStack(spacing: 6) {
                    Text(s.name).font(.caption)
                    if let h = s.topHost {
                        Text("→ \(h)").font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 4)
                    Text("\(s.connections)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            Text("Who's really opening connections — incl. traffic that shows under a VPN/tunnel process.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    // MARK: apps

    private var appsHeader: some View {
        HStack {
            Text("APPS USING THE NETWORK")
                .font(.caption2).fontWeight(.semibold).foregroundStyle(.secondary).kerning(0.5)
            Spacer()
        }
        .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 2)
    }

    private var appList: some View {
        Group {
            if model.rows.isEmpty {
                VStack { Spacer(); Text("No network activity").foregroundStyle(.secondary).font(.callout); Spacer() }
                    .frame(maxWidth: .infinity)
            } else {
                ScrollView { LazyVStack(spacing: 2) { ForEach(model.visibleRows) { row($0) } }.padding(.horizontal, 10).padding(.bottom, 8) }
            }
        }
    }

    private func row(_ row: Row) -> some View {
        HStack(spacing: 10) {
            (row.icon.map { Image(nsImage: $0).resizable() } ?? Image(systemName: "app.dashed").resizable())
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(row.name).font(.callout).lineLimit(1)
                    if row.isTunnel {
                        Text("tunnel").font(.caption2).foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.primary.opacity(0.1)))
                            .help("VPN/tunnel — carries other apps' traffic, so it's not added to the total")
                    }
                    Spacer(minLength: 6)
                    limitControl(row)
                }
                HStack(spacing: 8) {
                    bar(fraction: row.liveMbps / maxMbps)
                    Text(String(format: "%.1f Mbps", row.liveMbps))
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: 66, alignment: .trailing)
                }
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 6)
    }

    /// One control per app: "≤N Mbps ▾" when limited, "Set limit ▾" when limitable, "Hide ▾" for
    /// processes we can't limit. The menu always offers "Hide from list".
    private func limitControl(_ row: Row) -> some View {
        let label = row.limitMbps.map { "≤\($0) Mbps" } ?? (row.canLimit ? "Set limit" : "Hide")
        return Menu {
            if row.canLimit {
                Button(row.limitMbps == nil ? "✓ No limit" : "No limit") { model.setLimit(nil, for: row) }
                ForEach(AppModel.appPresets, id: \.self) { mbps in
                    Button(row.limitMbps == mbps ? "✓ \(mbps) Mbps" : "\(mbps) Mbps") { model.setLimit(mbps, for: row) }
                }
                Divider()
                Button("Custom…") { model.promptCustomLimit(for: row) }
            } else {
                Text("Can't limit this process (no app id)")
            }
            Divider()
            Button("Hide from list") { model.hide(row) }
        } label: {
            HStack(spacing: 3) {
                Text(label).font(.caption)
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
            }
            .foregroundStyle(row.limitMbps == nil ? Color.secondary : .blue)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill((row.limitMbps == nil ? Color.primary : Color.blue).opacity(0.12)))
            .contentShape(Capsule())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }

    private func bar(fraction: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08)).frame(height: 5)
                Capsule().fill(Color.blue).frame(width: max(0, min(1, fraction)) * geo.size.width, height: 5)
            }
        }
        .frame(height: 5)
    }
}

enum Format {
    /// "0 bytes", "11 KB", "201 KB", "55.9 MB", "1.2 GB" — bytes/KB integer, MB+ one decimal.
    static func bytes(_ n: Double) -> String {
        let units = ["bytes", "KB", "MB", "GB", "TB"]
        var v = n, i = 0
        while v >= 1000 && i < units.count - 1 { v /= 1000; i += 1 }
        switch i {
        case 0: return "\(Int(v)) bytes"
        case 1: return "\(Int(v.rounded())) KB"
        default: return String(format: "%.1f %@", v, units[i])
        }
    }
}

private struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .popover
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
