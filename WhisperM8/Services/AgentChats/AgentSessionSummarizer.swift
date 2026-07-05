import Foundation

/// Headless-Generator für Session-Zusammenfassungen — Spiegel des
/// `AgentTitleGenerator`-Musters: provider-spezifisches CLI, DI über
/// Closures, striktes JSON-Ausgabeformat mit tolerantem Parser.
struct AgentSummaryGenerator {
    var executableResolver: (AgentProvider) -> String?
    var runner: (URL, [String], [String: String]) async throws -> String

    static let live = AgentSummaryGenerator(
        executableResolver: { provider in
            switch provider {
            case .claude: return AgentCommandBuilder.commandPath("claude")
            case .codex: return AgentCommandBuilder.commandPath("codex")
            }
        },
        runner: AgentTitleGenerator.defaultRunner
    )

    /// Erwartetes JSON des Modells.
    struct Output: Codable, Equatable {
        var headline: String
        var details: String
        var status: String?
    }

    func generate(provider: AgentProvider, prompt: String) async throws -> Output {
        guard let path = executableResolver(provider) else {
            throw AgentTitleGeneratorError.executableNotFound(provider)
        }
        let executable = URL(fileURLWithPath: path)
        let args: [String]
        switch provider {
        case .claude:
            args = ["-p", prompt, "--output-format", "text"]
        case .codex:
            args = ["exec", "--skip-git-repo-check", prompt]
        }
        let stdout = try await runner(executable, args, LoginShellEnvironment.shared.processEnvironment())
        guard let output = Self.parseOutput(stdout) else {
            throw AgentTitleGeneratorError.emptyOutput
        }
        return output
    }

    /// Tolerant: Code-Fences strippen, erstes `{…}`-Objekt dekodieren.
    static func parseOutput(_ raw: String) -> Output? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            if let firstNewline = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: firstNewline)...])
            }
            if let closing = text.range(of: "```", options: .backwards) {
                text = String(text[..<closing.lowerBound])
            }
        }
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") else { return nil }
        let json = String(text[start...end])
        guard let data = json.data(using: .utf8),
              let output = try? JSONDecoder().decode(Output.self, from: data),
              !output.headline.trimmingCharacters(in: .whitespaces).isEmpty else {
            return nil
        }
        return output
    }

    static func summaryPrompt(excerpt: String, evidenceLines: String) -> String {
        """
        Du fasst eine Coding-Agent-Session für eine Übersichts-Karte zusammen. \
        Unten der Auszug (neueste Runden) und deterministisch extrahierte Fakten.
        Antworte NUR mit einem JSON-Objekt, ohne Text davor oder danach:
        {"headline": "1-2 Sätze: was in der Session erreicht wurde", \
        "details": "Markdown mit den Abschnitten **Aufgabe:**, **Verlauf:**, **Stand:** — insgesamt 3-8 Sätze", \
        "status": "abgeschlossen|offen|unterbrochen"}
        Erfinde KEINE Commits, SHAs oder Testergebnisse — die stehen bereits unter FAKTEN.

        FAKTEN:
        \(evidenceLines.isEmpty ? "(keine)" : evidenceLines)

        AUSZUG:
        \(excerpt)
        """
    }

    /// Kompakter Runden-Auszug fürs Prompt (neueste zuerst relevant, aber in
    /// chronologischer Reihenfolge belassen; hart gedeckelt).
    static func excerpt(from timeline: TranscriptTimeline, maxRounds: Int = 12, maxCharacters: Int = 6000) -> String {
        var lines: [String] = []
        for round in timeline.rounds.suffix(maxRounds) {
            if let prompt = round.prompt {
                let text = prompt.teammate?.gist ?? prompt.text
                lines.append("USER: " + String(text.prefix(280)).replacingOccurrences(of: "\n", with: " "))
            }
            if round.stats.toolCallCount > 0 {
                lines.append("[\(round.stats.toolCallCount) Tool-Aufrufe, \(round.stats.fileCount) Dateien, \(round.stats.errorCount) Fehler]")
            }
            for answer in round.answers {
                lines.append("AGENT: " + String(answer.text.prefix(500)).replacingOccurrences(of: "\n", with: " "))
            }
        }
        var result = lines.joined(separator: "\n")
        if result.count > maxCharacters {
            result = String(result.suffix(maxCharacters))
        }
        return result
    }

    static func evidenceLines(_ evidence: AgentSessionSummary.Evidence) -> String {
        var lines: [String] = []
        for commit in evidence.commits { lines.append("COMMIT \(commit.sha.prefix(7)) \(commit.message)") }
        for test in evidence.tests { lines.append("TEST \(test.passed ? "OK" : "FEHLGESCHLAGEN"): \(test.command)") }
        if !evidence.filesChanged.isEmpty { lines.append("DATEIEN: " + evidence.filesChanged.joined(separator: ", ")) }
        return lines.joined(separator: "\n")
    }
}

/// Orchestriert Chat-Zusammenfassungen: Digest-Guard (nie ein CLI-Lauf für
/// unveränderte Transcripts), inFlight-Schutz, Debounce nach Session-Ende.
/// Subagent-Jobs laufen NICHT hierüber — deren Summary kommt ohne LLM aus
/// dem Agent-Report (`applyReportSummary`).
@MainActor
final class AgentSessionSummarizer {
    static let shared = AgentSessionSummarizer()
    static let inFlightDidChangeNotification = Notification.Name("AgentSessionSummarizerInFlightDidChange")

    private let store: AgentSessionStore
    private let generator: AgentSummaryGenerator
    /// Mindest-Nachrichtenzahl für automatische Läufe (manuell: 1).
    private let minimumMessages = 4

    private(set) var inFlight: Set<UUID> = [] {
        didSet {
            guard oldValue != inFlight else { return }
            NotificationCenter.default.post(name: Self.inFlightDidChangeNotification, object: nil)
        }
    }
    private var terminationTasks: [UUID: Task<Void, Never>] = [:]

    init(store: AgentSessionStore = AgentSessionStore(), generator: AgentSummaryGenerator = .live) {
        self.store = store
        self.generator = generator
    }

    // MARK: - Digest

    /// "size-mtimeMs" — ein stat()-Aufruf, kein Lesen.
    nonisolated static func digest(forFileAt url: URL) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64 else { return nil }
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(size)-\(Int(mtime * 1000))"
    }

    /// Transcript-URL der Session (Claude braucht das Projekt-cwd).
    func transcriptURL(for session: AgentChatSession) -> URL? {
        guard let externalID = session.externalSessionID, !externalID.isEmpty else { return nil }
        switch session.provider {
        case .claude:
            guard let project = store.loadWorkspace().projects.first(where: { $0.id == session.projectID }) else { return nil }
            return ClaudeTranscriptReader.transcriptURL(forCwd: project.path, sessionID: externalID)
        case .codex:
            return CodexTranscriptReader.transcriptURL(forSessionID: externalID)
        }
    }

    /// `true` wenn das Transcript seit der letzten Zusammenfassung gewachsen
    /// ist (oder es nie eine gab) — Basis des „Veraltet"-Chips.
    func isSummaryStale(for session: AgentChatSession) -> Bool {
        guard let summary = session.summary else { return true }
        guard let url = transcriptURL(for: session), let current = Self.digest(forFileAt: url) else { return false }
        return summary.transcriptDigest != current
    }

    // MARK: - Trigger

    /// T2: PTY-Ende (Ctrl-C, exit, Prozess-Ende) — kurz debounced, damit
    /// letzte JSONL-Writes des CLI noch landen.
    func noteSessionTerminated(sessionID: UUID) {
        guard AppPreferences.shared.isAutoSummaryEnabled else { return }
        terminationTasks[sessionID]?.cancel()
        terminationTasks[sessionID] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.requestSummary(sessionID: sessionID, force: false, reason: "session-end")
        }
    }

    /// T3: Subagent-Abschluss — Summary direkt aus dem Report, KEIN LLM.
    func applyReportSummary(sessionID: UUID, report: AgentReport, transcriptDigest: String?) {
        var evidence = AgentSessionSummary.Evidence()
        evidence.commits = report.commits.map { .init(sha: $0.sha, message: $0.message) }
        if let tests = report.testsRun { evidence.tests = [.init(command: tests.command, passed: tests.passed)] }
        evidence.filesChanged = report.filesChanged
        let details = report.openQuestions.isEmpty
            ? ""
            : "**Offene Punkte:**\n" + report.openQuestions.map { "- \($0)" }.joined(separator: "\n")
        let summary = AgentSessionSummary(
            headline: report.summary,
            details: details,
            generatedAt: Date(),
            transcriptDigest: transcriptDigest,
            status: report.status == .success ? "abgeschlossen" : (report.status == .partial ? "offen" : "unterbrochen"),
            evidence: evidence.isEmpty ? nil : evidence
        )
        try? store.applySummary(id: sessionID, summary: summary)
    }

    /// T4: Start-Abgleich — nur die beim letzten Lauf offenen Tabs, hart
    /// gedeckelt und SERIELL (nie 6 parallele CLI-Läufe). Kurze Wartezeit,
    /// damit der erste Scan externe Session-IDs nachbinden kann.
    func runStartupReconciliation(openTabIDs: [UUID]) {
        guard AppPreferences.shared.isAutoSummaryEnabled else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard let self else { return }
            let sessions = self.store.loadWorkspace().sessions
            let candidates = SummaryStartupPlanner.plan(
                openTabIDs: openTabIDs,
                sessions: sessions,
                now: Date(),
                isStale: { self.isSummaryStale(for: $0) }
            )
            Logger.agentPerformance.debug("summarizer_startup candidates=\(candidates.count)")
            for sessionID in candidates {
                await self.summarizeIfNeeded(sessionID: sessionID, force: false, reason: "startup")
            }
        }
    }

    /// T5: manueller Refresh (Karte) bzw. Einzel-Trigger.
    func requestSummary(sessionID: UUID, force: Bool, reason: String) {
        Task { [weak self] in
            await self?.summarizeIfNeeded(sessionID: sessionID, force: force, reason: reason)
        }
    }

    /// Kern-Worker mit allen Guards; awaitbar für serielle Abarbeitung.
    func summarizeIfNeeded(sessionID: UUID, force: Bool, reason: String) async {
        guard force || AppPreferences.shared.isAutoSummaryEnabled else { return }
        guard !inFlight.contains(sessionID) else { return }
        guard let session = store.loadWorkspace().sessions.first(where: { $0.id == sessionID }),
              !session.isSubagentJob,
              let url = transcriptURL(for: session) else { return }
        let currentDigest = Self.digest(forFileAt: url)
        // Digest-Guard: unverändertes Transcript → garantiert kein CLI-Lauf.
        if !force, let currentDigest, session.summary?.transcriptDigest == currentDigest { return }

        inFlight.insert(sessionID)
        defer { inFlight.remove(sessionID) }
        let provider = session.provider
        let minimum = force ? 1 : minimumMessages
        Logger.agentPerformance.debug("summarizer_start session=\(sessionID) reason=\(reason, privacy: .public)")

        // Größeres Fenster als die UI (1 MB) — genug Kontext, hart gedeckelt.
        let timeline = await Task.detached(priority: .utility) {
            let transcript = provider == .claude
                ? ClaudeTranscriptReader.readTail(fileURL: url, tailBytes: 1024 * 1024)
                : CodexTranscriptReader.readTail(fileURL: url, tailBytes: 1024 * 1024)
            return TranscriptTimelineBuilder.build(from: transcript)
        }.value
        guard timeline.totalMessageCount >= minimum else { return }

        let evidence = TranscriptEvidenceExtractor.extract(from: timeline)
        let prompt = AgentSummaryGenerator.summaryPrompt(
            excerpt: AgentSummaryGenerator.excerpt(from: timeline),
            evidenceLines: AgentSummaryGenerator.evidenceLines(evidence)
        )
        do {
            let output = try await generator.generate(provider: provider, prompt: prompt)
            let summary = AgentSessionSummary(
                headline: output.headline,
                details: output.details,
                generatedAt: Date(),
                transcriptDigest: currentDigest,
                status: output.status,
                evidence: evidence.isEmpty ? nil : evidence
            )
            try store.applySummary(id: sessionID, summary: summary)
            Logger.agentPerformance.debug("summarizer_done session=\(sessionID)")
        } catch {
            Logger.agentPerformance.warning("summarizer_failed session=\(sessionID) error=\(error.localizedDescription, privacy: .public)")
        }
    }
}
