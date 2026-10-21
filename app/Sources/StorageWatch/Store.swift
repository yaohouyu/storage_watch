import Foundation

enum TrendPeriod: Int, CaseIterable, Identifiable {
    case day = 1, week = 7, month = 30
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .day: return "24 小时"
        case .week: return "7 天"
        case .month: return "30 天"
        }
    }
}

enum ComparePeriod: String, CaseIterable, Identifiable {
    case previous, today, week
    var id: String { rawValue }
    var label: String {
        switch self {
        case .previous: return "与上次比"
        case .today: return "与今天比"
        case .week: return "与近 7 天比"
        }
    }
}

/// Polls the engine and exposes dashboard state to the UI.
@MainActor
final class Store: ObservableObject {
    static let shared = Store()

    @Published var dashboard: Dashboard?
    @Published var status: Status?
    @Published var comparePeriod: ComparePeriod = .previous {
        didSet { Task { await refresh() } }
    }
    @Published var trendPeriod: TrendPeriod = .week
    @Published var searchText = ""
    @Published var showShrinking = false
    @Published var busyMessage: String?
    @Published var errorMessage: String?
    @Published var hasLoadedOnce = false

    private let engine = Engine.shared
    private var pollTask: Task<Void, Never>?

    func beginPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                // Engine may still be starting; retry quickly until it answers.
                if self?.engine.baseURL == nil || self?.engine.token.isEmpty == true {
                    try? await Task.sleep(for: .milliseconds(400))
                    continue
                }
                await self?.refresh()
                try? await Task.sleep(for: .seconds(self?.status?.state.scanning == true ? 2 : 8))
            }
        }
    }

    func refresh() async {
        guard let base = engine.baseURL, !engine.token.isEmpty else { return }
        do {
            let status: Status = try await engine.get(base.appendingPathComponent("api/status"))
            self.status = status
            var comps = URLComponents(url: base.appendingPathComponent("api/dashboard"), resolvingAgainstBaseURL: false)!
            comps.queryItems = [URLQueryItem(name: "period", value: comparePeriod.rawValue)]
            let dash: Dashboard = try await engine.get(comps.url!)
            self.dashboard = dash
            self.hasLoadedOnce = true
            self.errorMessage = nil
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    func scanNow() {
        Task {
            busyMessage = "正在请求扫描…"
            do {
                let _: ScanStarted = try await engine.post("api/scan")
            } catch { errorMessage = error.localizedDescription }
            busyMessage = nil
            await refresh()
        }
    }

    func reveal(_ path: String) {
        Task {
            do {
                let _: [String: Bool] = try await engine.post("api/reveal", body: ["path": path])
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func saveSettings(_ config: Config) {
        Task {
            busyMessage = "正在保存设置…"
            do {
                let body: [String: Any] = [
                    "roots": config.roots,
                    "interval_minutes": config.intervalMinutes,
                    "max_depth": config.maxDepth,
                    "alert_gb": config.alertGb,
                    "notifications": config.notifications,
                ]
                let _: Config = try await engine.post("api/settings", body: body)
            } catch { errorMessage = error.localizedDescription }
            busyMessage = nil
            await refresh()
        }
    }

    // MARK: - Derived data

    /// Rows currently shown in the change table.
    var visibleRows: [ChangeRow] {
        guard let rows = dashboard?.rows else { return [] }
        var result = rows.filter { showShrinking ? ($0.delta ?? 0) < 0 : ($0.delta ?? 0) > 0 }
        if !searchText.isEmpty {
            result = result.filter { $0.path.localizedCaseInsensitiveContains(searchText) }
        }
        return result.sorted { abs($0.delta ?? 0) > abs($1.delta ?? 0) }
    }

    var trendPoints: [(date: Date, free: Int64)] {
        let cutoff = Date().addingTimeInterval(-TimeInterval(trendPeriod.rawValue) * 86400)
        return (dashboard?.history ?? [])
            .filter { $0.finished >= cutoff.timeIntervalSince1970 }
            .compactMap { entry in entry.free.map { (Date(timeIntervalSince1970: entry.finished), $0) } }
    }

    /// Net change of used disk space for the selected comparison.
    var usedDelta: Int64? {
        guard let baseline = dashboard?.baseline?.free, let latest = dashboard?.latest?.free else { return nil }
        return baseline - latest // free dropped => used grew
    }
}
