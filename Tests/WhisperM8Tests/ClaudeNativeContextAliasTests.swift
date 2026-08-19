import XCTest
@testable import WhisperM8

/// Pure Logik des nativen 1M-Stempels. Hintergrund: Claude Codes `jw()` prueft
/// 1M-Faehigkeit ausschliesslich am String `[1m]`; Transcripts speichern die
/// Modell-ID aber suffixlos, weshalb ein Resume ohne Stempel auf den
/// 200000-Fallback fallen kann (Messung 2026-08-19, CLI 2.1.235).
final class ClaudeNativeContextAliasTests: XCTestCase {
    func testStampsOneMillionCapableClaudeFamilies() {
        for model in [
            "claude-fable-5",
            "claude-opus-5",
            "claude-opus-4-8",
            "claude-sonnet-5",
            "claude-sonnet-4-6",
        ] {
            XCTAssertEqual(
                ClaudeNativeContextAlias.oneMillionAlias(forTranscriptModel: model),
                model + "[1m]",
                model
            )
        }
    }

    func testKeepsDateStampedIDsIntact() {
        // Datums-/Versionsstempel sind erlaubt (Praefixvergleich), das Suffix
        // haengt hinten an — die ID bleibt sonst unveraendert.
        XCTAssertEqual(
            ClaudeNativeContextAlias.oneMillionAlias(forTranscriptModel: "claude-fable-5-20260101"),
            "claude-fable-5-20260101[1m]"
        )
    }

    func testReturnsNilWhenNothingToDo() {
        // Suffix schon vorhanden → kein zweiter Stempel.
        XCTAssertNil(
            ClaudeNativeContextAlias.oneMillionAlias(forTranscriptModel: "claude-fable-5[1m]")
        )
        // Haiku ist nicht 1M-faehig — nie stempeln.
        XCTAssertNil(
            ClaudeNativeContextAlias.oneMillionAlias(forTranscriptModel: "claude-haiku-4-5")
        )
        // GPT laeuft ueber ClaudeGPTModelAlias, nicht hier.
        XCTAssertNil(
            ClaudeNativeContextAlias.oneMillionAlias(forTranscriptModel: "gpt-5.6-sol")
        )
        // Unbekannte Claude-Familie bleibt unangetastet (konservativ).
        XCTAssertNil(
            ClaudeNativeContextAlias.oneMillionAlias(forTranscriptModel: "claude-neu-9")
        )
        XCTAssertNil(ClaudeNativeContextAlias.oneMillionAlias(forTranscriptModel: ""))
        XCTAssertNil(ClaudeNativeContextAlias.oneMillionAlias(forTranscriptModel: "   "))
    }

    func testIsCaseInsensitiveButPreservesInput() {
        XCTAssertEqual(
            ClaudeNativeContextAlias.oneMillionAlias(forTranscriptModel: " Claude-Fable-5 "),
            "Claude-Fable-5[1m]"
        )
    }
}
