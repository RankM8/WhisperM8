import AppKit
import XCTest
@testable import WhisperM8

/// WM8-113: Hat das Terminal des Board-Chats den Fokus, gehören J, K, ↑, ↓,
/// Esc und ⌘C ihm, nicht der Triage. Vorher erkannte die Tastenbehandlung des
/// Boards das Terminal nie und blätterte Tickets, während jemand im Board-Chat
/// tippte.
@MainActor
final class TicketBoardKeyRoutingTests: XCTestCase {
    /// Heißt wie ein Terminal (`BoardChatFocusRule.isTerminal` prüft den Typnamen).
    private final class FakeTerminalView: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    private final class PlainView: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    private var window: NSWindow!

    override func setUp() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled],
                          backing: .buffered, defer: true)
    }

    private func focus(_ view: NSView) {
        view.frame = NSRect(x: 0, y: 0, width: 100, height: 100)
        window.contentView?.addSubview(view)
        XCTAssertTrue(window.makeFirstResponder(view))
    }

    private func key(_ characters: String, code: UInt16, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                         windowNumber: window.windowNumber, context: nil, characters: characters,
                         charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }

    private var triageKeys: [NSEvent] {
        [key("j", code: 38), key("k", code: 40), key("\u{F701}", code: 125), key("\u{F700}", code: 126),
         key("\u{1b}", code: 53), key("c", code: 8, flags: .command)]
    }

    /// Leitet die Taste und meldet, ob das Board sie bekam.
    private func route(_ event: NSEvent) -> (passedOn: Bool, boardGot: TicketBoardKey?) {
        var got: TicketBoardKey?
        let result = TicketBoardKeyRouting.route(event, firstResponder: window.firstResponder) {
            got = $0
            return true
        }
        return (result != nil, got)
    }

    func testKeysReachAFocusedTerminal() {
        focus(FakeTerminalView())
        for event in triageKeys {
            let outcome = route(event)
            XCTAssertTrue(outcome.passedOn, "\(event.keyCode) muss ans Terminal")
            XCTAssertNil(outcome.boardGot, "\(event.keyCode) darf nicht ans Board")
        }
    }

    /// Dieselbe Prüfung mit der echten Terminal-Ansicht der App.
    func testKeysReachTheRealTerminalView() {
        focus(QuietableTerminalView(frame: .zero))
        XCTAssertTrue(BoardChatFocusRule.isTerminal(window.firstResponder))
        XCTAssertNil(route(key("j", code: 38)).boardGot)
        XCTAssertNil(route(key("c", code: 8, flags: .command)).boardGot, "⌘C kopiert die Markierung im Terminal")
    }

    func testBoardTakesTheKeysWithoutTerminalFocus() {
        focus(PlainView())
        let expected: [TicketBoardKey] = [.next, .previous, .move(.down, isRepeat: false), .move(.up, isRepeat: false),
                                          .close, .copyLink]
        for (event, want) in zip(triageKeys, expected) {
            let outcome = route(event)
            XCTAssertFalse(outcome.passedOn, "\(event.keyCode) gehört dem Board")
            XCTAssertEqual(outcome.boardGot, want)
        }
    }

    func testAnEditableTextFieldKeepsItsKeys() {
        let text = NSTextView()
        text.isEditable = true
        focus(text)
        XCTAssertNil(route(key("j", code: 38)).boardGot)
    }

    /// ⌘C in der (nicht bearbeitbaren) Beschreibung: mit Markierung der Text,
    /// ohne Markierung der Link.
    func testCopyInTheDescriptionPrefersTheSelection() {
        let text = NSTextView()
        text.isEditable = false
        text.string = "Beschreibung zu WM8-12"
        focus(text)
        XCTAssertEqual(route(key("c", code: 8, flags: .command)).boardGot, .copyLink)
        text.setSelectedRange(NSRange(location: 0, length: 5))
        XCTAssertNil(route(key("c", code: 8, flags: .command)).boardGot)
    }

    /// Ohne offene Triage nimmt das Board J nicht; die Taste geht weiter.
    func testUnhandledKeyGoesOn() {
        focus(PlainView())
        let result = TicketBoardKeyRouting.route(key("j", code: 38), firstResponder: window.firstResponder) { _ in false }
        XCTAssertNotNil(result)
    }

    /// WM8-91 Paket 3c: Im Terminal des Board-Chats nimmt das Board nur ⌘←
    /// (zurück aufs Ticket), ⌘⌥←/→ und ⌘⇧←/→ (Ticket) und ⌘J (→ Jarvis).
    /// Return, Esc, Pfeile, J, K und ⌘C bleiben beim Chat.
    func testTheBoardChatTerminalKeepsAllButTheBoardChatKeys() {
        let terminal = FakeTerminalView()
        focus(terminal)
        func routeInBoardChat(_ event: NSEvent) -> TicketBoardKey? {
            var got: TicketBoardKey?
            _ = TicketBoardKeyRouting.route(event, firstResponder: window.firstResponder,
                                            isBoardChatTerminal: { $0 === terminal }) { got = $0; return true }
            return got
        }
        for event in triageKeys + [key("\r", code: 36), key("\u{F703}", code: 124)] {
            XCTAssertNil(routeInBoardChat(event), "\(event.keyCode) gehört dem Chat")
        }
        XCTAssertEqual(routeInBoardChat(key("\u{F702}", code: 123, flags: .command)), .leaveBoardChat)
        XCTAssertEqual(routeInBoardChat(key("\u{F703}", code: 124, flags: [.command, .option])), .adjacent(1))
        XCTAssertEqual(routeInBoardChat(key("\u{F702}", code: 123, flags: [.command, .shift])), .adjacent(-1))
        XCTAssertEqual(routeInBoardChat(key("j", code: 38, flags: .command)), .handOff)
        // Ein anderes Terminal (der Chat hinter den Tickets) bekommt nichts vom Board.
        XCTAssertNil(route(key("\u{F702}", code: 123, flags: .command)).boardGot)
    }

    /// Der alte Fehler: ein in `Any` gepacktes Optional nennt seinen eigenen Typ.
    func testTheOldCheckCouldNotSeeTheTerminal() {
        focus(FakeTerminalView())
        let responder = window.firstResponder
        XCTAssertFalse(String(describing: type(of: responder as Any)).contains("TerminalView"))
        XCTAssertTrue(BoardChatFocusRule.isTerminal(responder))
    }
}
