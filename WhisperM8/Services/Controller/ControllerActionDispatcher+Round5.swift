import Foundation

// Runde 5: Einfügen aus der Zwischenablage (L1 + Kreuz) und Wiederöffnen des
// zuletzt geschlossenen Chats (L2 + Viereck).

extension ControllerActionDispatcher {
    /// L1 + Kreuz: neuesten Eintrag der Zwischenablage in den ausgewählten
    /// Chat. Text kommt wie ein Diktat als ein Block ins Feld (ohne Senden,
    /// auch in Shells); ein Bild wird in die Zwischenablage gelegt und mit
    /// Ctrl+V eingefügt (Claude, Codex). Geht der Chat bis dahin aus der
    /// Auswahl, wird nichts eingefügt.
    func pasteNewest() {
        guard let sessionID = selectedSessionID, let terminal = terminals.state(of: sessionID),
              terminal.isRunning, terminal.status != .awaitingInput,
              let clip = clipboard.newest() else {
            return playHaptic(.rejected)
        }
        let isAgentChat = terminal.profile == .claude || terminal.profile == .codex
        switch clip.kind {
        case .text:
            // Shell: nur an der Eingabezeile und mit Bracketed Paste — sonst
            // käme die Klammer-Folge als Text an oder ein Umbruch führte aus.
            let shellOK = terminal.profile == .shell && terminal.shellAtPrompt && terminal.bracketedPaste
            guard isAgentChat || shellOK else { return playHaptic(.rejected) }
            clipboard.loadText(clip.id) { [weak self] text in
                // Bis der Text geladen ist, kann eine Rückfrage aufgegangen sein.
                guard let self, let text, !text.isEmpty, self.selectedSessionID == sessionID,
                      self.terminals.state(of: sessionID)?.status != .awaitingInput,
                      self.terminals.sendText(text, submit: false, to: sessionID) else {
                    self?.playHaptic(.rejected)
                    return
                }
            }
        case .image:
            guard isAgentChat else { return playHaptic(.rejected) }
            clipboard.copyImage(clip.id) { [weak self] written in
                guard let self, written, self.selectedSessionID == sessionID,
                      self.terminals.state(of: sessionID)?.status != .awaitingInput,
                      self.terminals.sendKey(.imagePaste, to: sessionID) else {
                    self?.playHaptic(.rejected)
                    return
                }
            }
        }
    }

    /// L2 + Viereck: zuletzt geschlossenen Chat dieses App-Starts wieder öffnen
    /// (wie `chats reopen`). Wiederholt geht es weiter zurück. Schließt die
    /// Insel; ohne geschlossenen Chat „geht nicht“, die Insel bleibt.
    func reopenClosedChat() {
        guard spentLayer != .whereTo else { return }
        guard closedChats.reopen() else { return playHaptic(.rejected) }
        spendIsland(.whereTo)
        refreshContext()
    }
}

// MARK: - Kopf-Aktionen im Options-Menü (Runde 5, Punkt 10)

extension ControllerActionDispatcher {
    /// Aktionen aus den Gruppen Chat, Projekt, Workspace und Lebenszyklus: je
    /// ein Befehl an das Fenster, derselbe Weg wie Kopf, Kachel und
    /// Kontextmenü. Geht er nicht (Chat weg, nicht mehr passend), „geht nicht“.
    func performChatAction(_ item: ControllerMenuItem, setup: ControllerMenuSetup) {
        guard let sessionID = setup.sessionID else { return playHaptic(.rejected) }
        let chatCommand: AgentChatsCommand
        switch item {
        case .refreshTitle: chatCommand = .refreshChatTitle(sessionID)
        case .openProject: chatCommand = .openProjectOfChat(sessionID)
        case .revealInFinder: chatCommand = .revealProjectInFinder(sessionID)
        case .toggleTileNote: chatCommand = .toggleTileNote(sessionID)
        case .toggleNotes: chatCommand = .toggleNotes
        case .removeFromWorkspace: chatCommand = .removeChatFromWorkspace(sessionID)
        case .moveToNewWindow: chatCommand = .moveChatToNewWindow(sessionID)
        case .restart: chatCommand = .restartChat(sessionID)
        case .backgroundLogs: chatCommand = .backgroundLogs(sessionID)
        case .backgroundStop: chatCommand = .backgroundStop(sessionID)
        case .backgroundRestart: chatCommand = .backgroundRespawn(sessionID)
        case .stopJob: chatCommand = .stopSubagentJob(sessionID)
        default: return playHaptic(.rejected)
        }
        command(chatCommand, orReject: true)
    }
}

// MARK: - Konto-Menü mit Verbrauch (Runde 5, Punkt 3)

extension ControllerActionDispatcher {
    /// Verbrauch je Konto und „am meisten frei“, aus dem letzten Stand.
    func accountsWithUsage(_ accounts: [ControllerAccountChoice]) -> [ControllerAccountChoice] {
        ControllerAccountHeadroom.marked(accounts.map { account in
            var copy = account
            let limit = accountLimit(account.kind, account.name)
            copy.fiveHourUsed = limit?.fiveHour
            copy.weekUsed = limit?.week
            return copy
        })
    }

    /// Neue Zahlen kamen an: ein offenes Menü zieht nach.
    func accountLimitsChanged() {
        guard let accounts = ui.menu?.setup.chat?.accounts, !accounts.isEmpty else { return }
        ui.menu?.updateAccounts(accountsWithUsage(accounts))
    }
}
