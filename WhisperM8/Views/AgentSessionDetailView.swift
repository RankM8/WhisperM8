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
    /// Grid-Panes: unterdrückt Auto-Launch (`shouldLaunchOnOpen`) und den
    /// automatischen Terminal-Fokus beim Mount/Session-Wechsel — nur die
    /// Fokus-Pane darf beides, sonst spawnt ein Preset-Wechsel bis zu vier
    /// PTYs und die Panes kämpfen um den First-Responder. Explizite
    /// Start-Aktionen (Button, actionRequest) bleiben unberührt.
    var suppressesAutoActivation: Bool = false
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
    /// Tail-first: initial nur das Dateiende parsen. 17-MB-Transcripts
    /// froren die App beim Voll-Read ein — mehr Verlauf holt der User
    /// explizit nach (×4-Eskalation pro Klick).
    private static let initialTailBytes = 512 * 1024
    @State private var transcriptTailBytes = AgentSessionDetailView.initialTailBytes
    /// Feedback-Zustand des Nachladens (Spinner/„✓ N geladen"/Anfang).
    @State private var historyState = TranscriptHistoryState.idle
    /// Message-Zahl vor dem laufenden Nachladen — für das „✓ N"-Delta.
    @State private var countBeforeEarlierLoad: Int?

    private var controller: AgentTerminalController? {
        terminalRegistry.controller(for: session.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Launch-/Repair-Fehler sichtbar machen (Review-Befund 2026-07-13:
            // errorMessage wurde gesetzt, aber nie gerendert — abgebrochene
            // Launches wirkten wie ein No-op bzw. verschwundener Verlauf).
            if let errorMessage {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text(errorMessage)
                        .font(.system(size: 12))
                        .foregroundStyle(AgentTheme.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        self.errorMessage = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(AgentTheme.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(10)
                .background(Color.yellow.opacity(0.12))
            }
            if let controller {
                AgentTerminalView(controller: controller)
                    .background(AgentTheme.background)
            } else if session.isTerminal {
                // Terminal ohne laufenden Controller (App-Neustart oder Tab
                // wurde geschlossen): es gibt kein Transcript, das man zeigen
                // könnte — klarer Ended-State mit Ein-Klick-Neustart.
                terminalEndedView
            } else if isLoadingTranscript {
                loadingView
            } else {
                // Universal-Fallback fuer geschlossene Sessions: Timeline
                // (Variante E) mit Roh-Umschalter; leere Transcripts landen
                // im eingebauten Empty-State der Roh-View (z. B. wenn die
                // JSONL noch nicht existiert).
                AgentTranscriptContainerView(
                    transcript: cachedTranscript,
                    session: session,
                    onLoadEarlierHistory: { loadEarlierHistory() },
                    history: historyState,
                    loadHint: tailWindowHint,
                    showsSummaryCard: !session.isSubagentJob
                )
            }
        }
        .onAppear {
            if !suppressesAutoActivation {
                if session.shouldLaunchOnOpen == true {
                    prepareCommand()
                }
                // Direkt nach dem Mount Tastaturfokus auf das Terminal setzen,
                // damit der User sofort tippen kann und nicht im Sidebar-Filter
                // hängenbleibt. `focusTerminal` is async-dispatched — okay wenn
                // das View jetzt erst mountet.
                controller?.focusTerminal()
            }
            loadTranscriptIfNeeded()
        }
        .onChange(of: session.id) { _, _ in
            errorMessage = nil
            cachedTranscript = nil
            isLoadingTranscript = false
            transcriptTailBytes = Self.initialTailBytes
            historyState = .idle
            countBeforeEarlierLoad = nil
            if !suppressesAutoActivation {
                if session.shouldLaunchOnOpen == true {
                    prepareCommand()
                }
                // Wechsel zwischen offenen Chats: dem neuen Terminal Fokus geben.
                controller?.focusTerminal()
            }
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
        let tailBytes = transcriptTailBytes
        // Spinner nur beim Erst-Load — beim Nachladen von Verlauf bleibt
        // der bestehende Inhalt stehen (kein Flackern).
        if cachedTranscript == nil { isLoadingTranscript = true }
        Task.detached(priority: .userInitiated) {
            // Tail-Read statt Voll-Parse: bounded Memory + bounded Zeit,
            // egal wie groß die JSONL ist.
            let transcript: AgentChatTranscript?
            switch provider {
            case .claude:
                transcript = ClaudeTranscriptReader.readTail(cwd: cwd, sessionID: externalID, tailBytes: tailBytes)
            case .codex:
                transcript = CodexTranscriptReader.readTail(sessionID: externalID, tailBytes: tailBytes)
            }
            await MainActor.run {
                // Falls der User waehrend des Loads umgeschaltet hat,
                // diese Antwort verwerfen.
                guard targetSessionID == session.id else { return }
                cachedTranscript = transcript
                isLoadingTranscript = false
                // Nachlade-Feedback: „✓ N geladen" bzw. Anfang erreicht —
                // der Klick hat IMMER eine sichtbare Wirkung.
                if let before = countBeforeEarlierLoad {
                    countBeforeEarlierLoad = nil
                    historyState = TranscriptHistoryState(
                        isLoading: false,
                        lastLoadedDelta: max(0, (transcript?.messages.count ?? 0) - before),
                        reachedStart: transcript?.hasTruncatedHead != true
                    )
                }
            }
        }
    }

    /// „Früheren Verlauf laden": Lesefenster vervierfachen und neu laden.
    /// Explizite User-Aktion — so bleibt auch ein 50-MB-Chat beherrschbar
    /// (512 KB → 2 MB → 8 MB → …), statt beim Öffnen alles zu parsen.
    private func loadEarlierHistory() {
        guard cachedTranscript?.hasTruncatedHead == true, countBeforeEarlierLoad == nil else { return }
        countBeforeEarlierLoad = cachedTranscript?.messages.count ?? 0
        historyState = TranscriptHistoryState(isLoading: true, lastLoadedDelta: nil, reachedStart: false)
        transcriptTailBytes *= 4
        loadTranscriptIfNeeded()
    }

    /// Fenster-Hinweis für den Nachlade-Button („512 KB → 2 MB").
    private var tailWindowHint: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB]
        formatter.countStyle = .binary
        let current = formatter.string(fromByteCount: Int64(transcriptTailBytes))
        let next = formatter.string(fromByteCount: Int64(transcriptTailBytes * 4))
        return "\(current) → \(next)"
    }

    /// Ended-State für Terminal-Tabs: kein Transcript, keine Summary — nur
    /// eine klare Ansage plus Neustart im selben Projektverzeichnis.
    @ViewBuilder
    private var terminalEndedView: some View {
        VStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(AgentTheme.textTertiary)
            Text("Shell beendet")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AgentTheme.textSecondary)
            Text(project.path)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(AgentTheme.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            Button {
                prepareCommand()
            } label: {
                Label("Neue Shell starten", systemImage: "play.fill")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AgentTheme.background)
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
            // Terminals sind ebenfalls raus: der `provider` ist dort nur
            // Schema-Platzhalter, eine Shell hat keine Claude-Hooks.
            let useHookBridge = launchSession.provider == .claude
                && !launchSession.isAgentView
                && !launchSession.isBackgroundChat
                && !launchSession.isTerminal
            if useHookBridge {
                let hookArgs = onPrepareClaudeHookArguments(launchSession.id)
                if !hookArgs.isEmpty {
                    builder.extraLaunchArguments = hookArgs
                }
            }
            let command = try builder.command(for: launchSession, project: project)
            let launchedController = terminalRegistry.startController(
                sessionID: launchSession.id,
                command: command,
                onLaunched: markLaunched,
                onTerminated: { exitCode in markTerminated(exitCode: exitCode) }
            )
            // Terminal-Tabs: Shell-Titel (OSC 0/2 — laufendes Kommando/cwd)
            // live als Tab-Titel übernehmen, solange der User nicht manuell
            // umbenannt hat. Agent-Tabs behalten den Auto-Namer als Quelle.
            if launchSession.isTerminal {
                let sessionID = launchSession.id
                launchedController.onTitleChanged = { title in
                    applyShellTitle(title, sessionID: sessionID)
                }
            }
            if useHookBridge {
                onClaudeHookLaunched(launchSession.id)
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func repairedSessionForLaunch() throws -> AgentChatSession {
        // Agent View und Terminal haben keine externe Session-ID — kein
        // Repair noetig (Terminals resumen nie, jede Shell ist frisch).
        guard !session.isAgentView, !session.isTerminal else {
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
                Logger.claudeBinding.notice("resume_transcript_missing localID=\(session.id.uuidString, privacy: .public) old=\(oldID, privacy: .public)")
                onStateChanged()
                // Ehrlich statt still: der Verlauf ist gerade nicht auffindbar —
                // Launch stoppen und den Zustand zeigen. Die Bindung bleibt
                // ERHALTEN (kein Reset): taucht das Transcript wieder auf
                // (transienter I/O-Fehler, externes Volume, Wiederherstellung),
                // resumed der nächste Start ganz normal.
                throw AgentResumeTranscriptMissingError(externalSessionID: oldID)
            }
        }

        // FINAL-GARANTIE (Superset-Prinzip): NIEMALS `claude --resume <id>` ohne
        // real existierendes Transkript. Der Indexer kann per mtime/size-Cache
        // eine laengst geloeschte ODER nie geschriebene ID noch als gueltig
        // melden (-> Repair-Outcome `.unchanged`) — wir vertrauen nur der echten
        // `<id>.jsonl`-Datei (Multi-Root-Suche über main + alle Profile).
        // Fehlt sie überall, wird der Launch mit klarer Meldung GESTOPPT — kein
        // „No conversation found" im Terminal, kein stiller Fresh-Start. Die
        // Bindung bleibt bewusst UNANGETASTET: negative Evidenz kann transient
        // sein, und ein gelöschter Verlauf soll als solcher sichtbar bleiben
        // statt kommentarlos durch eine leere Session ersetzt zu werden.
        let candidate = repair?.session ?? session
        if candidate.hasLaunchedInitialPrompt,
           let ext = candidate.externalSessionID, !ext.isEmpty,
           !ClaudeTranscriptReader.transcriptExists(forCwd: project.path, sessionID: ext) {
            Logger.claudeBinding.notice("resume_guard_transcript_missing localID=\(session.id.uuidString, privacy: .public) deadID=\(ext, privacy: .public)")
            try? store.updateSession(id: session.id) { updated in
                updated.shouldLaunchOnOpen = false
            }
            onStateChanged()
            throw AgentResumeTranscriptMissingError(externalSessionID: ext)
        }

        return candidate
    }

    private func restartTerminal() {
        terminalRegistry.terminate(sessionID: session.id)
        prepareCommand()
    }

    /// Übernimmt den von der Shell gemeldeten Titel (OSC 0/2) als Tab-Titel.
    /// Ein manueller User-Rename (`titleIsAutoGenerated == false`) gewinnt
    /// dauerhaft — danach schreiben wir nie wieder. `titleIsAutoGenerated`
    /// wird auf `true` gesetzt, damit der Legacy-Pfad in `canAutoRenameTitle`
    /// („Titel endet auf ‚ Chat'") für Terminals keine Rolle spielt.
    private func applyShellTitle(_ title: String, sessionID: UUID) {
        try? store.updateSession(id: sessionID) { updated in
            guard updated.isTerminal,
                  updated.titleIsAutoGenerated != false,
                  updated.title != title else { return }
            updated.title = title
            updated.titleIsAutoGenerated = true
        }
    }

    private func markLaunched() {
        do {
            try store.updateSession(id: session.id) { updated in
                updated.status = .running
                updated.hasLaunchedInitialPrompt = true
                updated.shouldLaunchOnOpen = false
                updated.initialPrompt = nil
            }
            // Crash-safe: der Launch-Marker entscheidet, ob die Indexer-
            // Adoption die Session nach einem App-Tod wiederfindet — nicht
            // dem 0,5-s-Debounce überlassen (Review-Befund 2026-07-13).
            store.flushNow(reason: "launch")
            // Agent View hat keine externe Session-ID — kein binding noetig.
            // Terminals ebenfalls nicht: das Binding würde sonst die zeitlich
            // nächste indizierte Claude-/Codex-Session „kapern" (gleicher
            // Platzhalter-Provider, gleiches Projekt, ±5s-Fenster).
            if !session.isAgentView && !session.isTerminal {
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

/// Wird vom Launch-Guard geworfen, wenn für eine resumebare Session in KEINEM
/// Account-Root (main + Profile, inkl. Session-ID-Fallback) mehr eine
/// Transcript-Datei existiert. Der Launch stoppt mit dieser Meldung; die
/// Bindung der Session bleibt bewusst erhalten — Chat-Verlust darf nie
/// lautlos passieren (Vorfall 2026-07-13).
struct AgentResumeTranscriptMissingError: LocalizedError {
    let externalSessionID: String

    var errorDescription: String? {
        "Chat-Verlauf momentan nicht auffindbar: Für Session \(externalSessionID) "
            + "existiert weder unter ~/.claude/projects noch in einem Account-Profil "
            + "(~/.claude-profiles/*/projects) eine Transcript-Datei. Falls sie "
            + "gelöscht wurde, lege für neue Arbeit einen neuen Chat an — dieser "
            + "Tab behält seine Zuordnung und resumed automatisch wieder, sobald "
            + "die Datei wieder auftaucht."
    }
}
