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
    /// Wird gerufen direkt VOR dem Claude-Launch und liefert zusaetzliche
    /// CLI-Argumente (typisch: `--settings <hook-settings-path>`). `nil`
    /// erlaubt der View, im Test-Setup ohne Hook-Bridge zu laufen.
    var onPrepareClaudeHookArguments: (UUID) -> [String] = { _ in [] }
    /// Wird gerufen direkt NACH dem Launch um Hook-Tail-Polling zu starten.
    var onClaudeHookLaunched: (UUID) -> Void = { _ in }

    @State private var store = AgentSessionStore()
    @State private var errorMessage: String?
    /// Lokal gecachtes Transcript fuer die Offline-Ansicht. Wird beim Mount
    /// / Session-Wechsel asynchron via TranscriptReader von der JSONL der
    /// jeweiligen CLI geladen — verhindert dass jedes Re-Render erneut
    /// parsen muss.
    @State private var cachedTranscript: AgentChatTranscript?
    @State private var isLoadingTranscript = false

    private var controller: AgentTerminalController? {
        terminalRegistry.controller(for: session.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let controller {
                AgentTerminalView(controller: controller)
                    .background(AgentTheme.background)
            } else if isLoadingTranscript {
                loadingView
            } else {
                // Universal-Fallback fuer geschlossene Sessions: Transcript-
                // View nutzt seinen eingebauten Empty-State wenn `cachedTranscript`
                // nil oder leer ist (z. B. wenn die JSONL noch nicht existiert).
                AgentChatTranscriptView(
                    transcript: cachedTranscript,
                    session: session
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
            loadTranscriptIfNeeded()
        }
        .onChange(of: session.id) { _, _ in
            errorMessage = nil
            cachedTranscript = nil
            isLoadingTranscript = false
            if session.shouldLaunchOnOpen == true {
                prepareCommand()
            }
            // Wechsel zwischen offenen Chats: dem neuen Terminal Fokus geben.
            controller?.focusTerminal()
            loadTranscriptIfNeeded()
        }
        .onChange(of: actionRequest) { _, request in
            handleActionRequest(request)
        }
    }

    /// Laedt das Transcript fuer die aktuelle Session aus der JSONL-Datei
    /// der jeweiligen CLI. Nur wenn kein Live-Controller laeuft und eine
    /// externe Session-ID bekannt ist. Asynchron weil JSONL gross sein
    /// kann (mehrere MB / Sekunden zum Parsen).
    private func loadTranscriptIfNeeded() {
        guard controller == nil else {
            cachedTranscript = nil
            isLoadingTranscript = false
            return
        }
        // Agent View hat keinen eigenen Transcript-Stream — die JSONLs der
        // einzelnen Background-Sessions liegen jeweils dort wo Claude sie
        // schreibt, nicht unter dem Agent-View-Tab. Empty-State zeigen.
        guard !session.isAgentView else {
            cachedTranscript = nil
            isLoadingTranscript = false
            return
        }
        // Background-Chats sind erst nach erfolgreichem Spawn an eine JSONL
        // gebunden — und auch dann ueber die vom Supervisor gewaehlte UUID,
        // nicht ueber externalSessionID. Transcript-Loading folgt in Phase 3
        // (per Indexer-Lookup via cwd + lastActivityAt). Bis dahin: skip.
        guard !session.isBackgroundChat else {
            cachedTranscript = nil
            isLoadingTranscript = false
            return
        }
        guard let externalID = session.externalSessionID, !externalID.isEmpty else {
            cachedTranscript = nil
            isLoadingTranscript = false
            return
        }
        let provider = session.provider
        let cwd = project.path
        let targetSessionID = session.id
        isLoadingTranscript = true
        Task.detached(priority: .userInitiated) {
            let transcript: AgentChatTranscript?
            switch provider {
            case .claude:
                transcript = ClaudeTranscriptReader.read(cwd: cwd, sessionID: externalID)
            case .codex:
                transcript = CodexTranscriptReader.read(sessionID: externalID)
            }
            await MainActor.run {
                // Falls der User waehrend des Loads umgeschaltet hat,
                // diese Antwort verwerfen.
                guard targetSessionID == session.id else { return }
                cachedTranscript = transcript
                isLoadingTranscript = false
            }
        }
    }

    @ViewBuilder
    private var loadingView: some View {
        VStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Konversation wird geladen…")
                .font(.system(size: 12))
                .foregroundStyle(AgentTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AgentTheme.background)
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
            // Hook-Bridge nur fuer normale interaktive Claude-Sessions —
            // Agent View ist ein Dashboard, hat keine eigene Session-ID
            // zum Tracken. Background-Chats werden bereits beim Spawn
            // (`AgentChatsView.dispatchBackgroundAgent` → `--settings
            // <path>` an `claude --bg`) mit der Bridge verheiratet — beim
            // spaeteren `claude attach` darf NICHT erneut eine Bridge
            // gestartet werden, sonst wuerden zwei DispatchSources auf
            // dieselbe Event-JSONL laufen.
            let useHookBridge = launchSession.provider == .claude
                && !launchSession.isAgentView
                && !launchSession.isBackgroundChat
            if useHookBridge {
                let hookArgs = onPrepareClaudeHookArguments(launchSession.id)
                if !hookArgs.isEmpty {
                    builder.extraLaunchArguments = hookArgs
                }
            }
            let command = try builder.command(for: launchSession, project: project)
            terminalRegistry.startController(
                sessionID: launchSession.id,
                command: command,
                onLaunched: markLaunched,
                onTerminated: { exitCode in markTerminated(exitCode: exitCode) }
            )
            if useHookBridge {
                onClaudeHookLaunched(launchSession.id)
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func repairedSessionForLaunch() throws -> AgentChatSession {
        // Agent View hat keine externe Session-ID — kein Repair noetig.
        guard !session.isAgentView else {
            return session
        }
        guard session.provider == .claude,
              session.hasLaunchedInitialPrompt,
              let externalID = session.externalSessionID,
              !externalID.isEmpty else {
            return session
        }

        // FAST PATH: wenn die JSONL fuer die gespeicherte externalSessionID
        // bereits an der erwarteten Stelle liegt, gilt die ID als valide —
        // kein Scan ueber 2000+ Files noetig. Das ist der 99%-Fall und
        // verhindert den 2-Sekunden-UI-Block beim Resume-Klick.
        if ClaudeTranscriptReader.transcriptExists(forCwd: project.path, sessionID: externalID) {
            return session
        }

        // SLOW PATH: gespeicherte ID hat keine entsprechende JSONL — vielleicht
        // wurde sie von Claude per `/resume` umgebogen, oder das Transcript
        // wurde manuell geloescht. Erst jetzt machen wir den teuren
        // Indexer-Scan ueber alle Projekte und versuchen einen Repair.
        let indexedSessions = ClaudeSessionIndexer().indexedSessions(limit: 500)
        let repair = try store.repairResumeStateBeforeLaunch(
            localSessionID: session.id,
            projectPath: project.path,
            indexedSessions: indexedSessions
        )

        if let repair {
            switch repair.outcome {
            case .unchanged:
                break
            case .rebound(let oldID, let newID):
                Logger.claudeBinding.notice("resume_rebound localID=\(session.id.uuidString, privacy: .public) old=\(oldID, privacy: .public) new=\(newID, privacy: .public)")
                onExternalSessionIDBound(session.id)
                onStateChanged()
            case .resetInvalid(let oldID):
                Logger.claudeBinding.notice("resume_reset_invalid localID=\(session.id.uuidString, privacy: .public) old=\(oldID, privacy: .public)")
                onStateChanged()
            }
        }

        // FINAL-GARANTIE (Superset-Prinzip): NIEMALS `claude --resume <id>` ohne
        // real existierendes Transkript. Der Indexer kann per mtime/size-Cache
        // eine laengst geloeschte ODER nie geschriebene ID noch als gueltig
        // melden (-> Repair-Outcome `.unchanged`) — wir vertrauen nur der echten
        // `<id>.jsonl`-Datei. Fehlt sie, wird statt "No conversation found" eine
        // FRISCHE Session im selben Tab gestartet (extID/launched zuruecksetzen,
        // Claude vergibt eine neue ID, die `bindExternalSessionIDWhenAvailable`
        // danach an das real geschriebene Transkript bindet).
        let candidate = repair?.session ?? session
        if candidate.hasLaunchedInitialPrompt,
           let ext = candidate.externalSessionID, !ext.isEmpty,
           !ClaudeTranscriptReader.transcriptExists(forCwd: project.path, sessionID: ext) {
            Logger.claudeBinding.notice("resume_guard_fresh_start localID=\(session.id.uuidString, privacy: .public) deadID=\(ext, privacy: .public)")
            try? store.updateSession(id: session.id) { updated in
                updated.externalSessionID = nil
                updated.hasLaunchedInitialPrompt = false
            }
            onStateChanged()
            var fresh = candidate
            fresh.externalSessionID = nil
            fresh.hasLaunchedInitialPrompt = false
            return fresh
        }

        return candidate
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
            // Agent View hat keine externe Session-ID — kein binding noetig.
            if !session.isAgentView {
                bindExternalSessionIDWhenAvailable()
            }
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
