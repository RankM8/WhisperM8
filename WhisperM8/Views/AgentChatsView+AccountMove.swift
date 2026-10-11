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
        // Hintergrund-Task-Scan laufender Chats off-main vorwärmen (der erste
        // Durchlauf liest das ganze Transcript), dann synchron entscheiden.
        let runningIDs = sessions.map(\.id).filter { terminalRegistry.controller(for: $0)?.isRunning == true }
        guard !runningIDs.isEmpty else {
            presentAccountMove(sessions, toProfileNamed: targetName)
            return
        }
        Task { @MainActor in
            await ClaudeBackgroundTaskMonitor.shared.prefetch(liveSessionIDs: runningIDs)
            presentAccountMove(sessions, toProfileNamed: targetName)
        }
    }

    private func presentAccountMove(_ sessions: [AgentChatSession], toProfileNamed targetName: String) {
        let target = AccountMovePlanner.normalize(targetName)
        let profiles = ClaudeAccountProfiles()
        let targetIsLoggedIn = target == nil || profiles.profile(named: targetName).isLoggedIn
        let plan = AccountMovePlanner.plan(
            candidates: accountMoveCandidates(for: sessions, target: target),
            targetProfile: target,
            targetIsLoggedIn: targetIsLoggedIn
        )
        // Vorab-Prüfungen nur lesend gegen die `.claude.json` des Ziels:
        // Trust einmal lesen, für alle Chats prüfen (Prototyp P3).
        let trusted = ClaudeAccountPreflight.trustedPaths(claudeJSON: profiles.claudeJSONURL(forProfile: targetName))
        let cwdByID = Dictionary(
            sessions.compactMap { session in
                AccountMoveFacts.cwd(for: session, projects: workspace.projects).map { (session.id, $0) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        let trusts: (UUID) -> Bool = { id in
            cwdByID[id].map { ClaudeAccountPreflight.trustsProject(cwd: $0, trustedPaths: trusted) } ?? true
        }
        let decision = AccountSwitchCoordinator.shared.decide(plan: plan, targetTrustsProject: trusts)
        let startsInTarget = decision.moveNow + decision.switchNow + decision.waitForTurn.map(\.candidate)
        accountMovePhase = .preview
        accountMoveCancelRequested = false
        pendingAccountMove = PendingAccountMove(
            plan: plan,
            decision: decision,
            targetDisplayName: targetName,
            untrustedTitles: (decision.moveNow + decision.switchNow)
                .filter { !trusts($0.sessionID) }
                .map(\.title),
            missingMCPServers: ClaudeAccountPreflight.missingMCPServers(
                sourceProfiles: Set(startsInTarget.map { AccountMovePlanner.normalize($0.currentProfile) }),
                targetProfile: target,
                cwds: Array(Set(startsInTarget.compactMap { cwdByID[$0.sessionID] })),
                profiles: profiles
            )
        )
    }

    // MARK: - Ausfuehrung

    func commitAccountMove(_ pending: PendingAccountMove) {
        let decision = pending.decision
        guard decision.actionableCount > 0 else { return }
        let batchID = UUID()
        let plan = AccountMovePlanner.Plan(
            targetProfile: decision.targetProfile, movable: decision.moveNow, skipped: [])
        let moves = AccountMoveFacts.moves(
            for: plan,
            sessions: workspace.sessions,
            projects: workspace.projects
        ).moves

        accountMovePhase = .running(done: 0, total: moves.count + decision.switchNow.count)
        // Synchron auf dem MainActor: der Store ist MainActor-gebunden, und die
        // Bewegungen sind Dateisystem-Renames innerhalb desselben Volumes.
        // Der Fortschritt wird trotzdem gefuehrt — bei sehr grossen Auswahlen
        // bleibt so sichtbar, wo der Vorgang steht.
        let outcome = AccountMoveService().perform(
            moves,
            batchID: batchID,
            progress: { done, total in
                accountMovePhase = .running(done: done, total: total + decision.switchNow.count)
            },
            shouldCancel: { accountMoveCancelRequested }
        )
        AccountMenuData.invalidateAll()
        guard !outcome.wasCancelled, !decision.switchNow.isEmpty || !decision.waitForTurn.isEmpty else {
            accountMovePhase = .finished(outcome)
            return
        }
        // Laufende Chats: ruhende jetzt anhalten, umziehen und im Tab
        // fortsetzen, arbeitende vormerken — derselbe Journal-Batch, damit
        // „Rückgängig“ die ganze Aktion zurücknimmt.
        var running = decision
        running.moveNow = []
        Task { @MainActor in
            var combined = outcome
            combined.merge(await AccountSwitchCoordinator.shared.execute(
                running, targetName: pending.targetDisplayName, batchID: batchID))
            accountMovePhase = .finished(combined)
            AccountMenuData.invalidateAll()
        }
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
        AccountMenuData.invalidateAll()
    }

    /// `true`, sobald ein zuruecknehmbarer Batch im Journal liegt.
    /// Bewusst die stempel-gecachte Abfrage: dieser Getter haengt im
    /// `.contextMenu`-Builder und laeuft damit bei jedem Body-Rebuild
    /// (CPU-Befund 2026-08-23) — ein voller Journal-Read pro Render waere
    /// genau die Sorte Menue-I/O, die die App dauerhaft beschaeftigt hat.
    ///
    /// Seit 30.09.2026 zusaetzlich ueber `AccountMenuData` (TTL-Cache): auch
    /// der eine `stat` pro Zeile und Render summierte sich im Scope „Alle".
    var hasUndoableAccountMove: Bool {
        AccountMenuData.hasUndoableAccountMove.value
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
            // Ohne Mehrfachauswahl (der Normalfall jeder Zeile) direkt die
            // Session selbst — kein Scan ueber alle Sessions pro Render.
            let sessions = group == [session.id] ? [session] : self.sessions(in: group)
            let currentProfiles = Set(sessions.map { $0.claudeProfileName ?? ClaudeAccountProfiles.mainProfileName })
            let label = sessions.count == 1
                ? "Zu Account verschieben"
                : "\(sessions.count) Chats zu Account verschieben"
            Menu(label, systemImage: "person.crop.circle.badge.checkmark") {
                ForEach(AccountMenuData.claudeProfiles.value) { profile in
                    // Ziel ausblenden, wenn ALLE ausgewaehlten Chats schon dort
                    // sind — bei gemischter Auswahl bleibt es sichtbar.
                    if currentProfiles != [profile.name] {
                        Button(moveTargetLabel(profile)) {
                            requestAccountMove(sessions, toProfileNamed: profile.name)
                        }
                        .disabled(!profile.isLoggedIn)
                    }
                }
                if let pendingSwitch = AccountSwitchCoordinator.shared.pending[session.id] {
                    Divider()
                    Button("Kontowechsel zu \(pendingSwitch.targetName) aufheben", systemImage: "xmark.circle") {
                        AccountSwitchCoordinator.shared.cancel(sessionID: session.id)
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
    /// Wie jeder Chat ins Ziel kommt (sofort, angehalten + fortgesetzt, nach dem Turn).
    let decision: AccountSwitchPlanner.Decision
    let targetDisplayName: String
    /// Chats, die im Ziel beim Start nach Freigabe des Ordners fragen werden.
    var untrustedTitles: [String] = []
    /// User-MCP-Server der Herkunftskonten, die dem Ziel fehlen.
    var missingMCPServers: [String] = []
}
