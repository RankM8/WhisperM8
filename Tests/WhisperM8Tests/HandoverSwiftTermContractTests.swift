import XCTest
import SwiftTerm

/// Was „Neustart ohne Chatverlust“ vom SwiftTerm-Fork braucht
/// (`docs/plans/neustart-ohne-chatverlust.md`, Paket 1). Schlägt dieser Test
/// fehl, zeigt der Pin in `Package.swift` auf einen Fork ohne diese Wege.
final class HandoverSwiftTermContractTests: XCTestCase {
    private final class Silent: TerminalDelegate {
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
    }

    /// Bild sichern und in ein frisches Terminal gleicher Größe einspielen:
    /// Text, Farbe und die Schalter, die Claude und Codex beim Start setzen.
    func testScreenRoundTripKeepsContentAndModes() {
        let delegate = Silent()
        let options = TerminalOptions(cols: 40, rows: 8, scrollback: 100)
        let original = Terminal(delegate: delegate, options: options)
        original.feed(text: "Zeile 1\r\n\u{1b}[31mrot\u{1b}[0m\r\n\u{1b}[?2004h\u{1b}[>5u\u{1b}[?1006h\u{1b}[?1002h")
        let copy = Terminal(delegate: delegate, options: options)
        copy.feed(byteArray: original.serializeScreen())

        XCTAssertEqual(copy.getLine(row: 0)?.translateToString(trimRight: true), "Zeile 1")
        XCTAssertEqual(copy.getLine(row: 1)?.translateToString(trimRight: true), "rot")
        XCTAssertEqual(copy.getCharData(col: 0, row: 1)?.attribute, original.getCharData(col: 0, row: 1)?.attribute)
        XCTAssertEqual(copy.bracketedPasteMode, true)
        XCTAssertEqual(copy.keyboardEnhancementFlags, original.keyboardEnhancementFlags)
        XCTAssertEqual(copy.mouseMode, original.mouseMode)
        XCTAssertEqual(copy.getCursorLocation().x, original.getCursorLocation().x)
        XCTAssertEqual(copy.getCursorLocation().y, original.getCursorLocation().y)
    }

    func testHandoverAPIsExist() {
        // Nur die Signaturen; das Verhalten testet der Fork mit echten Prozessen.
        let detach: (LocalProcess) -> LocalProcess.HandoverHandle? = { $0.detachForHandover() }
        let adopt: (LocalProcess, LocalProcess.HandoverHandle) -> Bool = { $0.adopt($1) }
        XCTAssertNotNil(detach as Any)
        XCTAssertNotNil(adopt as Any)
        XCTAssertEqual(LocalProcess.HandoverHandle(fileDescriptor: 7, pid: 42).pid, 42)
    }
}
