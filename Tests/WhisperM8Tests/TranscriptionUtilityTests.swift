import Foundation
import XCTest
@testable import WhisperM8

final class TranscriptionUtilityTests: XCTestCase {
    func testNormalizesProviderWhitespaceAndInvisibleCharacters() {
        let input = "\u{FEFF}\u{200B}\u{00A0} Hello world \n"
        XCTAssertEqual(TextNormalizer.normalizeTranscriptionText(input), "Hello world")
    }

    func testTimeoutCalculationHonorsMinimumAndMaximum() {
        XCTAssertEqual(calculateTimeout(for: nil), 180)
        XCTAssertEqual(calculateTimeout(for: 30), 240)
        XCTAssertEqual(calculateTimeout(for: 120), 420)
        XCTAssertEqual(calculateTimeout(for: 600), 900)
    }

    func testMultipartFileBodyMatchesExpectedEnvelope() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MultipartWriterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let audioURL = tempDir.appendingPathComponent("sample.m4a")
        try Data("audio".utf8).write(to: audioURL)
        let bodyURL = tempDir.appendingPathComponent("body.tmp")

        try MultipartFormDataFileWriter.writeAudioTranscriptionBody(
            to: bodyURL,
            boundary: "boundary",
            model: "gpt-4o-transcribe",
            audioFileURL: audioURL,
            filename: "sample.m4a",
            language: "de"
        )

        let expected = "--boundary\r\n"
            + "Content-Disposition: form-data; name=\"model\"\r\n\r\n"
            + "gpt-4o-transcribe\r\n"
            + "--boundary\r\n"
            + "Content-Disposition: form-data; name=\"language\"\r\n\r\n"
            + "de\r\n"
            + "--boundary\r\n"
            + "Content-Disposition: form-data; name=\"file\"; filename=\"sample.m4a\"\r\n"
            + "Content-Type: audio/m4a\r\n\r\n"
            + "audio"
            + "\r\n--boundary--\r\n"

        XCTAssertEqual(try String(contentsOf: bodyURL, encoding: .utf8), expected)
    }

    func testMultipartFileBodyOmitsLanguageWhenNil() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MultipartWriterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let audioURL = tempDir.appendingPathComponent("sample.m4a")
        try Data("audio".utf8).write(to: audioURL)
        let bodyURL = tempDir.appendingPathComponent("body.tmp")

        try MultipartFormDataFileWriter.writeAudioTranscriptionBody(
            to: bodyURL,
            boundary: "boundary",
            model: "whisper-1",
            audioFileURL: audioURL,
            filename: "sample.m4a",
            language: nil
        )

        let text = try String(contentsOf: bodyURL, encoding: .utf8)
        XCTAssertFalse(text.contains("name=\"language\""))
        XCTAssertTrue(text.contains("name=\"model\""))
        XCTAssertTrue(text.contains("audio"))
    }

    func testMultipartFileBodyStreamsLargeFilesIntact() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MultipartWriterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // 3,5 MiB erzwingt mehrere 1-MiB-Chunks inkl. Rest-Chunk.
        var audioData = Data()
        for index in 0..<(3 * 1024 * 1024 + 512 * 1024) {
            audioData.append(UInt8(index % 251))
        }
        let audioURL = tempDir.appendingPathComponent("large.m4a")
        try audioData.write(to: audioURL)
        let bodyURL = tempDir.appendingPathComponent("body.tmp")

        try MultipartFormDataFileWriter.writeAudioTranscriptionBody(
            to: bodyURL,
            boundary: "boundary",
            model: "whisper-1",
            audioFileURL: audioURL,
            filename: "large.m4a",
            language: nil
        )

        let body = try Data(contentsOf: bodyURL)
        XCTAssertNotNil(body.range(of: audioData), "Audio-Bytes müssen vollständig und am Stück im Body stehen")
        XCTAssertTrue(body.starts(with: Data("--boundary\r\n".utf8)))
        XCTAssertEqual(body.suffix(16), Data("\r\n--boundary--\r\n".utf8))
    }

    func testModelMapsToExpectedProvider() {
        XCTAssertEqual(TranscriptionModel.openai_gpt4o.provider, .openai)
        XCTAssertEqual(TranscriptionModel.openai_whisper.provider, .openai)
        XCTAssertEqual(TranscriptionModel.groq_whisper_v3.provider, .groq)
        XCTAssertEqual(TranscriptionModel.groq_whisper_v3_turbo.provider, .groq)
    }

    func testRecordingPhasePriorityMatchesExistingStatusPrecedence() {
        XCTAssertEqual(
            RecordingPhase.resolve(isRecording: true, isTranscribing: true, isPostProcessing: true),
            .recording
        )
        XCTAssertEqual(
            RecordingPhase.resolve(isRecording: false, isTranscribing: true, isPostProcessing: true),
            .postProcessing
        )
        XCTAssertEqual(
            RecordingPhase.resolve(isRecording: false, isTranscribing: true, isPostProcessing: false),
            .transcribing
        )
        XCTAssertEqual(
            RecordingPhase.resolve(isRecording: false, isTranscribing: false, isPostProcessing: false),
            .idle
        )
    }
}
