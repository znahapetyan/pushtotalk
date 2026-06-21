import Foundation

/// Manages a local whisper.cpp server process tied to the app's lifetime:
/// started on launch (for the "local" provider) and stopped on quit.
final class WhisperServer {
    private var process: Process?
    private var starting = false

    /// Starts the server if the provider is local and nothing is already serving
    /// on the endpoint. No-op for cloud providers or if we already started one.
    func ensureRunning(config: Config) {
        guard config.provider == "local" else { return }
        if let process = process, process.isRunning { return }
        if starting { return }
        starting = true

        // Don't double-start if a server is already up (LaunchAgent, manual run,
        // or a leftover process).
        isReachable(config.transcriptionEndpoint) { [weak self] reachable in
            guard let self = self else { return }
            if !reachable { self.launch(config: config) }
            self.starting = false
        }
    }

    /// Terminates the server, but only the one this app started.
    func stop() {
        if let process = process, process.isRunning {
            process.terminate()
        }
        process = nil
    }

    private func launch(config: Config) {
        guard FileManager.default.isExecutableFile(atPath: config.whisperServerPath),
              FileManager.default.fileExists(atPath: config.whisperModelPath) else {
            return // binary or model missing — menu will show "NOT running"
        }

        let (host, port) = Self.hostPort(from: config.transcriptionEndpoint)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: config.whisperServerPath)
        proc.arguments = ["-m", config.whisperModelPath, "--host", host, "--port", port]

        // Append output to the log file.
        let logURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".talk/whisper-server.log")
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            proc.standardOutput = handle
            proc.standardError = handle
        }

        do {
            try proc.run()
            process = proc
        } catch {
            process = nil
        }
    }

    private static func hostPort(from url: URL) -> (String, String) {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let host = components?.host ?? "127.0.0.1"
        let port = components?.port.map(String.init) ?? "8080"
        return (host, port)
    }

    private func isReachable(_ endpoint: URL, completion: @escaping (Bool) -> Void) {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            completion(false); return
        }
        components.path = "/"
        components.query = nil
        guard let url = components.url else { completion(false); return }

        var request = URLRequest(url: url)
        request.timeoutInterval = 1.0
        URLSession.shared.dataTask(with: request) { _, response, error in
            DispatchQueue.main.async { completion(error == nil && response != nil) }
        }.resume()
    }
}
