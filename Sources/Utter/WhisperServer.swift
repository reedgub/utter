import Darwin
import Foundation
import UtterCore

/// Keeps one whisper-server process running with the model loaded, so a
/// dictation only pays for inference: no model load, no GPU setup.
///
/// It listens on a random port on 127.0.0.1. If Utter is killed without a
/// chance to clean up, the next launch finds the leftover process through a pid
/// file and stops it.
@MainActor
final class WhisperServer {
    enum State: Equatable {
        case stopped
        case starting
        case ready(URL)
        case failed(String)
    }

    private(set) var state: State = .stopped {
        didSet { if state != oldValue { onStateChange?() } }
    }
    var onStateChange: (@MainActor () -> Void)?

    private var process: Process?
    private var spec: WhisperServerSpec?
    private var startTask: Task<Void, Never>?

    private static let pidFile = Paths.configDir.appendingPathComponent("whisper-server.pid")
    static let logFile = Paths.configDir.appendingPathComponent("whisper-server.log")

    var summary: String {
        switch state {
        case .stopped: return "not running"
        case .starting: return "loading model…"
        case .ready: return "model loaded"
        case .failed(let message): return message
        }
    }

    /// Starts the server for `spec`, or restarts it if the spec changed.
    func ensureRunning(_ spec: WhisperServerSpec) {
        if spec == self.spec, process?.isRunning == true { return }
        stop()
        self.spec = spec
        launch(spec)
    }

    func stop() {
        startTask?.cancel()
        startTask = nil
        if let process {
            process.terminationHandler = nil
            if process.isRunning { process.terminate() }
        }
        process = nil
        spec = nil
        try? FileManager.default.removeItem(at: Self.pidFile)
        state = .stopped
    }

    /// Waits for the model to finish loading. Returns nil if the server is not
    /// running or does not become ready in time.
    func readyURL(timeout: TimeInterval) async -> URL? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            switch state {
            case .ready(let url): return url
            case .starting: break
            case .stopped, .failed: return nil
            }
            if Date() > deadline || Task.isCancelled { return nil }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// Called when a request failed in a way that suggests the process is gone.
    func markUnhealthy() {
        if let process, process.isRunning { return }
        process = nil
        spec = nil
        state = .failed("whisper-server stopped")
    }

    // MARK: Launch

    private func launch(_ spec: WhisperServerSpec) {
        Self.killLeftoverProcess()

        let port = Self.freePort()
        let process = Process()
        process.executableURL = spec.executable
        process.arguments = WhisperServerAPI.launchArguments(spec, port: port)
        process.standardInput = FileHandle.nullDevice
        // A file, not a pipe: a pipe nobody reads fills up and blocks the server.
        FileManager.default.createFile(atPath: Self.logFile.path, contents: nil)
        let logHandle = (try? FileHandle(forWritingTo: Self.logFile)) ?? FileHandle.nullDevice
        process.standardOutput = logHandle
        process.standardError = logHandle

        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            onMain {
                guard let self, self.process === finished else { return }
                log.error("whisper-server exited with \(status)")
                self.process = nil
                self.spec = nil
                self.startTask?.cancel()
                self.state = .failed("whisper-server exited (\(status)); see whisper-server.log")
            }
        }

        do {
            try process.run()
        } catch {
            state = .failed("could not start whisper-server: \(error.localizedDescription)")
            return
        }
        self.process = process
        try? String(process.processIdentifier).write(to: Self.pidFile, atomically: true, encoding: .utf8)
        state = .starting
        log.info("whisper-server starting on port \(port) with \(spec.model.lastPathComponent, privacy: .public)")

        let base = URL(string: "http://127.0.0.1:\(port)")!
        let started = Date()
        startTask = Task { [weak self] in
            // Loading medium can take a while on first run while macOS pages the file in.
            for _ in 0..<600 {
                try? await Task.sleep(nanoseconds: 200_000_000)
                if Task.isCancelled { return }
                if await WhisperServerAPI.isHealthy(base) {
                    await self?.warmUp(base, loadTime: Date().timeIntervalSince(started))
                    return
                }
            }
            guard let self, !Task.isCancelled else { return }
            self.state = .failed("whisper-server did not finish loading; see whisper-server.log")
        }
    }

    /// The first inference after loading compiles GPU kernels. Do it now, on half
    /// a second of silence, instead of on the user's first dictation.
    private func warmUp(_ base: URL, loadTime: TimeInterval) async {
        let silence = WAV.encode(samples: [Float](repeating: 0, count: 8_000), sampleRate: 16_000)
        let warmStart = Date()
        _ = try? await WhisperServerAPI.transcribe(baseURL: base, wav: silence, vocabulary: "")
        guard !Task.isCancelled else { return }
        log.info("whisper-server ready: load \(loadTime, format: .fixed(precision: 1))s, warm-up \(Date().timeIntervalSince(warmStart), format: .fixed(precision: 1))s")
        state = .ready(base)
    }

    // MARK: Helpers

    private static func killLeftoverProcess() {
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0,
              kill(pid, 0) == 0 else { return }
        // Only kill it if it really is a whisper-server, not a reused pid.
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-p", String(pid), "-o", "comm="]
        let out = Pipe()
        ps.standardOutput = out
        ps.standardError = FileHandle.nullDevice
        guard (try? ps.run()) != nil else { return }
        ps.waitUntilExit()
        let command = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        if command.contains(WhisperServerAPI.executableName) {
            log.notice("stopping leftover whisper-server (pid \(pid))")
            kill(pid, SIGTERM)
        }
    }

    /// Asks the kernel for an unused port on 127.0.0.1.
    private static func freePort() -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return 18_178 }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)

        let ok = withUnsafeMutablePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, length) == 0 && getsockname(fd, sa, &length) == 0
            }
        }
        guard ok else { return 18_178 }
        return Int(UInt16(bigEndian: addr.sin_port))
    }
}
