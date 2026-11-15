import Foundation
import os
import UtterCore

let log = Logger(subsystem: "dev.utter.Utter", category: "utter")

/// A lock-protected box for values shared with callbacks on other threads.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value
    init(_ value: Value) { _value = value }
    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
    func mutate(_ body: (inout Value) -> Void) {
        lock.lock(); body(&_value); lock.unlock()
    }
}

struct Recording: Sendable {
    let samples: [Float]
    let sampleRate: Int
    let peakRMS: Float
    var duration: TimeInterval { Double(samples.count) / Double(sampleRate) }
}

/// Where the time went, shown in the menu and the window so slowness can be
/// pinned on a stage instead of guessed at.
struct PipelineTimings: Sendable {
    var audio: TimeInterval = 0
    var engine = ""
    var transcribe: TimeInterval = 0
    var cleanup: TimeInterval?

    var summary: String {
        func s(_ t: TimeInterval) -> String { String(format: "%.1f s", t) }
        var parts = ["\(s(audio)) of audio", "\(engine) \(s(transcribe))"]
        if let cleanup { parts.append("cleanup \(s(cleanup))") }
        return parts.joined(separator: " · ")
    }
}

enum PipelineOutcome: Sendable {
    /// `note` explains a degraded result, such as cleanup being skipped.
    case text(String, note: String?, timings: PipelineTimings)
    case noSpeech
}

/// Recording → transcript → cleanup. Runs off the main actor; cancelling the
/// task kills a running whisper-cli or drops the in-flight HTTP request.
struct Pipeline: Sendable {
    let config: Config
    let keys: APIKeys
    /// The resident whisper-server, when `local_engine = "server"`.
    let server: WhisperServer?
    let progress: @Sendable (String) -> Void

    func run(_ recording: Recording) async throws -> PipelineOutcome {
        // Do not send silence to Whisper: it tends to invent "Thank you." for it.
        guard recording.duration >= 0.15, Double(recording.peakRMS) >= config.silenceThreshold else {
            log.info("skipped: \(recording.duration, format: .fixed(precision: 2))s, peak \(Double(recording.peakRMS), format: .fixed(precision: 4))")
            return .noSpeech
        }

        var timings = PipelineTimings(audio: recording.duration)
        let start = Date()
        let raw = try await transcribe(recording, timings: &timings)
        timings.transcribe = Date().timeIntervalSince(start)
        try Task.checkCancellation()
        if raw.isEmpty || TranscriptText.isLikelyHallucination(raw, duration: recording.duration) {
            return .noSpeech
        }
        return try await cleanup(raw, timings: timings)
    }

    private func transcribe(_ recording: Recording, timings: inout PipelineTimings) async throws -> String {
        let backend = try Backends.transcriber(for: config, keys: keys).get()
        let wav = WAV.encode(samples: recording.samples, sampleRate: recording.sampleRate)
        progress("Transcribing")

        if backend == .local { return try await transcribeLocally(wav, timings: &timings) }

        timings.engine = backend.name
        do {
            let text = try await CloudWhisper.transcribe(backend: backend, config: config, wav: wav)
            return TranscriptText.clean(text)
        } catch let error where isConnectivityError(error) && config.fallbackToLocal && localModelAvailable {
            log.notice("\(backend.name, privacy: .public) unreachable, falling back to local: \(error.localizedDescription, privacy: .public)")
            progress("Offline · transcribing locally")
            return try await transcribeLocally(wav, timings: &timings)
        }
    }

    private var localModelAvailable: Bool {
        LocalWhisper.findExecutable(configured: config.whisperCLI) != nil &&
            FileManager.default.fileExists(atPath: LocalWhisper.modelURL(for: config.localModel).path)
    }

    private func transcribeLocally(_ wav: Data, timings: inout PipelineTimings) async throws -> String {
        if config.localEngine == .server, let server {
            if case .starting = await server.state { progress("Loading model…") }
            if let base = await server.readyURL(timeout: 90) {
                do {
                    timings.engine = "whisper (loaded)"
                    let text = try await WhisperServerAPI.transcribe(baseURL: base, wav: wav, vocabulary: config.vocabulary)
                    return TranscriptText.clean(text)
                } catch let error where isConnectivityError(error) {
                    // The server died mid-request; whisper-cli still works.
                    log.error("whisper-server unreachable, using whisper-cli: \(error.localizedDescription, privacy: .public)")
                    await server.markUnhealthy()
                }
            }
        }
        timings.engine = "whisper-cli"
        return try await transcribeWithCLI(wav)
    }

    private func transcribeWithCLI(_ wav: Data) async throws -> String {
        guard let exe = LocalWhisper.findExecutable(configured: config.whisperCLI) else {
            throw BackendError("whisper-cli not found. Run `brew install whisper-cpp`, or set whisper_cli in config.toml.")
        }
        let model = LocalWhisper.modelURL(for: config.localModel)
        guard FileManager.default.fileExists(atPath: model.path) else {
            throw BackendError("No model at \(model.path). Run `make model MODEL=\(config.localModel)`.")
        }

        let audio = FileManager.default.temporaryDirectory.appendingPathComponent("utter-\(UUID().uuidString).wav")
        try wav.write(to: audio)
        defer { try? FileManager.default.removeItem(at: audio) }

        let args = LocalWhisper.arguments(model: model.path, audio: audio.path, config: config)
        let result = try await ProcessRunner.run(exe, arguments: args)
        try Task.checkCancellation()
        guard result.status == 0 else {
            let detail = result.stderr.split(separator: "\n").last.map(String.init) ?? ""
            throw BackendError("whisper-cli exited with \(result.status). \(detail)")
        }
        return LocalWhisper.parseOutput(result.stdout)
    }

    private func cleanup(_ raw: String, timings: PipelineTimings) async throws -> PipelineOutcome {
        var timings = timings
        let backend: CleanupBackend
        switch Backends.cleanup(for: config, keys: keys) {
        case .success(let b): backend = b
        case .failure(let e): return .text(raw, note: e.description, timings: timings)
        }
        if backend == .none { return .text(raw, note: nil, timings: timings) }

        progress("Cleaning up")
        let start = Date()
        defer { log.info("cleanup took \(Date().timeIntervalSince(start), format: .fixed(precision: 2))s") }
        do {
            let output = try await CleanupClient.clean(raw, backend: backend, config: config)
            try Task.checkCancellation()
            timings.cleanup = Date().timeIntervalSince(start)
            guard let accepted = Cleanup.accept(raw: raw, cleaned: output) else {
                log.notice("cleanup output rejected, inserting raw transcript")
                return .text(raw, note: "Cleanup looked off · inserted raw text", timings: timings)
            }
            return .text(accepted, note: nil, timings: timings)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            timings.cleanup = Date().timeIntervalSince(start)
            log.error("cleanup failed: \(error.localizedDescription, privacy: .public)")
            let reason = isConnectivityError(error) ? "offline" : "failed"
            return .text(raw, note: "Cleanup \(reason) · inserted raw text", timings: timings)
        }
    }
}

struct ProcessResult: Sendable {
    let status: Int32
    let stdout: String
    let stderr: String
}

enum ProcessRunner {
    /// Runs a process to completion. Task cancellation terminates it.
    static func run(_ executable: URL, arguments: [String]) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice

        let cancelled = Locked(false)
        let box = Locked(process)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessResult, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    let process = box.value
                    do {
                        try process.run()
                    } catch {
                        continuation.resume(throwing: error)
                        return
                    }
                    // Cancelled between the check and launch: stop it now.
                    if cancelled.value { process.terminate() }

                    // Drain both pipes at once so neither fills and blocks the child.
                    let outData = Locked(Data())
                    let errData = Locked(Data())
                    let group = DispatchGroup()
                    DispatchQueue.global().async(group: group) {
                        outData.value = out.fileHandleForReading.readDataToEndOfFile()
                    }
                    DispatchQueue.global().async(group: group) {
                        errData.value = err.fileHandleForReading.readDataToEndOfFile()
                    }
                    group.wait()
                    process.waitUntilExit()

                    if cancelled.value {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    continuation.resume(returning: ProcessResult(
                        status: process.terminationStatus,
                        stdout: String(decoding: outData.value, as: UTF8.self),
                        stderr: String(decoding: errData.value, as: UTF8.self)
                    ))
                }
            }
        } onCancel: {
            cancelled.value = true
            let process = box.value
            if process.isRunning { process.terminate() }
        }
    }
}
