import AppKit
import DozzleCore
import SwiftUI

private enum Palette {
    static let ok = Color(red: 0.30, green: 0.85, blue: 0.50)
    static let warn = Color(red: 1.00, green: 0.72, blue: 0.25)
    static let bad = Color(red: 1.00, green: 0.38, blue: 0.36)
    static let idle = Color.white.opacity(0.35)
    static let accent = Color(red: 0.45, green: 0.72, blue: 1.00)
    static let tile = Color.white.opacity(0.06)
    static let hairline = Color.white.opacity(0.10)
}

/// The same dashboard renders as the desktop card or as the menu bar dropdown.
enum DashboardStyle {
    case desktop, popover
    var width: CGFloat { self == .desktop ? 440 : 380 }
}

struct DashboardView: View {
    @ObservedObject var model: DeskModel
    var style: DashboardStyle = .desktop

    private var status: LinkStatus { model.status }
    private var isLive: Bool { status.phase.isLive && model.finalMessage == nil }

    var body: some View {
        styled(content)
            .environment(\.colorScheme, .dark)
            .foregroundStyle(.white.opacity(0.92))
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let snap = status.snapshot {
                Group {
                    hostGrid(snap)
                    countsRow(snap.counts)
                    if !snap.problems.isEmpty {
                        problems(snap.problems)
                    } else if style == .popover && isLive {
                        allGood
                    }
                    if style == .desktop { topLists(snap) }
                }
                .opacity(isLive ? 1 : 0.45)
                .saturation(isLive ? 1 : 0.15)
                .allowsHitTesting(isLive)
            }
            if let banner = bannerText {
                ConnectionBanner(text: banner.text, detail: banner.detail, tone: banner.tone)
            }
            if style == .popover {
                Rectangle().fill(Palette.hairline).frame(height: 1)
                footer
            }
        }
        .padding(14)
        .frame(width: style.width, alignment: .topLeading)
    }

    @ViewBuilder private func styled<V: View>(_ view: V) -> some View {
        switch style {
        case .desktop:
            view
                .background(background)
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Palette.hairline))
                .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .gesture(DragGesture(minimumDistance: 3)
                    .onChanged { _ in model.dragChanged?() }
                    .onEnded { _ in model.dragEnded?() })
                .fixedSize(horizontal: false, vertical: true)
        case .popover:
            // The popover supplies its own material; offscreen renders get a solid fill.
            view
                .background(model.renderMode ? AnyView(Color(white: 0.13)) : AnyView(Color.clear))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Dropdown-only pieces

    private var allGood: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.seal.fill").font(.system(size: 11)).foregroundStyle(Palette.ok)
            Text("All systems healthy").font(.system(size: 11.5, weight: .medium))
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Palette.ok.opacity(0.10)))
    }

    @ViewBuilder private var footer: some View {
        if model.renderMode {
            // ImageRenderer can't draw native controls; show their labels for layout checks.
            HStack(spacing: 14) {
                Label("Open Dozzle", systemImage: "safari")
                Label("Reconnect", systemImage: "arrow.clockwise")
                Spacer(minLength: 0)
                Image(systemName: "slider.horizontal.3")
                Image(systemName: "power")
            }
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(Palette.accent)
        } else {
            liveFooter
        }
    }

    private var liveFooter: some View {
        HStack(spacing: 14) {
            Button { model.actions?.openDozzle() } label: { Label("Open Dozzle", systemImage: "safari") }
            Button { model.actions?.reconnect() } label: { Label("Reconnect", systemImage: "arrow.clockwise") }
                .disabled(status.phase == .sleeping || status.phase == .preflight)
            Spacer(minLength: 0)
            Menu {
                Toggle("Show Desktop Card", isOn: Binding(
                    get: { model.showCard },
                    set: { model.actions?.setShowCard($0) }))
                Divider()
                Group {
                    Toggle("Click-through", isOn: Binding(
                        get: { model.clickThrough },
                        set: { model.actions?.setClickThrough($0) }))
                    Picker("Opacity", selection: Binding(
                        get: { model.opacity },
                        set: { model.actions?.setOpacity($0) })) {
                        ForEach([1.0, 0.85, 0.7, 0.5], id: \.self) { Text("\(Int($0 * 100))%").tag($0) }
                    }
                    Button("Reset Position") { model.actions?.resetPosition() }
                }
                .disabled(!model.showCard)
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Desktop card options")
            Button { model.actions?.quit() } label: { Image(systemName: "power") }
                .help("Quit DozzleDesk")
        }
        .buttonStyle(.borderless)
        .font(.system(size: 11.5, weight: .medium))
    }

    @ViewBuilder private var background: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        if model.renderMode {
            shape.fill(Color(white: 0.11).opacity(0.94))
        } else {
            VisualEffectBackground().clipShape(shape)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "server.rack").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.accent)
            Text("Homelab").font(.system(size: 15, weight: .semibold))
            if let v = status.snapshot?.version {
                Text(v).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            StatusDot(color: dotColor, pulsing: isLive)
            Text(headerStatus)
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var dotColor: Color {
        if model.finalMessage != nil { return Palette.bad }
        switch status.phase {
        case .live: return Palette.ok
        case .preflight, .connecting: return Palette.accent
        case .lost: return Palette.warn
        case .sleeping: return Palette.idle
        case .exited: return Palette.bad
        }
    }

    private var headerStatus: String {
        switch status.phase {
        case .live:
            guard let t = status.snapshot?.generatedAt else { return "live" }
            return "live · " + Self.clock.string(from: t)
        case .preflight, .connecting: return "connecting…"
        case .lost: return "connection lost"
        case .sleeping: return "paused"
        case .exited: return "closed"
        }
    }

    private struct Banner { var text: String; var detail: String?; var tone: Color }

    private var bannerText: Banner? {
        if let msg = model.finalMessage { return Banner(text: msg, detail: nil, tone: Palette.bad) }
        switch status.phase {
        case .preflight:
            return Banner(text: "Connecting to \(status.endpoint)…", detail: nil, tone: Palette.accent)
        case .connecting where status.snapshot == nil:
            return Banner(text: "Connecting to \(status.endpoint)…", detail: nil, tone: Palette.accent)
        case .lost(_, let attempt):
            var parts: [String] = []
            if !status.networkAvailable {
                parts.append("no network")
            } else if let next = status.nextRetryIn, next >= 1 {
                parts.append("retry \(attempt) in \(Int(next.rounded(.up)))s")
            } else {
                parts.append("retrying…")
            }
            if let g = status.graceRemaining { parts.append("closing in \(Self.mmss(g))") }
            let stale = status.staleSince.map { "Showing data from " + Self.clock.string(from: $0) }
            return Banner(text: "Connection lost · " + parts.joined(separator: " · "), detail: stale, tone: Palette.warn)
        case .sleeping:
            return Banner(text: "Paused while the Mac sleeps", detail: nil, tone: Palette.idle)
        default:
            return nil
        }
    }

    // MARK: Hosts

    private func hostGrid(_ snap: DashboardSnapshot) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
            ForEach(snap.hosts) { h in
                Button { model.open(model.config.hostPage(h.id)) } label: { HostTile(host: h) }
                    .buttonStyle(.plain)
                    .help("Open \(h.name) in Dozzle")
            }
        }
    }

    // MARK: Counts

    private func countsRow(_ c: DashboardSnapshot.Counts) -> some View {
        HStack(spacing: 6) {
            CountChip(label: "running", value: c.running, color: Palette.ok)
            CountChip(label: "healthy", value: c.healthy, color: Palette.ok)
            CountChip(label: "unhealthy", value: c.unhealthy, color: c.unhealthy > 0 ? Palette.bad : Palette.idle)
            CountChip(label: "exited", value: c.exited, color: Palette.idle)
            if c.paused > 0 { CountChip(label: "paused", value: c.paused, color: Palette.warn) }
            if c.restarting > 0 { CountChip(label: "restarting", value: c.restarting, color: Palette.warn) }
            Spacer(minLength: 0)
        }
    }

    // MARK: Problems

    private func problems(_ list: [DashboardSnapshot.Problem]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel("Needs attention")
            ForEach(list.prefix(5)) { p in
                Button {
                    if let c = p.containerId { model.open(model.config.containerPage(c)) }
                    else if let h = p.hostId { model.open(model.config.hostPage(h)) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: p.severity == .critical ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(p.severity == .critical ? Palette.bad : Palette.warn)
                        Text(p.title).font(.system(size: 11.5, weight: .medium)).lineLimit(1).truncationMode(.middle)
                        Text(p.detail).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 4)
                        if let since = p.since {
                            Text(Self.age(since, now: status.snapshot?.generatedAt ?? Date()))
                                .font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if list.count > 5 {
                Text("+\(list.count - 5) more").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Palette.bad.opacity(0.10)))
    }

    // MARK: Top lists

    private func topLists(_ snap: DashboardSnapshot) -> some View {
        HStack(alignment: .top, spacing: 12) {
            TopList(title: "Top CPU", rows: snap.topCPU, value: { String(format: "%.1f%%", $0.cpu) }, open: openContainer)
            TopList(title: "Top memory", rows: snap.topMemory, value: { Self.bytes($0.memUsage) }, open: openContainer)
        }
    }

    private func openContainer(_ row: DashboardSnapshot.ContainerRow) {
        model.open(model.config.containerPage(row.id))
    }

    // MARK: Formatting

    static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    static func mmss(_ t: TimeInterval) -> String {
        let s = max(0, Int(t.rounded(.up)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    static func age(_ d: Date, now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(d)))
        if s < 60 { return "\(s)s ago" }
        if s < 3600 { return "\(s / 60)m ago" }
        return "\(s / 3600)h ago"
    }

    static func bytes(_ b: Double) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var v = b, i = 0
        while v >= 1000, i < units.count - 1 { v /= 1000; i += 1 }
        return i >= 3 ? String(format: "%.1f %@", v, units[i]) : String(format: "%.0f %@", v, units[i])
    }
}

// MARK: - Components

private struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 9.5, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
    }
}

private struct StatusDot: View {
    let color: Color
    let pulsing: Bool
    var body: some View {
        Circle().fill(color).frame(width: 7, height: 7)
            .shadow(color: color.opacity(pulsing ? 0.8 : 0), radius: 3)
    }
}

private struct HostTile: View {
    let host: DashboardSnapshot.Host

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Circle().fill(host.available ? Palette.ok : Palette.bad).frame(width: 6, height: 6)
                Text(host.name).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 2)
                Text("\(host.running)/\(host.total)")
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help("running / total containers")
            }
            if host.available {
                HStack(alignment: .bottom, spacing: 6) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("CPU").font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
                        Text(host.cpuPercent.map { String(format: "%.0f%%", $0) } ?? "—")
                            .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    }
                    Sparkline(values: host.cpuHistory, color: Palette.accent)
                        .frame(height: 20)
                }
                Meter(label: "MEM", used: host.memUsed, total: host.memTotal)
                HStack(spacing: 8) {
                    if let free = host.diskFree {
                        Text("disk \(DashboardView.bytes(free)) free")
                    }
                    Spacer(minLength: 0)
                    if let l = host.load1 {
                        Text(String(format: "load %.2f", l))
                    }
                }
                .font(.system(size: 9.5).monospacedDigit())
                .foregroundStyle(.secondary)
            } else {
                Text("Unreachable from Dozzle")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.bad)
                    .frame(maxWidth: .infinity, minHeight: 56, alignment: .center)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(host.available ? Palette.tile : Palette.bad.opacity(0.12)))
        .contentShape(RoundedRectangle(cornerRadius: 10))
    }
}

private struct Meter: View {
    let label: String
    let used: Double
    let total: Double?

    private var fraction: Double {
        guard let t = total, t > 0 else { return 0 }
        return min(1, max(0, used / t))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Text(total.map { "\(DashboardView.bytes(used)) / \(DashboardView.bytes($0))" } ?? DashboardView.bytes(used))
                    .font(.system(size: 9.5).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.10))
                    Capsule().fill(fraction > 0.9 ? Palette.bad : fraction > 0.75 ? Palette.warn : Palette.ok)
                        .frame(width: max(2, g.size.width * fraction))
                }
            }
            .frame(height: 4)
        }
    }
}

private struct Sparkline: View {
    let values: [Double]
    let color: Color

    var body: some View {
        GeometryReader { g in
            if values.count >= 2 {
                let maxV = max(values.max() ?? 1, 5) // keep tiny idle noise flat-looking
                let step = g.size.width / CGFloat(values.count - 1)
                let points = values.enumerated().map { i, v in
                    CGPoint(x: CGFloat(i) * step, y: g.size.height * (1 - CGFloat(v / maxV)))
                }
                ZStack {
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: g.size.height))
                        points.forEach { p.addLine(to: $0) }
                        p.addLine(to: CGPoint(x: g.size.width, y: g.size.height))
                        p.closeSubpath()
                    }
                    .fill(color.opacity(0.18))
                    Path { p in
                        p.move(to: points[0])
                        points.dropFirst().forEach { p.addLine(to: $0) }
                    }
                    .stroke(color, style: StrokeStyle(lineWidth: 1.3, lineJoin: .round))
                }
            } else {
                Path { p in
                    p.move(to: CGPoint(x: 0, y: g.size.height - 1))
                    p.addLine(to: CGPoint(x: g.size.width, y: g.size.height - 1))
                }
                .stroke(color.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
            }
        }
    }
}

private struct CountChip: View {
    let label: String
    let value: Int
    let color: Color
    var body: some View {
        HStack(spacing: 4) {
            Text("\(value)").font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(color)
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(Palette.tile))
    }
}

private struct TopList: View {
    let title: String
    let rows: [DashboardSnapshot.ContainerRow]
    let value: (DashboardSnapshot.ContainerRow) -> String
    let open: (DashboardSnapshot.ContainerRow) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            SectionLabel(title)
            ForEach(rows) { r in
                Button { open(r) } label: {
                    HStack(spacing: 4) {
                        Text(r.name).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 4)
                        Text(value(r)).font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(r.name) on \(r.hostName)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ConnectionBanner: View {
    let text: String
    let detail: String?
    let tone: Color
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.exclamationmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(tone)
            VStack(alignment: .leading, spacing: 1) {
                Text(text).font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                if let detail { Text(detail).font(.system(size: 10)).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(tone.opacity(0.16)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(tone.opacity(0.35)))
    }
}

/// Real behind-window blur of the desktop wallpaper.
private struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        v.appearance = NSAppearance(named: .darkAqua)
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
