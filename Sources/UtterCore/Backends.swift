import Foundation

public enum TranscriptionBackend: Equatable, Sendable {
    case local
    case groq(apiKey: String)
    case openai(apiKey: String)

    public var name: String {
        switch self {
        case .local: return "local whisper.cpp"
        case .groq: return "Groq"
        case .openai: return "OpenAI"
        }
    }

    public var isCloud: Bool { self != .local }
}

public enum CleanupBackend: Equatable, Sendable {
    case none
    case openAICompatible(name: String, baseURL: URL, apiKey: String?, model: String, sendsTemperature: Bool)
    case anthropic(apiKey: String, model: String)

    public var summary: String {
        switch self {
        case .none: return "off"
        case .openAICompatible(let name, _, _, let model, _): return "\(name) · \(model)"
        case .anthropic(_, let model): return "Anthropic · \(model)"
        }
    }
}

public struct BackendError: Error, Equatable, CustomStringConvertible, LocalizedError {
    public let description: String
    public init(_ description: String) { self.description = description }
    public var errorDescription: String? { description }
}

public enum Backends {
    public static let groqBase = URL(string: "https://api.groq.com/openai/v1")!
    public static let openAIBase = URL(string: "https://api.openai.com/v1")!

    public static let defaultCleanupModels: [CleanupChoice: String] = [
        .groq: "llama-3.3-70b-versatile",
        .openai: "gpt-4.1-mini",
        .anthropic: "claude-haiku-5-5",
        .ollama: "llama3.1:8b",
    ]

    public static func transcriber(for config: Config, keys: APIKeys) -> Result<TranscriptionBackend, BackendError> {
        switch config.transcriber {
        case .local:
            return .success(.local)
        case .groq:
            guard let key = keys.groq else {
                return .failure(BackendError("transcriber = \"groq\" but GROQ_API_KEY is not set in ~/.config/utter/.env"))
            }
            return .success(.groq(apiKey: key))
        case .openai:
            guard let key = keys.openai else {
                return .failure(BackendError("transcriber = \"openai\" but OPENAI_API_KEY is not set in ~/.config/utter/.env"))
            }
            return .success(.openai(apiKey: key))
        case .auto:
            if let key = keys.groq { return .success(.groq(apiKey: key)) }
            if let key = keys.openai { return .success(.openai(apiKey: key)) }
            return .success(.local)
        }
    }

    public static func cleanup(for config: Config, keys: APIKeys) -> Result<CleanupBackend, BackendError> {
        let choice: CleanupChoice
        switch config.cleanup {
        case .off:
            return .success(.none)
        case .auto:
            if keys.groq != nil { choice = .groq }
            else if keys.openai != nil { choice = .openai }
            else if keys.anthropic != nil { choice = .anthropic }
            else { return .success(.none) }
        default:
            choice = config.cleanup
        }

        let model = config.cleanupModel.isEmpty ? (defaultCleanupModels[choice] ?? "") : config.cleanupModel

        switch choice {
        case .groq:
            guard let key = keys.groq else { return .failure(BackendError("cleanup = \"groq\" but GROQ_API_KEY is not set")) }
            return .success(.openAICompatible(name: "Groq", baseURL: groqBase, apiKey: key, model: model, sendsTemperature: true))
        case .openai:
            guard let key = keys.openai else { return .failure(BackendError("cleanup = \"openai\" but OPENAI_API_KEY is not set")) }
            // Newer OpenAI reasoning models reject `temperature`, so it is not sent.
            return .success(.openAICompatible(name: "OpenAI", baseURL: openAIBase, apiKey: key, model: model, sendsTemperature: false))
        case .anthropic:
            guard let key = keys.anthropic else { return .failure(BackendError("cleanup = \"anthropic\" but ANTHROPIC_API_KEY is not set")) }
            return .success(.anthropic(apiKey: key, model: model))
        case .ollama:
            let trimmed = config.ollamaURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
            guard let base = URL(string: trimmed + "/v1"), base.scheme != nil else {
                return .failure(BackendError("ollama_url \"\(config.ollamaURL)\" is not a URL"))
            }
            return .success(.openAICompatible(name: "Ollama", baseURL: base, apiKey: nil, model: model, sendsTemperature: true))
        case .off, .auto:
            return .success(.none)
        }
    }
}
