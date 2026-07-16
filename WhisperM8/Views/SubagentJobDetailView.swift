import SwiftUI

/// Detail-View eines Codex-Subagent-Jobs (kein PTY): Ergebnis-Karte oben,
/// Live-Transcript in der Mitte, Composer unten. Wird vom `mainWorkspace`
/// der `AgentChatsView` gerendert, solange der Job NICHT interaktiv
/// übernommen wurde — danach übernimmt die normale `AgentSessionDetailView`.
struct SubagentJobDetailView: View {
    let session: AgentChatSession
    let project: AgentProject
    /// Laufzeit-Snapshots (Phase/Metrics/Worktree) — vom Sync gepflegt.
    var jobRuntimeModel: AgentJobRuntimeModel = .shared
    /// Übernahme-Flow lebt in AgentChatsView+Subagents (braucht
    /// `sessionActionRequest`); die View meldet nur den Klick.
    var onTakeOver: () -> Void = {}
    /// Unread-Clearing beim Öffnen (AgentWindowStore gehört der Parent-View).
    var onAppearClearUnread: () -> Void = {}

    @State private var report: AgentReport?
    @State private var rawLastMessage: String?
    @State private var transcript: AgentChatTranscript?
    /// EINMALIG aufgelöste Rollout-JSONL-URL (rekursiver ~/.codex-Walk ist
    /// teuer — nie pro Render/Event neu suchen).
    @State private var cachedTranscriptURL: URL?
    /// Tail-first wie in AgentSessionDetailView: initial nur das Dateiende,
    /// mehr Verlauf per ×4-Eskalation auf User-Klick.
    @State private var transcriptTailBytes = TranscriptTailReader.defaultTailBytes
    @State private var historyState = TranscriptHistoryState.idle
    @State private var countBeforeEarlierLoad: Int?
    @State private var eventSource: FileEventSource?
    @State private var transcriptReloadTask: Task<Void, Never>?
    @State private var composerText = ""
    @State private var isSending = false
    @State private var errorMessage: String?

    private var shortId: String? { session.subagentJobShortID }

    private var snapshot: AgentJobState? {
        jobRuntimeModel.snapshot(for: session.id)
    }

    /// Send-Guards wie `AgentSendCLI`: nur auf ruhenden, nicht übernommenen
    /// Jobs mit bekannter Thread-ID.
    private var isComposerDisabled: Bool {
        guard let snapshot else { return true }
        return snapshot.isActive
            || snapshot.state == .takenOver
            || snapshot.codexThreadID == nil
            || isSending
    }

    var body: some View {
        VStack(spacing: 10) {
            headerBar

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(AgentTheme.statusError)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 2)
            }

            // Auftrag: der Prompt an den Subagent — immer sichtbar, ganz oben
            // (Prototyp: Hierarchie Auftrag → Ergebnis → Live-Verlauf).
            if let intent = snapshot?.intent, !intent.isEmpty {
                mandateBlock(intent)
            }

            resultCard

            AgentTranscriptContainerView(
                transcript: transcript,
                session: session,
                isWorking: snapshot?.isActive == true,
                onLoadEarlierHistory: transcriptTailBytes < Self.maxTailBytes
                    ? { loadEarlierHistory() } : nil,
                history: historyState,
                loadHint: nil
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AgentTheme.surface, in: RoundedRectangle(cornerRadius: 8))

            composer
        }
        .onAppear {
            onAppearClearUnread()
            reloadReport()
            startTranscriptWatchIfNeeded()
        }
        .onDisappear {
            eventSource?.stop()
            eventSource = nil
            transcriptReloadTask?.cancel()
        }
        // state.json-Flips kommen via FSEvents → Sync → Runtime-Modell:
        // Phasenwechsel lädt Report + Transcript nach (done schreibt
        // last-message.txt; ein frisch gestarteter Turn erzeugt die JSONL).
        .onChange(of: snapshot?.state) { _, _ in
            reloadReport()
            startTranscriptWatchIfNeeded()
            scheduleTranscriptReload()
        }
    }

    // MARK: - Kopfzeile

    private var headerBar: some View {
        HStack(spacing: 8) {
            statusPill

            VStack(alignment: .leading, spacing: 1) {
                Text(session.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AgentTheme.textPrimary)
                    .lineLimit(1)
                Text(headerSubtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(AgentTheme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            if snapshot?.isActive == true {
                Button {
                    stopJob()
                } label: {
                    Label("Stoppen", systemImage: "stop.circle")
                        .font(.system(size: 11, weight: .medium))
                }
                .help("SIGTERM an den Supervisor — Turn sauber abbrechen")
            }

            if session.subagentParentSessionID != nil {
                Button {
                    sendReportToParentChat()
                } label: {
                    Label("Report → Chat", systemImage: "arrowshape.turn.up.left")
                        .font(.system(size: 11, weight: .medium))
                }
                .disabled(report == nil && rawLastMessage == nil)
                .help("Report als Prompt-Baustein in die Claude-Session einfügen, die diesen Subagent gespawnt hat (ohne automatisches Absenden)")
            }

            Button {
                onTakeOver()
            } label: {
                Label("Interaktiv übernehmen", systemImage: "terminal")
                    .font(.system(size: 11, weight: .medium))
            }
            .disabled(snapshot == nil || snapshot?.isActive == true || snapshot?.state == .takenOver)
            .help("Job dauerhaft als interaktiven Codex-Chat fortsetzen (exklusiv — `agent send` ist danach deaktiviert)")
        }
    }

    private var headerSubtitle: String {
        var parts: [String] = []
        if let worktree = snapshot?.worktree {
            parts.append("⎇ \(worktree.branch)")
        }
        parts.append(session.subagentCwd ?? project.path)
        if let shortId {
            parts.append("Job \(shortId)")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var statusPill: some View {
        let (label, color) = statusPillContent
        Text(label)
            .font(.system(size: 9, weight: .bold))
            .tracking(0.04)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.16), in: Capsule())
            .overlay(Capsule().stroke(color.opacity(0.30), lineWidth: 0.5))
            .fixedSize()
    }

    private var statusPillContent: (String, Color) {
        switch snapshot?.state {
        case .spawning: return ("STARTET", .teal)
        case .running: return ("ARBEITET", .teal)
        case .done: return ("FERTIG", .green)
        case .failed: return ("FEHLER", .red)
        case .stopped: return ("GESTOPPT", .orange)
        case .takenOver: return ("ÜBERNOMMEN", .indigo)
        case nil: return ("KEIN JOB-STATE", .gray)
        }
    }

    // MARK: - Ergebnis-Karte

    /// Auftrag-Bubble (Gegenstück zur User-Bubble, von links).
    @ViewBuilder
    private func mandateBlock(_ intent: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("Auftrag")
                .font(.system(size: 9, weight: .bold))
                .tracking(0.6)
                .textCase(.uppercase)
                .foregroundStyle(AgentTheme.textTertiary)
                .padding(.top, 9)
            Text(intent)
                .font(.system(size: 12.5))
                .foregroundStyle(AgentTheme.textPrimary)
                .lineSpacing(2)
                .lineLimit(4)
                .truncationMode(.tail)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(
                    UnevenRoundedRectangle(
                        topLeadingRadius: 5, bottomLeadingRadius: 16,
                        bottomTrailingRadius: 16, topTrailingRadius: 16
                    )
                    .fill(AgentTheme.control)
                )
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var resultCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Ergebnis")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(AgentTheme.textTertiary)
                if let reportStatus = report?.status, snapshot?.isActive != true {
                    Text(reportStatus.rawValue.uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(reportStatusColor(reportStatus))
                    reportSourceChip
                }
                if snapshot?.isActive == true {
                    generatingChip
                }
                Spacer(minLength: 0)
                if let metrics = metricsLine {
                    Text(metrics)
                        .font(.system(size: 9.5).monospacedDigit())
                        .foregroundStyle(AgentTheme.textTertiary)
                }
            }

            // Zustands-Hierarchie (Prototyp): Übernommen → Live → Fehler →
            // Report → Roh-Fallback → Platzhalter. Die Karte hält ihren
            // Platz in JEDEM Zustand.
            if snapshot?.state == .takenOver {
                HStack(spacing: 8) {
                    Image(systemName: "keyboard")
                        .font(.system(size: 11))
                        .foregroundStyle(AgentTheme.textTertiary)
                    Text("Interaktiv übernommen — dieser Job läuft jetzt als normaler Codex-Chat weiter. Composer und `agent send` sind deaktiviert; der Verlauf unten bleibt lesbar.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(AgentTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if snapshot?.isActive == true {
                liveStrip
            } else if snapshot?.state == .failed, let reason = snapshot?.failureReason {
                Text(reason)
                    .font(.system(size: 12))
                    .foregroundStyle(AgentTheme.statusError)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Der letzte Report bleibt unten im Verlauf sichtbar. Ein Folge-Prompt startet einen frischen Turn.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(AgentTheme.textTertiary)
            } else if let report {
                TranscriptMarkdownView(text: report.summary)
                ReportEvidenceRows(report: report, includeOpenQuestions: false)
                if !report.openQuestions.isEmpty {
                    openQuestionsDisclosure(report)
                }
            } else if let rawLastMessage {
                // Nicht als Report parsebar → Rohtext durchreichen statt
                // still verwerfen.
                ScrollView {
                    Text(rawLastMessage)
                        .font(.system(size: 11).monospaced())
                        .foregroundStyle(AgentTheme.textSecondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
            } else {
                Text("Noch kein Report vorhanden.")
                    .font(.system(size: 11))
                    .foregroundStyle(AgentTheme.textTertiary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AgentTheme.panel, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AgentTheme.border, lineWidth: 1))
    }

    /// Live-Zeile IN der Karte (running): pulsierender Dot + Tool-Zähler +
    /// letztes Kommando — der Ergebnis-Platz bleibt reserviert.
    @ViewBuilder
    private var liveStrip: some View {
        let stats = liveToolStats
        HStack(spacing: 8) {
            TimelinePulsingDot(color: AgentTheme.statusWorking)
            Text(stats.count > 0 ? "arbeitet — \(stats.count) Tool-Aufrufe bisher" : "arbeitet …")
                .font(.system(size: 11.5))
                .foregroundStyle(AgentTheme.textSecondary)
            if let last = stats.lastSubject {
                Text("zuletzt: \(last)")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(AgentTheme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    /// Tool-Statistik aus dem Live-Transcript (Tail — bounded).
    private var liveToolStats: (count: Int, lastSubject: String?) {
        guard let messages = transcript?.messages else { return (0, nil) }
        var count = 0
        var last: String?
        for message in messages {
            for block in message.blocks {
                if case .toolUse(let name, let input) = block {
                    count += 1
                    last = ToolCallClassifier.classify(name: name, input: input).subject
                }
            }
        }
        return (count, last)
    }

    /// Teal-Chip: das Ergebnis stammt aus dem Agent-Report (kein LLM-Lauf).
    private var reportSourceChip: some View {
        HStack(spacing: 5) {
            Circle().fill(Color.teal).frame(width: 5, height: 5)
            Text("Quelle: Agent-Report")
        }
        .font(.system(size: 9.5, weight: .semibold))
        .foregroundStyle(Color.teal)
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(Color.teal.opacity(0.06), in: Capsule())
        .overlay(Capsule().stroke(Color.teal.opacity(0.3), lineWidth: 1))
    }

    private var generatingChip: some View {
        HStack(spacing: 5) {
            Text("✦")
                .font(.system(size: 10))
            Text("Turn läuft — Report folgt")
        }
        .font(.system(size: 9.5, weight: .semibold))
        .foregroundStyle(AgentTheme.accent)
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(AgentTheme.accentTintSoft, in: Capsule())
        .overlay(Capsule().stroke(AgentTheme.accentTint, lineWidth: 1))
    }

    /// Offene Fragen im Deep-Dive-Stil (Prototyp: „Offene Punkte & Hinweise").
    @ViewBuilder
    private func openQuestionsDisclosure(_ report: AgentReport) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(report.openQuestions.enumerated()), id: \.offset) { _, question in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text("?")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(AgentTheme.statusAwaiting)
                        Text(question)
                            .font(.system(size: 11))
                            .foregroundStyle(AgentTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.top, 6)
        } label: {
            Text("Offene Punkte & Hinweise (\(report.openQuestions.count))")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AgentTheme.textTertiary)
        }
    }

    private func reportStatusColor(_ status: AgentReport.Status) -> Color {
        switch status {
        case .success: return .green
        case .partial: return .orange
        case .failure: return .red
        }
    }

    private var metricsLine: String? {
        guard let snapshot else { return nil }
        var parts: [String] = ["Turns \(snapshot.turns)"]
        if let seconds = snapshot.metrics?.lastTurnSeconds {
            parts.append(String(format: "%.0fs", seconds))
        }
        if let files = snapshot.metrics?.diffChangedFiles {
            let added = snapshot.metrics?.diffAdded ?? 0
            let deleted = snapshot.metrics?.diffDeleted ?? 0
            parts.append("\(files) Dateien +\(added) −\(deleted)")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Composer

    /// Placeholder erklärt den Zustand (Prototyp) — nicht nur disabled.
    private var composerPlaceholder: String {
        if snapshot?.state == .takenOver { return "Übernommen — weiter im Terminal-Tab" }
        if snapshot?.isActive == true { return "Turn läuft — warten oder stoppen …" }
        return "Folge-Prompt an den Subagent …"
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(composerPlaceholder, text: $composerText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .lineLimit(1...5)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(AgentTheme.control, in: RoundedRectangle(cornerRadius: 8))
                .disabled(isComposerDisabled)

            Button {
                sendFollowUpPrompt()
            } label: {
                Image(systemName: isSending ? "hourglass" : "arrow.up.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(isComposerDisabled || composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? AgentTheme.textTertiary
                        : AgentTheme.accent)
            }
            .buttonStyle(.plain)
            .disabled(isComposerDisabled || composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .help(composerHelp)
        }
    }

    private var composerHelp: String {
        guard let snapshot else { return "Kein Job-State — Senden nicht möglich." }
        if snapshot.state == .takenOver { return "Job wurde interaktiv übernommen — Senden deaktiviert." }
        if snapshot.isActive { return "Turn läuft — warte auf done/failed oder stoppe den Job." }
        if snapshot.codexThreadID == nil { return "Keine Codex-Thread-ID — Resume unmöglich." }
        return "Startet einen Folge-Turn (detachter Supervisor)."
    }

    // MARK: - Aktionen

    /// Folge-Turn: exakt der `agent send`-Pfad, nur ohne Shell-out — Claim
    /// (prüfen → auf spawning reservieren → Prompt hinterlegen) läuft unterm
    /// selben prozessübergreifenden Job-Lock wie das CLI, damit Composer und
    /// parallele CLI-sends nicht racen (TOCTOU-Schutz aus dem Codex-Review).
    private func sendFollowUpPrompt() {
        guard let shortId else { return }
        let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        isSending = true
        errorMessage = nil
        Task {
            let failure: String? = await Task.detached(priority: .userInitiated) {
                let store = AgentJobStore()
                guard store.readCorrected(shortId: shortId) != nil else {
                    return "Job \(shortId) nicht gefunden."
                }
                var options = AgentSendOptions()
                options.shortId = shortId
                options.prompt = text
                let claim: Result<Void, AgentSendCLI.AgentSendClaimError>
                do {
                    claim = try store.withExclusiveLock(shortId: shortId) {
                        AgentSendCLI.claim(store: store, options: options)
                    }
                } catch {
                    return "Job-Lock fehlgeschlagen: \(error.localizedDescription)"
                }
                if case .failure(let claimError) = claim {
                    return claimError.message
                }
                do {
                    let pid = try AgentSupervisorLauncher().launchDetached(
                        shortId: shortId,
                        logURL: store.supervisorLogURL(for: shortId)
                    )
                    try store.mutateState(shortId: shortId) { $0.supervisorPid = pid }
                    return nil
                } catch {
                    // Claim hat schon auf spawning reserviert — ohne Supervisor
                    // wäre der Job sonst für 30s "aktiv" gesperrt.
                    _ = try? store.mutateState(shortId: shortId) { job in
                        if job.canTransition(to: .failed) { job.state = .failed }
                        job.failureReason = "Supervisor-Launch fehlgeschlagen: \(error.localizedDescription)"
                    }
                    return error.localizedDescription
                }
            }.value

            if let failure {
                errorMessage = failure
            } else {
                composerText = ""
                // Der Sync sieht den state.json-Flip via FSEvents ohnehin —
                // der explizite Anstoß macht den Status-Dot nur schneller.
                AgentJobWorkspaceSync.shared.requestSync(reason: "composer-send")
            }
            isSending = false
        }
    }

    /// Routet den Report in die Parent-Session (Fokus + Terminal-Injektion,
    /// ohne Auto-Enter — der User schickt selbst ab).
    private func sendReportToParentChat() {
        guard let parentExtID = session.subagentParentSessionID, !parentExtID.isEmpty else { return }
        guard let parent = AgentSessionStore().loadWorkspace().sessions
            .first(where: { !$0.isSubagentJob && $0.externalSessionID == parentExtID }) else {
            errorMessage = "Parent-Session nicht gefunden — wurde sie gelöscht?"
            return
        }
        let text: String
        if let report, let shortId {
            text = report.promptText(shortId: shortId)
        } else if let rawLastMessage {
            text = "Subagent-Report \(shortId ?? "?") (roh):\n\(rawLastMessage)"
        } else {
            return
        }
        AgentPromptRoutingService().route(text: text, toLocalSessionID: parent.id)
    }

    /// SIGTERM an den Supervisor — derselbe Weg wie `agent stop`.
    private func stopJob() {
        guard let pid = snapshot?.supervisorPid else {
            errorMessage = "Keine Supervisor-PID — Zustand inkonsistent."
            return
        }
        _ = kill(pid, SIGTERM)
        AgentJobWorkspaceSync.shared.requestSync(reason: "stop-clicked")
    }

    // MARK: - Report laden

    private func reloadReport() {
        guard let shortId else { return }
        Task {
            let lastMessage = await Task.detached(priority: .utility) {
                AgentJobStore().readLastMessage(shortId: shortId)
            }.value
            rawLastMessage = lastMessage
            report = lastMessage.flatMap(AgentReport.parse(lastMessage:))
        }
    }

    // MARK: - Live-Transcript

    /// Rollout-JSONL EINMALIG auflösen (rekursiver Walk über
    /// ~/.codex/sessions), dann vnode-Watch + initialer Tail-Read.
    private func startTranscriptWatchIfNeeded() {
        guard cachedTranscriptURL == nil, eventSource == nil else { return }
        guard let threadID = session.externalSessionID ?? snapshot?.codexThreadID,
              !threadID.isEmpty else { return }
        Task {
            let url = await Task.detached(priority: .utility) {
                CodexTranscriptReader.transcriptURL(forSessionID: threadID)
            }.value
            guard let url else { return } // JSONL existiert noch nicht — Retry beim nächsten Phasenwechsel
            guard cachedTranscriptURL == nil else { return }
            cachedTranscriptURL = url
            reloadTranscript(from: url)
            armEventSource(on: url)
        }
    }

    private func armEventSource(on url: URL) {
        eventSource?.stop()
        let source = FileEventSource(url: url)
        source.onChange = { scheduleTranscriptReload() }
        source.onFileGone = {
            // Rollout-Datei rotiert/gelöscht → Resolution invalidieren und
            // beim nächsten Anlass frisch auflösen.
            eventSource = nil
            cachedTranscriptURL = nil
            startTranscriptWatchIfNeeded()
        }
        if source.start() {
            eventSource = source
        }
    }

    /// Debounced (~200 ms) — JSONL-Appends kommen im Burst, ein Read reicht.
    private func scheduleTranscriptReload() {
        transcriptReloadTask?.cancel()
        transcriptReloadTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            if let url = cachedTranscriptURL {
                reloadTranscript(from: url)
            }
        }
    }

    /// Obergrenze des ×4-Fensters — Begründung siehe
    /// `AgentSessionDetailView.maxTailBytes`.
    private static let maxTailBytes = 32 * 1024 * 1024

    /// Explizites Nachladen älteren Verlaufs (×4-Fenster) mit Feedback-Zustand.
    private func loadEarlierHistory() {
        guard transcript?.hasTruncatedHead == true, countBeforeEarlierLoad == nil,
              transcriptTailBytes < Self.maxTailBytes,
              let url = cachedTranscriptURL else { return }
        countBeforeEarlierLoad = transcript?.messages.count ?? 0
        historyState = TranscriptHistoryState(isLoading: true, lastLoadedDelta: nil, reachedStart: false)
        transcriptTailBytes = min(transcriptTailBytes * 4, Self.maxTailBytes)
        reloadTranscript(from: url)
    }

    private func reloadTranscript(from url: URL) {
        let tailBytes = transcriptTailBytes
        Task {
            let fresh = await Task.detached(priority: .utility) {
                CodexTranscriptReader.readTail(fileURL: url, tailBytes: tailBytes)
            }.value
            transcript = fresh
            // Feedback nur für explizites Nachladen — Live-Reloads (Events)
            // fassen den History-Zustand nicht an.
            if let before = countBeforeEarlierLoad {
                countBeforeEarlierLoad = nil
                historyState = TranscriptHistoryState(
                    isLoading: false,
                    lastLoadedDelta: max(0, fresh.messages.count - before),
                    reachedStart: !fresh.hasTruncatedHead
                )
            }
        }
    }
}
