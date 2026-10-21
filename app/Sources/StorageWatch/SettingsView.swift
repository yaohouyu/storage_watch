import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var engine: Engine
    @EnvironmentObject var store: Store

    @State private var rootsText = ""
    @State private var interval = 60
    @State private var maxDepth = 6
    @State private var alertGb = 5.0
    @State private var notifications = false
    @State private var updateStatus: String?
    @State private var checkingUpdate = false

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("监控", systemImage: "scope") }
            aboutTab
                .tabItem { Label("关于与更新", systemImage: "info.circle") }
        }
        .frame(width: 480, height: 340)
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
        VStack(spacing: 14) {
            Image(systemName: "chart.bar.doc.horizontal")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text("Storage Watch").font(.title2.weight(.semibold))
            Text("版本 \(UpdateChecker.currentVersion)")
                .foregroundStyle(.secondary)
            Text("本机空间变化记录：不上传文件、不读取文件内容、不自动删除文件。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button(checkingUpdate ? "正在检查…" : "检查更新") { checkUpdate() }
                .disabled(checkingUpdate)
            if let updateStatus {
                Text(updateStatus).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(20)
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

    private func checkUpdate() {
        checkingUpdate = true
        updateStatus = nil
        Task {
            let result = await UpdateChecker.check()
            checkingUpdate = false
            switch result {
            case .upToDate:
                updateStatus = "已是最新版本"
            case .available(let release):
                updateStatus = "发现新版本 \(release.tagName)"
                NSWorkspace.shared.open(release.htmlURL)
            case .failed(let message):
                updateStatus = "检查失败：\(message)"
            }
        }
    }
}
