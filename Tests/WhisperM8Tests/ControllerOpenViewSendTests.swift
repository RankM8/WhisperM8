import Foundation
import XCTest
@testable import WhisperM8

/// WM8-123, Befund der Prüferin (16.11.2026): Die Controller-Wege, die Text
/// oder Enter in einen Chat schicken, prüften die neue Ablesung offener
/// Ansichten nicht. In `/config` wählte das Enter von „Weiter“ eine
/// Einstellung (so ging Auto-compact für alle Konten aus). Geprüft mit den
/// Fußzeilen der drei Ansichten, wie `ComposerFieldReading` sie erkennt.
@MainActor
final class ControllerOpenViewSendTests: XCTestCase {
    /// Untere Zeilen der drei Ansichten (Claude Code 2.1.325, wie in
    /// `TypedDraftLiveFieldTests`) und eine gewöhnliche Fußzeile.
    private static let views: [(name: String, lines: [String])] = [
        ("agentList", ["  ❯ Vic · Board und Insel", "  ⏵⏵ auto mode · enter to return · space to reply · ctrl+x to remove"]),
        ("config", ["  ❯ Auto-compact        true", "  Enter/Space to change · / to search · Esc to close"]),
        ("config", ["  ❯ Auto-compact        true", "  Type to filter · Enter/↓ to select · ↑ to tabs · Esc to clear"]),
        ("historySearch", ["  > Weiter mit WM8-12", "  search prompts:   ⏵⏵ auto mode on (shift+tab to cycle)"]),
    ]
    private static let ordinary = ["  ⏵⏵ auto mode on (shift+tab to cycle) · ← for agents", "  ? for shortcuts"]

    private var window = ControllerWindowFake()
    private var center = AgentChatsCommandCenter(keyWindowID: { nil })
    private var terminals = ControllerTerminalSpy()
    private var dispatcher: ControllerActionDispatcher!
    private var haptics: [ControllerHapticPattern] = []
    private var chat = UUID()

    override func setUp() async throws {
        window = ControllerWindowFake()
        center = AgentChatsCommandCenter(keyWindowID: { [unowned self] in window.id })
        _ = center.register(windowID: window.id, handler: window.handler)
        terminals = ControllerTerminalSpy()
        haptics = []
        dispatcher = ControllerActionDispatcher(
            chats: center, terminals: terminals, dictation: ControllerDictationSpy(),
            environment: ControllerEnvironmentSpy(), ui: ControllerUIModel(), island: ControllerIslandSpy())
        dispatcher.playHaptic = { [unowned self] in haptics.append($0) }
        dispatcher.scheduleOnMain = { _, work in work() }
        chat = UUID()
        window.selected = chat
        window.rows = [AgentChatsListRow(row: .chat(chat))]
        terminals.states[chat] = ControllerTerminalState(
            isRunning: true, profile: .claude, status: .idle, statusSince: nil,
            draftSuspected: false, lastEnterAt: nil, lastEscapeAt: nil)
    }

    /// Die Ansicht so, wie die Sendeprüfung sie aus diesen Zeilen abliest.
    private func show(_ lines: [String]) {
        terminals.openViews[chat] = ComposerFieldReading.viewWithoutUsableField(lines)
    }

    private var setup: ControllerMenuSetup {
        var setup = ControllerMenuSetup()
        setup.sessionID = chat
        setup.target = .chat(chat)
        setup.acceptsInput = true
        setup.profile = .claude
        return setup
    }

    private var context: ControllerContext { ControllerContextResolver.context(for: dispatcher.snapshot()) }

    func testTheLinesAreRecognized() {
        for view in Self.views {
            XCTAssertEqual(ComposerFieldReading.viewWithoutUsableField(view.lines), view.name, "\(view.lines)")
        }
        XCTAssertNil(ComposerFieldReading.viewWithoutUsableField(Self.ordinary))
    }

    // MARK: Die drei Aktionen aus dem Befund

    func testContinueWorkStaysOutOfAnOpenView() {
        for view in Self.views {
            show(view.lines)
            dispatcher.perform(.continueWork, setup: setup)
            XCTAssertTrue(terminals.texts.isEmpty, "„Weiter“ in \(view.name)")
            XCTAssertEqual(haptics.last, .rejected)
        }
        show(Self.ordinary)
        dispatcher.perform(.continueWork, setup: setup)
        XCTAssertEqual(terminals.texts.map(\.submit), [true], "ohne Ansicht wie bisher")
    }

    func testSlashCommandsStayOutOfAnOpenView() {
        for view in Self.views {
            show(view.lines)
            dispatcher.sendCommand(ControllerSlashCommand(text: "/model"), setup: setup)
            dispatcher.sendCommand(ControllerSlashCommand(text: "/"), setup: setup)
            XCTAssertTrue(terminals.texts.isEmpty, "Befehl in \(view.name)")
        }
        show(Self.ordinary)
        dispatcher.sendCommand(ControllerSlashCommand(text: "/model"), setup: setup)
        XCTAssertEqual(terminals.texts.map(\.text), ["/model"])
    }

    func testPasteNewestStaysOutOfAnOpenView() {
        dispatcher.clipboard = ControllerClipboardAccess(
            newest: { ControllerClipPreview(id: "t", kind: .text, preview: "hallo") },
            loadText: { _, completion in completion("hallo welt") })
        for view in Self.views {
            show(view.lines)
            dispatcher.perform(.pasteNewest, in: context)
            XCTAssertTrue(terminals.texts.isEmpty, "Einfügen in \(view.name)")
            XCTAssertEqual(haptics.last, .rejected)
        }
        show(Self.ordinary)
        dispatcher.perform(.pasteNewest, in: context)
        XCTAssertEqual(terminals.texts.map(\.text), ["hallo welt"])
    }

    // MARK: Weitere Wege mit Enter

    /// Kreuz und Dreieck im Chat: in den drei neuen Ansichten nichts („Enter/
    /// Space to change“ in `/config`).
    func testCrossAndTriangleStayOutOfTheNewViews() {
        for view in Self.views {
            show(view.lines)
            dispatcher.perform(.chatKey(.enter), in: context)
            dispatcher.perform(.chatKey(.space), in: context)
            dispatcher.perform(.chatKey(.newline), in: context)
            XCTAssertTrue(terminals.keys.isEmpty, "\(terminals.keys) in \(view.name)")
        }
        // Pfeile und Escape bleiben: Damit schließt und bedient man die Ansicht.
        show(Self.views[1].lines)
        dispatcher.perform(.chatKey(.down), in: context)
        dispatcher.perform(.chatKey(.escape), in: context)
        XCTAssertEqual(terminals.keys, [.down, .escape])
    }

    /// In den Ansichten, die der Controller-Leser selbst kennt (etwa die
    /// Auswahl in der Fußzeile), wählt Kreuz weiter aus.
    func testCrossStillSelectsInTheKnownViews() {
        terminals.openViews[chat] = ControllerOpenView.footerSelection.rawValue
        dispatcher.perform(.chatKey(.enter), in: context)
        XCTAssertEqual(terminals.keys, [.enter])
    }

    /// R1 + Kreuz und das Paddle „Jetzt senden / Weiter“.
    func testSendNowOrContinueStaysOutOfAnOpenView() {
        for view in Self.views {
            show(view.lines)
            var withText = setup
            withText.quickCross = .send
            dispatcher.sendOrContinue(setup: withText) {}
            dispatcher.sendOrContinue(setup: setup) {}
            XCTAssertTrue(terminals.keys.isEmpty && terminals.texts.isEmpty, "\(view.name)")
        }
    }

    /// Das verzögerte Enter (Kreuz am arbeitenden Chat) prüft die Ansicht beim
    /// Nachsehen noch einmal.
    func testSettledConfirmChecksTheView() {
        // Die Agent-Liste hält der Controller-Leser für ein leeres Feld.
        terminals.states[chat]?.screen = ControllerScreenSnapshot(
            promptField: ControllerPromptField(rows: 1, cursorRow: 0, cursorAtStart: true, isEmpty: true))
        show(Self.ordinary)
        dispatcher.confirmWhenSettled()
        XCTAssertEqual(terminals.keys, [.enter], "ohne Ansicht wie bisher")
        show(Self.views[0].lines)
        dispatcher.confirmWhenSettled()
        XCTAssertEqual(terminals.keys, [.enter], "in der Agent-Liste kein zweites Enter")
        XCTAssertEqual(haptics.last, .rejected)
    }
}
