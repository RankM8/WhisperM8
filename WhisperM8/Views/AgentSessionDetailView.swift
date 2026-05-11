import SwiftUI

struct AgentSessionActionRequest: Equatable {
    enum Kind: Equatable {
        case start
        case restart
    }

    let id = UUID()
    let sessionID: UUID
    let kind: Kind
}

struct AgentSessionDetailView: View {
    let project: AgentProject
    let session: AgentChatSession
    @ObservedObject var terminalRegistry: AgentTerminalRegistry
    var actionRequest: AgentSessionActionRequest?
    var onStateChanged: () -> Void
    /// Runtime-Watcher-Hooks. Aufrufer (AgentChatsView) reicht hier Closures
    /// rein, die intern `runtimeWatcher?.watch(...)` etc. aufrufen — so muss
    /// die Detail-View nichts vom Watcher selbst wissen.
    var onSessionLaunched: (UUID) -> Void = { _ in }
    var onSessionTerminated: (UUID, Int32?) -> Void = { _, _ in }
    var onExternalSessionIDBound: (UUID) -> Void = { _ in }
    /// Wird aufgerufen wenn der Detail-View eine inhaltliche Zusammenfassung
    /// der geschlossenen Session generieren möchte. `force == true` bedeutet
    /// "User hat 'Neu generieren' geklickt" — dann auch dann generieren, wenn
    /// schon ein `summary` existiert.
    var onRequestSummary: (UUID, _ force: Bool) -> Void = { _, _ in }
    /// Liefert `true`, solange ein Summary für diese Session aktuell generiert
    /// wird — die UI bindet das auf einen Spinner.
    var isGeneratingSummary: (UUID) -> Bool = { _ in false }
    /// Wird gerufen direkt VOR dem Claude-Launch und liefert zusaetzliche
    /// CLI-Argumente (typisch: `--settings <hook-settings-path>`). `nil`
    /// erlaubt der View, im Test-Setup ohne Hook-Bridge zu laufen.
    var onPrepareClaudeHookArguments: (UUID) -> [String] = { _ in [] }
    /// Wird gerufen direkt NACH dem Launch um Hook-Tail-Polling zu starten.
    var onClaudeHookLaunched: (UUID) -> Void = { _ in }

    @State private var store = AgentSessionStore()
    @State private var snapshotStore = AgentTerminalSnapshotStore()
    @State private var errorMessage: String?
    /// Lokal gecachtes Snapshot fuer die Offline-Ansicht. Wird beim Mount /
    /// Session-Wechsel asynchron geladen — verhindert dass jedes
    /// Re-Render erneut ueber Disk muss.
    @State private var cachedSnapshot: AgentTerminalSnapshot?

    private var controller: AgentTerminalController? {
        terminalRegistry.controller(for: session.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let controller {
                AgentTerminalView(controller: controller)
                    .background(AgentTheme.background)
            } else if let snapshot = cachedSnapshot {
                AgentTerminalSnapshotView(snapshot: snapshot, session: session)
            } else {
                ClosedSessionSummaryView(
                    session: session,
                    errorMessage: errorMessage,
                    isGenerating: isGeneratingSummary(session.id),
                    onGenerate: { force in onRequestSummary(session.id, force) }
                )
            }
        }
        .onAppear {
            if session.shouldLaunchOnOpen == true {
                prepareCommand()
            }
            // Direkt nach dem Mount Tastaturfokus auf das Terminal setzen,
            // damit der User sofort tippen kann und nicht im Sidebar-Filter
            // hängenbleibt. `focusTerminal` is async-dispatched — okay wenn
            // das View jetzt erst mountet.
            controller?.focusTerminal()
            loadSnapshotIfNeeded()
            // Beim Öffnen einer geschlossenen Session ohne Summary einmal
            // im Hintergrund anstoßen — der Coordinator (AgentChatsView)
            // entscheidet, ob das tatsächlich ausgeführt wird (in-flight,
            // schon vorhanden, fehlende externalSessionID).
            if controller == nil && session.summary == nil {
                onRequestSummary(session.id, false)
            }
        }
        .onChange(of: session.id) { _, _ in
            errorMessage = nil
            cachedSnapshot = nil
            if session.shouldLaunchOnOpen == true {
                prepareCommand()
            }
            // Wechsel zwischen offenen Chats: dem neuen Terminal Fokus geben.
            controller?.focusTerminal()
            loadSnapshotIfNeeded()
            if controller == nil && session.summary == nil {
                onRequestSummary(session.id, false)
            }
        }
        .onChange(of: actionRequest) { _, request in
            handleActionRequest(request)
        }
    }

    /// Laedt das persistierte Snapshot fuer die aktuelle Session, falls
    /// noch nicht gecacht und kein Live-Controller laeuft. Synchron weil
    /// das File klein ist (max ~100 KiB) — async waere overkill.
    private func loadSnapshotIfNeeded() {
        guard controller == nil else {
            cachedSnapshot = nil
            return
        }
        cachedSnapshot = snapshotStore.load(localSessionID: session.id)
    }

    private func handleActionRequest(_ request: AgentSessionActionRequest?) {
        guard let request, request.sessionID == session.id else { return }
        switch request.kind {
        case .start:
            prepareCommand()
        case .restart:
            restartTerminal()
        }
    }

    private func prepareCommand() {
        do {
            let launchSession = try repairedSessionForLaunch()
            // Claude-Hook-Bridge: VOR dem Command-Build die Settings-Datei
            // erzeugen und `--settings <path>` als extra-Argument liefern.
            // Codex bekommt das nicht (kein Hook-API).
            var builder = AgentCommandBuilder()
            if launchSession.provider == .claude {
                let hookArgs = onPrepareClaudeHookArguments(launchSession.id)
                if !hookArgs.isEmpty {
                    builder.extraLaunchArguments = hookArgs
                }
            }
            let command = try builder.command(for: launchSession, project: project)
            let snapshotContext = AgentTerminalSnapshotContext(
                localSessionID: launchSession.id,
                provider: launchSession.provider,
                externalSessionID: launchSession.externalSessionID,
                cwd: project.path
            )
            terminalRegistry.startController(
                sessionID: launchSession.id,
                command: command,
                snapshotContext: snapshotContext,
                onLaunched: markLaunched,
                onTerminated: { exitCode in markTerminated(exitCode: exitCode) }
            )
            if launchSession.provider == .claude {
                onClaudeHookLaunched(launchSession.id)
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func repairedSessionForLaunch() throws -> AgentChatSession {
        guard session.provider == .claude,
              session.hasLaunchedInitialPrompt,
              session.externalSessionID?.isEmpty == false else {
            return session
        }

        let indexedSessions = ClaudeSessionIndexer().indexedSessions(limit: 500)
        guard let repair = try store.repairResumeStateBeforeLaunch(
            localSessionID: session.id,
            projectPath: project.path,
            indexedSessions: indexedSessions
        ) else {
            return session
        }

        switch repair.outcome {
        case .unchanged:
            break
        case .rebound(let oldID, let newID):
            Logger.debug("Rebound Claude resume ID \(oldID) -> \(newID)")
            onExternalSessionIDBound(session.id)
            onStateChanged()
        case .resetInvalid(let oldID):
            Logger.debug("Reset invalid Claude resume ID \(oldID); starting a fresh terminal session in the existing tab")
            onStateChanged()
        }

        return repair.session
    }

    private func restartTerminal() {
        terminalRegistry.terminate(sessionID: session.id)
        prepareCommand()
    }

    private func markLaunched() {
        do {
            try store.updateSession(id: session.id) { updated in
                updated.status = .running
                updated.hasLaunchedInitialPrompt = true
                updated.shouldLaunchOnOpen = false
                updated.initialPrompt = nil
            }
            bindExternalSessionIDWhenAvailable()
            onSessionLaunched(session.id)
            // Erster Start: Terminal-NSView ist jetzt mit dem Window verbunden
            // → Tastaturfokus dorthin, damit der User direkt tippen kann.
            controller?.focusTerminal()
            onStateChanged()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func markTerminated(exitCode: Int32?) {
        do {
            try store.updateSession(id: session.id) { updated in
                if updated.status == .running {
                    updated.status = .closed
                }
            }
            onSessionTerminated(session.id, exitCode)
            onStateChanged()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func bindExternalSessionIDWhenAvailable() {
        Task { @MainActor in
            let retryDelays: [UInt64] = [
                250_000_000,
                500_000_000,
                1_000_000_000,
                2_000_000_000,
                4_000_000_000
            ]

            for delay in retryDelays {
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled else { return }

                do {
                    let indexedSessions = CodexSessionIndexer().indexedSessions(limit: 20)
                        + ClaudeSessionIndexer().indexedSessions(limit: 20)
                    if try store.bindLatestIndexedSession(
                        localSessionID: session.id,
                        provider: session.provider,
                        projectPath: project.path,
                        indexedSessions: indexedSessions
                    ) != nil {
                        onExternalSessionIDBound(session.id)
                        onStateChanged()
                        return
                    }
                } catch {
                    errorMessage = error.localizedDescription
                    return
                }
            }
        }
    }
}
