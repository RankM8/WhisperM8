import AVFoundation
import XCTest
@testable import WhisperM8

/// Phase-3 Test-Seam: deckt die aus `AudioRecorder` (startRecording +
/// handleConfigurationChange) extrahierte Converter-Entscheidung ab —
/// ohne laufende AVAudioEngine.
final class AudioFormatDecisionTests: XCTestCase {
    private let target = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false
    )!

    private func format(_ sampleRate: Double, _ channels: AVAudioChannelCount) -> AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: false)!
    }

    func testNoConversionWhenFormatMatchesTarget() {
        XCTAssertFalse(AudioFormatDecision.needsConversion(from: format(16000, 1), to: target))
    }

    func testConversionWhenSampleRateDiffers() {
        XCTAssertTrue(AudioFormatDecision.needsConversion(from: format(44100, 1), to: target))
        XCTAssertTrue(AudioFormatDecision.needsConversion(from: format(48000, 1), to: target))
    }

    func testConversionWhenChannelCountDiffers() {
        XCTAssertTrue(AudioFormatDecision.needsConversion(from: format(16000, 2), to: target))
    }

    func testConversionWhenBothDiffer() {
        XCTAssertTrue(AudioFormatDecision.needsConversion(from: format(48000, 2), to: target))
    }

    // MARK: - isRecordable (Crash-Guard)

    // CoreAudio liefert 0 Hz / 0 Kanäle, solange das Eingabegerät nicht
    // gebunden ist — installTap damit wirft eine unfangbare NSException
    // (Crashes 2026-07-01 + 2026-07-08). AVAudioFormat lässt sich mit 0 Hz
    // nicht konstruieren, daher die skalare Variante testen (genau das, was
    // die Format-Property-Werte liefern).

    func testRecordableWithValidHardwareFormat() {
        XCTAssertTrue(AudioFormatDecision.isRecordable(sampleRate: 48000, channelCount: 1))
        XCTAssertTrue(AudioFormatDecision.isRecordable(format(16000, 1)))
    }

    func testNotRecordableWithZeroSampleRate() {
        XCTAssertFalse(AudioFormatDecision.isRecordable(sampleRate: 0, channelCount: 1))
    }

    func testNotRecordableWithZeroChannels() {
        XCTAssertFalse(AudioFormatDecision.isRecordable(sampleRate: 48000, channelCount: 0))
        XCTAssertFalse(AudioFormatDecision.isRecordable(sampleRate: 0, channelCount: 0))
    }
}
