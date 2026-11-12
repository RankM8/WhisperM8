import SwiftUI

/// Aktionen am Chat für den Controller (Options-Menü, Kreuz und R3 auf einem
/// gestoppten Chat): Angaben über einen Chat und das Starten. Alles ruft
/// dieselben Funktionen wie das Kontextmenü und der Kopf des Chats.
extension AgentChatsView {
    /// Kopf der Einzelansicht mit Anker für die Menü-Karte des Controllers
    /// (sie hängt rechts darunter, `ControllerMenuCard.swift`).
    var anchoredChatStatusRow: some View {
        activeChatStatusRow
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .controllerMenuAnchor(.header, sessionID: selectedSessionID)
    }

    /// Angaben für das Menü. Nur im Ereignis-Pfad aufrufen: Die Kontenlisten
    /// kommen aus dem kurzlebigen Cache des Kontextmenüs.
    func controllerChatActionInfo(for sessionID: UUID) -> ControllerChatActionInfo? {
        guard let session = workspace.sessions.first(where: { $0.id == sessionID }) else { return nil }
        // Dieselben Ziele wie im Kontextmenü: „Zu Account verschieben“ für
        // Claude-Chats, „GPT-Konto“ zusätzlich bei aktivem GPT-Backend.
        var accounts: [ControllerAccountChoice] = []
        if canMoveToAccount(session) {
            let current = session.claudeProfileName ?? ClaudeAccountProfiles.mainProfileName
            accounts += AccountMenuData.claudeProfiles.value.map { profile in
                ControllerAccountChoice(
                    kind: .claude, name: profile.name, label: moveTargetLabel(profile),
                    isCurrent: profile.name == current, isLoggedIn: profile.isLoggedIn)
            }
        }
        if canSwitchGPTAccount(session) {
            let current = session.gptProfileName ?? GPTAccountProfiles.mainProfileName
            accounts += AccountMenuData.gptProfiles.value.map { profile in
                ControllerAccountChoice(
                    kind: .gpt, name: profile.name, label: gptAccountLabel(profile),
                    isCurrent: profile.name == current, isLoggedIn: profile.isLoggedIn)
            }
        }
        var info = ControllerChatActionInfo(
            title: session.title,
            isPinned: pinnedSessionIDs.contains(session.id),
            isArchived: session.status == .archived,
            isTerminal: session.isTerminal,
            canFork: session.isForkable,
            accounts: accounts
        )
        addControllerHeadActions(to: &info, session: session)
        return info
    }

    /// Startet einen gestoppten Chat — derselbe Weg wie der Knopf „Starten“
    /// im Kopf (`sessionActionRequest`; die Detail-Ansicht des Chats führt es
    /// aus). Nicht für archivierte und laufende Chats und nicht für
    /// Subagent-Jobs ohne Übernahme (die haben eigene Knöpfe). Ist der Chat
    /// nicht ausgewählt (R3 auf einer Zeile der Liste), wird er zuerst
    /// ausgewählt und die Anfrage kurz danach gestellt, wenn seine Ansicht
    /// steht — sonst sähe sie die Anfrage nie.
    func startChatFromCommand(_ sessionID: UUID) -> Bool {
        guard let session = workspace.sessions.first(where: { $0.id == sessionID }),
              session.status != .archived,
              !session.isSubagentJob || jobRuntimeModel.isTakenOver(session.id),
              terminalRegistry.controller(for: sessionID)?.isRunning != true else { return false }
        let request = AgentSessionActionRequest(sessionID: sessionID, kind: .start)
        guard selectedSessionID != sessionID else {
            sessionActionRequest = request
            return true
        }
        selectedSessionID = sessionID
        multiSelection = []
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            sessionActionRequest = request
        }
        return true
    }
}
