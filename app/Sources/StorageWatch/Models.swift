import Foundation

struct Status: Decodable {
    let state: ScanState
    let latestId: Int?
    let disk: Disk
    let config: Config
    enum CodingKeys: String, CodingKey {
        case state, disk, config
        case latestId = "latest_id"
    }
}

struct ScanState: Decodable {
    let scanning: Bool
    let progress: [String: ProgressValue]
    let lastError: String?
    let nextScan: TimeInterval
    let scanStarted: TimeInterval?
    enum CodingKeys: String, CodingKey {
        case scanning, progress
        case lastError = "last_error"
        case nextScan = "next_scan"
        case scanStarted = "scan_started"
    }
}

enum ProgressValue: Decodable {
    case string(String), number(Double)
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { self = .string(s); return }
        self = .number((try? c.decode(Double.self)) ?? 0)
    }
    var text: String {
        switch self {
        case .string(let s): return s
        case .number(let n): return n.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(n)) : String(n)
        }
    }
}

struct Disk: Decodable {
    let total: Int64
    let free: Int64
}

struct Config: Decodable {
    var roots: [String]
    var intervalMinutes: Int
    var maxDepth: Int
    var alertGb: Double
    var notifications: Bool
    enum CodingKeys: String, CodingKey {
        case roots, notifications
        case intervalMinutes = "interval_minutes"
        case maxDepth = "max_depth"
        case alertGb = "alert_gb"
    }
}

struct Dashboard: Decodable {
    let state: ScanState
    let config: Config
    let history: [HistoryEntry]
    let disk: Disk
    let rows: [ChangeRow]
    let latest: HistoryEntry?
    let baseline: HistoryEntry?
    let errors: [ScanError]
    let baselineNote: String
    let alert: ChangeRow?
    enum CodingKeys: String, CodingKey {
        case state, config, history, disk, rows, latest, baseline, errors, alert
        case baselineNote = "baseline_note"
    }
}

struct HistoryEntry: Decodable, Identifiable {
    let id: Int
    let started: TimeInterval
    let finished: TimeInterval
    let free: Int64?
}

struct ScanError: Decodable, Identifiable {
    var id: String { "\(path)-\(kind)" }
    let path: String
    let kind: String
    let detail: String?
}

struct ChangeRow: Decodable, Identifiable {
    var id: String { path }
    let path: String
    let parent: String?
    let depth: Int
    let root: String?
    let before: Int64?
    let after: Int64?
    let delta: Int64?
    let kind: String
    let complete: Bool
    let exists: Bool
}

struct ScanStarted: Decodable { let started: Bool }

// MARK: - Formatting

func formatBytes(_ bytes: Int64?, unit: Bool = true) -> String {
    guard let bytes else { return "—" }
    let gb = Double(bytes) / 1e9
    let value: String
    if abs(gb) >= 100 { value = String(format: "%.0f", gb) }
    else if abs(gb) >= 10 { value = String(format: "%.1f", gb) }
    else { value = String(format: "%.2f", gb) }
    return unit ? "\(value) GB" : value
}

func formatDelta(_ bytes: Int64?) -> String {
    guard let bytes else { return "—" }
    let sign = bytes > 0 ? "+" : bytes < 0 ? "-" : ""
    return sign + formatBytes(abs(bytes))
}

func formatTime(_ ts: TimeInterval?) -> String {
    guard let ts else { return "—" }
    let date = Date(timeIntervalSince1970: ts)
    let f = DateFormatter()
    f.locale = Locale(identifier: "zh_CN")
    f.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "M月d日 HH:mm"
    return f.string(from: date)
}
