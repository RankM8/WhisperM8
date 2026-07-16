import XCTest
@testable import WhisperM8

/// Render-Deckel + Parse-Cache der Transcript-Ansichten (Absturz-Schutz
/// 2026-07-16: ungedeckelte Texte froren CoreText beim Hochscrollen ein).
final class TranscriptRenderSupportTests: XCTestCase {

    // MARK: - TranscriptRenderLimits.clip

    func testClipLeavesShortTextUntouched() {
        let clipped = TranscriptRenderLimits.clip("Hallo Welt", max: 100)
        XCTAssertEqual(clipped.text, "Hallo Welt")
        XCTAssertEqual(clipped.truncatedCount, 0)
        XCTAssertFalse(clipped.isTruncated)
    }

    func testClipTruncatesLongTextAndCountsRemainder() {
        let text = String(repeating: "a", count: 150)
        let clipped = TranscriptRenderLimits.clip(text, max: 100)
        XCTAssertEqual(clipped.text.count, 100)
        XCTAssertEqual(clipped.truncatedCount, 50)
        XCTAssertTrue(clipped.isTruncated)
    }

    /// Mehrbyte-Zeichen: utf8.count überschätzt die Zeichenzahl — ein Text,
    /// dessen UTF8-Bytes über dem Limit liegen, aber dessen Zeichenzahl
    /// darunter, darf NICHT geclippt werden.
    func testClipUsesCharacterCountNotByteCount() {
        let text = String(repeating: "ü", count: 80) // 160 UTF8-Bytes, 80 Zeichen
        let clipped = TranscriptRenderLimits.clip(text, max: 100)
        XCTAssertEqual(clipped.text, text)
        XCTAssertFalse(clipped.isTruncated)
    }

    func testClipHandlesEmojiBoundaries() {
        let text = String(repeating: "👩‍👩‍👧‍👦", count: 30)
        let clipped = TranscriptRenderLimits.clip(text, max: 10)
        XCTAssertEqual(clipped.text.count, 10)
        XCTAssertEqual(clipped.truncatedCount, 20)
    }

    func testClipExactLimitIsNotTruncated() {
        let text = String(repeating: "x", count: 100)
        let clipped = TranscriptRenderLimits.clip(text, max: 100)
        XCTAssertEqual(clipped.text, text)
        XCTAssertFalse(clipped.isTruncated)
    }

    // MARK: - MarkdownRenderCache

    func testBlocksCacheReturnsSameResultAsDirectParse() {
        let markdown = "# Titel\n\nAbsatz mit **fett**.\n\n- eins\n- zwei"
        let cache = MarkdownRenderCache()
        XCTAssertEqual(cache.blocks(for: markdown), MarkdownBlockParser.parse(markdown))
        // Zweiter Aufruf (Cache-Hit) liefert identisches Ergebnis.
        XCTAssertEqual(cache.blocks(for: markdown), MarkdownBlockParser.parse(markdown))
    }

    func testInlineAttributedResolvesMarkdownAndCaches() {
        let cache = MarkdownRenderCache()
        let first = cache.inlineAttributed(for: "ein **fetter** Text")
        XCTAssertNotNil(first)
        XCTAssertEqual(cache.inlineAttributed(for: "ein **fetter** Text"), first)
    }
}
