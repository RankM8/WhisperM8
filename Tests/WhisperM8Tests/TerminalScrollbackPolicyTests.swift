import XCTest
@testable import WhisperM8

/// Absicherung der Scrollback-Politik. Der fachliche Hintergrund steht in
/// `TerminalScrollbackPolicy`: bei vollem Ringpuffer senkt jede neue
/// Ausgabezeile die Leseposition um 1, ein zu kleiner Puffer schiebt den
/// lesenden Nutzer deshalb an den oberen Anschlag.
final class TerminalScrollbackPolicyTests: XCTestCase {

    // MARK: - resolve

    func testUnsetFallsBackToDefault() {
        XCTAssertEqual(TerminalScrollbackPolicy.resolve(configured: nil),
                       TerminalScrollbackPolicy.defaultLines)
    }

    func testDefaultIsGenerousEnoughForALongAnswer() {
        // Eine laengere Agent-Antwort mit Tool-Ausgaben sind 100–300 Zeilen.
        // Der Default muss ein Vielfaches davon abdecken, sonst ist der Nutzer
        // nach einer einzigen Antwort wieder oben angeschlagen.
        XCTAssertGreaterThanOrEqual(TerminalScrollbackPolicy.defaultLines, 5_000)
    }

    func testConfiguredValueIsHonored() {
        XCTAssertEqual(TerminalScrollbackPolicy.resolve(configured: 20_000), 20_000)
    }

    func testValueBelowMinimumIsRaised() {
        // Unter SwiftTerms eigenem Default faengt das Problem wieder an.
        XCTAssertEqual(TerminalScrollbackPolicy.resolve(configured: 10),
                       TerminalScrollbackPolicy.minimumLines)
    }

    func testValueAboveMaximumIsCapped() {
        XCTAssertEqual(TerminalScrollbackPolicy.resolve(configured: 5_000_000),
                       TerminalScrollbackPolicy.maximumLines)
    }

    /// Eine kaputte Preference (0 oder negativ, z. B. `defaults write … -int 0`)
    /// darf einen Chat nicht unbrauchbar machen — 0 hiesse „kein Scrollback".
    func testZeroAndNegativeFallBackToDefault() {
        XCTAssertEqual(TerminalScrollbackPolicy.resolve(configured: 0),
                       TerminalScrollbackPolicy.defaultLines)
        XCTAssertEqual(TerminalScrollbackPolicy.resolve(configured: -1),
                       TerminalScrollbackPolicy.defaultLines)
    }

    func testBoundaryValuesArePassedThroughUnchanged() {
        XCTAssertEqual(TerminalScrollbackPolicy.resolve(configured: TerminalScrollbackPolicy.minimumLines),
                       TerminalScrollbackPolicy.minimumLines)
        XCTAssertEqual(TerminalScrollbackPolicy.resolve(configured: TerminalScrollbackPolicy.maximumLines),
                       TerminalScrollbackPolicy.maximumLines)
    }

    // MARK: - Knob-Groesse

    /// Der Preis des langen Puffers: der Knob wird winzig. SwiftTerm deckelt
    /// bei 1 % — das soll bewusst und getestet sein, nicht als Ueberraschung
    /// im Feld auftauchen.
    func testThumbShrinksWithLargeScrollbackAndIsFloored() {
        let small = TerminalScrollbackPolicy.expectedThumbFraction(rows: 45, scrollbackLines: 500)
        XCTAssertEqual(small, 45.0 / 545.0, accuracy: 0.0001)

        let large = TerminalScrollbackPolicy.expectedThumbFraction(rows: 45, scrollbackLines: 10_000)
        XCTAssertEqual(large, 0.01, accuracy: 0.0001, "SwiftTerms 1-%-Untergrenze muss greifen")
    }

    func testThumbIsFullWhenNothingToScroll() {
        XCTAssertEqual(TerminalScrollbackPolicy.expectedThumbFraction(rows: 45, scrollbackLines: 0),
                       1.0, accuracy: 0.0001)
    }

    /// Division durch Null darf es nicht geben — eine Pane kann waehrend des
    /// Layouts kurz 0 Zeilen hoch sein.
    func testZeroRowsIsSafe() {
        XCTAssertEqual(TerminalScrollbackPolicy.expectedThumbFraction(rows: 0, scrollbackLines: 10_000),
                       1.0, accuracy: 0.0001)
    }
}
