import Carbon.HIToolbox
import XCTest
@testable import WhisperM8

/// LR-DIK-025: Tastencode für Cmd+V/Cmd+C aus dem aktiven Layout.
final class KeyCodeResolverTests: XCTestCase {
    /// US-QWERTY-Ausschnitt (Code → Zeichen). QWERTZ unterscheidet sich nur bei y/z.
    private let qwerty: [UInt16: String] = [0: "a", 8: "c", 9: "v", 32: "u", 40: "k", 38: "j"]
    /// Dvorak: „v" liegt auf Code 47, „c" auf 34; Code 9 ist „k", Code 8 „j".
    private let dvorak: [UInt16: String] = [9: "k", 8: "j", 47: "v", 34: "c"]

    func testQwertyAndQwertzResolveVTo9() {
        XCTAssertEqual(KeyCodeResolver.keyCode(for: "v", fallback: kVK_ANSI_V, translate: { self.qwerty[$0] }), 9)
        XCTAssertEqual(KeyCodeResolver.keyCode(for: "c", fallback: kVK_ANSI_C, translate: { self.qwerty[$0] }), 8)
    }

    func testDvorakResolvesVTo47() {
        XCTAssertEqual(KeyCodeResolver.keyCode(for: "v", fallback: kVK_ANSI_V, translate: { self.dvorak[$0] }), 47)
        XCTAssertEqual(KeyCodeResolver.keyCode(for: "c", fallback: kVK_ANSI_C, translate: { self.dvorak[$0] }), 34)
    }

    func testFallsBackWhenLayoutUnreadableOrCharacterMissing() {
        XCTAssertEqual(KeyCodeResolver.keyCode(for: "v", fallback: kVK_ANSI_V, translate: { _ in nil }), 9)
        // Nicht-lateinisches Layout: kein „v" im Block.
        XCTAssertEqual(KeyCodeResolver.keyCode(for: "v", fallback: kVK_ANSI_V, translate: { _ in "ж" }), 9)
    }
}
