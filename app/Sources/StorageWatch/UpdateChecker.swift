import Foundation

/// Checks GitHub Releases for a newer version. Replace `repository` once the repo is public.
struct UpdateChecker {
    static var repository = "yaohouyu/storage-watch"
    static let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"

    struct Release: Decodable {
        let tagName: String
        let htmlURL: URL
        let body: String?
        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name", htmlURL = "html_url", body
        }
    }

    enum CheckResult {
        case upToDate
        case available(Release)
        case failed(String)
    }

    static func check() async -> CheckResult {
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else {
            return .failed("无效的仓库地址")
        }
        do {
            var request = URLRequest(url: url)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 15
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return .failed("无法获取发布信息") }
            let release = try JSONDecoder().decode(Release.self, from: data)
            let latest = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            return isNewer(latest, than: currentVersion) ? .available(release) : .upToDate
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Semantic version comparison, ignoring pre-release suffixes.
    private static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ v: String) -> [Int] {
            v.split(separator: "-").first.map {
                $0.split(separator: ".").compactMap { Int($0) }
            } ?? []
        }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
