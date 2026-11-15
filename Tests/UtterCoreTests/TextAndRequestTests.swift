import XCTest
@testable import UtterCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class CleanupGuardTests: XCTestCase {
    func testAcceptsNormalCleanup() {
        let raw = "um so I think we should uh ship it on friday"
        XCTAssertEqual(Cleanup.accept(raw: raw, cleaned: "So I think we should ship it on Friday."),
                       "So I think we should ship it on Friday.")
    }

    func testRejectsAnAnswerInsteadOfACleanup() {
        let raw = "what's the capital of france"
        let answer = "The capital of France is Paris. It has been the country's capital since the 10th century and is its largest city."
        XCTAssertNil(Cleanup.accept(raw: raw, cleaned: answer))
    }

    func testStripsTagsPreambleAndQuotes() {
        XCTAssertEqual(Cleanup.accept(raw: "hello there", cleaned: "<transcript>\nHello there.\n</transcript>"), "Hello there.")
        XCTAssertEqual(Cleanup.accept(raw: "hello there", cleaned: "Here is the cleaned text:\nHello there."), "Hello there.")
        XCTAssertEqual(Cleanup.accept(raw: "hello there", cleaned: "\"Hello there.\""), "Hello there.")
    }

    func testRejectsEmptyAndTruncated() {
        XCTAssertNil(Cleanup.accept(raw: "hello", cleaned: "   "))
        let long = String(repeating: "this is a long dictated sentence ", count: 4)
        XCTAssertNil(Cleanup.accept(raw: long, cleaned: "This."))
    }

    func testVocabularyIsAppended() {
        XCTAssertTrue(Cleanup.systemPrompt(custom: "", vocabulary: "Kubernetes, gRPC").hasSuffix("Kubernetes, gRPC"))
        XCTAssertEqual(Cleanup.systemPrompt(custom: "Be brief.", vocabulary: ""), "Be brief.")
    }
}

final class TranscriptTextTests: XCTestCase {
    func testRemovesWhisperAnnotations() {
        XCTAssertEqual(TranscriptText.clean(" [BLANK_AUDIO]\n Hello world. (music)\n *laughs* Bye."), "Hello world. Bye.")
    }

    func testKeepsRealParentheses() {
        XCTAssertEqual(TranscriptText.clean("Use the new API (version two) today."), "Use the new API (version two) today.")
    }

    func testHallucinationsOnlyMatterForShortClips() {
        XCTAssertTrue(TranscriptText.isLikelyHallucination(" Thank you.", duration: 0.8))
        XCTAssertFalse(TranscriptText.isLikelyHallucination("Thank you.", duration: 6))
        XCTAssertFalse(TranscriptText.isLikelyHallucination("Thank you for the notes.", duration: 1))
    }
}

final class AudioTests: XCTestCase {
    func testWAVHeader() {
        let data = WAV.encode(samples: [0, 1, -1, 0.5], sampleRate: 16_000)
        XCTAssertEqual(data.count, 44 + 8)
        XCTAssertEqual(String(decoding: data[0..<4], as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: data[8..<12], as: UTF8.self), "WAVE")
        XCTAssertEqual(String(decoding: data[36..<40], as: UTF8.self), "data")

        func u32(_ offset: Int) -> UInt32 {
            data[offset..<offset + 4].enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
        }
        XCTAssertEqual(u32(4), 36 + 8)
        XCTAssertEqual(u32(24), 16_000)
        XCTAssertEqual(u32(40), 8)

        func i16(_ offset: Int) -> Int16 {
            Int16(bitPattern: UInt16(data[offset]) | UInt16(data[offset + 1]) << 8)
        }
        XCTAssertEqual(i16(44), 0)
        XCTAssertEqual(i16(46), Int16.max)
        XCTAssertEqual(i16(48), -Int16.max)
    }

    func testMeter() {
        XCTAssertEqual(AudioLevel.meter(rms: 0), 0)
        XCTAssertEqual(AudioLevel.meter(rms: 1), 1)
        XCTAssertEqual(AudioLevel.meter(rms: 0.01), 0.25, accuracy: 0.01)
    }
}

final class RequestTests: XCTestCase {
    func testGroqTranscriptionRequest() throws {
        var config = Config()
        config.vocabulary = "Utter"
        let req = try XCTUnwrap(CloudWhisper.request(backend: .groq(apiKey: "gsk"), config: config, wav: Data([1, 2, 3])))
        XCTAssertEqual(req.url?.absoluteString, "https://api.groq.com/openai/v1/audio/transcriptions")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer gsk")
        let body = String(decoding: try XCTUnwrap(req.httpBody), as: UTF8.self)
        XCTAssertTrue(body.contains("whisper-large-v3-turbo"))
        XCTAssertTrue(body.contains("name=\"language\"\r\n\r\nen"))
        XCTAssertTrue(body.contains("name=\"prompt\"\r\n\r\nUtter"))
        XCTAssertTrue(body.hasSuffix("--\r\n"))
        XCTAssertNil(CloudWhisper.request(backend: .local, config: config, wav: Data()))
    }

    func testAutoLanguageIsOmitted() throws {
        var config = Config()
        config.language = "auto"
        let req = try XCTUnwrap(CloudWhisper.request(backend: .openai(apiKey: "k"), config: config, wav: Data()))
        let body = String(decoding: try XCTUnwrap(req.httpBody), as: UTF8.self)
        XCTAssertFalse(body.contains("name=\"language\""))
        XCTAssertTrue(body.contains("whisper-1"))
    }

    func testParsesWhisperResponse() throws {
        XCTAssertEqual(try CloudWhisper.parse(Data(#"{"text":" hi there","x_groq":{}}"#.utf8)), " hi there")
    }

    func testAnthropicCleanupRequestAndResponse() throws {
        let backend = CleanupBackend.anthropic(apiKey: "sk-ant", model: "m")
        let req = try XCTUnwrap(CleanupClient.request(backend: backend, system: "sys", user: "u", timeout: 5))
        XCTAssertEqual(req.value(forHTTPHeaderField: "x-api-key"), "sk-ant")
        XCTAssertEqual(req.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        let json = try JSONSerialization.jsonObject(with: try XCTUnwrap(req.httpBody)) as? [String: Any]
        XCTAssertEqual(json?["system"] as? String, "sys")

        let response = #"{"content":[{"type":"text","text":"Hello."}],"stop_reason":"end_turn"}"#
        XCTAssertEqual(try CleanupClient.parse(backend: backend, data: Data(response.utf8)), "Hello.")
    }

    func testOpenAICompatibleCleanup() throws {
        let backend = CleanupBackend.openAICompatible(name: "OpenAI", baseURL: Backends.openAIBase, apiKey: "k",
                                                      model: "gpt", sendsTemperature: false)
        let req = try XCTUnwrap(CleanupClient.request(backend: backend, system: "s", user: "u", timeout: 5))
        XCTAssertEqual(req.url?.absoluteString, "https://api.openai.com/v1/chat/completions")
        let json = try JSONSerialization.jsonObject(with: try XCTUnwrap(req.httpBody)) as? [String: Any]
        XCTAssertNil(json?["temperature"])

        let response = #"{"choices":[{"index":0,"message":{"role":"assistant","content":"Hi."}}]}"#
        XCTAssertEqual(try CleanupClient.parse(backend: backend, data: Data(response.utf8)), "Hi.")
    }

    func testWhisperCLIArguments() {
        var config = Config()
        config.whisperThreads = 4
        config.vocabulary = "Utter"
        let args = LocalWhisper.arguments(model: "/m.bin", audio: "/a.wav", config: config)
        XCTAssertEqual(args, ["-m", "/m.bin", "-f", "/a.wav", "--no-timestamps", "--no-prints",
                              "-l", "en", "-bs", "1", "-t", "4", "--prompt", "Utter"])
        XCTAssertEqual(LocalWhisper.modelURL(for: "small.en", modelsDir: URL(fileURLWithPath: "/models")).path,
                       "/models/ggml-small.en.bin")
        XCTAssertEqual(LocalWhisper.modelURL(for: "/opt/x.bin").path, "/opt/x.bin")
    }
}
