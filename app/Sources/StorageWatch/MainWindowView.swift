import SwiftUI
import Charts

struct MainWindowView: View {
    @EnvironmentObject var engine: Engine
    @EnvironmentObject var store: Store

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let error = engine.launchError ?? store.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }
                if !store.hasLoadedOnce && engine.launchError == nil {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("正在启动采集引擎…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                }
                metricsRow
                trendCard
                changesCard
                toolsCard
            }
            .padding(24)
        }
        .toolbar {
            ToolbarItemGroup {
                if store.status?.state.scanning == true {
                    ProgressView().controlSize(.small)
                    Text("正在扫描").foregroundStyle(.secondary)
                }
                Button { store.scanNow() } label: {
                    Label("立即记录", systemImage: "arrow.clockwise")
                }
                .disabled(store.status?.state.scanning == true)
            }
        }
    }

    // MARK: - Metrics

    private var metricsRow: some View {
        HStack(spacing: 14) {
            MetricCard(title: "磁盘可用",
                       value: formatBytes(store.status?.disk.free, unit: false),
                       unit: "GB",
                       caption: "共 \(formatBytes(store.status?.disk.total))",
                       tint: .accentColor)
            MetricCard(title: "时段净变化",
                       value: store.usedDelta.map { formatDelta($0) } ?? "—",
                       unit: "",
                       caption: store.dashboard?.baselineNote.isEmpty == false ? "时段覆盖不完整" : store.comparePeriod.label,
                       tint: .orange)
            MetricCard(title: "增长目录",
                       value: "\(store.dashboard?.rows.filter { ($0.delta ?? 0) > 0 }.count ?? 0)",
                       unit: "个",
                       caption: "目录树节点",
                       tint: .orange)
            MetricCard(title: "最近记录",
                       value: formatTime(store.dashboard?.latest?.finished),
                       unit: "",
                       caption: nextScanCaption,
                       tint: .green)
        }
    }

    private var nextScanCaption: String {
        guard let next = store.status?.state.nextScan else { return "" }
        let remain = Int(next - Date().timeIntervalSince1970)
        return remain > 0 ? "下次约 \(remain / 60) 分钟后" : "即将扫描"
    }

    /// Pad the visible GB range so small shifts stay readable without
    /// flattening the line against a zero baseline.
    private func chartDomain(_ points: [(date: Date, free: Int64)]) -> ClosedRange<Double> {
        let values = points.map { Double($0.free) / 1e9 }
        guard let low = values.min(), let high = values.max() else { return 0...1 }
        let span = max(high - low, max(high * 0.03, 1))
        return (low - span * 0.15)...(high + span * 0.15)
    }

    // MARK: - Trend chart

    private var trendCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("可用空间趋势").font(.headline)
                Spacer()
                Picker("", selection: $store.trendPeriod) {
                    ForEach(TrendPeriod.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
            }
            let points = store.trendPoints
            if points.count >= 2 {
                Chart(points, id: \.date) { point in
                    AreaMark(x: .value("时间", point.date),
                             y: .value("可用", Double(point.free) / 1e9))
                        .foregroundStyle(.linearGradient(colors: [.accentColor.opacity(0.25), .clear],
                                                         startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.catmullRom)
                    LineMark(x: .value("时间", point.date),
                             y: .value("可用", Double(point.free) / 1e9))
                        .interpolationMethod(.catmullRom)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                }
                .chartYScale(domain: chartDomain(points))
                .chartYAxisLabel("GB")
                .frame(height: 180)
            } else {
                EmptyStateView(title: "记录不足", systemImage: "chart.xyaxis.line",
                               message: "完成两次记录后显示趋势")
                    .frame(height: 180)
            }
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
    }

    // MARK: - Changes table

    private var changesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("目录变化").font(.headline)
                Spacer()
                Picker("", selection: $store.comparePeriod) {
                    ForEach(ComparePeriod.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 260)
                Toggle("只看缩小", isOn: $store.showShrinking)
                    .toggleStyle(.checkbox)
                TextField("搜索路径", text: $store.searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
            }

            if let alert = store.dashboard?.alert {
                Label("\(URL(fileURLWithPath: alert.path).lastPathComponent) 增长了 \(formatBytes(alert.delta))",
                      systemImage: "arrow.up.right.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            let rows = store.visibleRows
            if rows.isEmpty {
                EmptyStateView(title: "没有可显示的变化", systemImage: "checkmark.circle",
                               message: store.dashboard == nil ? "正在读取" : "试试切换对比时段")
                    .frame(height: 160)
            } else {
                Table(rows) {
                    TableColumn("目录") { row in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(URL(fileURLWithPath: row.path).lastPathComponent)
                                .fontWeight(.medium)
                            Text(row.path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .width(min: 240, ideal: 320)
                    TableColumn("之前") { row in
                        Text(formatBytes(row.before)).monospacedDigit()
                    }
                    .width(90)
                    TableColumn("现在") { row in
                        Text(formatBytes(row.after)).monospacedDigit()
                    }
                    .width(90)
                    TableColumn("变化") { row in
                        Text(formatDelta(row.delta))
                            .monospacedDigit()
                            .fontWeight(.semibold)
                            .foregroundStyle((row.delta ?? 0) > 0 ? Color.orange : Color.green)
                    }
                    .width(90)
                    TableColumn("") { row in
                        Button {
                            store.reveal(row.path)
                        } label: {
                            Image(systemName: "finder")
                        }
                        .buttonStyle(.borderless)
                        .help("在 Finder 中显示")
                    }
                    .width(36)
                }
                .frame(minHeight: 260, maxHeight: 420)

                if let note = store.dashboard?.baselineNote, !note.isEmpty {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
    }

    // MARK: - Plugin modules

    private var toolsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("工具").font(.headline)
            HStack(spacing: 12) {
                ForEach(PluginRegistry.all) { plugin in
                    HStack(spacing: 10) {
                        Image(systemName: plugin.systemImage)
                            .font(.title3)
                            .frame(width: 32, height: 32)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(plugin.title).font(.callout.weight(.medium))
                            Text(plugin.subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(10)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                    .opacity(plugin.isAvailable ? 1 : 0.6)
                }
            }
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
    }
}

private struct MetricCard: View {
    let title: String
    let value: String
    let unit: String
    let caption: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 26, weight: .semibold).monospacedDigit())
                    .foregroundStyle(tint)
                if !unit.isEmpty {
                    Text(unit).font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(caption).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
    }
}

/// macOS 13-compatible stand-in for ContentUnavailableView (macOS 14+).
private struct EmptyStateView: View {
    let title: String
    let systemImage: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(title).font(.callout.weight(.medium))
            Text(message).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
