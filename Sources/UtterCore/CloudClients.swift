import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct HTTPError: Error, LocalizedError, Equatable {
    public let status: Int
    public let body: String
    public var errorDescription: String? {
        let snippet = body.count > 200 ? String(body.prefix(200)) + "…" : body
        return "HTTP \(status): \(snippet)"
    }
}

public struct MultipartForm {
    public let boundary: String
    private(set) public var body = Data()

    public init(boundary: String = "utter-\(UUID().uuidString)") {
        self.boundary = boundary
    }

    public var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    public mutating func addField(_ name: String, _ value: String) {
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
        body.append(Data("\(value)\r\n".utf8))
    }

    public mutating func addFile(_ name: String, filename: String, mimeType: String, data: Data) {
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".utf8))
        body.append(Data("Content-Type: \(mimeType)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n".utf8))
    }

    public func finalized() -> Data {
        var out = body
        out.append(Data("--\(boundary)--\r\n".utf8))
        return out
    }
}

public enum CloudWhisper {
    public static func request(backend: TranscriptionBackend, config: Config, wav: Data) -> URLRequest? {
        let base: URL
        let key: String
        let model: String
        switch backend {
        case .local: return nil
        case .groq(let k): base = Backends.groqBase; key = k; model = config.groqTranscribeModel
        case .openai(let k): base = Backends.openAIBase; key = k; model = config.openaiTranscribeModel
        }

        var form = MultipartForm()
        form.addField("model", model)
        form.addField("response_format", "json")
        form.addField("temperature", "0")
        let language = config.language.lowercased()
        if !language.isEmpty && language != "auto" { form.addField("language", language) }
        let vocab = config.vocabulary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !vocab.isEmpty { form.addField("prompt", vocab) }
        form.addFile("file", filename: "dictation.wav", mimeType: "audio/wav", data: wav)

        var req = URLRequest(url: base.appendingPathComponent("audio/transcriptions"))
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        req.httpBody = form.finalized()
        return req
    }

    struct Response: Decodable { let text: String }

    public static func parse(_ data: Data) throws -> String {
        try JSONDecoder().decode(Response.self, from: data).text
    }

    public static func transcribe(backend: TranscriptionBackend, config: Config, wav: Data,
                                  session: URLSession = .shared) async throws -> String {
        guard let req = request(backend: backend, config: config, wav: wav) else {
            throw BackendError("not a cloud transcriber")
        }
        let data = try await HTTP.send(req, session: session)
        return try parse(data)
    }
}

public enum CleanupClient {
    public static func request(backend: CleanupBackend, system: String, user: String, timeout: TimeInterval) -> URLRequest? {
        switch backend {
        case .none:
            return nil

        case .openAICompatible(_, let baseURL, let apiKey, let model, let sendsTemperature):
            var body: [String: Any] = [
                "model": model,
                "messages": [
                    ["role": "system", "content": system],
                    ["role": "user", "content": user],
                ],
            ]
            if sendsTemperature { body["temperature"] = 0 }
            var req = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
            req.httpMethod = "POST"
            req.timeoutInterval = timeout
            if let apiKey { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
            return req

        case .anthropic(let apiKey, let model):
            let body: [String: Any] = [
                "model": model,
                "max_tokens": 4096,
                "temperature": 0,
                "system": system,
                "messages": [["role": "user", "content": user]],
            ]
            var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
            req.httpMethod = "POST"
            req.timeoutInterval = timeout
            req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
            return req
        }
    }

    struct ChatResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String? }
            let message: Message
        }
        let choices: [Choice]
    }

    struct AnthropicResponse: Decodable {
        struct Block: Decodable { let type: String; let text: String? }
        let content: [Block]
    }

    public static func parse(backend: CleanupBackend, data: Data) throws -> String {
        switch backend {
        case .none:
            return ""
        case .openAICompatible:
            let r = try JSONDecoder().decode(ChatResponse.self, from: data)
            return r.choices.first?.message.content ?? ""
        case .anthropic:
            let r = try JSONDecoder().decode(AnthropicResponse.self, from: data)
            return r.content.filter { $0.type == "text" }.compactMap(\.text).joined()
        }
    }

    public static func clean(_ transcript: String, backend: CleanupBackend, config: Config,
                             session: URLSession = .shared) async throws -> String {
        let system = Cleanup.systemPrompt(custom: config.cleanupPrompt, vocabulary: config.vocabulary)
        guard let req = request(backend: backend, system: system, user: Cleanup.userMessage(transcript: transcript),
                                timeout: TimeInterval(config.cleanupTimeoutSeconds)) else {
            return transcript
        }
        let data = try await HTTP.send(req, session: session)
        return try parse(backend: backend, data: data)
    }
}

extension WhisperServerAPI {
    public static func transcribe(baseURL: URL, wav: Data, vocabulary: String,
                                  session: URLSession = .shared) async throws -> String {
        let data = try await HTTP.send(inferenceRequest(baseURL: baseURL, wav: wav, vocabulary: vocabulary), session: session)
        return try CloudWhisper.parse(data)
    }

    public static func isHealthy(_ baseURL: URL, session: URLSession = .shared) async -> Bool {
        var req = URLRequest(url: healthURL(baseURL))
        req.timeoutInterval = 2
        guard let (_, response) = try? await session.data(for: req) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }
}

enum HTTP {
    static func send(_ request: URLRequest, session: URLSession) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw HTTPError(status: http.statusCode, body: String(decoding: data, as: UTF8.self))
        }
        return data
    }

    /// Network-level failures (offline, DNS, timeout), as opposed to an API
    /// rejecting the request. Only these trigger the local fallback.
    static func isConnectivityError(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
             .timedOut, .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed, .secureConnectionFailed:
            return true
        default:
            return false
        }
    }
}

public func isConnectivityError(_ error: Error) -> Bool { HTTP.isConnectivityError(error) }
