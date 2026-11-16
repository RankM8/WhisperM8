import AppKit
import XCTest
@testable import WhisperM8

/// Vor jeder Board-Aktion des Controllers geht der Tastaturfokus aus dem
/// Terminal des Board-Chats zurück ans Fenster (WM8-91 mit WM8-113); „Zum
/// Chat“ lässt ihn, wo er ist.
@MainActor
final class ControllerTicketFocusTests: XCTestCase {
    /// Heißt wie ein Terminal (`BoardChatFocusRule.isTerminal` prüft den Typnamen).
    private final class FakeTerminalView: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    private func windowWithFocusedTerminal() -> (NSWindow, FakeTerminalView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled],
                              backing: .buffered, defer: true)
        let terminal = FakeTerminalView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        window.contentView?.addSubview(terminal)
        XCTAssertTrue(window.makeFirstResponder(terminal))
        return (window, terminal)
    }

    func testBoardActionsTakeTheFocusOutOfTheTerminal() {
        let commands: [ControllerTicketCommand] = [
            .move(.down), .open, .back, .adjacent(1), .copyLink, .openInLinear, .refresh, .scroll(lines: 3),
            .copyList, .dictationUnavailable,
        ]
        for command in commands {
            let (window, terminal) = windowWithFocusedTerminal()
            ControllerTicketFocus.prepare(for: command, in: window)
            XCTAssertFalse(window.firstResponder === terminal, "\(command): Fokus noch im Terminal")
        }
    }

    func testGoToChatLeavesTheFocus() {
        let (window, terminal) = windowWithFocusedTerminal()
        ControllerTicketFocus.prepare(for: .goToChat(UUID()), in: window)
        XCTAssertTrue(window.firstResponder === terminal)
        XCTAssertFalse(ControllerTicketCommand.goToChat(UUID()).actsOnBoard)
    }
}
