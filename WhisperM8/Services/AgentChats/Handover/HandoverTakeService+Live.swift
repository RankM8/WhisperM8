import Foundation

// MARK: - Übernahme: Verdrahtung mit der App

extension HandoverTakeService {
    static func live(
        paths: HandoverPaths = .default,
        marker: AgentCrashRecoveryMarker = .shared
    ) -> HandoverTakeService {
        let store = AgentSessionStore()
        return HandoverTakeService(dependencies: .init(
            paths: paths,
            // Lazy: Die Datei-Ablage kostet nichts, aber mit dem späteren Wechsel
            // zurück in den Schlüsselbund (Apple-Konto) läse jeder Start sonst
            // wieder die Signatur.
            secretStore: HandoverLazySecretStore { HandoverSecretStores.live(paths: paths) },
            marker: marker,
            sessions: { store.loadWorkspace().sessions },
            adopt: { taken, session in adoptLive(taken, session: session, store: store) },
            showEnded: { taken, session in showEndedLive(taken, session: session, store: store) },
            scheduleResume: { ids in scheduleFallbackResume(ids, store: store) }
        ))
    }

    private static func adoptLive(_ taken: HandoverClient.TakenChat, session: AgentChatSession,
                                  store: AgentSessionStore) -> Bool {
        let manifest = taken.manifest
        guard let fd = taken.descriptor,
              let command = manifest.launchCommand?
                .decoded(as: HandoverLaunchCommandSnapshot.self)?.launchCommand else { return false }
        let id = session.id
        let coordinator = AgentSessionStatusCoordinator.shared
        // Das Ende meldet die Registry (Store, Status) wie bei jedem Chat.
        let controller = AgentTerminalRegistry.shared.adoptController(
            sessionID: id, command: command,
            setUp: { $0.adoptHandedOver(descriptor: fd, manifest: manifest, image: taken.image) })
        guard controller != nil else { return false }

        if let token = manifest.controlToken {
            AgentSessionTokenRegistry.shared.register(token: token, for: id, pid: manifest.pid,
                                                      isAttach: command.isClaudeAttach)
        }
        try? store.updateSession(id: id) {
            $0.status = .running
            $0.shouldLaunchOnOpen = false
        }
        // Nicht `sessionLaunched`: Der Prozess läuft längst. `sessionAdopted`
        // hält den Chat ohne Startphase im Startzustand, bis er sich meldet,
        // mit einer Notfrist nach dem Status bei der Abgabe (WM8-97).
        coordinator.sessionAdopted(sessionID: id, handedOverStatus: Self.handedOverStatus(manifest))
        coordinator.restorePendingBinding(
            .init(pendingExternalID: manifest.pendingExternalSessionID,
                  forkExternalIDs: manifest.forkExternalSessionIDs ?? []),
            for: id)
        if let since = manifest.workingSince {
            StatisticsCollectors.noteHandedOverWork(since: Date(timeIntervalSince1970: since), for: id)
        }
        if let cursor = manifest.hookCursor {
            coordinator.hookTrackingAdopted(sessionID: id, cursor: cursor, isBackground: session.isBackgroundChat)
        }
        if let pending = manifest.pendingAccountSwitch?
            .decoded(as: HandoverPendingAccountSwitch.self)?.pendingSwitch {
            AccountSwitchCoordinator.shared.schedule(
                [(sessionID: id, reason: pending.reason)],
                targetProfile: pending.targetProfile, targetName: pending.targetName)
        }
        // Kein Nachfassen der Warteschlange nach fester Zeit mehr (WM8-97):
        // Der Chat bleibt im Startzustand, bis ein echtes Signal kommt. Der
        // Übergang nach „bereit“ oder ein Turn-Ende (auch eines in der Lücke,
        // arbeitete der Chat bei der Abgabe) stößt die Zustellung an.
        Logger.agentStore.info(
            "handover_adopted session=\(id.uuidString, privacy: .public) pid=\(manifest.pid) gapBytes=\(taken.gapBytes)")
        return true
    }

    /// Status bei der Abgabe aus dem Manifest; ältere Manifeste kennen nur
    /// „arbeitet seit“.
    static func handedOverStatus(_ manifest: HandoverManifest) -> AgentSessionRuntimeStatus? {
        if let raw = manifest.runtimeStatus, let status = AgentSessionRuntimeStatus(rawValue: raw) { return status }
        return manifest.workingSince != nil ? .working : nil
    }

    private static func showEndedLive(_ taken: HandoverClient.TakenChat, session: AgentChatSession,
                                      store: AgentSessionStore) {
        let id = session.id
        guard let command = taken.manifest.launchCommand?
            .decoded(as: HandoverLaunchCommandSnapshot.self)?.launchCommand else { return }
        AgentTerminalRegistry.shared.adoptController(
            sessionID: id, command: command,
            setUp: { controller in
                controller.showEndedInGap(manifest: taken.manifest, image: taken.image, exitStatus: taken.exitStatus)
                return true
            })
        try? store.updateSession(id: id) { if $0.status == .running { $0.status = .closed } }
        AgentSessionStatusCoordinator.shared.sessionTerminated(sessionID: id, exitCode: taken.exitStatus)
    }

    /// Wie die Absturz-Wiederaufnahme: beim Anzeigen per `--resume` starten,
    /// fehlender Tab kommt zurück, ohne die Auswahl zu ändern. Je Sitzung
    /// höchstens ein Chat, laufende und schon vorgemerkte zählen mit
    /// (`AgentCollectiveStartPlanner`). Anders als dort starten die Chats
    /// auch in unterdrückten Grid-Panes (`HandoverFallbackLaunchQueue`).
    static func scheduleFallbackResume(
        _ ids: [UUID],
        store: AgentSessionStore,
        windowStore: AgentWindowStore? = nil,
        runningSessionIDs: Set<UUID>? = nil,
        queue: HandoverFallbackLaunchQueue? = nil,
        hadTurn: ((AgentChatSession) -> Bool)? = nil,
        claudeRecoverable: ((AgentChatSession) -> Bool)? = nil,
        hookPaths: ClaudeHookPaths = ClaudeHookPaths(),
        notices: AgentCollectiveStartNotices? = nil
    ) {
        let windowStore = windowStore ?? .shared
        let runningSessionIDs = runningSessionIDs ?? AgentTerminalRegistry.shared.activeSessionIDs
        let queue = queue ?? .shared
        let notices = notices ?? .shared
        let workspaceSessions = store.loadWorkspace().sessions
        // Dieselbe Regel wie die Absturz-Wiederaufnahme: Belege aus der
        // Hook-Datei entscheiden den Halter, der übersprungene Chat zeigt,
        // wer seine Unterhaltung führt (Vic, Gus' Halter-Regel 5bb84874).
        let plan = AgentCollectiveStartPlanner.plan(
            ids, sessions: workspaceSessions,
            alreadyStarted: runningSessionIDs.union(queue.scheduledThisLaunch),
            evidence: { AgentSessionOwnershipEvidence.live(for: $0, hookPaths: hookPaths) })
        let titles = Dictionary(workspaceSessions.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        for skipped in plan.skipped {
            // Nur zurücksetzen, wenn ein ANDERER Chat die Sitzung führt; ein
            // selbst schon vorgemerkter oder laufender behält sein Flag (Vic).
            guard let keeper = plan.keeperOf[skipped], keeper != skipped else { continue }
            let title = titles[keeper].flatMap { $0.isEmpty ? nil : $0 }
            notices.note(skipped: skipped, keeperTitle: title ?? String(keeper.uuidString.prefix(8)).lowercased())
            if windowStore.windowID(containingTab: skipped) == nil {
                windowStore.openTab(skipped, in: windowStore.primaryWindowID, select: false)
            }
            try? store.updateSession(id: skipped) { $0.shouldLaunchOnOpen = false }
            Logger.agentStore.notice(
                "handover_fallback_duplicate_skipped session=\(skipped.uuidString, privacy: .public) keeper=\(plan.keeperOf[skipped]?.uuidString ?? "-", privacy: .public)")
        }
        // Punkt 11: Chats ohne Sitzungs-ID frisch starten oder gestoppt lassen.
        let sessions = Dictionary(store.loadWorkspace().sessions.map { ($0.id, $0) },
                                  uniquingKeysWith: { first, _ in first })
        var starting: [UUID] = []
        // Der Beleg kostet einen Blick in die Verläufe; nur für Chats ohne ID.
        let needsEvidence = { (session: AgentChatSession) in
            session.hasLaunchedInitialPrompt && (session.externalSessionID?.isEmpty ?? true) && !session.isTerminal
        }
        for id in plan.start {
            guard let session = sessions[id] else { starting.append(id); continue }
            let decision = HandoverFallbackStart.decide(
                for: session,
                hadTurn: needsEvidence(session)
                    && (hadTurn ?? { liveHadTurn($0, store: store) })(session),
                claudeRecoverable: claudeRecoverable.map { $0(session) } ?? liveClaudeRecoverable(session, store: store))
            if let notice = decision.notice { queue.setNotice(notice, for: id) }
            switch decision {
            case .resume:
                starting.append(id)
            case .startFresh:
                try? store.updateSession(id: id) { $0.hasLaunchedInitialPrompt = false }
                Logger.agentStore.notice("handover_fallback_start_fresh session=\(id.uuidString, privacy: .public)")
                starting.append(id)
            case .keepStopped:
                try? store.updateSession(id: id) { $0.shouldLaunchOnOpen = false }
                Logger.agentStore.notice("handover_fallback_kept_stopped session=\(id.uuidString, privacy: .public)")
            }
        }
        // Vor dem Flag: Dessen Änderung startet die Pane schon.
        queue.schedule(starting)
        for id in starting {
            try? store.updateSession(id: id) { $0.shouldLaunchOnOpen = true }
            if windowStore.windowID(containingTab: id) == nil {
                windowStore.openTab(id, in: windowStore.primaryWindowID, select: false)
            }
        }
        Logger.agentStore.notice("handover_fallback_resume count=\(starting.count) skipped=\(plan.skipped.count)")
    }

    private static func liveHadTurn(_ session: AgentChatSession, store: AgentSessionStore) -> Bool {
        let events = ClaudeExternalIDRecovery.tailData(
            of: ClaudeHookPaths().eventFileURL(localSessionID: session.id),
            maxBytes: ClaudeExternalIDRecovery.unboundResumeTailBytes)
        if HandoverFallbackStart.hadTurn(
            session, journal: ChatsStatusJournal.recent(sessionID: session.id, limit: 50), hookEvents: events) {
            return true
        }
        // Unabhängiger Beleg: ein ungebundener Verlauf im Projektordner.
        let workspace = store.loadWorkspace()
        guard let project = workspace.projects.first(where: { $0.id == session.projectID }) else { return true }
        var cache = AgentSessionIndexCacheStore().load()
        let indexed: [IndexedAgentSession]
        switch session.provider {
        // 500 wie im Startweg: Die Liste ist nach Aktivität über ALLE Projekte
        // sortiert; ein seit Stunden ruhender Chat läge sonst außerhalb (Vic).
        case .claude: indexed = ClaudeSessionIndexer().indexedSessionResult(limit: 500, cache: &cache).sessions
        case .codex: indexed = CodexSessionIndexer().indexedSessionResult(limit: 500, cache: &cache).sessions
        }
        return HandoverFallbackStart.hasUnboundTranscript(
            for: session, projectPath: project.path, indexed: indexed,
            boundIDs: AgentSessionStore.externalIDsBound(in: workspace, except: session.id))
    }

    /// Wie der Start-Pfad (`AgentCommandBuilder.unboundResumeResolver`):
    /// nennen die Hook-Ereignisse eine Sitzung, wird über sie fortgesetzt.
    private static func liveClaudeRecoverable(_ session: AgentChatSession, store: AgentSessionStore) -> Bool {
        guard session.provider == .claude,
              let project = store.loadWorkspace().projects.first(where: { $0.id == session.projectID })
        else { return false }
        return AgentCommandBuilder().unboundResumeResolver(session, project) != nil
    }
}
