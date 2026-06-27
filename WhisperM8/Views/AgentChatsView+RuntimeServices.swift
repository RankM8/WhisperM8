import SwiftUI
import AppKit

/// Laufzeit-/Daten-Dienste der AgentChatsView: Workspace-Load, Index-Refresh,
/// Runtime-Watcher/AutoNamer/Hook-Bridge-Setup, Selektions-Reconcile und der
/// Agent-Stop-Sound. Aus AgentChatsView.swift ausgelagert (Phase-2-Split).
extension AgentChatsView {
    func refresh() {
        loadWorkspaceFast()
        AgentScanCoordinator.shared.requestScan(reason: .manual)
    }

    /// Lazy-init der Runtime-Services. Wird einmal beim ersten `onAppear`
    /// aufgerufen — verträgt aber Re-Calls, weil sie sich mit `nil`-Check
    /// schützen. Wir können das nicht im `init()` machen, weil
    /// `runtimeStatusStore` ein `@StateObject` ist und vor `body` noch nicht
    /// instanziiert ist.
    func setupRuntimeServicesIfNeeded() {
        if autoNamer == nil {
            autoNamer = AgentSessionAutoNamer(store: store)
        }
        if runtimeWatcher == nil {
            let store = self.store
            let statusStore = runtimeStatusStore
            let watcher = AgentSessionRuntimeWatcher(statusStore: statusStore) { [weak autoNamer] sessionID in
                AgentChatsView.handleTurnFinished(
                    sessionID: sessionID,
                    store: store,
                    autoNamer: autoNamer
                ) {
                    // Wir können hier kein `self` capturen (wäre stale beim
                    // mehrfachen Watcher-Init); der Workspace-Reload passiert
                    // beim nächsten `loadWorkspaceFast`-Tick (Indexer-Refresh
                    // bzw. UI-Reload).
                }
            }
            runtimeWatcher = watcher
        }
        if claudeHookBridge == nil {
            let store = self.store
            let registry = terminalRegistry
            let bridge = ClaudeHookBridge()
            bridge.setDecisionHandler { localID, event in
                AgentChatsView.handleClaudeHookEvent(
                    localID: localID,
                    event: event,
                    store: store,
                    terminalRegistry: registry
                )
            }
            claudeHookBridge = bridge
        }
    }

    /// Notification fuer den ambiguous-rebind-Picker (Phase 6).
    static let ambiguousRebindNotification = Notification.Name("AgentChatsView.ambiguousRebind")
    /// Wird vom Hook-Bridge-Handler bei `Notification`-Events gepostet —
    /// die View fuegt die `localID` aus `userInfo["localID"]` in
    /// `awaitingInputSessionIDs` ein.
    static let backgroundNeedsInputNotification = Notification.Name("AgentChatsView.backgroundNeedsInput")
    /// Pendant zum oberen — entfernt die localID wieder (z. B. nach
    /// `.preToolUse` oder `.sessionEnd`).
    static let backgroundNeedsInputClearedNotification = Notification.Name("AgentChatsView.backgroundNeedsInputCleared")
    /// Gepostet vom `Stop`-Hook — die View setzt die Session sofort auf `.idle`
    /// (zuverlaessiger als der Transkript-Poll) und spielt optional den
    /// Fertig-Ton.
    static let agentDidStopNotification = Notification.Name("AgentChatsView.agentDidStop")

    /// Verarbeitet die User-Wahl im Ambiguous-Picker. `externalID == nil`
    /// bedeutet "Neue Session starten" — wir nullen die externe ID und
    /// markieren die Session als nicht gelauncht, damit der naechste
    /// Resume-Klick einen frischen Claude-Lauf startet.
    func applyAmbiguousRebindChoice(request: AmbiguousRebindRequest, externalID: String?) {
        do {
            try store.updateSession(id: request.localSessionID) { session in
                let old = session.externalSessionID
                session.externalSessionID = externalID
                if externalID == nil {
                    session.hasLaunchedInitialPrompt = false
                }
                Logger.claudeRecovery.info("recovery_user_chose localID=\(request.localSessionID.uuidString, privacy: .public) old=\(old ?? "nil", privacy: .public) new=\(externalID ?? "nil", privacy: .public)")
            }
            Task { @MainActor in
                terminalRegistry.controller(for: request.localSessionID)?
                    .updateExternalSessionID(externalID)
            }
            loadWorkspaceFast()
        } catch {
            Logger.claudeRecovery.warning("recovery_user_chose_failed localID=\(request.localSessionID.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }

    /// Hook-Event-Handler: bei `SessionStart` mit nicht-leerer `session_id`
    /// updaten wir die externalSessionID; bei `SessionEnd(reason: "resume")`
    /// machen wir uns mental "darauf bereit, dass eine neue ID kommt" —
    /// behalten aber die alte ID bis das naechste SessionStart-Event kommt.
    private static func handleClaudeHookEvent(
        localID: UUID,
        event: ClaudeHookEvent,
        store: AgentSessionStore,
        terminalRegistry: AgentTerminalRegistry
    ) {
        switch event.hookEventName {
        case .sessionStart:
            guard let newID = event.sessionID, !newID.isEmpty else { return }
            do {
                try store.updateSession(id: localID) { session in
                    let old = session.externalSessionID
                    guard old != newID else { return }
                    session.externalSessionID = newID
                    Logger.claudeBinding.info("binding_launch_id_set localID=\(localID.uuidString, privacy: .public) old=\(old ?? "nil", privacy: .public) new=\(newID, privacy: .public)")
                }
                Task { @MainActor in
                    terminalRegistry.controller(for: localID)?.updateExternalSessionID(newID)
                }
            } catch {
                Logger.claudeBinding.warning("binding_launch_set_failed localID=\(localID.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            }
        case .sessionEnd:
            // /resume-Wechsel ist erwartet — naechstes SessionStart wird die
            // neue ID liefern. Nichts tun ausser Logging. Ein eventueller
            // "Needs input"-Pulse wird vom Notification-Listener selbst
            // bei .preToolUse / SessionStart geclearet — beim Ende ist die
            // Session ohnehin nicht mehr "awaiting".
            let reason = event.reason ?? "unknown"
            Logger.claudeBinding.info("binding_session_end localID=\(localID.uuidString, privacy: .public) reason=\(reason, privacy: .public)")
            NotificationCenter.default.post(
                name: AgentChatsView.backgroundNeedsInputClearedNotification,
                object: nil,
                userInfo: ["localID": localID]
            )
        case .userPromptSubmit, .preToolUse, .postToolUse:
            // Aktivitaet: User hat einen Prompt geschickt, oder ein Tool
            // startet/ist fertig → die Session arbeitet, ein "Needs input"-
            // Pulse ist veraltet. Wir clearen ihn; der naechste Notification-
            // Event setzt ihn bei Bedarf erneut.
            Logger.claudeBinding.debug("binding_activity localID=\(localID.uuidString, privacy: .public) event=\(event.hookEventName.rawValue, privacy: .public)")
            NotificationCenter.default.post(
                name: AgentChatsView.backgroundNeedsInputClearedNotification,
                object: nil,
                userInfo: ["localID": localID]
            )
        case .stop:
            // Turn fertig → zuverlaessiges "idle" (auch fuer Background-Agents
            // ohne aussagekraeftiges Transkript) + optionaler Ton. Ein
            // eventueller "Needs input"-Pulse ist hinfaellig.
            Logger.claudeBinding.info("binding_stop localID=\(localID.uuidString, privacy: .public)")
            NotificationCenter.default.post(
                name: AgentChatsView.backgroundNeedsInputClearedNotification,
                object: nil,
                userInfo: ["localID": localID]
            )
            NotificationCenter.default.post(
                name: AgentChatsView.agentDidStopNotification,
                object: nil,
                userInfo: ["localID": localID]
            )
        case .permissionRequest:
            // Echte Erlaubnis-Anfrage (Permission-Dialog) → "braucht Handlung".
            // Claudes dedizierter Hook, feuert NUR beim echten Dialog — die
            // saubere awaiting-Quelle statt des frueheren Notification-Hooks
            // (der auch idle_prompts schickte und fertige Chats faelschlich
            // markierte). Clear erfolgt ueber PostToolUse/Stop.
            Logger.claudeBinding.info("binding_permission_request localID=\(localID.uuidString, privacy: .public)")
            NotificationCenter.default.post(
                name: AgentChatsView.backgroundNeedsInputNotification,
                object: nil,
                userInfo: ["localID": localID]
            )
        case .notification:
            // Defensiv: Notification wird nicht mehr registriert. Falls doch
            // eine kommt (fremde settings.json), NICHT als awaiting werten —
            // ein idle_prompt wuerde sonst fertige Chats orange markieren.
            // Stattdessen einen evtl. veralteten awaiting-Pulse clearen.
            Logger.claudeBinding.debug("binding_notification_ignored localID=\(localID.uuidString, privacy: .public)")
            NotificationCenter.default.post(
                name: AgentChatsView.backgroundNeedsInputClearedNotification,
                object: nil,
                userInfo: ["localID": localID]
            )
        case .other:
            return
        }
    }

    /// Hängt den Watcher an eine laufende Session — entweder direkt nach
    /// `markLaunched` (externalSessionID kann noch fehlen) oder nach
    /// `bindExternalSessionIDWhenAvailable` (jetzt mit valider ID).
    /// Idempotent: bei wiederholtem Aufruf updated der Watcher die ID intern.
    func attachWatcher(sessionID: UUID) {
        guard let watcher = runtimeWatcher else { return }
        let workspace = store.loadWorkspace()
        guard let session = workspace.sessions.first(where: { $0.id == sessionID }),
              let project = workspace.projects.first(where: { $0.id == session.projectID }) else {
            return
        }
        watcher.watch(
            sessionID: session.id,
            provider: session.provider,
            externalSessionID: session.externalSessionID,
            cwd: project.path,
            priorTurnFinishedAt: session.lastTurnAt
        )
    }

    /// Spielt den optionalen Fertig-Ton (Stop-Hook), gedrosselt gegen
    /// Mehrfach-Stops (max. 1 Ton / 2 s). Lautlos, wenn in den Einstellungen
    /// deaktiviert (`AppPreferences.isAgentStopSoundEnabled`).
    func playAgentStopSoundIfEnabled() {
        guard AppPreferences.shared.isAgentStopSoundEnabled else { return }
        let now = Date()
        if let last = lastStopSoundAt, now.timeIntervalSince(last) < 2 { return }
        lastStopSoundAt = now
        NSSound(named: "Glass")?.play()
    }

    /// Triggert beim turn-finished-Signal des Watchers das Persistieren des
    /// `lastTurnAt`-Stempels und den Auto-Namer. Bewusst static, damit der
    /// Closure beim Watcher-Init kein View-`self` festhält.
    private static func handleTurnFinished(
        sessionID: UUID,
        store: AgentSessionStore,
        autoNamer: AgentSessionAutoNamer?,
        onCompletion: @escaping () -> Void
    ) {
        let workspace = store.loadWorkspace()
        guard let session = workspace.sessions.first(where: { $0.id == sessionID }),
              let project = workspace.projects.first(where: { $0.id == session.projectID }) else {
            return
        }

        // Auto-Namer mit Snapshot starten (lastTurnAt ist hier noch nil) —
        // der `recordTurnEnded` läuft direkt danach und beeinflusst diesen
        // Snapshot nicht mehr.
        autoNamer?.handleTurnFinished(session: session, cwd: project.path) { _ in
            Task { @MainActor in onCompletion() }
        }

        do {
            try store.recordTurnEnded(id: sessionID)
        } catch {
            Logger.debug("Failed to record turn ended: \(error.localizedDescription)")
        }
    }

    func loadWorkspaceFast() {
        PerfBudgets.sidebarWorkspaceLoad.withInterval { loadWorkspaceFastBody() }
    }

    /// Vom Signpost-Wrapper getrennt, damit die bestehende
    /// durationMs-Logzeile unverändert bleibt. Läuft auf dem MainActor!
    /// P1 S6: lädt nichts mehr manuell — der Workspace kommt live aus der
    /// `AgentWorkspaceUIModel`-Projektion; hier bleiben nur Stale-Cleanup
    /// und Selection-Fixup.
    func loadWorkspaceFastBody() {
        let startedAt = Date()
        do {
            try store.markStaleRunningSessionsClosed(excluding: terminalRegistry.activeSessionIDs)
        } catch {
            errorMessage = error.localizedDescription
        }

        reconcileSelection()
        Logger.agentPerformance.debug("agent_chats_fast_load durationMs=\(Int(Date().timeIntervalSince(startedAt) * 1000)) projects=\(workspace.projects.count) sessions=\(workspace.sessions.count)")
    }

    /// Selection-/Expansion-Fixup nach Workspace-Änderungen: Selektion darf
    /// nie auf gelöschte Projekte/Sessions zeigen. Ändert nur dann etwas,
    /// wenn die aktuelle Selektion ungültig geworden ist.
    func reconcileSelection() {
        // Tote/archivierte Sessions aus Tab-Bar und Pins entfernen
        // (z. B. nach deleteSession aus dem Spawn-Fehlerpfad).
        let liveIDs = Set(workspace.sessions.filter { $0.status != .archived }.map(\.id))
        if openTabIDs.contains(where: { !liveIDs.contains($0) }) {
            openTabIDs.removeAll { !liveIDs.contains($0) }
        }
        if pinnedSessionIDs.contains(where: { !liveIDs.contains($0) }) {
            pinnedSessionIDs.removeAll { !liveIDs.contains($0) }
        }

        if selectedProjectID == nil || !workspace.projects.contains(where: { $0.id == selectedProjectID }) {
            selectedProjectID = workspace.projects.first?.id
        }
        if expandedProjectIDs.isEmpty {
            expandedProjectIDs = Set(workspace.projects.prefix(3).map(\.id))
        }
        if let selectedProjectID {
            expandedProjectIDs.insert(selectedProjectID)
        }
        if selectedSessionID == nil || !liveIDs.contains(selectedSessionID!) {
            selectedSessionID = openTabIDs.first
        }
    }

    func refreshSessionsInBackground(reason: String) {
        indexRefreshTask?.cancel()
        isIndexingSessions = true
        let startedAt = Date()
        let activeSessionIDs = terminalRegistry.activeSessionIDs

        indexRefreshTask = Task {
            defer {
                if !Task.isCancelled {
                    isIndexingSessions = false
                }
            }
            // P1 S5: Detached-Block macht nur noch das reine Indexing
            // (JSONL-Parsing off-main); der Merge läuft danach auf dem
            // MainActor über die Facade.
            let result = Task.detached(priority: .utility) {
                PerfBudgets.sidebarBackgroundIndex.withInterval {
                    let cacheStore = AgentSessionIndexCacheStore()
                    var cache = cacheStore.load()
                    let codex = CodexSessionIndexer().indexedSessionResult(cache: &cache)
                    let claude = ClaudeSessionIndexer().indexedSessionResult(cache: &cache)
                    cacheStore.save(cache)
                    return (sessions: codex.sessions + claude.sessions, stats: [codex.stats, claude.stats])
                }
            }

            guard !Task.isCancelled else { return }
            do {
                let indexResult = await result.value
                guard !Task.isCancelled else { return }
                try store.markStaleRunningSessionsClosed(excluding: activeSessionIDs)
                try store.mergeIndexedSessions(indexResult.sessions)
                lastIndexStats = indexResult.stats
                loadWorkspaceFast()
                // Manuelles Sessions-Scannen ist auch der natürliche Trigger,
                // um *alle* generisch benannten Sessions nachträglich vom
                // Auto-Namer benennen zu lassen — sowohl frisch indexierte
                // alte Sessions als auch solche, deren erster
                // Auto-Naming-Versuch vorher gescheitert ist.
                forceAutoNameUntitledSessions()
                Logger.agentPerformance.info("agent_chats_background_index reason=\(reason, privacy: .public) durationMs=\(Int(Date().timeIntervalSince(startedAt) * 1000)) stats=\(lastIndexStats.map { "\($0.provider.rawValue):\($0.scannedFiles)/\($0.cacheHits)/\($0.bytesRead)" }.joined(separator: ","), privacy: .public)")
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
            }
        }
    }
}
