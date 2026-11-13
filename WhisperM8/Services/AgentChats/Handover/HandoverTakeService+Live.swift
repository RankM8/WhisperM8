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
            secretStore: HandoverSecretStore.live(paths: paths),
            marker: marker,
            sessions: { store.loadWorkspace().sessions },
            adopt: { taken, session in adoptLive(taken, session: session, store: store) },
            showEnded: { taken, session in showEndedLive(taken, session: session, store: store) },
            scheduleResume: { ids in scheduleResumeLive(ids, store: store) }
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
        // Nicht `sessionLaunched` (Review Ende-Meldung): das setzte „startet
        // gerade“ samt Startfrist für einen Prozess, der längst läuft.
        coordinator.sessionAdopted(sessionID: id)
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
        // Ein Turn-Ende in der Lücke hat keinen Auftrag aus der Warteschlange
        // ausgelöst. Einmal nachfassen, sobald der Status wieder bekannt ist;
        // die Zustellung prüft selbst, ob der Chat ruht.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            AgentPromptQueueDelivery.shared.deliverNext(for: id)
        }
        Logger.agentStore.info(
            "handover_adopted session=\(id.uuidString, privacy: .public) pid=\(manifest.pid) gapBytes=\(taken.gapBytes)")
        return true
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
    /// fehlender Tab kommt zurück, ohne die Auswahl zu ändern.
    private static func scheduleResumeLive(_ ids: [UUID], store: AgentSessionStore) {
        let windowStore = AgentWindowStore.shared
        for id in ids {
            try? store.updateSession(id: id) { $0.shouldLaunchOnOpen = true }
            if windowStore.windowID(containingTab: id) == nil {
                windowStore.openTab(id, in: windowStore.primaryWindowID, select: false)
            }
        }
        Logger.agentStore.notice("handover_fallback_resume count=\(ids.count)")
    }
}
