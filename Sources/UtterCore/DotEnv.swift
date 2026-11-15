import Foundation

public enum DotEnv {
    /// Parses `KEY=value` lines. Supports `export KEY=...`, `#` comments,
    /// single/double quoted values and ` # trailing comments` on unquoted values.
    public static func parse(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for rawLine in text.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst("export ".count)) }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !key.contains(" ") else { continue }
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)

            if let q = value.first, q == "\"" || q == "'" {
                let body = value.dropFirst()
                if let end = body.firstIndex(of: q) {
                    value = String(body[..<end])
                    if q == "\"" { value = value.replacingOccurrences(of: "\\n", with: "\n") }
                } else {
                    value = String(body)
                }
            } else if let hash = value.range(of: " #") {
                value = value[..<hash.lowerBound].trimmingCharacters(in: .whitespaces)
            }
            result[key] = value
        }
        return result
    }
}

public struct APIKeys: Equatable, Sendable {
    public var groq: String?
    public var openai: String?
    public var anthropic: String?

    public init(groq: String? = nil, openai: String? = nil, anthropic: String? = nil) {
        self.groq = groq
        self.openai = openai
        self.anthropic = anthropic
    }

    /// Variables already in the process environment win over the .env file,
    /// the usual dotenv convention.
    public init(dotEnv: [String: String], processEnvironment: [String: String] = [:]) {
        func lookup(_ name: String) -> String? {
            let v = processEnvironment[name] ?? dotEnv[name]
            guard let v, !v.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return v.trimmingCharacters(in: .whitespaces)
        }
        self.init(
            groq: lookup("GROQ_API_KEY"),
            openai: lookup("OPENAI_API_KEY"),
            anthropic: lookup("ANTHROPIC_API_KEY")
        )
    }

    public static let template = """
    # API keys for Utter. Only read locally; sent only to the provider they belong to.
    # Leave a line commented out to not use that provider.
    # GROQ_API_KEY=gsk_...
    # OPENAI_API_KEY=sk-...
    # ANTHROPIC_API_KEY=sk-ant-...
    """
}
