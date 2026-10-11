import Darwin
import Foundation

/// Führt einen Kontowechsel ohne Stoppen aus (Plan
/// `docs/plans/claude-account-switch-ohne-stopp.md`, Slice 2) und hält die
/// Vormerkungen der Chats, die erst nach ihrem Turn wechseln.
///
/// Ablauf je laufendem Chat — dieselbe Kette wie `chats move-account
/// --stop-and-resume`: graceful beenden (2× Ctrl+C, dann SIGTERM), aufs
/// nachweisliche Prozessende warten (erst dann schreibt er nicht mehr in die
/// alte Datei), frisch planen, umziehen (Journal → „Rückgängig" bleibt),
/// Neustart im Tab vormerken. `claude --resume` setzt im Zielkonto fort;
/// Claude zeigt dort selbst den Hinweis, dass früheres Thinking nicht
/// mitkommt (Prototyp P3).
///
/// Vormerkungen sind bewusst flüchtig (E4): nach einem App-Neustart läuft
/// ohnehin kein Turn mehr, der zu Ende gehen könnte.
@MainActor
final class AccountSwitchCoordinator {
    static let shared = AccountSwitchCoordinator()

    struct PendingSwitch: Equatable {
        var targetProfile: String?
        var targetName: String
        var reason: AccountSwitchPlanner.WaitReason
    }

    /// Alles, was die Kette von außen braucht — als Closures, damit Tests ohne
    /// Terminals, Prozesse und Produktionsdaten auskommen.
    struct Dependencies {
        var isRunning: (UUID) -> Bool
        var processID: (UUID) -> pid_t?
        /// Graceful beenden (gemeinsam, eine Wartezeit für alle) und den
        /// Store-Status von `running` auf `closed` setzen.
        var terminate: ([UUID]) -> Void
        var waitForExit: @Sendable (pid_t) async -> Bool
        var status: (UUID) -> AgentSessionRuntimeStatus?
        var mayHaveUnsentInput: (UUID) -> Bool
        /// Offene Hintergrund-Tasks des laufenden Prozesses (Transcript).
        var openBackgroundTasks: (UUID) -> Int
        var workspace: () -> AgentWorkspace
        /// Fakten sammeln + `AccountMovePlanner` (inkl. Login-Prüfung des Ziels).
        var plan: (_ sessions: [AgentChatSession], _ projects: [AgentProject], _ targetName: String) -> AccountMovePlanner.Plan
        var perform: (_ moves: [AccountMoveService.Move], _ batchID: UUID) -> AccountMoveService.Outcome
        /// `shouldLaunchOnOpen` + Tab sicherstellen — Start beim Anzeigen.
        var scheduleResume: (UUID) -> Void
        var isEnabled: () -> Bool
    }

    private let dependencies: Dependencies
    private(set) var pending: [UUID: PendingSwitch] = [:]
    /// Chats, deren Wechsel gerade läuft — gegen doppeltes Anstoßen.
    private var inFlight: Set<UUID> = []
    private var recheckTimer: Timer?
    /// Wird nach jeder Änderung an `pending` gerufen (Anzeige, Menüs).
    var onPendingChanged: (() -> Void)?

    init(dependencies: Dependencies? = nil) {
        self.dependencies = dependencies ?? .live
    }

    var isEnabled: Bool { dependencies.isEnabled() }

    // MARK: - Entscheiden

    /// Entscheidung für eine Auswahl. Bei abgeschaltetem Feature bleibt es beim
    /// alten Verhalten: laufende Chats werden übersprungen.
    func decide(
        plan: AccountMovePlanner.Plan,
        isCaller: (UUID) -> Bool = { _ in false },
        targetTrustsProject: (UUID) -> Bool
    ) -> AccountSwitchPlanner.Decision {
        guard isEnabled else {
            return AccountSwitchPlanner.Decision(
                targetProfile: plan.targetProfile, moveNow: plan.movable, skipped: plan.skipped)
        }
        return AccountSwitchPlanner.decide(
            plan: plan,
            isCaller: isCaller,
            status: dependencies.status,
            mayHaveUnsentInput: dependencies.mayHaveUnsentInput,
            openBackgroundTasks: dependencies.openBackgroundTasks,
            targetTrustsProject: targetTrustsProject
        )
    }

    // MARK: - Ausführen

    /// Führt eine Entscheidung aus: Ruhendes sofort, Beschäftigtes vormerken.
    /// Alle sofortigen Bewegungen landen in EINEM Journal-Batch, damit
    /// „Rückgängig" die ganze Aktion zurücknimmt.
    func execute(
        _ decision: AccountSwitchPlanner.Decision,
        targetName: String,
        batchID: UUID = UUID()
    ) async -> AccountMoveService.Outcome {
        var outcome = AccountMoveService.Outcome()
        if !decision.moveNow.isEmpty {
            let workspace = dependencies.workspace()
            let plan = AccountMovePlanner.Plan(
                targetProfile: decision.targetProfile, movable: decision.moveNow, skipped: [])
            let built = AccountMoveFacts.moves(for: plan, sessions: workspace.sessions, projects: workspace.projects)
            outcome.merge(dependencies.perform(built.moves, batchID))
            outcome.failed += built.unresolved.map { ($0.title, "Projektpfad unbekannt") }
        }
        for (candidate, reason) in decision.waitForTurn {
            pending[candidate.sessionID] = PendingSwitch(
                targetProfile: decision.targetProfile, targetName: targetName, reason: reason)
        }
        if !decision.waitForTurn.isEmpty {
            Logger.agentStore.info(
                "account_switch_scheduled count=\(decision.waitForTurn.count) target=\(targetName, privacy: .public)")
            pendingDidChange()
        }
        if !decision.switchNow.isEmpty {
            outcome.merge(await switchRunning(
                decision.switchNow.map(\.sessionID), targetName: targetName, batchID: batchID))
        }
        return outcome
    }

    /// Direkt vormerken (CLI `move-account --stop-and-resume` für Chats, die
    /// gerade arbeiten) — die Entscheidung hat der Aufrufer schon getroffen.
    func schedule(
        _ entries: [(sessionID: UUID, reason: AccountSwitchPlanner.WaitReason)],
        targetProfile: String?,
        targetName: String
    ) {
        guard !entries.isEmpty else { return }
        for entry in entries {
            pending[entry.sessionID] = PendingSwitch(
                targetProfile: targetProfile, targetName: targetName, reason: entry.reason)
        }
        Logger.agentStore.info(
            "account_switch_scheduled count=\(entries.count) target=\(targetName, privacy: .public)")
        pendingDidChange()
    }

    /// Vormerkung zurücknehmen (Kontextmenü).
    func cancel(sessionID: UUID) {
        guard pending.removeValue(forKey: sessionID) != nil else { return }
        Logger.agentStore.info("account_switch_cancelled session=\(sessionID.uuidString, privacy: .public)")
        pendingDidChange()
    }

    /// Prüft alle Vormerkungen: wer jetzt ruht, wechselt. Läuft per Timer,
    /// solange es Vormerkungen gibt; Tests rufen es direkt.
    func recheckPending() async {
        guard !pending.isEmpty else { return }
        let workspace = dependencies.workspace()
        var ready: [String: [UUID]] = [:]
        var endedOnTheirOwn: [String: [UUID]] = [:]
        for (id, entry) in pending where !inFlight.contains(id) {
            guard let session = workspace.sessions.first(where: { $0.id == id }),
                  session.status != .archived else {
                pending.removeValue(forKey: id)  // geschlossen und archiviert/gelöscht
                continue
            }
            if !dependencies.isRunning(id) {
                // Selbst beendet, während er vorgemerkt war: nur umziehen, nicht
                // neu starten — gestoppt hat ihn der User.
                endedOnTheirOwn[entry.targetName, default: []].append(id)
                pending.removeValue(forKey: id)
            } else if let reason = AccountSwitchPlanner.waitReason(
                status: dependencies.status(id),
                mayHaveUnsentInput: dependencies.mayHaveUnsentInput(id),
                openBackgroundTasks: dependencies.openBackgroundTasks(id)
            ) {
                pending[id]?.reason = reason
            } else {
                ready[entry.targetName, default: []].append(id)
                pending.removeValue(forKey: id)
            }
        }
        pendingDidChange()
        for (targetName, ids) in endedOnTheirOwn {
            _ = moveStopped(ids, targetName: targetName, batchID: UUID())
        }
        for (targetName, ids) in ready {
            Logger.agentStore.info(
                "account_switch_after_turn count=\(ids.count) target=\(targetName, privacy: .public)")
            _ = await switchRunning(ids, targetName: targetName, batchID: UUID())
        }
    }

    // MARK: - Kette

    /// Anhalten → Prozessende abwarten → frisch planen und umziehen → Neustart
    /// vormerken. Neu gestartet werden ALLE beendeten Chats, auch wenn ihr
    /// Umzug scheiterte — dann im bisherigen Konto, gelaufen sind sie vorher auch.
    private func switchRunning(_ ids: [UUID], targetName: String, batchID: UUID) async -> AccountMoveService.Outcome {
        let ids = ids.filter { !inFlight.contains($0) }
        guard !ids.isEmpty else { return AccountMoveService.Outcome() }
        inFlight.formUnion(ids)
        defer { inFlight.subtract(ids) }

        // PIDs VOR dem Anhalten sichern — danach ist der Controller weg.
        let stopped: [(id: UUID, pid: pid_t?)] = ids.map { ($0, dependencies.processID($0)) }
        dependencies.terminate(ids)

        let waitForExit = dependencies.waitForExit
        let exited: Set<UUID> = await withTaskGroup(of: UUID?.self) { group in
            for entry in stopped {
                guard let pid = entry.pid else { continue }
                let id = entry.id
                group.addTask { await waitForExit(pid) ? id : nil }
            }
            var exited: Set<UUID> = []
            for await id in group {
                if let id { exited.insert(id) }
            }
            return exited
        }

        var outcome = moveStopped(ids.filter { exited.contains($0) }, targetName: targetName, batchID: batchID)
        let titles = Dictionary(
            dependencies.workspace().sessions.map { ($0.id, $0.title) },
            uniquingKeysWith: { first, _ in first })
        for entry in stopped where !exited.contains(entry.id) {
            outcome.failed.append((titles[entry.id] ?? entry.id.uuidString,
                                   "angehalten, aber der Prozess hat sich nicht beendet — nicht umgezogen, nicht neu gestartet"))
            Logger.agentStore.warning(
                "account_switch_stop_timeout session=\(entry.id.uuidString, privacy: .public)")
        }
        for id in ids where exited.contains(id) {
            dependencies.scheduleResume(id)
        }
        return outcome
    }

    /// Umzug für Chats, deren Prozess nicht (mehr) läuft — frisch geplant, weil
    /// zwischen Entscheidung und hier Zeit vergangen ist.
    private func moveStopped(_ ids: [UUID], targetName: String, batchID: UUID) -> AccountMoveService.Outcome {
        guard !ids.isEmpty else { return AccountMoveService.Outcome() }
        let workspace = dependencies.workspace()
        let sessions = workspace.sessions.filter { ids.contains($0.id) }
        let plan = dependencies.plan(sessions, workspace.projects, targetName)
        let built = AccountMoveFacts.moves(for: plan, sessions: sessions, projects: workspace.projects)
        var outcome = dependencies.perform(built.moves, batchID)
        outcome.failed += built.unresolved.map { ($0.title, "Projektpfad unbekannt") }
        outcome.failed += plan.skipped.map { ($0.candidate.title, $0.reason.label) }
        return outcome
    }

    private func pendingDidChange() {
        onPendingChanged?()
        if pending.isEmpty {
            recheckTimer?.invalidate()
            recheckTimer = nil
        } else if recheckTimer == nil {
            // Nur In-Memory-Lookups je Vormerkung — 2 s sind reaktionsschnell
            // genug und kosten nichts, solange niemand vorgemerkt ist.
            recheckTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                Task { @MainActor in await self?.recheckPending() }
            }
        }
    }
}

extension AccountMoveService.Outcome {
    mutating func merge(_ other: AccountMoveService.Outcome) {
        moved += other.moved
        failed += other.failed
        wasCancelled = wasCancelled || other.wasCancelled
        skippedRunning += other.skippedRunning
    }
}

extension AccountSwitchCoordinator.Dependencies {
    @MainActor static var live: Self {
        Self(
            isRunning: { AgentTerminalRegistry.shared.controller(for: $0)?.isRunning == true },
            processID: { AgentTerminalRegistry.shared.controller(for: $0)?.processID },
            terminate: { ids in
                AgentTerminalRegistry.shared.terminate(sessionIDs: ids)
                let store = AgentSessionStore()
                for id in ids {
                    try? store.updateSession(id: id) { updated in
                        if updated.status == .running { updated.status = .closed }
                    }
                }
            },
            waitForExit: { pid in await ProcessExitWaiter.waitForExit(pid: pid) },
            status: { AgentSessionStatusCoordinator.shared.statusStore.status(for: $0) },
            mayHaveUnsentInput: {
                AgentTerminalRegistry.shared.controller(for: $0)?.composerDraft.mayHaveUnsentInput == true
            },
            openBackgroundTasks: { ClaudeBackgroundTaskMonitor.shared.openTaskCount(liveSessionID: $0) },
            workspace: { AgentWorkspaceUIModel.shared.workspace },
            plan: { sessions, projects, targetName in
                let profiles = ClaudeAccountProfiles()
                let target = AccountMovePlanner.normalize(targetName)
                return AccountMovePlanner.plan(
                    candidates: AccountMoveFacts.candidates(
                        for: sessions, projects: projects, target: target, profiles: profiles,
                        isRunning: { AgentTerminalRegistry.shared.controller(for: $0)?.isRunning == true }),
                    targetProfile: target,
                    targetIsLoggedIn: target == nil || profiles.profile(named: targetName).isLoggedIn
                )
            },
            perform: { moves, batchID in
                let outcome = AccountMoveService().perform(moves, batchID: batchID)
                AccountMenuData.invalidateAll()
                return outcome
            },
            scheduleResume: { id in
                do {
                    try AgentSessionStore().updateSession(id: id) { $0.shouldLaunchOnOpen = true }
                    let windows = AgentWindowStore.shared
                    if windows.windowID(containingTab: id) == nil {
                        windows.openTab(id, in: windows.primaryWindowID, select: false)
                    }
                } catch {
                    Logger.agentStore.warning(
                        "account_switch_resume_flag_failed session=\(id.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                }
            },
            isEnabled: { AppPreferences.shared.isAccountSwitchAfterTurnEnabled }
        )
    }
}
