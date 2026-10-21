import SwiftUI
import Charts

/// Drop-down panel shown from the menu bar, Magpie-style:
/// compact status, top movers, quick actions.
struct MenuPanelView: View {
    @EnvironmentObject var engine: Engine
    @EnvironmentObject var store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().padding(.vertical, 8)
            content
            Divider().padding(.vertical, 8)
            footer
        }
        .padding(12)
        .frame(width: 340)
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("存储空间看板").font(.headline)
                Text(statusLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if store.status?.state.scanning == true {
                ProgressView().controlSize(.small)
            } else {
                Button { store.scanNow() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("立即记录一次")
            }
        }
    }

    private var statusLine: String {
        if engine.isRunning == false { return engine.launchError ?? "引擎未运行" }
        if store.status?.state.scanning == true {
            let path = store.status?.state.progress["path"]?.text ?? ""
            return path.isEmpty ? "正在扫描…" : "正在扫描 \(URL(fileURLWithPath: path).lastPathComponent)"
        }
        if let latest = store.dashboard?.latest {
            return "上次记录 \(formatTime(latest.finished))"
        }
        return "等待首次记录"
    }

    @ViewBuilder
    private var content: some View {
        if let disk = store.status?.disk {
            DiskGaugeView(disk: disk)
                .padding(.bottom, 8)
        }

        if store.trendPoints.count >= 2 {
            MenuSparkline(points: store.trendPoints)
                .frame(height: 44)
                .padding(.bottom, 6)
        }

        HStack {
            Text(store.comparePeriod.label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text("变化")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.bottom, 2)

        let rows = Array(store.visibleRows.prefix(6))
        if rows.isEmpty {
            Text(store.dashboard == nil ? "正在读取记录…" : "这一时段没有明显增长")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 14)
        } else {
            VStack(spacing: 1) {
                ForEach(rows) { row in
                    Button {
                        store.reveal(row.path)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "folder.fill")
                                .foregroundStyle(row.delta ?? 0 > 0 ? Color.orange : Color.green)
                                .font(.caption)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(URL(fileURLWithPath: row.path).lastPathComponent)
                                    .font(.callout)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(shortPath(row.path))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            Text(formatDelta(row.delta))
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(deltaColor(row.delta))
                        }
                        .contentShape(Rectangle())
                        .padding(.vertical, 4)
                        .padding(.horizontal, 5)
                    }
                    .buttonStyle(.plain)
                    .background(Color.primary.opacity(0.0001))
                    .onHover { inside in
                        // Native hover highlight is handled by the button's default look.
                    }
                    .help("在 Finder 中显示")
                }
            }
        }
    }

    private func shortPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    private var footer: some View {
        HStack {
            Button("打开看板") {
                WindowController.shared.show()
            }
            .buttonStyle(.borderless)
            Button("设置") {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            Spacer()
            Button("退出") {
                engine.stop()
                NSApp.terminate(nil)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
        .font(.callout)
    }

    private func deltaColor(_ delta: Int64?) -> Color {
        guard let delta else { return .secondary }
        return delta > 0 ? .orange : .green
    }
}

private struct MenuSparkline: View {
    let points: [(date: Date, free: Int64)]

    var body: some View {
        Chart(points, id: \.date) { point in
            AreaMark(x: .value("时间", point.date),
                     y: .value("可用", Double(point.free) / 1e9))
                .foregroundStyle(.linearGradient(colors: [.accentColor.opacity(0.22), .clear],
                                                 startPoint: .top, endPoint: .bottom))
                .interpolationMethod(.catmullRom)
            LineMark(x: .value("时间", point.date),
                     y: .value("可用", Double(point.free) / 1e9))
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
                .foregroundStyle(.tint)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
    }
}

struct DiskGaugeView: View {
    let disk: Disk

    var body: some View {
        let used = Double(disk.total - disk.free) / Double(max(disk.total, 1))
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(formatBytes(disk.free))
                    .font(.title3.weight(.semibold).monospacedDigit())
                Text("可用")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("共 \(formatBytes(disk.total))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(gaugeColor(used).gradient)
                        .frame(width: geo.size.width * used)
                }
            }
            .frame(height: 6)
        }
    }

    private func gaugeColor(_ used: Double) -> Color {
        used > 0.9 ? .red : used > 0.75 ? .orange : .accentColor
    }
}
