import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var engine: Engine
    @EnvironmentObject var store: Store
    @StateObject private var updater = UpdateChecker.shared

    @State private var rootsText = ""
    @State private var interval = 60
    @State private var maxDepth = 6
    @State private var alertGb = 5.0
    @State private var notifications = false

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("监控", systemImage: "scope") }
            aboutTab
                .tabItem { Label("关于与更新", systemImage: "info.circle") }
        }
        .frame(width: 500, height: 380)
        .onAppear(perform: load)
    }

    private var generalTab: some View {
        Form {
            TextField("监控目录（每行一个）", text: $rootsText, axis: .vertical)
                .lineLimit(3...5)
                .help("默认包含用户目录、/Applications、/Library、/private/var")
            Stepper("记录间隔：\(interval) 分钟", value: $interval, in: 15...720, step: 15)
            Stepper("保留层级：\(maxDepth) 层", value: $maxDepth, in: 2...10)
            Stepper("增长提醒阈值：\(alertGb, specifier: "%.0f") GB", value: $alertGb, in: 1...50)
            Toggle("超阈值时发送 macOS 通知", isOn: $notifications)
            HStack {
                Spacer()
                Button("存储设置") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.status?.state.scanning == true)
            }
            if let busy = store.busyMessage {
                Text(busy).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(20)
    }

    private var aboutTab: some View {
        VStack(spacing: 12) {
            Image(systemName: "chart.bar.doc.horizontal")
                .font(.system(size: 40))
                .foregroundStyle(.tint)
            Text("Storage Watch").font(.title2.weight(.semibold))
            Text("版本 \(UpdateChecker.currentVersion)").foregroundStyle(.secondary)
            Text("本机空间变化记录：不上传文件、不读取文件内容、不自动删除文件。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)

            updateSection
            Spacer()
            HStack(spacing: 12) {
                Link("GitHub", destination: URL(string: "https://github.com/\(UpdateChecker.repository)")!)
                Text("·").foregroundStyle(.tertiary)
                Link("问题反馈", destination: URL(string: "https://github.com/\(UpdateChecker.repository)/issues")!)
            }
            .font(.caption)
        }
        .padding(20)
    }

    @ViewBuilder
    private var updateSection: some View {
        switch updater.state {
        case .idle:
            Button("检查更新") { Task { await updater.check() } }
        case .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在检查…").font(.caption).foregroundStyle(.secondary)
            }
        case .upToDate:
            VStack(spacing: 6) {
                Label("已是最新版本", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
                Button("重新检查") { Task { await updater.check() } }
                    .buttonStyle(.link)
            }
        case .available(let version, let notes):
            VStack(spacing: 8) {
                Label("发现新版本 \(version)", systemImage: "arrow.down.circle.fill")
                    .font(.callout.weight(.medium))
                if !notes.isEmpty {
                    ScrollView {
                        Text(notes)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 90)
                    .padding(8)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                }
                Button("下载并安装") { Task { await updater.install() } }
                    .buttonStyle(.borderedProminent)
            }
        case .downloading(let progress):
            VStack(spacing: 6) {
                ProgressView(value: progress) { Text("正在下载更新…") }
                    .frame(width: 240)
                Text("\(Int(progress * 100))%").font(.caption2).foregroundStyle(.secondary)
            }
        case .installing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在安装，应用将自动重启…").font(.caption)
            }
        case .failed(let message):
            VStack(spacing: 6) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Button("重试") { Task { await updater.check() } }
            }
        }
    }

    private func load() {
        guard let config = store.status?.config ?? store.dashboard?.config else { return }
        rootsText = config.roots.joined(separator: "\n")
        interval = config.intervalMinutes
        maxDepth = config.maxDepth
        alertGb = config.alertGb
        notifications = config.notifications
    }

    private func save() {
        var config = store.status?.config ?? Config(roots: [], intervalMinutes: 60,
                                                    maxDepth: 6, alertGb: 5, notifications: false)
        config.roots = rootsText.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        config.intervalMinutes = interval
        config.maxDepth = maxDepth
        config.alertGb = alertGb
        config.notifications = notifications
        store.saveSettings(config)
    }
}
