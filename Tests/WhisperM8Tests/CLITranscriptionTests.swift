import Foundation
import XCTest
@testable import WhisperM8

final class CLITranscriptionTests: XCTestCase {

    // MARK: - CLI-Modus-Erkennung

    func testGUIBinaryWithoutArgsRunsGUI() {
        XCTAssertFalse(CLIModeDetector.shouldRunCLI(["/Applications/WhisperM8.app/Contents/MacOS/WhisperM8"]))
    }

    func testSymlinkNameRunsCLI() {
        XCTAssertTrue(CLIModeDetector.shouldRunCLI(["/Users/x/.local/bin/whisperm8"]))
    }

    func testRecognizedSubcommandRunsCLI() {
        let base = "/Applications/WhisperM8.app/Contents/MacOS/WhisperM8"
        XCTAssertTrue(CLIModeDetector.shouldRunCLI([base, "transcribe", "a.mp4"]))
        XCTAssertTrue(CLIModeDetector.shouldRunCLI([base, "modes"]))
        XCTAssertTrue(CLIModeDetector.shouldRunCLI([base, "--help"]))
    }

    func testUnrecognizedFirstArgRunsGUI() {
        let base = "/Applications/WhisperM8.app/Contents/MacOS/WhisperM8"
        XCTAssertFalse(CLIModeDetector.shouldRunCLI([base, "random.mp4"]))
        XCTAssertFalse(CLIModeDetector.shouldRunCLI([base]))
    }

    // MARK: - Argument-Parsing

    func testParsesBasicInputWithDefaults() throws {
        let options = try CLIArgumentParser.parse(["vortrag.mp4"])
        XCTAssertEqual(options.inputs, ["vortrag.mp4"])
        XCTAssertEqual(options.provider, .groq)
        XCTAssertEqual(options.resolvedModel, .groq_whisper_v3_turbo)
        XCTAssertEqual(options.format, .txt)
        XCTAssertFalse(options.dryRun)
    }

    func testProviderSwitchChangesDefaultModel() throws {
        let options = try CLIArgumentParser.parse(["a.mp4", "--provider", "openai"])
        XCTAssertEqual(options.provider, .openai)
        XCTAssertEqual(options.resolvedModel, .openai_gpt4o)
    }

    func testFormatInferredFromOutputExtension() throws {
        let options = try CLIArgumentParser.parse(["a.mp4", "-o", "out.vtt"])
        XCTAssertEqual(options.format, .vtt)
        XCTAssertEqual(options.outputPath, "out.vtt")
    }

    func testExplicitFormatWinsOverExtension() throws {
        let options = try CLIArgumentParser.parse(["a.mp4", "-o", "out.txt", "-f", "json"])
        XCTAssertEqual(options.format, .json)
    }

    func testMismatchedModelFallsBackToProviderDefault() throws {
        // provider=groq, aber gpt-4o gehört zu OpenAI → Modell wird verworfen.
        let options = try CLIArgumentParser.parse(["a.mp4", "--provider", "groq", "--model", "gpt-4o-transcribe"])
        XCTAssertNil(options.model)
        XCTAssertEqual(options.resolvedModel, .groq_whisper_v3_turbo)
    }

    func testParsesAdvancedFlags() throws {
        let options = try CLIArgumentParser.parse([
            "a.mp4", "-l", "de", "--mode", "clean", "--chunk-seconds", "30", "--dry-run", "--api-key", "sk-x"
        ])
        XCTAssertEqual(options.language, "de")
        XCTAssertEqual(options.modeID, "clean")
        XCTAssertEqual(options.chunkSeconds, 30)
        XCTAssertTrue(options.dryRun)
        XCTAssertEqual(options.apiKey, "sk-x")
    }

    func testParseErrors() {
        XCTAssertThrowsError(try CLIArgumentParser.parse([]))                       // kein Input
        XCTAssertThrowsError(try CLIArgumentParser.parse(["a.mp4", "--bogus"]))     // unbekanntes Flag
        XCTAssertThrowsError(try CLIArgumentParser.parse(["a.mp4", "-f", "bad"]))   // ungültiges Format
        XCTAssertThrowsError(try CLIArgumentParser.parse(["a.mp4", "-o"]))          // fehlender Wert
    }

    // MARK: - Modell-Fähigkeiten

    func testModelSegmentSupport() {
        XCTAssertFalse(CLITranscribeCommand.modelSupportsSegments(.openai_gpt4o))
        XCTAssertTrue(CLITranscribeCommand.modelSupportsSegments(.openai_whisper))
        XCTAssertTrue(CLITranscribeCommand.modelSupportsSegments(.groq_whisper_v3))
        XCTAssertTrue(CLITranscribeCommand.modelSupportsSegments(.groq_whisper_v3_turbo))
    }

    // MARK: - Timecode + Formatter

    func testTimecodeFormatting() {
        XCTAssertEqual(CLIOutputFormatter.timecode(0, millisSeparator: ","), "00:00:00,000")
        XCTAssertEqual(CLIOutputFormatter.timecode(3661.5, millisSeparator: ","), "01:01:01,500")
        XCTAssertEqual(CLIOutputFormatter.timecode(2.0, millisSeparator: "."), "00:00:02.000")
    }

    func testSRTRendering() {
        let segments = [
            TranscriptionSegment(start: 0, end: 2, text: "Hello"),
            TranscriptionSegment(start: 2, end: 4, text: "World")
        ]
        let srt = CLIOutputFormatter.renderSRT(segments)
        XCTAssertTrue(srt.contains("1\n00:00:00,000 --> 00:00:02,000\nHello"))
        XCTAssertTrue(srt.contains("2\n00:00:02,000 --> 00:00:04,000\nWorld"))
    }

    func testVTTRendering() {
        let segments = [TranscriptionSegment(start: 0, end: 2, text: "Hi")]
        let vtt = CLIOutputFormatter.renderVTT(segments)
        XCTAssertTrue(vtt.hasPrefix("WEBVTT"))
        XCTAssertTrue(vtt.contains("00:00:00.000 --> 00:00:02.000\nHi"))
    }

    func testJSONRenderingContainsFields() throws {
        let result = CLITranscriptResult(
            text: "hallo welt",
            segments: [TranscriptionSegment(start: 0, end: 1, text: "hallo welt")],
            language: "de",
            duration: 1.0,
            provider: "groq",
            model: "whisper-large-v3-turbo"
        )
        let json = CLIOutputFormatter.renderJSON(result)
        let data = try XCTUnwrap(json.data(using: .utf8))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(object?["text"] as? String, "hallo welt")
        XCTAssertEqual(object?["provider"] as? String, "groq")
        XCTAssertEqual((object?["segments"] as? [[String: Any]])?.count, 1)
    }

    // MARK: - Stitching

    func testStitchOffsetsSegmentsAndConcatenatesText() {
        let parts: [(transcription: DetailedTranscription, offset: Double)] = [
            (DetailedTranscription(text: "erster teil", segments: [TranscriptionSegment(start: 0, end: 1, text: "erster teil")], language: "de", duration: 1), 0),
            (DetailedTranscription(text: "zweiter teil", segments: [TranscriptionSegment(start: 0, end: 1, text: "zweiter teil")], language: nil, duration: 1), 10)
        ]
        let stitched = CLITranscriptStitcher.stitch(parts)
        XCTAssertEqual(stitched.text, "erster teil zweiter teil")
        XCTAssertEqual(stitched.segments.count, 2)
        XCTAssertEqual(stitched.segments[1].start, 10, accuracy: 0.001)
        XCTAssertEqual(stitched.segments[1].end, 11, accuracy: 0.001)
        XCTAssertEqual(stitched.language, "de")
        XCTAssertEqual(stitched.duration ?? 0, 11, accuracy: 0.001)
    }

    // MARK: - Silence-aware Split

    func testComputeSplitTimesReturnsEmptyForShortAudio() {
        let energies = Array(repeating: Float(0.5), count: 5)
        let splits = CLIAudioChunker.computeSplitTimes(
            duration: 5, energies: energies, frameDuration: 1.0, targetSeconds: 10, windowSeconds: 5
        )
        XCTAssertTrue(splits.isEmpty)
    }

    func testComputeSplitTimesSnapsToLowEnergyFrame() {
        // 20 s, 1 Frame/s, Stille bei Sekunde 12 innerhalb des Fensters [5,15].
        var energies = Array(repeating: Float(1.0), count: 20)
        energies[12] = 0.0
        let splits = CLIAudioChunker.computeSplitTimes(
            duration: 20, energies: energies, frameDuration: 1.0, targetSeconds: 10, windowSeconds: 5
        )
        XCTAssertEqual(splits.count, 1)
        XCTAssertEqual(splits.first ?? 0, 12.0, accuracy: 0.001)
    }

    // MARK: - Multipart-Envelope mit response_format

    func testMultipartBodyIncludesResponseFormatWhenRequested() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CLIEnvelope-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let audioURL = tempDir.appendingPathComponent("a.m4a")
        try Data("audio".utf8).write(to: audioURL)
        let bodyURL = tempDir.appendingPathComponent("body.tmp")

        try MultipartFormDataFileWriter.writeAudioTranscriptionBody(
            to: bodyURL,
            boundary: "b",
            model: "whisper-large-v3-turbo",
            audioFileURL: audioURL,
            filename: "a.m4a",
            language: "de",
            responseFormat: "verbose_json"
        )

        let body = try String(contentsOf: bodyURL, encoding: .utf8)
        XCTAssertTrue(body.contains("Content-Disposition: form-data; name=\"response_format\"\r\n\r\nverbose_json\r\n"))
    }

    func testMultipartBodyOmitsResponseFormatByDefault() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CLIEnvelope-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let audioURL = tempDir.appendingPathComponent("a.m4a")
        try Data("audio".utf8).write(to: audioURL)
        let bodyURL = tempDir.appendingPathComponent("body.tmp")

        // Diktat-Pfad (kein responseFormat) → Body darf das Feld nicht enthalten.
        try MultipartFormDataFileWriter.writeAudioTranscriptionBody(
            to: bodyURL,
            boundary: "b",
            model: "whisper-1",
            audioFileURL: audioURL,
            filename: "a.m4a",
            language: nil
        )

        let body = try String(contentsOf: bodyURL, encoding: .utf8)
        XCTAssertFalse(body.contains("response_format"))
    }

    // MARK: - Key-Auflösung

    func testKeyResolverPrefersExplicitKey() {
        XCTAssertEqual(CLIKeyResolver.resolve(provider: .openai, explicit: "sk-explicit"), "sk-explicit")
    }
}
