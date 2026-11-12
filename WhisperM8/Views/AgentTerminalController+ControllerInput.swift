import AppKit
import Foundation

// Eingaben des Controllers ins Eingabefeld, die über einzelne Tasten
// (`sendKey`) hinausgehen, und die Merker der Schutzregeln
// (`ControllerTerminalMarks`). Ausgelagert, damit AgentTerminalView.swift
// unter der Größengrenze bleibt.

extension AgentTerminalController {
    /// Absicherung des Controller-Wegs mit Profil und offener Auswahl dieses
    /// Chats (`TerminalControlKey.controllerAllows`).
    func controllerAllows(_ key: TerminalControlKey, status: AgentSessionRuntimeStatus?, now: Date) -> Bool {
        TerminalControlKey.controllerAllows(
            key, status: status, profile: command.keyboardProfile,
            choiceListOpen: controllerChoiceListOpen(status: status, at: now),
            composerMayHaveText: composerDraft.mayHaveUnsentInput)
    }

    /// Ist eine Auswahlliste, die das Controller-Menü geöffnet hat, vermutlich
    /// noch offen? Bei Claude nur im Ruhezustand; sonst wird der Merker
    /// gelöscht (`ControllerTerminalMarks.checkedChoiceListOpen`).
    func controllerChoiceListOpen(status: AgentSessionRuntimeStatus?, at now: Date = Date()) -> Bool {
        controllerMarks.checkedChoiceListOpen(
            at: now, status: status, isClaude: command.keyboardProfile == .claudeCodeChat)
    }

    /// Merker „Auswahl offen“ setzen — bei Claude nur, wenn der Chat ruht.
    func noteControllerChoiceListOpened(status: AgentSessionRuntimeStatus?, at now: Date = Date()) {
        guard command.keyboardProfile != .claudeCodeChat || status == .idle else { return }
        controllerMarks.choiceListOpened(at: now)
    }

    /// Controller hat etwas ins Eingabefeld geschrieben oder daraus gelöscht
    /// (Text oder Diktat, mit oder ohne Senden). Kreuz darf bei arbeitendem
    /// Chat nur nach einer solchen Eingabe Enter schicken (`confirmAllowed`).
    func noteControllerDraftInput(submitted: Bool, now: Date = Date()) {
        controllerMarks.recordDraftInput(submitted: submitted, at: now)
    }

    /// Merker nach einer Taste vom Controller (aus `sendKey`, nach der
    /// Absicherung); Regeln in `ControllerTerminalMarks.recordControllerKey`.
    func noteControllerKey(_ key: TerminalControlKey, status: AgentSessionRuntimeStatus?, now: Date) {
        controllerMarks.recordControllerKey(
            key, status: status, isCodex: command.keyboardProfile == .codexChat, at: now)
    }

    /// Taste der echten Tastatur an dieses Terminal: Enter zählt als Absenden
    /// (hebt eine frische Controller-Eingabe auf, Befund 5 nach Runde 3),
    /// Enter und Escape schließen eine Auswahl des Menüs.
    func noteKeyboardKeyForController(_ event: NSEvent, now: Date = Date()) {
        controllerMarks.recordKeyboard(keyCode: event.keyCode, modifiers: event.modifierFlags, at: now)
    }

    /// R3 halten: ganze Eingabe leeren (`TerminalControlKey.clearInputBursts`),
    /// in Stößen alle 15 ms über den Main-Run-Loop, ohne zu blockieren. Nicht
    /// in einer Rückfrage; in einer Shell nur an der Eingabezeile
    /// (`TerminalControlKey.controllerMayClearInput`). Der Entwurfs-Tracker
    /// gilt danach als leer.
    /// - Returns: `false`, wenn kein Prozess läuft, eine Rückfrage offen ist
    ///   oder in der Shell ein Vollbild-Programm läuft.
    @discardableResult
    func clearInputFromController() -> Bool {
        guard isRunning else { return false }
        let status = AgentSessionStatusCoordinator.shared.statusStore.status(for: sessionID)
        let now = Date()
        guard TerminalControlKey.controllerMayClearInput(
            status: status, profile: command.keyboardProfile,
            alternateBuffer: terminal.getTerminal().isCurrentBufferAlternate,
            choiceListOpen: controllerChoiceListOpen(status: status, at: now)
        ) else { return false }
        noteComposerCleared()
        controllerMarks.lastDraftInputAt = nil
        controllerMarks.choiceListClosed()
        for (index, burst) in TerminalControlKey.clearInputBursts.enumerated() {
            let bytes = burst.flatMap { $0.bytes(applicationCursor: false) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.015 * Double(index)) { [weak self] in
                guard let self, self.isRunning else { return }
                self.terminal.send(bytes)
            }
        }
        return true
    }
}
