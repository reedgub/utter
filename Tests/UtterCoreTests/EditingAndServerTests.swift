import XCTest
@testable import UtterCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class ConfigEditorTests: XCTestCase {
    func testEditsTemplateInPlaceAndKeepsComments() {
        var text = Config.template
        text = ConfigEditor.set("hotkey", to: .string("right_option"), in: text)
        text = ConfigEditor.set("whisper_threads", to: .int(6), in: text)
        text = ConfigEditor.set("restore_clipboard", to: .bool(true), in: text)
        text = ConfigEditor.set("silence_threshold", to: .double(0.02), in: text)
        text = ConfigEditor.set("cleanup_model", to: .string("my \"model\""), in: text)

        let result = ConfigParser.parse(text)
        XCTAssertEqual(result.warnings, [])
        XCTAssertEqual(result.config.hotkey, "right_option")
        XCTAssertEqual(result.config.whisperThreads, 6)
        XCTAssertTrue(result.config.restoreClipboard)
        XCTAssertEqual(result.config.silenceThreshold, 0.02)
        XCTAssertEqual(result.config.cleanupModel, "my \"model\"")

        // Same number of lines, explanatory comments untouched.
        XCTAssertEqual(text.components(separatedBy: "\n").count, Config.template.components(separatedBy: "\n").count)
        XCTAssertTrue(text.contains("whisper_threads = 6   # 0 lets whisper.cpp decide"))
        XCTAssertTrue(text.contains(#"cleanup_model = "my \"model\""            # empty uses the provider's default"#))
        XCTAssertTrue(text.contains("# Hold to talk, release to insert."))
    }

    func testAppendsMissingKey() {
        let text = ConfigEditor.set("sounds", to: .bool(false), in: "hotkey = \"fn\"")
        XCTAssertEqual(text, "hotkey = \"fn\"\nsounds = false\n")
        XCTAssertEqual(ConfigParser.parse(text).config.sounds, false)
    }

    func testIgnoresCommentedOutKey() {
        let text = ConfigEditor.set("sounds", to: .bool(false), in: "# sounds = true\n")
        XCTAssertEqual(text, "# sounds = true\nsounds = false\n")
    }

    func testCommentAfterStringWithHash() {
        XCTAssertEqual(ConfigEditor.trailingComment(afterEquals: #" "a # b"  # note"#), "  # note")
        XCTAssertEqual(ConfigEditor.trailingComment(afterEquals: " 5"), "")
        XCTAssertEqual(ConfigEditor.trailingComment(afterEquals: " 5# x"), " # x")
    }
}

final class DotEnvEditTests: XCTestCase {
    func testFillsTemplateLineThenRemoves() {
        var text = APIKeys.template
        text = DotEnv.set("GROQ_API_KEY", to: "gsk_abc", in: text)
        XCTAssertEqual(APIKeys(dotEnv: DotEnv.parse(text)).groq, "gsk_abc")
        XCTAssertEqual(text.components(separatedBy: "\n").count, APIKeys.template.components(separatedBy: "\n").count)
        XCTAssertFalse(text.contains("# GROQ_API_KEY"))

        text = DotEnv.set("GROQ_API_KEY", to: "gsk_new", in: text)
        XCTAssertEqual(APIKeys(dotEnv: DotEnv.parse(text)).groq, "gsk_new")

        text = DotEnv.set("GROQ_API_KEY", to: nil, in: text)
        XCTAssertNil(APIKeys(dotEnv: DotEnv.parse(text)).groq)
        XCTAssertTrue(text.contains("# GROQ_API_KEY="))
    }

    func testAppendsWhenAbsentAndQuotesOddValues() {
        let text = DotEnv.set("OPENAI_API_KEY", to: "  sk with space ", in: "")
        XCTAssertEqual(text, "OPENAI_API_KEY=\"sk with space\"\n")
        XCTAssertEqual(DotEnv.parse(text)["OPENAI_API_KEY"], "sk with space")
        XCTAssertEqual(DotEnv.set("OPENAI_API_KEY", to: nil, in: "X=1\n"), "X=1\n")
    }
}

final class WhisperServerTests: XCTestCase {
    func testLaunchArguments() {
        let spec = WhisperServerSpec(executable: URL(fileURLWithPath: "/opt/homebrew/bin/whisper-server"),
                                     model: URL(fileURLWithPath: "/m/ggml-small.en.bin"),
                                     language: "en", threads: 0, beamSize: 1)
        XCTAssertEqual(WhisperServerAPI.launchArguments(spec, port: 51234),
                       ["-m", "/m/ggml-small.en.bin", "--host", "127.0.0.1", "--port", "51234", "-l", "en", "-bs", "1"])
        var threaded = spec
        threaded.threads = 4
        XCTAssertEqual(WhisperServerAPI.launchArguments(threaded, port: 1).suffix(2), ["-t", "4"])
        XCTAssertNotEqual(spec, threaded)
    }

    func testInferenceRequest() throws {
        let req = WhisperServerAPI.inferenceRequest(baseURL: URL(string: "http://127.0.0.1:5000")!,
                                                    wav: Data([0, 1]), vocabulary: "Utter")
        XCTAssertEqual(req.url?.absoluteString, "http://127.0.0.1:5000/inference")
        XCTAssertEqual(req.httpMethod, "POST")
        let body = String(decoding: try XCTUnwrap(req.httpBody), as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"file\"; filename=\"dictation.wav\""))
        XCTAssertTrue(body.contains("name=\"response_format\"\r\n\r\njson"))
        XCTAssertTrue(body.contains("name=\"prompt\"\r\n\r\nUtter"))
        XCTAssertEqual(WhisperServerAPI.healthURL(URL(string: "http://127.0.0.1:5000")!).absoluteString,
                       "http://127.0.0.1:5000/health")
    }

    func testFindsInstalledModelsAndServerBinary() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("utter-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["ggml-small.en.bin", "ggml-medium.en.bin", "notes.txt"] {
            FileManager.default.createFile(atPath: dir.appendingPathComponent(name).path, contents: Data())
        }
        XCTAssertEqual(LocalWhisper.installedModels(in: dir), ["medium.en", "small.en"])

        let server = dir.appendingPathComponent("whisper-server")
        FileManager.default.createFile(atPath: server.path, contents: Data("#!/bin/sh\n".utf8),
                                       attributes: [.posixPermissions: 0o755])
        let cli = dir.appendingPathComponent("whisper-cli").path
        XCTAssertEqual(WhisperServerAPI.findExecutable(configuredCLI: cli)?.path, server.path)
    }

    func testConfigDefaultsAreFast() {
        XCTAssertEqual(Config().localEngine, .server)
        XCTAssertEqual(Config().beamSize, 1)
        XCTAssertEqual(ConfigParser.parse("local_engine = \"cli\"\nbeam_size = 5").config.beamSize, 5)
        XCTAssertFalse(ConfigParser.parse("beam_size = 0").warnings.isEmpty)
    }
}
