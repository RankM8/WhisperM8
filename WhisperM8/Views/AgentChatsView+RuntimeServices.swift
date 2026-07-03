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

    /// Bindet die View an die app-weiten Runtime-Services. Status-Ableitung,
    /// Hook-Bridge und Watcher leben im `AgentSessionStatusCoordinator`
    /// (Singleton) — Fenster sind reine Konsumenten. Dadurch zeigen alle
    /// Fenster denselben Status und ein Fenster-Schließen reißt das Tracking
    /// nicht mehr ab.
    func setupRuntimeServicesIfNeeded() {
        if autoNamer == nil {
            autoNamer = AgentSessionStatusCoordinator.shared.autoNamer
        }
    }

    /// Notification fuer den ambiguous-rebind-Picker (Phase 6).
    static let ambiguousRebindNotification = Notification.Name("AgentChatsView.ambiguousRebind")

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
