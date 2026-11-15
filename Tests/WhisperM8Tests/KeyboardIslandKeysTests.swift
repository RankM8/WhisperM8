import AppKit
import XCTest
@testable import WhisperM8

/// Pure Tastenregeln der Insel per Tastatur (WM8-104): Wann ⌥Tab öffnet, was
/// eine Taste bei offener Insel tut, wann ⌥-Loslassen wechselt.
final class KeyboardIslandKeysTests: XCTestCase {
    private typealias K = KeyboardIslandKeys.KeyCode

    func testOnlyOptionTabOpens() {
        XCTAssertTrue(KeyboardIslandKeys.opens(keyCode: K.tab, modifiers: [.option]))
        XCTAssertTrue(KeyboardIslandKeys.opens(keyCode: K.tab, modifiers: [.option, .capsLock]), "CapsLock zählt nicht")
        XCTAssertFalse(KeyboardIslandKeys.opens(keyCode: K.tab, modifiers: [.control]), "⌃Tab bleibt der Umschalter")
        XCTAssertFalse(KeyboardIslandKeys.opens(keyCode: K.tab, modifiers: [.control, .option]), "⌃⌥Tab: nächster wartender")
        XCTAssertFalse(KeyboardIslandKeys.opens(keyCode: K.tab, modifiers: [.command, .option]))
        XCTAssertFalse(KeyboardIslandKeys.opens(keyCode: K.tab, modifiers: [.option, .shift]), "⌥⇧Tab öffnet nicht")
        XCTAssertFalse(KeyboardIslandKeys.opens(keyCode: K.tab, modifiers: []))
        XCTAssertFalse(KeyboardIslandKeys.opens(keyCode: K.space, modifiers: [.option]), "⌥Leertaste bleibt das Diktat")
    }

    func testKeysWhileOpen() {
        let option: NSEvent.ModifierFlags = [.option]
        XCTAssertEqual(KeyboardIslandKeys.action(keyCode: K.tab, modifiers: option), .step(1))
        XCTAssertEqual(KeyboardIslandKeys.action(keyCode: K.tab, modifiers: [.option, .shift]), .step(-1))
        XCTAssertEqual(KeyboardIslandKeys.action(keyCode: K.downArrow, modifiers: [.option, .function, .numericPad]), .step(1))
        XCTAssertEqual(KeyboardIslandKeys.action(keyCode: K.upArrow, modifiers: [.option, .function]), .step(-1))
        XCTAssertEqual(KeyboardIslandKeys.action(keyCode: K.leftArrow, modifiers: [.option, .function]), .tab(-1))
        XCTAssertEqual(KeyboardIslandKeys.action(keyCode: K.rightArrow, modifiers: [.option, .function]), .tab(1))
        XCTAssertEqual(KeyboardIslandKeys.action(keyCode: K.space, modifiers: option), .dictate)
        XCTAssertEqual(KeyboardIslandKeys.action(keyCode: K.w, modifiers: option), .nextWaiting)
        XCTAssertEqual(KeyboardIslandKeys.action(keyCode: K.r, modifiers: option), .reopen)
        XCTAssertEqual(KeyboardIslandKeys.action(keyCode: K.returnKey, modifiers: option), .commit)
        XCTAssertEqual(KeyboardIslandKeys.action(keyCode: K.keypadEnter, modifiers: option), .commit)
        XCTAssertEqual(KeyboardIslandKeys.action(keyCode: K.escape, modifiers: option), .cancel)
    }

    /// Andere Tasten bei gehaltenem ⌥ werden geschluckt: Ein ⌥-Zeichen soll
    /// nicht ins Terminal rutschen, solange die Insel offen ist.
    func testOtherOptionKeysAreSwallowed() {
        XCTAssertEqual(KeyboardIslandKeys.action(keyCode: 2, modifiers: [.option]), .ignore, "⌥D")
        XCTAssertEqual(KeyboardIslandKeys.action(keyCode: K.w, modifiers: [.option, .shift]), .ignore)
        XCTAssertEqual(KeyboardIslandKeys.action(keyCode: K.tab, modifiers: [.option, .control]), .ignore)
        XCTAssertEqual(KeyboardIslandKeys.action(keyCode: K.leftArrow, modifiers: [.option, .command]), .ignore)
    }

    /// Ohne ⌥ ist das Loslassen an uns vorbeigegangen: abbrechen, Taste läuft
    /// weiter. Return wechselt dann nicht zur alten Markierung und wird wie Esc
    /// verschluckt: durchgereicht bestätigte es womöglich eine offene Freigabe.
    func testKeyWithoutOptionMeansMissedRelease() {
        XCTAssertEqual(KeyboardIslandKeys.action(keyCode: K.tab, modifiers: []), .cancelAndPassThrough)
        XCTAssertEqual(KeyboardIslandKeys.action(keyCode: K.w, modifiers: []), .cancelAndPassThrough)
        XCTAssertEqual(KeyboardIslandKeys.action(keyCode: K.returnKey, modifiers: []), .cancel)
        XCTAssertEqual(KeyboardIslandKeys.action(keyCode: K.keypadEnter, modifiers: [.function]), .cancel)
        XCTAssertEqual(KeyboardIslandKeys.action(keyCode: K.escape, modifiers: []), .cancel)
    }

    func testReleasingOptionCommits() {
        XCTAssertEqual(KeyboardIslandKeys.flagsChange(previous: [.option], current: []), .commit)
        XCTAssertEqual(KeyboardIslandKeys.flagsChange(previous: [.option, .shift], current: [.shift]), .commit)
        XCTAssertEqual(KeyboardIslandKeys.flagsChange(previous: [.option], current: [.option, .shift]), .none)
        XCTAssertEqual(KeyboardIslandKeys.flagsChange(previous: [.option, .shift], current: [.option]), .none)
        XCTAssertEqual(KeyboardIslandKeys.flagsChange(previous: [.option], current: [.option, .capsLock]), .none)
    }

    /// ⌥ fehlt, aber dieses Ereignis hat eine andere Taste geändert: Das
    /// Loslassen ging an uns vorbei — nicht in die alte Markierung wechseln.
    func testMissedReleaseCancels() {
        XCTAssertEqual(KeyboardIslandKeys.flagsChange(previous: [], current: [.shift]), .cancel)
        XCTAssertEqual(KeyboardIslandKeys.flagsChange(previous: [.option, .shift], current: []), .cancel)
    }
}

/// Markierung der Insel per Tastatur im puren Modell: Start auf „vorher“,
/// Reiterwechsel mit „vorher“ bzw. dem aktuellen Eintrag.
final class KeyboardIslandWhereToTests: XCTestCase {
    private let chats = (0..<4).map { _ in UUID() }
    private let workspaces = (0..<3).map { _ in UUID() }

    private func rows(current: Int) -> [ControllerIslandChatRow] {
        chats.enumerated().map { index, id in
            ControllerIslandChatRow(id: id, title: "Chat \(index)", status: .idle, detail: "", isCurrent: index == current)
        }
    }

    private func choices(current: Int?) -> [ControllerWorkspaceChoice] {
        workspaces.enumerated().map { index, id in
            ControllerWorkspaceChoice(id: id, name: "W\(index)", colorHex: "#5E6AD2", chatCount: 2,
                                      hasWaitingChat: false, isCurrent: index == current)
        }
    }

    func testStartsOnPreviousChatOneStepBelowCurrent() {
        let order = ControllerWhereToState.chatOrder(chats, current: chats[1], previous: .chat(chats[3]))
        let byID = Dictionary(uniqueKeysWithValues: rows(current: 1).map { ($0.id, $0) })
        var state = ControllerWhereToState(
            chats: order.compactMap { byID[$0] }, currentChatID: chats[1], workspaces: choices(current: nil),
            gridActive: false, previous: .chat(chats[3]))
        state.markPreviousForKeyboard()
        XCTAssertEqual(state.tab, .chats)
        XCTAssertEqual(state.chats.selected?.id, chats[3])
        XCTAssertEqual(state.chats.rows.firstIndex { $0.id == chats[3] }, 2, "gleich unter dem aktuellen")
        XCTAssertEqual(state.destination, .chat(chats[3]))
    }

    /// Im Raster ist der Start-Reiter „Workspaces & Projekte“. War der vorige
    /// Ort ein Chat, springt die Tastatur in den Reiter „Chats“: ⌥Tab kurz
    /// führt immer an den vorigen Ort wie L2 getippt.
    func testPreviousChatWinsOverGridStartTab() {
        var state = ControllerWhereToState(
            chats: rows(current: 1), currentChatID: chats[1], workspaces: choices(current: 0),
            gridActive: true, previous: .chat(chats[2]))
        XCTAssertEqual(state.tab, .workspaces)
        state.markPreviousForKeyboard()
        XCTAssertEqual(state.tab, .chats)
        XCTAssertEqual(state.destination, .chat(chats[2]))
    }

    func testPreviousWorkspaceInGrid() {
        var state = ControllerWhereToState(
            chats: rows(current: 1), currentChatID: chats[1], workspaces: choices(current: 0),
            gridActive: true, previous: .workspace(workspaces[2]))
        state.markPreviousForKeyboard()
        XCTAssertEqual(state.tab, .workspaces)
        XCTAssertEqual(state.destination, .workspace(workspaces[2]))
    }

    /// Ohne vorigen Ort: ein Schritt unter den aktuellen (wie ⌘Tab).
    func testWithoutPreviousOneStepDown() {
        var state = ControllerWhereToState(
            chats: rows(current: 1), currentChatID: chats[1], workspaces: [], gridActive: false)
        state.markPreviousForKeyboard()
        XCTAssertEqual(state.destination, .chat(chats[2]))
    }

    /// ←/→: im anderen Reiter auf „vorher“, sonst auf dem aktuellen Eintrag.
    func testTabSwitchMarksPreviousElseCurrent() {
        var state = ControllerWhereToState(
            chats: rows(current: 1), currentChatID: chats[1], workspaces: choices(current: 0),
            gridActive: false, previous: .workspace(workspaces[2]))
        state.markPreviousForKeyboard()
        XCTAssertEqual(state.tab, .workspaces)
        XCTAssertTrue(state.switchTabForKeyboard(-1))
        XCTAssertEqual(state.tab, .chats)
        XCTAssertEqual(state.chats.selected?.id, chats[1], "kein voriger Chat: auf dem aktuellen")
        XCTAssertEqual(state.destination, .stay)
        XCTAssertTrue(state.switchTabForKeyboard(1))
        XCTAssertEqual(state.destination, .workspace(workspaces[2]))
        XCTAssertFalse(state.switchTabForKeyboard(1), "kein Umlauf")
    }

    func testFooterFollowsTabAndDictation() {
        let chatsTab = KeyboardIslandFooter.items(tab: .chats, dictating: false, canReopen: false)
        XCTAssertEqual(chatsTab.map(\.keys.first), ["⇥", "←", "␣", "W", "R", "esc", "⌥"])
        XCTAssertEqual(chatsTab.first { $0.keys == ["R"] }?.isOn, false, "nichts geschlossen: ausgegraut, aber sichtbar")
        let workspacesTab = KeyboardIslandFooter.items(tab: .workspaces, dictating: false, canReopen: true)
        XCTAssertEqual(workspacesTab.map(\.keys.first), ["⇥", "←", "␣", "esc", "⌥"])
        let dictating = KeyboardIslandFooter.items(tab: .chats, dictating: true, canReopen: true)
        XCTAssertEqual(dictating.map(\.keys.first), ["␣", "⇥", "esc", "⌥"])
    }
}

/// Paket 2: Buchstaben der Tastenzeile, Spickzettel, Options-Menü per Tastatur.
final class KeyboardIslandCommandKeysTests: XCTestCase {
    private typealias K = KeyboardIslandKeys.KeyCode

    func testLettersByKeyCode() {
        let expected: [(UInt16, KeyboardIslandCommand)] = [
            (1, .sendNow), (46, .cycleMode), (31, .transcript), (11, .commands), (40, .account),
            (37, .limits), (45, .alerts), (0, .stayAwake), (8, .clipboard),
        ]
        for (keyCode, command) in expected {
            XCTAssertEqual(KeyboardIslandKeys.action(keyCode: keyCode, modifiers: [.option]), .command(command))
            XCTAssertEqual(command.keyCode, keyCode)
        }
        XCTAssertEqual(KeyboardIslandKeys.action(keyCode: 1, modifiers: [.option, .shift]), .ignore, "⌥⇧S")
        XCTAssertEqual(KeyboardIslandKeys.action(keyCode: 1, modifiers: [.option, .command]), .ignore)
        XCTAssertEqual(Set(KeyboardIslandCommand.allCases.map(\.letter)).count, 9, "jeder Buchstabe einmal")
        XCTAssertFalse(KeyboardIslandCommand.allCases.map(\.letter).contains { ["Y", "Z", "W", "R"].contains($0) })
    }

    /// „?“ liegt je nach Layout woanders (US ⇧/, DE ⇧ß): erkannt am Zeichen.
    func testQuestionMarkByCharacter() {
        XCTAssertEqual(KeyboardIslandKeys.action(keyCode: 44, modifiers: [.option, .shift], characters: "?"), .cheatSheet)
        XCTAssertEqual(KeyboardIslandKeys.action(keyCode: 27, modifiers: [.option, .shift], characters: "?"), .cheatSheet)
        XCTAssertEqual(KeyboardIslandKeys.action(keyCode: 44, modifiers: [.option], characters: "/"), .ignore)
    }

    func testMenuKeys() {
        XCTAssertEqual(KeyboardIslandKeys.menuAction(keyCode: K.downArrow, modifiers: [.function]), .move(1))
        XCTAssertEqual(KeyboardIslandKeys.menuAction(keyCode: K.upArrow, modifiers: [.option, .function]), .move(-1))
        XCTAssertEqual(KeyboardIslandKeys.menuAction(keyCode: K.tab, modifiers: [.shift]), .move(-1))
        XCTAssertEqual(KeyboardIslandKeys.menuAction(keyCode: K.returnKey, modifiers: []), .activate)
        XCTAssertEqual(KeyboardIslandKeys.menuAction(keyCode: K.rightArrow, modifiers: [.function]), .activate)
        XCTAssertEqual(KeyboardIslandKeys.menuAction(keyCode: K.escape, modifiers: []), .back)
        XCTAssertEqual(KeyboardIslandKeys.menuAction(keyCode: K.leftArrow, modifiers: [.function]), .back)
        XCTAssertEqual(KeyboardIslandKeys.menuAction(keyCode: 0, modifiers: []), .closeAndPassThrough, "Tippen schließt")
        XCTAssertEqual(KeyboardIslandKeys.menuAction(keyCode: K.downArrow, modifiers: [.command]), .closeAndPassThrough)
    }

    func testFooterAfterToggle() {
        let items = KeyboardIslandFooter.items(tab: .chats, dictating: false, canReopen: true, releaseSwitches: false)
        XCTAssertEqual(items.map(\.keys), [["⌥"]], "nur: loslassen wechselt nichts")
    }
}
