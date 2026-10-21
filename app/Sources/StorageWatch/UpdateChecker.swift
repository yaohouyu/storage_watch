import Foundation
import AppKit

/// In-app updater backed by GitHub Releases.
///
/// Release contract (see `.github/workflows/release.yml`):
/// - Asset `StorageWatch-<version>.zip` containing `Storage Watch.app`.
/// - Asset `StorageWatch-<version>.zip.sha256` with the lowercase hex digest.
///
/// Only a bundle that passes `codesign --verify --deep --strict` is installed.
@MainActor
final class UpdateChecker: ObservableObject {
    static let repository = "yaohouyuterry/storage_watch"
    static let shared = UpdateChecker()

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String, notes: String)
        case downloading(progress: Double)
        case installing
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    private var pendingRelease: Release?

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    struct Release: Decodable {
        let tagName: String
        let htmlURL: URL
        let body: String?
        let assets: [Asset]
        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name", htmlURL = "html_url", body, assets
        }
        var version: String { tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV")) }
        func asset(suffix: String) -> Asset? { assets.first { $0.name.hasSuffix(suffix) } }
    }

    struct Asset: Decodable {
        let name: String
        let browserDownloadURL: URL
        let size: Int
        enum CodingKeys: String, CodingKey {
            case name, size
            case browserDownloadURL = "browser_download_url"
        }
    }

    func check() async {
        if case .checking = state { return }
        if case .downloading = state { return }
        state = .checking
        guard let url = URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest") else {
            state = .failed("更新地址无效")
            return
        }
        do {
            var request = URLRequest(url: url)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 15
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                state = .failed("网络响应无效")
                return
            }
            switch http.statusCode {
            case 200: break
            case 404:
                state = .failed("还没有发布版本")
                return
            default:
                state = .failed("检查更新失败（HTTP \(http.statusCode)）")
                return
            }
            let release = try JSONDecoder().decode(Release.self, from: data)
            pendingRelease = release
            if Self.isNewer(release.version, than: Self.currentVersion) {
                state = .available(version: release.version, notes: Self.summarize(release.body ?? ""))
            } else {
                state = .upToDate
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Downloads, verifies, swaps the bundle and relaunches.
    func install() async {
        guard let release = pendingRelease,
              let zip = release.asset(suffix: ".zip"),
              let sha = release.asset(suffix: ".zip.sha256") else {
            state = .failed("发布包不完整，缺少 zip 或 sha256")
            return
        }
        do {
            state = .downloading(progress: 0)
            let archive = try await download(zip)
            state = .downloading(progress: 0.8)
            let expected = try await fetchDigest(sha)
            let actual = try FileDigest.sha256(of: archive)
            guard expected == actual else {
                state = .failed("校验失败，安装包可能已损坏")
                return
            }
            state = .installing
            try installArchive(archive)
            UserDefaults.standard.set(release.version, forKey: "lastInstalledVersion")
            relaunch()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func download(_ asset: Asset) async throws -> URL {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("StorageWatch-\(UUID().uuidString).zip")
        var request = URLRequest(url: asset.browserDownloadURL)
        request.setValue("StorageWatch/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.download }
        state = .downloading(progress: 0.7)
        try data.write(to: destination, options: .atomic)
        return destination
    }

    private func fetchDigest(_ asset: Asset) async throws -> String {
        let (data, response) = try await URLSession.shared.data(from: asset.browserDownloadURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let text = String(data: data, encoding: .utf8),
              let digest = text.split(whereSeparator: \.isWhitespace).first,
              digest.count == 64 else { throw UpdateError.download }
        return digest.lowercased()
    }

    @MainActor
    private func installArchive(_ archive: URL) throws {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("StorageWatch-staging-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", archive.path, staging.path]
        try unzip.run()
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0 else { throw UpdateError.unpack }

        guard let newApp = try fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" }) else { throw UpdateError.unpack }

        let verify = Process()
        verify.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        verify.arguments = ["--verify", "--deep", "--strict", newApp.path]
        try verify.run()
        verify.waitUntilExit()
        guard verify.terminationStatus == 0 else { throw UpdateError.unsigned }

        let current = Bundle.main.bundleURL
        let staged = current.deletingLastPathComponent()
            .appendingPathComponent(".StorageWatch-\(UUID().uuidString).app")
        try fm.moveItem(at: newApp, to: staged)
        _ = try fm.replaceItemAt(current, withItemAt: staged)
    }

    private func relaunch() {
        let script = Process()
        script.executableURL = URL(fileURLWithPath: "/bin/sh")
        script.arguments = ["-c", "sleep 1; /usr/bin/open \"$1\"", "relaunch", Bundle.main.bundlePath]
        try? script.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSApp.terminate(nil) }
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ value: String) -> [Int] {
            let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            return trimmed.split(separator: "-").first.map {
                $0.split(separator: ".").map { Int($0) ?? 0 }
            } ?? []
        }
        let a = parts(candidate), b = parts(current)
        for index in 0..<max(a.count, b.count) {
            let lhs = index < a.count ? a[index] : 0
            let rhs = index < b.count ? b[index] : 0
            if lhs != rhs { return lhs > rhs }
        }
        return false
    }

    private static func summarize(_ body: String) -> String {
        body.components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("<!--") }
            .prefix(12)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    enum UpdateError: LocalizedError {
        case download, unpack, unsigned
        var errorDescription: String? {
            switch self {
            case .download: return "下载更新失败"
            case .unpack: return "更新包解压失败"
            case .unsigned: return "更新包签名无效，已拒绝安装"
            }
        }
    }
}

enum FileDigest {
    static func sha256(of url: URL) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
        process.arguments = ["-a", "256", url.path]
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateChecker.UpdateError.download }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let line = String(data: data, encoding: .utf8),
              let digest = line.split(whereSeparator: \.isWhitespace).first else {
            throw UpdateChecker.UpdateError.download
        }
        return digest.lowercased()
    }
}
