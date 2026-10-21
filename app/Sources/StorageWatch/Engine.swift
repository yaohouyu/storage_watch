import Foundation

/// Manages the embedded Python collection engine (`engine/monitor.py`)
/// and talks to its loopback-only HTTP API.
final class Engine: ObservableObject {
    static let shared = Engine()

    @Published private(set) var baseURL: URL?
    @Published private(set) var token: String = ""
    @Published private(set) var isRunning = false
    @Published private(set) var launchError: String?

    private var process: Process?
    private var stdoutBuffer = Data()
    private var restartAttempts = 0
    private var runtimeFile: URL { dataDir.appendingPathComponent("runtime.json") }
    private var dataDir: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("StorageWatch", isDirectory: true)
    }

    /// Path to the engine script: bundled in the .app, or the repo checkout during development.
    private var engineScript: URL? {
        if let bundled = Bundle.main.url(forResource: "monitor", withExtension: "py") {
            return bundled
        }
        // Development fallback: <repo>/engine/monitor.py relative to the built binary.
        let dev = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // StorageWatch
            .deletingLastPathComponent() // Sources
            .deletingLastPathComponent() // app
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("engine/monitor.py")
        return FileManager.default.fileExists(atPath: dev.path) ? dev : nil
    }

    private func pythonInterpreter() -> String? {
        // Preferred: the runtime embedded in the app bundle, so users need no Python install.
        if let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("python/bin/python3", isDirectory: false),
           FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled.path
        }
        // Development fallback: repo-local runtime downloaded by build-app.sh --bundle-python.
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // StorageWatch
            .deletingLastPathComponent() // Sources
            .deletingLastPathComponent() // app
        for candidate in ["Resources/python/bin/python3", "../Resources/python/bin/python3"] {
            let path = sourceRoot.appendingPathComponent(candidate).path
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        // Last resort: a system/Homebrew Python for development builds only.
        let candidates = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: path)
            task.arguments = ["-c", "import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)"]
            do {
                try task.run(); task.waitUntilExit()
                if task.terminationStatus == 0 { return path }
            } catch { continue }
        }
        return nil
    }

    func start() {
        guard process == nil else { return }
        guard let script = engineScript else {
            launchError = "找不到采集引擎 monitor.py"
            return
        }

        // Reuse an engine that is already serving this data directory (e.g. app relaunch).
        if let info = try? JSONDecoder().decode(RuntimeInfo.self, from: Data(contentsOf: runtimeFile)),
           let url = URL(string: "http://127.0.0.1:\(info.port)"),
           let session: SessionInfo = try? synchronousGet(url.appendingPathComponent("api/session")),
           session.token.isEmpty == false {
            baseURL = url
            token = session.token
            isRunning = true
            launchError = nil
            return
        }

        guard let python = pythonInterpreter() else {
            launchError = "需要 Python 3.10 或更高版本"
            return
        }
        try? FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)

        let task = Process()
        task.executableURL = URL(fileURLWithPath: python)
        // Fixed private port with fallback; the engine writes the actual port to runtime.json.
        task.arguments = [script.path, "--port", "8791", "--auto-port",
                          "--data-dir", dataDir.path,
                          "--parent-pid", String(ProcessInfo.processInfo.processIdentifier)]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            Task { @MainActor in
                guard let self else { return }
                self.stdoutBuffer.append(chunk)
                if self.stdoutBuffer.count > 8192 {
                    self.stdoutBuffer = self.stdoutBuffer.suffix(8192)
                }
            }
        }
        do {
            try task.run()
            process = task
            isRunning = true
            launchError = nil
            Task { await discoverEndpoint() }
            task.terminationHandler = { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.process = nil
                    self.isRunning = false
                    self.baseURL = nil
                    // Restart once if the engine died unexpectedly (crashed or port taken).
                    if self.restartAttempts < 2 {
                        self.restartAttempts += 1
                        try? await Task.sleep(for: .seconds(3))
                        self.start()
                    } else {
                        let log = String(data: self.stdoutBuffer, encoding: .utf8) ?? ""
                        self.launchError = "采集引擎已退出：" + (log.suffix(300).trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                }
            }
        } catch {
            launchError = "引擎启动失败：\(error.localizedDescription)"
        }
    }

    func stop() {
        guard let baseURL else { process?.terminate(); return }
        var request = URLRequest(url: baseURL.appendingPathComponent("api/stop"))
        request.httpMethod = "POST"
        request.setValue(token, forHTTPHeaderField: "X-Storage-Token")
        URLSession.shared.dataTask(with: request).resume()
        process?.terminate()
    }

    /// The engine writes runtime.json with its actual port once bound.
    private func discoverEndpoint() async {
        for _ in 0..<60 {
            if let data = try? Data(contentsOf: runtimeFile),
               let info = try? JSONDecoder().decode(RuntimeInfo.self, from: data),
               let url = URL(string: "http://127.0.0.1:\(info.port)") {
                // Verify the live process matches the runtime record.
                if let session: SessionInfo = try? await get(url.appendingPathComponent("api/session"), authed: false) {
                    await MainActor.run {
                        self.baseURL = url
                        self.token = session.token
                        self.restartAttempts = 0
                    }
                    return
                }
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        await MainActor.run { self.launchError = "引擎端口握手超时" }
    }

    /// Blocking token handshake used only during startup, before polling begins.
    private func synchronousGet<T: Decodable>(_ url: URL) -> T? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5
        let semaphore = DispatchSemaphore(value: 0)
        var result: T?
        URLSession.shared.dataTask(with: request) { data, response, _ in
            defer { semaphore.signal() }
            guard let data,
                  (response as? HTTPURLResponse)?.statusCode == 200 else { return }
            result = try? JSONDecoder().decode(T.self, from: data)
        }.resume()
        _ = semaphore.wait(timeout: .now() + 2)
        return result
    }

    // MARK: - API

    func get<T: Decodable>(_ url: URL, authed: Bool = true) async throws -> T {
        var request = URLRequest(url: url)
        if authed { request.setValue(token, forHTTPHeaderField: "X-Storage-Token") }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw EngineError.http((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    @discardableResult
    func post<T: Decodable>(_ path: String, body: [String: Any] = [:]) async throws -> T {
        guard let baseURL else { throw EngineError.notReady }
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(token, forHTTPHeaderField: "X-Storage-Token")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw EngineError.http((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    enum EngineError: LocalizedError {
        case notReady, http(Int)
        var errorDescription: String? {
            switch self {
            case .notReady: return "采集引擎尚未就绪"
            case .http(let code): return "引擎返回错误（\(code)）"
            }
        }
    }
}

private struct RuntimeInfo: Decodable { let pid: Int; let port: Int }
private struct SessionInfo: Decodable { let token: String }
