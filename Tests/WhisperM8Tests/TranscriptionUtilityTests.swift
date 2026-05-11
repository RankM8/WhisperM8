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

    func testMultipartBodyContainsModelLanguageAndFile() {
        let body = MultipartFormDataBuilder.buildAudioTranscriptionBody(
            boundary: "boundary",
            model: "gpt-4o-transcribe",
            audioData: Data("audio".utf8),
            filename: "sample.m4a",
            language: "de"
        )

        let text = String(data: body, encoding: .utf8)
        XCTAssertNotNil(text)
        XCTAssertTrue(text?.contains("name=\"model\"") == true)
        XCTAssertTrue(text?.contains("gpt-4o-transcribe") == true)
        XCTAssertTrue(text?.contains("name=\"language\"") == true)
        XCTAssertTrue(text?.contains("de") == true)
        XCTAssertTrue(text?.contains("filename=\"sample.m4a\"") == true)
        XCTAssertTrue(text?.contains("audio") == true)
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
