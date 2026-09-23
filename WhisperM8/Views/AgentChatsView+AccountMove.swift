import SwiftUI

/// Konto-Umzug bestehender Chats (Slice 6): Vorschau bauen, Sheet fuehren,
/// Ausfuehrung anstossen, Rueckgaengig. Die Entscheidungslogik liegt pur im
/// `AccountMovePlanner`, die Ausfuehrung im `AccountMoveService` — hier bleibt
/// nur die Verdrahtung mit dem View-State.
extension AgentChatsView {
    // MARK: - Vorschau

    /// Sammelt die Fakten fuer den Planer — derselbe Baustein wie
    /// `whisperm8 chats move-account`, damit GUI und CLI gleich entscheiden.
    func accountMoveCandidates(for sessions: [AgentChatSession], target: String?) -> [AccountMovePlanner.Candidate] {
        AccountMoveFacts.candidates(
            for: sessions,
            projects: workspace.projects,
            target: target,
            isRunning: { terminalRegistry.controller(for: $0)?.isRunning == true }
        )
    }

    /// Einstieg aus dem Kontextmenue — fuer einen Chat wie fuer eine Auswahl
    /// derselbe Weg. Oeffnet immer die Vorschau; auch ein Einzel-Umzug hat
    /// Nebenwirkungen, die benannt gehoeren.
    func requestAccountMove(_ sessions: [AgentChatSession], toProfileNamed targetName: String) {
        guard !sessions.isEmpty else { return }
        let target = AccountMovePlanner.normalize(targetName)
        let profiles = ClaudeAccountProfiles()
        let targetIsLoggedIn = target == nil || profiles.profile(named: targetName).isLoggedIn
        let plan = AccountMovePlanner.plan(
            candidates: accountMoveCandidates(for: sessions, target: target),
            targetProfile: target,
            targetIsLoggedIn: targetIsLoggedIn
        )
        accountMovePhase = .preview
        accountMoveCancelRequested = false
        pendingAccountMove = PendingAccountMove(plan: plan, targetDisplayName: targetName)
    }

    // MARK: - Ausfuehrung

    func commitAccountMove(_ pending: PendingAccountMove) {
        let plan = pending.plan
        guard !plan.movable.isEmpty else { return }
        let moves = AccountMoveFacts.moves(
            for: plan,
            sessions: workspace.sessions,
            projects: workspace.projects
        ).moves
        guard !moves.isEmpty else { return }

        accountMovePhase = .running(done: 0, total: moves.count)
        // Synchron auf dem MainActor: der Store ist MainActor-gebunden, und die
        // Bewegungen sind Dateisystem-Renames innerhalb desselben Volumes.
        // Der Fortschritt wird trotzdem gefuehrt — bei sehr grossen Auswahlen
        // bleibt so sichtbar, wo der Vorgang steht.
        let outcome = AccountMoveService().perform(
            moves,
            progress: { done, total in
                accountMovePhase = .running(done: done, total: total)
            },
            shouldCancel: { accountMoveCancelRequested }
        )
        accountMovePhase = .finished(outcome)
    }

    /// Nimmt den zuletzt protokollierten Umzug zurueck.
    func undoLastAccountMove() {
        let sessionsByID = Dictionary(
            workspace.sessions.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let projectsByID = Dictionary(
            workspace.projects.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let outcome = AccountMoveService().undoLastBatch(
            isRunning: { terminalRegistry.controller(for: $0)?.isRunning == true },
            cwdResolver: { id in
                guard let session = sessionsByID[id] else { return nil }
                return session.subagentCwd ?? projectsByID[session.projectID]?.path
            },
            externalIDResolver: { sessionsByID[$0]?.externalSessionID }
        )
        if !outcome.skippedRunning.isEmpty {
            // Auch ohne offenes Sheet sichtbar (Rueckgaengig aus dem Kontextmenue).
            errorMessage = "Nicht zurückgenommen, weil gerade laufend: "
                + outcome.skippedRunning.joined(separator: ", ")
                + " — Chat anhalten und „Letzten Kontowechsel rückgängig machen“ erneut wählen."
        } else if outcome.moved.isEmpty, outcome.failed.isEmpty {
            errorMessage = "Es gibt keinen Kontowechsel, der zurückgenommen werden könnte."
        }
        accountMovePhase = .finished(outcome)
    }

    /// `true`, sobald ein zuruecknehmbarer Batch im Journal liegt.
    /// Bewusst die stempel-gecachte Abfrage: dieser Getter haengt im
    /// `.contextMenu`-Builder und laeuft damit bei jedem Body-Rebuild
    /// (CPU-Befund 2026-08-23) — ein voller Journal-Read pro Render waere
    /// genau die Sorte Menue-I/O, die die App dauerhaft beschaeftigt hat.
    var hasUndoableAccountMove: Bool {
        AccountMoveJournal().hasUndoableBatch()
    }

    // MARK: - Menue

    /// Untermenue „Zu Account verschieben" — fuer einen Chat wie fuer eine
    /// Auswahl. Anders als frueher ist der Eintrag auch bei laufenden Chats
    /// sichtbar: die Vorschau erklaert dann, warum sie uebersprungen werden,
    /// statt den Eintrag wortlos zu sperren.
    @ViewBuilder
    func moveToAccountMenu(_ session: AgentChatSession) -> some View {
        if canMoveToAccount(session) {
            let group = AppPreferences.shared.isAccountBulkMoveEnabled
                ? actionGroup(for: session)
                : [session.id]
            let sessions = workspace.sessions.filter { group.contains($0.id) }
            let currentProfiles = Set(sessions.map { $0.claudeProfileName ?? ClaudeAccountProfiles.mainProfileName })
            let label = sessions.count == 1
                ? "Zu Account verschieben"
                : "\(sessions.count) Chats zu Account verschieben"
            Menu(label, systemImage: "person.crop.circle.badge.checkmark") {
                ForEach(ClaudeAccountProfiles().profiles()) { profile in
                    // Ziel ausblenden, wenn ALLE ausgewaehlten Chats schon dort
                    // sind — bei gemischter Auswahl bleibt es sichtbar.
                    if currentProfiles != [profile.name] {
                        Button(moveTargetLabel(profile)) {
                            requestAccountMove(sessions, toProfileNamed: profile.name)
                        }
                        .disabled(!profile.isLoggedIn)
                    }
                }
                if hasUndoableAccountMove {
                    Divider()
                    Button("Letzten Kontowechsel rückgängig machen", systemImage: "arrow.uturn.backward") {
                        undoLastAccountMove()
                    }
                }
            }
        }
    }
}

/// State-Snapshot des Umzugs-Sheets.
struct PendingAccountMove: Identifiable, Equatable {
    let id = UUID()
    let plan: AccountMovePlanner.Plan
    let targetDisplayName: String
}
