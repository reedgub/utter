import Foundation

public enum TranscriberChoice: String, CaseIterable, Sendable {
    case local, groq, openai, auto
}

public enum CleanupChoice: String, CaseIterable, Sendable {
    case auto, off, groq, openai, anthropic, ollama
}

public enum InsertMethod: String, CaseIterable, Sendable {
    case paste, type
}

/// Everything that lives in ~/.config/utter/config.toml. Defaults here must match
/// `Config.template`; a test enforces that.
public struct Config: Equatable, Sendable {
    public var hotkey = "fn"
    public var tapThresholdMs = 250
    public var doubleTapWindowMs = 350
    public var maxRecordingSeconds = 300

    public var transcriber: TranscriberChoice = .local
    public var localModel = "small.en"
    public var whisperCLI = ""
    public var whisperThreads = 0
    public var language = "en"
    public var vocabulary = ""
    public var groqTranscribeModel = "whisper-large-v3-turbo"
    public var openaiTranscribeModel = "whisper-1"
    public var fallbackToLocal = true

    public var cleanup: CleanupChoice = .auto
    public var cleanupModel = ""
    public var cleanupPrompt = ""
    public var cleanupTimeoutSeconds = 8
    public var ollamaURL = "http://localhost:11434"

    public var insertMethod: InsertMethod = .paste
    public var restoreClipboard = false

    public var showPill = true
    public var sounds = true
    public var silenceThreshold = 0.01

    public init() {}

    public var timing: DictationTiming {
        DictationTiming(
            tapThreshold: Double(tapThresholdMs) / 1000,
            doubleTapWindow: Double(doubleTapWindowMs) / 1000,
            maxDuration: Double(maxRecordingSeconds)
        )
    }
}

public enum ConfigValue: Equatable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
}

public struct ConfigParseResult: Sendable {
    public var config: Config
    public var warnings: [String]
}

/// A deliberately small TOML subset: flat `key = value` lines, `#` comments,
/// basic/literal strings, integers, floats and booleans. Enough for a settings
/// file people edit by hand, with no dependency.
public enum ConfigParser {
    public struct Entry: Equatable, Sendable {
        public var key: String
        public var value: ConfigValue
        public var line: Int
    }

    public static func parseEntries(_ text: String) -> (entries: [Entry], warnings: [String]) {
        var entries: [Entry] = []
        var warnings: [String] = []

        for (index, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            let lineNo = index + 1
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("[") {
                warnings.append("line \(lineNo): sections are not supported; keep every setting at the top level")
                continue
            }
            guard let eq = line.firstIndex(of: "=") else {
                warnings.append("line \(lineNo): expected `key = value`")
                continue
            }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
            guard !key.isEmpty, key.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
                warnings.append("line \(lineNo): invalid key `\(key)`")
                continue
            }
            let rest = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            switch parseValue(rest) {
            case .success(let value):
                entries.append(Entry(key: key, value: value, line: lineNo))
            case .failure(let message):
                warnings.append("line \(lineNo): \(key): \(message.text)")
            }
        }
        return (entries, warnings)
    }

    struct Message: Error { let text: String }

    static func parseValue(_ s: String) -> Result<ConfigValue, Message> {
        guard let first = s.first else { return .failure(Message(text: "missing value")) }

        if first == "\"" || first == "'" {
            let literal = first == "'"
            var out = ""
            var i = s.index(after: s.startIndex)
            var closed = false
            while i < s.endIndex {
                let c = s[i]
                if c == first {
                    closed = true
                    i = s.index(after: i)
                    break
                }
                if c == "\\" && !literal {
                    let next = s.index(after: i)
                    guard next < s.endIndex else { break }
                    switch s[next] {
                    case "n": out.append("\n")
                    case "t": out.append("\t")
                    case "\"": out.append("\"")
                    case "\\": out.append("\\")
                    default: out.append(s[next])
                    }
                    i = s.index(after: next)
                    continue
                }
                out.append(c)
                i = s.index(after: i)
            }
            guard closed else { return .failure(Message(text: "unterminated string")) }
            let trailing = s[i...].trimmingCharacters(in: .whitespaces)
            guard trailing.isEmpty || trailing.hasPrefix("#") else {
                return .failure(Message(text: "unexpected text after string"))
            }
            return .success(.string(out))
        }

        var bare = s
        if let hash = bare.firstIndex(of: "#") { bare = String(bare[..<hash]) }
        bare = bare.trimmingCharacters(in: .whitespaces)
        switch bare {
        case "true": return .success(.bool(true))
        case "false": return .success(.bool(false))
        default: break
        }
        let digits = bare.replacingOccurrences(of: "_", with: "")
        if let i = Int(digits) { return .success(.int(i)) }
        if let d = Double(digits) { return .success(.double(d)) }
        return .failure(Message(text: "`\(bare)` is not a string, number or boolean (strings need quotes)"))
    }

    public static func parse(_ text: String) -> ConfigParseResult {
        let (entries, initialWarnings) = parseEntries(text)
        var warnings = initialWarnings
        var c = Config()

        func string(_ e: Entry) -> String? {
            if case .string(let s) = e.value { return s }
            warnings.append("line \(e.line): \(e.key) must be a quoted string")
            return nil
        }
        func bool(_ e: Entry) -> Bool? {
            if case .bool(let b) = e.value { return b }
            warnings.append("line \(e.line): \(e.key) must be true or false")
            return nil
        }
        func int(_ e: Entry, _ range: ClosedRange<Int>) -> Int? {
            guard case .int(let i) = e.value else {
                warnings.append("line \(e.line): \(e.key) must be a whole number")
                return nil
            }
            guard range.contains(i) else {
                warnings.append("line \(e.line): \(e.key) must be between \(range.lowerBound) and \(range.upperBound)")
                return nil
            }
            return i
        }
        func double(_ e: Entry, _ range: ClosedRange<Double>) -> Double? {
            let d: Double
            switch e.value {
            case .double(let v): d = v
            case .int(let v): d = Double(v)
            default:
                warnings.append("line \(e.line): \(e.key) must be a number")
                return nil
            }
            guard range.contains(d) else {
                warnings.append("line \(e.line): \(e.key) must be between \(range.lowerBound) and \(range.upperBound)")
                return nil
            }
            return d
        }
        func choice<T: RawRepresentable & CaseIterable>(_ e: Entry, _: T.Type) -> T? where T.RawValue == String {
            guard let s = string(e) else { return nil }
            if let v = T(rawValue: s.lowercased()) { return v }
            let options = T.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
            warnings.append("line \(e.line): \(e.key) must be one of \(options)")
            return nil
        }

        for e in entries {
            switch e.key {
            case "hotkey": if let v = string(e) { c.hotkey = v }
            case "tap_threshold_ms": if let v = int(e, 50...1000) { c.tapThresholdMs = v }
            case "double_tap_window_ms": if let v = int(e, 100...1500) { c.doubleTapWindowMs = v }
            case "max_recording_seconds": if let v = int(e, 5...3600) { c.maxRecordingSeconds = v }
            case "transcriber": if let v = choice(e, TranscriberChoice.self) { c.transcriber = v }
            case "local_model": if let v = string(e) { c.localModel = v }
            case "whisper_cli": if let v = string(e) { c.whisperCLI = v }
            case "whisper_threads": if let v = int(e, 0...64) { c.whisperThreads = v }
            case "language": if let v = string(e) { c.language = v.isEmpty ? "auto" : v }
            case "vocabulary": if let v = string(e) { c.vocabulary = v }
            case "groq_transcribe_model": if let v = string(e) { c.groqTranscribeModel = v }
            case "openai_transcribe_model": if let v = string(e) { c.openaiTranscribeModel = v }
            case "fallback_to_local": if let v = bool(e) { c.fallbackToLocal = v }
            case "cleanup": if let v = choice(e, CleanupChoice.self) { c.cleanup = v }
            case "cleanup_model": if let v = string(e) { c.cleanupModel = v }
            case "cleanup_prompt": if let v = string(e) { c.cleanupPrompt = v }
            case "cleanup_timeout_seconds": if let v = int(e, 1...120) { c.cleanupTimeoutSeconds = v }
            case "ollama_url": if let v = string(e) { c.ollamaURL = v }
            case "insert_method": if let v = choice(e, InsertMethod.self) { c.insertMethod = v }
            case "restore_clipboard": if let v = bool(e) { c.restoreClipboard = v }
            case "show_pill": if let v = bool(e) { c.showPill = v }
            case "sounds": if let v = bool(e) { c.sounds = v }
            case "silence_threshold": if let v = double(e, 0...1) { c.silenceThreshold = v }
            default:
                warnings.append("line \(e.line): unknown setting `\(e.key)`")
            }
        }
        return ConfigParseResult(config: c, warnings: warnings)
    }
}

extension Config {
    /// Written to ~/.config/utter/config.toml on first launch.
    public static let template = #"""
    # Utter settings. Edit, then choose "Reload Settings" from the menu bar icon.

    # ── Hotkey ──────────────────────────────────────────────────────────────
    # Hold to talk, release to insert. Double-tap for hands-free; tap once more
    # to finish. Esc cancels a recording or a transcription in progress.
    #   "fn"                                  the fn / globe key (default)
    #   "right_option", "right_command", "right_control", "right_shift"
    #   "left_option", "left_command", "left_control", "left_shift"
    #   a chord such as "ctrl+option+space", "cmd+shift+d", or a bare "f5"
    hotkey = "fn"

    # A press shorter than this (milliseconds) counts as a tap, not a hold.
    tap_threshold_ms = 250
    # Longest gap between two taps that starts hands-free mode.
    double_tap_window_ms = 350
    # Every recording stops itself after this many seconds and is transcribed,
    # so a forgotten hands-free session cannot run all afternoon.
    max_recording_seconds = 300

    # ── Transcription ───────────────────────────────────────────────────────
    # "local"  whisper.cpp on this Mac, works offline (default)
    # "groq"   Groq Whisper API, needs GROQ_API_KEY in ~/.config/utter/.env
    # "openai" OpenAI Whisper API, needs OPENAI_API_KEY
    # "auto"   groq if its key is set, else openai if its key is set, else local
    transcriber = "local"
    # A model name in ~/.config/utter/models ("small.en", "medium.en", "small",
    # "medium", ...) or an absolute path to a ggml .bin file.
    local_model = "small.en"
    # Path to whisper-cli. Empty searches /opt/homebrew/bin and /usr/local/bin.
    whisper_cli = ""
    whisper_threads = 0   # 0 lets whisper.cpp decide
    # Spoken language ("en", "de", "fr", ...) or "auto". English-only *.en models need "en".
    language = "en"
    # Names and jargon to spell correctly, comma separated. Passed to Whisper as a
    # hint and to the cleanup model.
    vocabulary = ""
    groq_transcribe_model = "whisper-large-v3-turbo"
    openai_transcribe_model = "whisper-1"
    # If a cloud transcription fails (offline, outage), retry with the local model
    # when whisper-cli and the model are installed.
    fallback_to_local = true

    # ── Cleanup ─────────────────────────────────────────────────────────────
    # An LLM pass that removes filler words and fixes punctuation and casing.
    # "auto"      first key found in .env: GROQ_API_KEY, OPENAI_API_KEY, ANTHROPIC_API_KEY
    # "groq", "openai", "anthropic"
    # "ollama"    a local model through Ollama, works offline
    # "off"       insert the raw transcript
    cleanup = "auto"
    cleanup_model = ""            # empty uses the provider's default
    cleanup_prompt = ""           # empty uses the built-in prompt
    cleanup_timeout_seconds = 8   # past this the raw transcript is inserted instead
    ollama_url = "http://localhost:11434"

    # ── Insertion ───────────────────────────────────────────────────────────
    # "paste" puts the text on the pasteboard and sends Cmd-V (fast, reliable).
    # "type" simulates keystrokes (slower; for apps that block paste).
    insert_method = "paste"
    # false: the transcript stays on the clipboard so you can paste it again.
    # true: your previous clipboard contents are put back after inserting.
    restore_clipboard = false

    # ── Feedback ────────────────────────────────────────────────────────────
    show_pill = true
    sounds = true
    # Recordings whose loudest moment stays below this level (0-1 RMS) are treated
    # as silence and skipped instead of being sent to Whisper.
    silence_threshold = 0.01
    """#
}
