import XCTest
@testable import UtterCore

final class ConfigTests: XCTestCase {
    func testTemplateParsesToDefaultsWithoutWarnings() {
        let result = ConfigParser.parse(Config.template)
        XCTAssertEqual(result.warnings, [])
        XCTAssertEqual(result.config, Config())
    }

    func testEmptyFileIsDefaults() {
        XCTAssertEqual(ConfigParser.parse("").config, Config())
    }

    func testValues() {
        let text = """
        hotkey = "right_option"   # trailing comment
        transcriber = "GROQ"
        restore_clipboard = true
        max_recording_seconds = 120
        silence_threshold = 0.02
        vocabulary = 'Kubernetes, "Utter", gRPC'
        cleanup_prompt = "line one\\nline two # not a comment"
        """
        let r = ConfigParser.parse(text)
        XCTAssertEqual(r.warnings, [])
        XCTAssertEqual(r.config.hotkey, "right_option")
        XCTAssertEqual(r.config.transcriber, .groq)
        XCTAssertTrue(r.config.restoreClipboard)
        XCTAssertEqual(r.config.maxRecordingSeconds, 120)
        XCTAssertEqual(r.config.silenceThreshold, 0.02)
        XCTAssertEqual(r.config.vocabulary, #"Kubernetes, "Utter", gRPC"#)
        XCTAssertEqual(r.config.cleanupPrompt, "line one\nline two # not a comment")
        XCTAssertEqual(r.config.timing.maxDuration, 120)
    }

    func testBadValuesWarnAndKeepDefaults() {
        let text = """
        transcriber = "whisperx"
        max_recording_seconds = 99999
        restore_clipboard = "yes"
        hotkey = fn
        colour = "blue"
        [section]
        """
        let r = ConfigParser.parse(text)
        XCTAssertEqual(r.config, Config())
        XCTAssertEqual(r.warnings.count, 6, r.warnings.joined(separator: "\n"))
        XCTAssertTrue(r.warnings.contains { $0.contains("line 1") && $0.contains("transcriber") })
        XCTAssertTrue(r.warnings.contains { $0.contains("unknown setting `colour`") })
    }

    func testDotEnv() {
        let env = DotEnv.parse("""
        # comment
        GROQ_API_KEY=gsk_123
        export OPENAI_API_KEY="sk-abc" # inline
        ANTHROPIC_API_KEY='sk-ant-x'
        EMPTY=
        PLAIN=value # comment
        """)
        XCTAssertEqual(env["GROQ_API_KEY"], "gsk_123")
        XCTAssertEqual(env["OPENAI_API_KEY"], "sk-abc")
        XCTAssertEqual(env["ANTHROPIC_API_KEY"], "sk-ant-x")
        XCTAssertEqual(env["PLAIN"], "value")

        let keys = APIKeys(dotEnv: env, processEnvironment: ["GROQ_API_KEY": "from-shell"])
        XCTAssertEqual(keys.groq, "from-shell")
        XCTAssertEqual(keys.openai, "sk-abc")
        XCTAssertNil(APIKeys(dotEnv: ["GROQ_API_KEY": "  "]).groq)
    }

    func testEnvTemplateDefinesNoKeys() {
        XCTAssertEqual(APIKeys(dotEnv: DotEnv.parse(APIKeys.template)), APIKeys())
    }
}

final class BackendTests: XCTestCase {
    func testTranscriberSelection() {
        var c = Config()
        XCTAssertEqual(try Backends.transcriber(for: c, keys: APIKeys(groq: "g")).get(), .local)

        c.transcriber = .auto
        XCTAssertEqual(try Backends.transcriber(for: c, keys: APIKeys()).get(), .local)
        XCTAssertEqual(try Backends.transcriber(for: c, keys: APIKeys(openai: "o")).get(), .openai(apiKey: "o"))
        XCTAssertEqual(try Backends.transcriber(for: c, keys: APIKeys(groq: "g", openai: "o")).get(), .groq(apiKey: "g"))

        c.transcriber = .groq
        XCTAssertThrowsError(try Backends.transcriber(for: c, keys: APIKeys(openai: "o")).get())
    }

    func testCleanupSelection() {
        var c = Config()
        XCTAssertEqual(try Backends.cleanup(for: c, keys: APIKeys()).get(), CleanupBackend.none)

        let anthropic = try? Backends.cleanup(for: c, keys: APIKeys(anthropic: "a")).get()
        XCTAssertEqual(anthropic, .anthropic(apiKey: "a", model: Backends.defaultCleanupModels[.anthropic]!))

        guard case .openAICompatible(let name, _, _, let model, _)? = try? Backends.cleanup(for: c, keys: APIKeys(groq: "g", anthropic: "a")).get() else {
            return XCTFail()
        }
        XCTAssertEqual(name, "Groq")
        XCTAssertEqual(model, Backends.defaultCleanupModels[.groq])

        c.cleanup = .ollama
        c.cleanupModel = "qwen2.5:7b"
        c.ollamaURL = "http://localhost:11434/"
        guard case .openAICompatible(_, let url, let key, let ollamaModel, _)? = try? Backends.cleanup(for: c, keys: APIKeys()).get() else {
            return XCTFail()
        }
        XCTAssertEqual(url.absoluteString, "http://localhost:11434/v1")
        XCTAssertNil(key)
        XCTAssertEqual(ollamaModel, "qwen2.5:7b")

        c.cleanup = .off
        XCTAssertEqual(try Backends.cleanup(for: c, keys: APIKeys(groq: "g")).get(), CleanupBackend.none)

        c.cleanup = .openai
        XCTAssertThrowsError(try Backends.cleanup(for: c, keys: APIKeys(groq: "g")).get())
    }
}
