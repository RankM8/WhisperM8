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
    /// Wird gerufen direkt VOR dem Claude-Launch: schreibt die
    /// `--settings`-Datei (Hook-Bridge + Context-Profil-Overlay) und liefert
    /// Args + hooksActive-Flag. Der Default erlaubt der View, im Test-Setup
    /// ohne Coordinator zu laufen.
    var onPrepareLaunchSettings: (UUID, ClaudeContextProfile?) -> AgentSessionStatusCoordinator.LaunchSettingsPreparation = { _, _ in .none }
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
    /// Obergrenze des Nachlade-Fensters: ×4-Wachstum lief sonst unbegrenzt
    /// (512 KB → … → 128 MB) — ein voll geparster 100-MB-Chat killt die App
    /// über Speicher + Timeline-Build. 32 MiB decken monatelange Verläufe;
    /// darüber verschwindet der Nachlade-Button.
    private static let maxTailBytes = 32 * 1024 * 1024
    @State private var transcriptTailBytes = AgentSessionDetailView.initialTailBytes
    /// Feedback-Zustand des Nachladens (Spinner/„✓ N geladen"/Anfang).
    @State private var historyState = TranscriptHistoryState.idle
    /// Message-Zahl vor dem laufenden Nachladen — für das „✓ N"-Delta.
    @State private var countBeforeEarlierLoad: Int?
    /// Nachgeholter Fokus-Launch (Grid-Fokuswechsel) läuft bereits — schützt
    /// vor doppelter Hook-Vorbereitung bei schnellem Fokus-Hin-und-Her.
    @State private var focusLaunchInFlight = false
    /// Persistierter Terminal-Stand der beendeten Session (Stufe 1) — zeigt
    /// den echten CLI-Exit inkl. Resume-Hinweis, ohne JSONL zu laden.
    @State private var terminalSnapshot: TerminalSnapshot?
    /// Gleicher globaler Modus wie im Container — steuert hier, ob der
    /// Transcript-Load aufgeschoben werden darf (Terminal-Modus braucht
    /// kein JSONL) und wird beim Umschalten nachgeholt.
    @AppStorage("agentTranscriptViewMode") private var transcriptViewMode = "terminal"

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
                    onLoadEarlierHistory: transcriptTailBytes < Self.maxTailBytes
                        ? { loadEarlierHistory() } : nil,
                    history: historyState,
                    loadHint: tailWindowHint,
                    showsSummaryCard: !session.isSubagentJob,
                    terminalSnapshot: terminalSnapshot
                )
            }
        }
        .onAppear {
            if !suppressesAutoActivation {
                if session.shouldLaunchOnOpen == true {
                    launchAfterCacheWarmup()
                }
                // Direkt nach dem Mount Tastaturfokus auf das Terminal setzen,
                // damit der User sofort tippen kann und nicht im Sidebar-Filter
                // hängenbleibt. `focusTerminal` is async-dispatched — okay wenn
                // das View jetzt erst mountet.
                controller?.focusTerminal()
            }
            loadTerminalSnapshotIfNeeded()
            loadTranscriptIfNeeded()
        }
        .onChange(of: session.id) { _, _ in
            errorMessage = nil
            cachedTranscript = nil
            isLoadingTranscript = false
            transcriptTailBytes = Self.initialTailBytes
            historyState = .idle
            countBeforeEarlierLoad = nil
            terminalSnapshot = nil
            if !suppressesAutoActivation {
                if session.shouldLaunchOnOpen == true {
                    launchAfterCacheWarmup()
                }
                // Wechsel zwischen offenen Chats: dem neuen Terminal Fokus geben.
                controller?.focusTerminal()
            }
            loadTerminalSnapshotIfNeeded()
            loadTranscriptIfNeeded()
        }
        .onChange(of: actionRequest) { _, request in
            handleActionRequest(request)
        }
        // `whisperm8 chats resume`: Der Control-Handler setzt
        // `shouldLaunchOnOpen = true` — ist der Tab aber BEREITS offen und
        // selektiert, feuert weder onAppear noch der Session-ID-Wechsel
        // (GPT-Review-Befund). Dieser Trigger holt den Launch dann nach;
        // Guards wie beim Grid-Fokus-Nachholen (kein Controller, keine
        // laufende Vorbereitung, nicht unterdrückt).
        .onChange(of: session.shouldLaunchOnOpen) { wasSet, isSet in
            guard isSet == true, wasSet != true,
                  !suppressesAutoActivation,
                  controller == nil,
                  !focusLaunchInFlight else { return }
            focusLaunchInFlight = true
            launchAfterCacheWarmup()
        }
        // Umschalten Terminal → Chat/Roh holt den aufgeschobenen
        // Transcript-Load nach (im Terminal-Modus wird kein JSONL gelesen).
        .onChange(of: transcriptViewMode) { _, _ in
            loadTranscriptIfNeeded()
        }
        // Grid-Fokusmodell (Plan F9): Wird eine bisher unterdrückte Pane zur
        // Fokus-Pane (suppressesAutoActivation false), holt sie Launch +
        // Tastaturfokus GENAU EINMAL nach — die View remountet beim
        // Fokuswechsel nicht (stabile .id), onAppear feuert also nicht
        // erneut (Review-Finding: Offline-Panes starteten nie). Der Launch
        // läuft nur ohne existierenden Controller UND ohne bereits laufende
        // Vorbereitung — ein schnelles Hin-und-Her darf die Hook-Vorbereitung
        // nicht doppelt anstoßen (Review-Finding: doppeltes SessionStart-
        // Tracking).
        .onChange(of: suppressesAutoActivation) { wasSuppressed, isSuppressed in
            guard wasSuppressed, !isSuppressed else { return }
            if session.shouldLaunchOnOpen == true,
               controller == nil,
               !focusLaunchInFlight {
                focusLaunchInFlight = true
                launchAfterCacheWarmup()
            }
            controller?.focusTerminal()
        }
        .onChange(of: terminalRegistry.controller(for: session.id) != nil) { _, hasController in
            if hasController {
                focusLaunchInFlight = false
            } else {
                // Prozess gerade beendet: der Terminate-Pfad hat den Snapshot
                // synchron persistiert — jetzt laden, damit der beendete Chat
                // direkt als eingefrorenes Terminal erscheint.
                loadTerminalSnapshotIfNeeded()
                loadTranscriptIfNeeded()
            }
        }
    }

    /// Lädt den persistierten Terminal-Stand (falls vorhanden) off-main.
    /// Nur für Sessions ohne Live-Controller relevant — die Existenzprüfung
    /// selbst ist 1 stat() und läuft synchron für die Lade-Weiche.
    private func loadTerminalSnapshotIfNeeded() {
        guard controller == nil, !session.isAgentView, !session.isSubagentJob else {
            terminalSnapshot = nil
            return
        }
        let sessionID = session.id
        Task.detached(priority: .userInitiated) {
            let snapshot = TerminalSnapshotStore.shared.load(sessionID: sessionID)
            await MainActor.run {
                guard sessionID == session.id else { return }
                terminalSnapshot = snapshot
            }
        }
    }

    /// `true`, wenn der Transcript-Load aufgeschoben werden darf: Es gibt
    /// einen Terminal-Snapshot und der User ist im Terminal-Modus — für die
    /// reine Anzeige wird dann kein JSONL gelesen (Performance-Ziel der
    /// Snapshot-Architektur). Beim Umschalten auf Chat/Roh wird nachgeladen.
    private var transcriptLoadIsDeferred: Bool {
        transcriptViewMode == AgentTranscriptContainerView.TranscriptViewMode.terminal.rawValue
            && TerminalSnapshotStore.shared.hasSnapshot(sessionID: session.id)
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
        // Terminal-Modus mit Snapshot: JSONL-Load aufschieben — die Anzeige
        // braucht ihn nicht. Bereits geladene Transcripts bleiben gecacht
        // (kein Wegwerfen beim Zurückschalten).
        guard !transcriptLoadIsDeferred || cachedTranscript != nil else {
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
            // Geteilter LRU-Cache (Plan F12): Workspace-Wechsel mounten bis
            // zu 9 Offline-Panes — Cache-Hits liefern sofort, Misses teilen
            // sich den Read (global max. 2 parallel) statt CPU und SSD
            // gleichzeitig zu fluten. Frische via Datei-Identität
            // (Größe + mtime); Tail-Read bleibt bounded, egal wie groß die
            // JSONL ist.
            let transcript = await AgentTranscriptCache.shared.transcript(
                for: AgentTranscriptCache.Key(
                    provider: provider,
                    externalSessionID: externalID,
                    cwd: cwd,
                    tailBytes: tailBytes
                )
            )
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
        guard cachedTranscript?.hasTruncatedHead == true, countBeforeEarlierLoad == nil,
              transcriptTailBytes < Self.maxTailBytes else { return }
        countBeforeEarlierLoad = cachedTranscript?.messages.count ?? 0
        historyState = TranscriptHistoryState(isLoading: true, lastLoadedDelta: nil, reachedStart: false)
        transcriptTailBytes = min(transcriptTailBytes * 4, Self.maxTailBytes)
        loadTranscriptIfNeeded()
    }

    /// Fenster-Hinweis für den Nachlade-Button („512 KB → 2 MB").
    private var tailWindowHint: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB]
        formatter.countStyle = .binary
        let current = formatter.string(fromByteCount: Int64(transcriptTailBytes))
        let next = formatter.string(fromByteCount: Int64(min(transcriptTailBytes * 4, Self.maxTailBytes)))
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
                launchAfterCacheWarmup()
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
            launchAfterCacheWarmup()
        case .restart:
            restartTerminal()
        }
    }

    /// Wärmt die beim Launch blockierenden Caches (Login-Shell-PATH via
    /// `zsh -l`, `which`-Lookup des CLI-Binaries) off-main vor. Falls eine
    /// gespeicherte Claude-Resume-ID repariert werden muss, läuft auch der
    /// dafür nötige JSONL-Scan hier — `prepareCommand()` bleibt dadurch auf
    /// dem MainActor frei von blockierendem Datei-I/O.
    private func launchAfterCacheWarmup() {
        let commandName: String? = session.isTerminal
            ? nil
            : (session.provider == .claude ? "claude" : "codex")
        let launchSession = session
        let projectPath = project.path
        Task.detached(priority: .userInitiated) {
            _ = LoginShellEnvironment.shared.path
            if let commandName {
                _ = AgentCommandBuilder.commandPath(commandName)
            }

            let launchGuardResult: ClaudeGPTLaunchGuardResult
            if launchSession.provider == .claude,
               !launchSession.isTerminal,
               AppPreferences.shared.claudeGPTBackendEnabled {
                switch ClaudeCodeProxyManager.shared.ensureRunning(
                    port: AppPreferences.shared.claudeGPTBackendPort
                ) {
                case .success:
                    launchGuardResult = .ready
                case .failure(let error):
                    Logger.claudeGPTRouter.error(
                        "launch_guard_unavailable error=\(error.localizedDescription, privacy: .public)"
                    )
                    launchGuardResult = .unavailable
                }
            } else {
                launchGuardResult = .notNeeded
            }

            let resumeRepairPreparation: ResumeRepairPreparation
            if !launchSession.isAgentView,
               !launchSession.isTerminal,
               launchSession.provider == .claude,
               launchSession.hasLaunchedInitialPrompt,
               let externalID = launchSession.externalSessionID,
               !externalID.isEmpty,
               !ClaudeTranscriptReader.transcriptExists(forCwd: projectPath, sessionID: externalID) {
                // Nur einen Snapshot des persistenten Caches laden und lokal
                // erweitern. Kein Save hier: Ein paralleler globaler Scan darf
                // nicht durch einen älteren Snapshot überschrieben werden.
                var cache = AgentSessionIndexCacheStore().load()
                let indexedSessions = ClaudeSessionIndexer()
                    .indexedSessionResult(limit: 500, cache: &cache)
                    .sessions
                resumeRepairPreparation = .scanResult(indexedSessions)
            } else {
                resumeRepairPreparation = .noRepairNeeded
            }

            await MainActor.run {
                // Der Warmup kann bei kaltem Cache Sekunden dauern: Wurde die
                // Session inzwischen gelöscht oder archiviert, darf KEIN
                // Prozess mehr starten — sonst liefe ein unsichtbarer PTY
                // weiter bzw. markLaunched() setzte eine archivierte Session
                // wieder auf .running (Verify-Befund 2026-07-13).
                guard let currentSession = store.loadWorkspace().sessions
                    .first(where: { $0.id == launchSession.id }),
                    currentSession.status != .archived else {
                    // R4-RESUME-01: abgebrochener Launch gibt den
                    // Fokus-Trigger frei — sonst bleibt die Session
                    // dauerhaft launch-verriegelt.
                    focusLaunchInFlight = false
                    return
                }
                prepareCommand(
                    resumeRepairPreparation: resumeRepairPreparation,
                    launchGuardResult: launchGuardResult
                )
            }
        }
    }

    private func prepareCommand(
        resumeRepairPreparation: ResumeRepairPreparation,
        launchGuardResult: ClaudeGPTLaunchGuardResult
    ) {
        do {
            let launchSession = try repairedSessionForLaunch(
                resumeRepairPreparation: resumeRepairPreparation
            )
            let hasGPTModelStamp = !(launchSession.claudeBackendModel?
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            let hasGPTSubagentModel = !AppPreferences.shared.claudeGPTSubagentModel
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let launchDecision = ClaudeGPTLaunchGuard.decision(
                for: launchGuardResult,
                hasGPTModelStamp: hasGPTModelStamp,
                hasGPTSubagentModel: hasGPTSubagentModel
            )
            if launchDecision.presentsGPTFallbackAlert {
                presentGPTBackendFallbackAlert()
            }
            // Claude-Hook-Bridge: VOR dem Command-Build die Settings-Datei
            // erzeugen und `--settings <path>` als extra-Argument liefern.
            // Codex bekommt das nicht (kein Hook-API).
            var builder = AgentCommandBuilder()
            // Der Guard friert die Lifecycle-Entscheidung fuer genau diesen
            // Launch ein. Bei Fehler baut derselbe pure Builder damit den
            // bisherigen Direktbetrieb ohne Router-Env.
            builder.gptBackendEnabledResolver = { launchDecision.usesRouter }
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
            var launchPreparation = AgentSessionStatusCoordinator.LaunchSettingsPreparation.none
            if useHookBridge {
                // Context-Profil aufloesen (Session-Stempel > Projekt-Default;
                // geloescht → kein Overlay) und zusammen mit den Hooks in die
                // eine `--settings`-Datei composen. Das Profil-Env geht
                // zusaetzlich als Prozess-Env mit (wirkt ab Prozessstart).
                let contextProfile = ClaudeContextProfileStore.shared.resolvedProfile(
                    sessionStamp: launchSession.contextProfileID,
                    projectDefault: project.contextProfileID
                )
                launchPreparation = onPrepareLaunchSettings(launchSession.id, contextProfile)
                builder.extraLaunchArguments = launchPreparation.settingsArguments
                builder.extraEnvironmentOverrides =
                    ClaudeContextSettingsBuilder.processEnvironmentOverlay(for: contextProfile)
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
            // Tracking nur bei aktiver Hook-Bridge — eine Settings-Datei kann
            // seit Context-Profilen auch OHNE Hooks existieren.
            if launchPreparation.hooksActive {
                onClaudeHookLaunched(launchSession.id)
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            // R4-RESUME-01: Fehlerpfad (z. B. fehlendes Resume-Transcript,
            // Builder-Fehler) gibt den Launch-Trigger wieder frei — sonst
            // blockiert `focusLaunchInFlight` jeden weiteren Versuch, bis
            // irgendwann doch ein Controller erscheint.
            focusLaunchInFlight = false
        }
    }

    private func presentGPTBackendFallbackAlert() {
        let alert = NSAlert()
        alert.messageText = "GPT-Backend nicht erreichbar"
        alert.informativeText = "Chat startet mit dem Claude-Standardmodell. Details in Einstellungen > GPT-Backend."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func repairedSessionForLaunch(
        resumeRepairPreparation: ResumeRepairPreparation
    ) throws -> AgentChatSession {
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

        // FAST PATH: Der vorgeschaltete Detached-Task hat die JSONL bereits
        // per Stat geprüft. Im 99%-Fall ist damit kein Indexer-Scan nötig.
        guard case let .scanResult(indexedSessions) = resumeRepairPreparation else {
            return session
        }

        // SLOW PATH: gespeicherte ID hat keine entsprechende JSONL — vielleicht
        // wurde sie von Claude per `/resume` umgebogen, oder das Transcript
        // wurde manuell geloescht. Der teure Scan wurde off-main vorbereitet;
        // nur die serialisierte Store-Reparatur läuft auf dem MainActor.
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
        launchAfterCacheWarmup()
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
        let localSessionID = session.id
        let provider = session.provider
        let projectPath = project.path
        let store = store
        let onExternalSessionIDBound = onExternalSessionIDBound
        let onStateChanged = onStateChanged

        Task.detached(priority: .utility) {
            let retryDelays: [UInt64] = [
                250_000_000,
                500_000_000,
                1_000_000_000,
                2_000_000_000,
                4_000_000_000
            ]
            // Ein lokaler Cache für den gesamten Retry-Loop: Nach Versuch 1
            // liefern unveränderte JSONLs fast nur noch Cache-Treffer.
            var cache = AgentSessionIndexCacheStore().load()

            for delay in retryDelays {
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled else { return }

                // Der Hook ist die schnellere und genauere Quelle. Immer den
                // frischen Store lesen; `session` ist nur ein View-Snapshot.
                let currentSession = store.loadWorkspace().sessions
                    .first(where: { $0.id == localSessionID })
                guard let currentSession,
                      currentSession.externalSessionID == nil else { return }

                let indexedSessions: [IndexedAgentSession]
                switch provider {
                case .claude:
                    indexedSessions = ClaudeSessionIndexer()
                        .indexedSessionResult(limit: 20, cache: &cache)
                        .sessions
                case .codex:
                    indexedSessions = CodexSessionIndexer()
                        .indexedSessionResult(limit: 20, cache: &cache)
                        .sessions
                }

                let shouldStop = await MainActor.run {
                    // Der Hook kann während des Scans gewonnen haben. Dann
                    // weder erneut binden noch doppelte UI-Callbacks senden.
                    let freshSession = store.loadWorkspace().sessions
                        .first(where: { $0.id == localSessionID })
                    guard let freshSession,
                          freshSession.externalSessionID == nil else { return true }

                    do {
                        if try store.bindLatestIndexedSession(
                            localSessionID: localSessionID,
                            provider: provider,
                            projectPath: projectPath,
                            indexedSessions: indexedSessions
                        ) != nil {
                            onExternalSessionIDBound(localSessionID)
                            onStateChanged()
                            return true
                        }
                        return false
                    } catch {
                        errorMessage = error.localizedDescription
                        return true
                    }
                }
                if shouldStop { return }
            }
        }
    }
}

private enum ResumeRepairPreparation {
    case noRepairNeeded
    case scanResult([IndexedAgentSession])
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
