import Foundation

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
        let language = config.language.trimmingCharacters(in: .whitespaces).lowercased()
        args += ["-l", language.isEmpty ? "auto" : language]
        if config.whisperThreads > 0 { args += ["-t", String(config.whisperThreads)] }
        let vocab = config.vocabulary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !vocab.isEmpty { args += ["--prompt", vocab] }
        return args
    }

    public static func parseOutput(_ stdout: String) -> String {
        TranscriptText.clean(stdout)
    }
}
