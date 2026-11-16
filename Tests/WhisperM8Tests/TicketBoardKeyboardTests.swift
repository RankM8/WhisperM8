import Foundation
import XCTest
@testable import WhisperM8

/// WM8-91 Paket 3c: dieselben Wege wie am Controller per Tastatur (Plan
/// „Tastatur“) und die Sperre nach einem Sprung per Tastatur in ein Terminal.
@MainActor
final class TicketBoardKeyboardTests: XCTestCase {
    private func resolve(_ code: UInt16, _ characters: String? = nil,
                         _ modifiers: TicketBoardKey.ModifierSet = [], isRepeat: Bool = false) -> TicketBoardKey? {
        TicketBoardKey.resolve(keyCode: code, characters: characters, modifiers: modifiers, isRepeat: isRepeat)
    }

    func testPlanKeys() {
        XCTAssertEqual(resolve(123), .move(.left, isRepeat: false))
        XCTAssertEqual(resolve(124), .move(.right, isRepeat: false))
        XCTAssertEqual(resolve(124, isRepeat: true), .move(.right, isRepeat: true), "gehalten: nie über den Rand")
        XCTAssertEqual(resolve(36, "\r"), .open)
        XCTAssertEqual(resolve(76), .open, "Enter am Ziffernblock")
        XCTAssertEqual(resolve(53, "\u{1b}"), .close)
        XCTAssertEqual(resolve(123, nil, [.command, .option]), .adjacent(-1))
        XCTAssertEqual(resolve(124, nil, [.command, .option]), .adjacent(1))
        XCTAssertEqual(resolve(123, nil, [.command, .shift]), .adjacent(-1))
        XCTAssertEqual(resolve(124, nil, [.command, .shift]), .adjacent(1))
        XCTAssertEqual(resolve(31, "o", .command), .openInLinear)
        XCTAssertEqual(resolve(15, "r", .command), .refresh)
        XCTAssertEqual(resolve(38, "j", .command), .handOff)
        XCTAssertEqual(resolve(40, "k", .command), .menu)
        XCTAssertEqual(resolve(40, "k"), .previous, "K ohne ⌘ bleibt voriges Ticket")
        XCTAssertEqual(resolve(123, nil, .command), .leaveBoardChat)
        XCTAssertEqual(resolve(8, "c", .command), .copyLink)
    }

    /// ⌘⇧C bleibt der Zwischenablage-Verlauf; ⌃- und ⌥-Pfeile gehören anderen.
    func testOtherShortcutsStayFree() {
        XCTAssertNil(resolve(8, "c", [.command, .shift]))
        XCTAssertNil(resolve(123, nil, .control))
        XCTAssertNil(resolve(123, nil, .option))
        XCTAssertNil(resolve(124, nil, .command), "⌘→ ist frei")
        XCTAssertNil(resolve(0, "a", .command))
    }

    func testOnlyTheseKeysWorkInTheBoardChatTerminal() {
        let inChat: [TicketBoardKey] = [.leaveBoardChat, .adjacent(1), .adjacent(-1), .handOff]
        XCTAssertTrue(inChat.allSatisfy(\.isBoardChatKey))
        let board: [TicketBoardKey] = [.open, .close, .next, .previous, .copyLink, .refresh, .openInLinear, .menu,
                                       .move(.left, isRepeat: false), .move(.down, isRepeat: false)]
        XCTAssertFalse(board.contains(where: \.isBoardChatKey))
    }

    // MARK: Sperre nach der Ankunft

    func testArrivalLockBlocksReturnEnterAndEscapeOnly() {
        XCTAssertTrue(KeyboardArrivalLock.blocks(keyCode: 36, command: false))
        XCTAssertTrue(KeyboardArrivalLock.blocks(keyCode: 76, command: false))
        XCTAssertTrue(KeyboardArrivalLock.blocks(keyCode: 53, command: false))
        XCTAssertFalse(KeyboardArrivalLock.blocks(keyCode: 36, command: true), "⌘-Kürzel bleiben frei")
        XCTAssertFalse(KeyboardArrivalLock.blocks(keyCode: 0, command: false), "Tippen geht sofort")
        XCTAssertFalse(KeyboardArrivalLock.blocks(keyCode: 125, command: false), "Pfeile gehen sofort")
    }

    func testArrivalLockLastsOneSecondForThatChat() {
        let lock = KeyboardArrivalLock()
        var now = Date(timeIntervalSince1970: 1_000)
        lock.now = { now }
        XCTAssertNil(lock.lockedSession())
        let chat = UUID()
        lock.arrive(at: chat)
        XCTAssertEqual(lock.lockedSession(), chat)
        XCTAssertEqual(lock.judge(keyCode: 36, command: false, isRepeat: false), .refuse)
        now = now.addingTimeInterval(KeyboardArrivalLock.duration + 0.1)
        // Nach der Sekunde geht ein neuer Druck durch und beendet alles.
        XCTAssertEqual(lock.judge(keyCode: 36, command: false, isRepeat: false), .pass)
        XCTAssertNil(lock.lockedSession())
        XCTAssertNil(lock.arrival, "abgelaufen wird weggeräumt")
        XCTAssertEqual(KeyboardArrivalLock.duration, ControllerBindingResolver.arrivalLock, "dieselbe Sperre wie am Controller")
    }

    /// Auflage der Prüferin: Return auf der Chat-Zeile gehalten. Die
    /// Wiederholung beginnt nach rund 0,5 s und läuft über 1,2 s hinaus; nichts
    /// davon geht in den Ziel-Chat. Erst ein neuer Druck wirkt wieder.
    func testHeldReturnNeverRunsIntoTheChat() {
        let lock = KeyboardArrivalLock()
        var now = Date(timeIntervalSince1970: 1_000)
        lock.now = { now }
        let chat = UUID()
        lock.arrive(at: chat)   // Return auf der Chat-Zeile hat „Zum Chat“ ausgelöst
        var verdicts: [KeyboardArrivalLock.Verdict] = []
        var t = 0.5
        while t <= 1.2 {
            now = Date(timeIntervalSince1970: 1_000 + t)
            XCTAssertEqual(lock.lockedSession(), chat)
            verdicts.append(lock.judge(keyCode: 36, command: false, isRepeat: true))
            t += 0.05
        }
        XCTAssertFalse(verdicts.contains(.pass), "keine Wiederholung als Enter: \(verdicts)")
        XCTAssertFalse(verdicts.contains(.refuse), "Wiederholungen still, ohne Warnton-Gewitter")
        // Esc gehalten ebenso.
        XCTAssertEqual(lock.judge(keyCode: 53, command: false, isRepeat: true), .swallow)
        // Tippen beendet das Schlucken; danach gilt wieder alles.
        XCTAssertEqual(lock.judge(keyCode: 0, command: false, isRepeat: false), .pass)
        XCTAssertEqual(lock.judge(keyCode: 36, command: false, isRepeat: false), .pass)
        XCTAssertNil(lock.lockedSession())
    }

    /// Ein neuer Druck innerhalb der Sperre beendet das Schlucken nicht: Seine
    /// eigenen Wiederholungen kämen sonst nach Ablauf durch.
    func testAFreshPressInsideTheLockKeepsHoldingItsRepeats() {
        let lock = KeyboardArrivalLock()
        var now = Date(timeIntervalSince1970: 1_000)
        lock.now = { now }
        lock.arrive(at: UUID())
        now = now.addingTimeInterval(0.8)
        XCTAssertEqual(lock.judge(keyCode: 36, command: false, isRepeat: false), .refuse)
        now = now.addingTimeInterval(0.5)
        XCTAssertEqual(lock.judge(keyCode: 36, command: false, isRepeat: true), .swallow)
    }
}
