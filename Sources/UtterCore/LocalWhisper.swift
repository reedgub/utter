import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum Paths {
    public static var configDir: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config/utter", isDirectory: true)
    }
    public static var configFile: URL { configDir.appendingPathComponent("config.toml") }
    public static var envFile: URL { configDir.appendingPathComponent(".env") }
    public static var modelsDir: URL { configDir.appendingPathComponent("models", isDirectory: true) }

    public static func expandTilde(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }
}

public enum LocalWhisper {
    /// Homebrew's whisper-cpp formula installs `whisper-cli`; older builds called it `whisper-cpp`.
    public static let executableNames = ["whisper-cli", "whisper-cpp"]
    public static let searchDirectories = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"]

    public static func modelURL(for name: String, modelsDir: URL = Paths.modelsDir) -> URL {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.contains("/") || trimmed.hasSuffix(".bin") {
            return URL(fileURLWithPath: Paths.expandTilde(trimmed))
        }
        return modelsDir.appendingPathComponent("ggml-\(trimmed).bin")
    }

    public static func findExecutable(configured: String, fileManager: FileManager = .default) -> URL? {
        let configured = configured.trimmingCharacters(in: .whitespaces)
        if !configured.isEmpty {
            let path = Paths.expandTilde(configured)
            return fileManager.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
        for dir in searchDirectories {
            for name in executableNames {
                let path = (dir as NSString).appendingPathComponent(name)
                if fileManager.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
            }
        }
        return nil
    }

    public static func arguments(model: String, audio: String, config: Config) -> [String] {
        var args = ["-m", model, "-f", audio, "--no-timestamps", "--no-prints"]
        args += ["-l", normalizedLanguage(config.language)]
        // whisper-cli defaults to a 5-beam search; 1 means a single greedy pass.
        args += ["-bs", String(config.beamSize)]
        if config.whisperThreads > 0 { args += ["-t", String(config.whisperThreads)] }
        let vocab = config.vocabulary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !vocab.isEmpty { args += ["--prompt", vocab] }
        return args
    }

    public static func parseOutput(_ stdout: String) -> String {
        TranscriptText.clean(stdout)
    }

    static func normalizedLanguage(_ language: String) -> String {
        let l = language.trimmingCharacters(in: .whitespaces).lowercased()
        return l.isEmpty ? "auto" : l
    }

    /// Model names installed in the models folder ("small.en" for ggml-small.en.bin).
    public static func installedModels(in dir: URL = Paths.modelsDir, fileManager: FileManager = .default) -> [String] {
        let files = (try? fileManager.contentsOfDirectory(atPath: dir.path)) ?? []
        return files
            .filter { $0.hasPrefix("ggml-") && $0.hasSuffix(".bin") }
            .map { String($0.dropFirst("ggml-".count).dropLast(".bin".count)) }
            .sorted()
    }
}

/// Everything that decides which whisper-server process we need. A change in any
/// field means restarting it.
public struct WhisperServerSpec: Equatable, Sendable {
    public var executable: URL
    public var model: URL
    public var language: String
    public var threads: Int
    public var beamSize: Int

    public init(executable: URL, model: URL, language: String, threads: Int, beamSize: Int) {
        self.executable = executable
        self.model = model
        self.language = language
        self.threads = threads
        self.beamSize = beamSize
    }
}

/// whisper.cpp's examples/server: POST /inference with a multipart `file`,
/// GET /health returns 200 once the model is loaded.
public enum WhisperServerAPI {
    public static let executableName = "whisper-server"

    /// Next to a configured whisper-cli, otherwise in the usual Homebrew locations.
    public static func findExecutable(configuredCLI: String, fileManager: FileManager = .default) -> URL? {
        var dirs = LocalWhisper.searchDirectories
        let cli = configuredCLI.trimmingCharacters(in: .whitespaces)
        if !cli.isEmpty {
            dirs.insert((Paths.expandTilde(cli) as NSString).deletingLastPathComponent, at: 0)
        }
        for dir in dirs {
            let path = (dir as NSString).appendingPathComponent(executableName)
            if fileManager.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }
        return nil
    }

    public static func spec(for config: Config, fileManager: FileManager = .default) -> WhisperServerSpec? {
        guard let exe = findExecutable(configuredCLI: config.whisperCLI, fileManager: fileManager) else { return nil }
        let model = LocalWhisper.modelURL(for: config.localModel)
        guard fileManager.fileExists(atPath: model.path) else { return nil }
        return WhisperServerSpec(executable: exe, model: model,
                                 language: LocalWhisper.normalizedLanguage(config.language),
                                 threads: config.whisperThreads, beamSize: config.beamSize)
    }

    public static func launchArguments(_ spec: WhisperServerSpec, port: Int) -> [String] {
        var args = ["-m", spec.model.path, "--host", "127.0.0.1", "--port", String(port),
                    "-l", spec.language, "-bs", String(spec.beamSize)]
        if spec.threads > 0 { args += ["-t", String(spec.threads)] }
        return args
    }

    public static func inferenceRequest(baseURL: URL, wav: Data, vocabulary: String) -> URLRequest {
        var form = MultipartForm()
        form.addField("response_format", "json")
        form.addField("temperature", "0")
        form.addField("no_timestamps", "true")
        let vocab = vocabulary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !vocab.isEmpty { form.addField("prompt", vocab) }
        form.addFile("file", filename: "dictation.wav", mimeType: "audio/wav", data: wav)

        var req = URLRequest(url: baseURL.appendingPathComponent("inference"))
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        req.httpBody = form.finalized()
        return req
    }

    public static func healthURL(_ baseURL: URL) -> URL {
        baseURL.appendingPathComponent("health")
    }
}
