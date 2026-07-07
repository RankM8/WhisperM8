import Foundation

/// Liest einen kurzen "Conversation Tail" aus dem JSONL-Transcript einer
/// aktiven Agent-Session — typischerweise die letzte User-Message + die
/// letzte Assistant-Antwort, gekuerzt auf ein Token-vertraegliches Budget.
///
/// Wird vom `RecordingCoordinator` beim Recording-Start aufgerufen, um den
/// laufenden Chat-Kontext mit ins Post-Processing-Prompt-Paket zu schreiben.
/// Niemals den ganzen Transcript einbinden — das wuerde bei langen Sessions
/// das Modell-Kontextfenster sprengen und ist meist gar nicht hilfreich.
enum AgentChatTailExtractor {
    /// Default-Limit fuer die zusammengebaute Tail-Zeichenkette. ~600 Chars
    /// ≈ 150 Tokens; reicht fuer "worum geht's gerade".
    static let defaultMaxCharacters = 600

    /// Default Recency-Window fuer den `.agentView`-Fallback. Bewusst
    /// grosszuegiger als das UI-Tracker-Window (60 s im
    /// `ActiveBackgroundSessionTracker`): "in welchem Chat bin ich gerade"
    /// aendert sich nicht im Sekundentakt. Wenn der letzte Sub-Agent-Turn
    /// vor 3 Minuten war, ist das immer noch der relevante Chat.
    /// 10 Minuten ist ein praktikabler Kompromiss zwischen "frisch genug
    /// um relevant zu sein" und "alte historische Jobs aussortieren".
    static let agentViewRecencyWindow: TimeInterval = 600

    /// Liefert den Tail fuer eine `AgentChatContextRef`. Die Routing-Logik
    /// haengt am `effectiveKind` der Session:
    ///
    /// - `.chat` (Default fuer Legacy-Refs): JSONL via `externalSessionID`
    ///   aus dem provider-spezifischen Reader. Wenn die ID fehlt (Session
    ///   noch nie gestartet), gibt es `nil`.
    /// - `.backgroundChat`: Auflösung ueber den Supervisor — die Short-ID
    ///   verweist auf `~/.claude/jobs/<shortID>/state.json`, dort steht
    ///   der `linkScanPath` zur JSONL-Datei. Liest das JSONL direkt per
    ///   `ClaudeTranscriptReader.read(fileURL:)`. Falls die Short-ID fehlt
    ///   oder das state.json kaputt ist, gibt es `nil`.
    /// - `.agentView`: das Dashboard hat kein eigenes Transcript. Als
    ///   sinnvoller Fallback nehmen wir den **zuletzt aktiven** Sub-Job
    ///   aus dem Supervisor (`SupervisorJobReader.mostRecentlyActive`) —
    ///   das ist die heuristisch beste Annaeherung an "in welchem Agent
    ///   bin ich gerade", weil genau dieser Job gerade JSONL-Writes
    ///   produziert. Wenn nichts aktiv ist (alle Jobs aelter als das
    ///   Recency-Window), gibt es `nil`.
    ///
    /// Liest das JSONL nicht-blockierend genug, dass der Caller das gerne
    /// im Recording-Start-Pfad awaiten kann.
    static func extract(
        for ref: AgentChatContextRef,
        maxCharacters: Int = defaultMaxCharacters
    ) -> String? {
        switch ref.effectiveKind {
        case .chat:
            return extractFromChat(ref: ref, maxCharacters: maxCharacters)
        case .backgroundChat:
            return extractFromBackgroundChat(ref: ref, maxCharacters: maxCharacters)
        case .agentView:
            return extractFromAgentView(ref: ref, maxCharacters: maxCharacters)
        case .subagentJob:
            // Subagent-Jobs persistieren als normale Codex-Sessions —
            // derselbe Tail-Read wie beim Chat (externalSessionID =
            // codexThreadID des Jobs).
            return extractFromChat(ref: ref, maxCharacters: maxCharacters)
        case .terminal:
            // Normales Shell-Terminal: kein Transcript, kein Chat-Kontext.
            return nil
        }
    }

    /// Normaler interaktiver `.chat` (Claude oder Codex). Liest die JSONL
    /// ueber den provider-spezifischen Reader anhand der `externalSessionID`.
    private static func extractFromChat(
        ref: AgentChatContextRef,
        maxCharacters: Int
    ) -> String? {
        guard let externalID = ref.externalSessionID, !externalID.isEmpty else {
            return nil
        }
        // P3 S6: Tail-Read statt Voll-Parse — fuer die ~600 Zeichen Kontext
        // reicht das Dateiende, Transcripts koennen >50 MB gross sein.
        let transcript: AgentChatTranscript?
        switch ref.provider {
        case .claude:
            transcript = ClaudeTranscriptReader.readTail(cwd: ref.projectPath, sessionID: externalID)
        case .codex:
            transcript = CodexTranscriptReader.readTail(sessionID: externalID)
        }
        guard let transcript, !transcript.messages.isEmpty else { return nil }
        return summarize(messages: transcript.messages, maxCharacters: maxCharacters)
    }

    /// Background-Chat via `claude --bg`. Die `externalSessionID` zeigt hier
    /// nicht direkt auf eine JSONL (das ist die Supervisor-Short-ID, kein
    /// Claude-Session-UUID). Wir gehen den Umweg ueber das state.json des
    /// Supervisors und lesen den dort vermerkten `linkScanPath`.
    private static func extractFromBackgroundChat(
        ref: AgentChatContextRef,
        maxCharacters: Int
    ) -> String? {
        // Background-Chats sind exklusiv ein Claude-Feature — Codex hat
        // keinen `--bg`-Modus, ergo brauchen wir hier nur den Claude-Reader.
        guard ref.provider == .claude else { return nil }
        guard let shortID = ref.backgroundShortID, !shortID.isEmpty else {
            return nil
        }
        let stateFileURL = SupervisorJobReader.defaultJobsDirectory
            .appendingPathComponent(shortID, isDirectory: true)
            .appendingPathComponent("state.json")
        guard let state = SupervisorJobReader.readSingle(stateFileURL: stateFileURL, shortID: shortID),
              let linkScanPath = state.linkScanPath,
              !linkScanPath.isEmpty
        else {
            return nil
        }
        let transcript = ClaudeTranscriptReader.readTail(fileURL: URL(fileURLWithPath: linkScanPath))
        guard !transcript.messages.isEmpty else { return nil }
        return summarize(messages: transcript.messages, maxCharacters: maxCharacters)
    }

    /// `.agentView`-Dashboard. Da das TUI kein eigenes Transcript hat,
    /// approximieren wir "in welchem Sub-Agent ist der User gerade" ueber
    /// den Supervisor: derjenige Job, in dessen JSONL zuletzt geschrieben
    /// wurde, ist mit hoher Wahrscheinlichkeit der gerade fokussierte.
    /// Recency-Window beschneidet das Ganze auf "aktiv in den letzten
    /// `agentViewRecencyWindow` Sekunden" — sonst wuerde nach Stunden
    /// einfach der letzte historische Job als Tail erscheinen, was
    /// inhaltlich irrefuehrend waere.
    ///
    /// `now` ist als Parameter ausgehoben, damit Tests die Recency-Logik
    /// deterministisch durchspielen koennen.
    static func extractFromAgentView(
        ref: AgentChatContextRef,
        maxCharacters: Int,
        jobsDirectory: URL = SupervisorJobReader.defaultJobsDirectory,
        recencyWindow: TimeInterval = agentViewRecencyWindow,
        now: Date = Date()
    ) -> String? {
        // Agent View ist ausschliesslich ein Claude-Konstrukt — Codex hat
        // keinen eigenen Multi-Session-Dashboard-Modus.
        guard ref.provider == .claude else { return nil }
        let jobs = SupervisorJobReader.readAll(from: jobsDirectory)
        guard let active = SupervisorJobReader.mostRecentlyActive(
            among: jobs,
            within: recencyWindow,
            now: now
        ) else {
            return nil
        }
        guard let linkScanPath = active.linkScanPath, !linkScanPath.isEmpty else {
            return nil
        }
        let transcript = ClaudeTranscriptReader.readTail(fileURL: URL(fileURLWithPath: linkScanPath))
        guard !transcript.messages.isEmpty else { return nil }
        return summarize(messages: transcript.messages, maxCharacters: maxCharacters)
    }

    /// Pure-Funktion fuer Tests: nimmt eine Message-Liste, sucht die letzten
    /// User+Assistant-Messages, baut einen kompakten String.
    static func summarize(
        messages: [AgentChatMessage],
        maxCharacters: Int = defaultMaxCharacters
    ) -> String? {
        // Bewusst die letzte Message MIT Klartext — seit der Codex-Reader
        // auch Tool-Aktivitaet liefert (toolUse-only Assistant-Messages,
        // toolResult-only User-Messages), waere "letzte Message der Rolle"
        // oft textleer und der Kontext-Tail verloere seinen Inhalt.
        let lastAssistant = messages.last(where: { $0.role == .assistant && plainText(from: $0) != nil })
        let lastUser = messages.last(where: { $0.role == .user && plainText(from: $0) != nil })
        var lines: [String] = []
        if let user = lastUser, let text = plainText(from: user) {
            lines.append("[user] \(text)")
        }
        if let assistant = lastAssistant, let text = plainText(from: assistant) {
            lines.append("[assistant] \(text)")
        }
        guard !lines.isEmpty else { return nil }
        let joined = lines.joined(separator: "\n\n")
        return truncate(joined, maxCharacters: maxCharacters)
    }

    /// Reduziert eine Message auf einen Plain-Text-Anteil. Wir ignorieren
    /// Tool-Aufrufe, Tool-Results, Thinking-Bloecke und Bilder — die wuerden
    /// die Prompt-Groesse aufblaehen ohne neue inhaltliche Information ueber
    /// "worum geht's gerade" zu liefern. Wenn eine Message ausschliesslich
    /// aus Tool-Use besteht, liefern wir `nil` und der Caller fallback'd.
    static func plainText(from message: AgentChatMessage) -> String? {
        var parts: [String] = []
        for block in message.blocks {
            switch block {
            case .text(let text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { parts.append(trimmed) }
            case .toolUse, .toolResult, .imagePlaceholder, .thinking:
                continue
            }
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " ")
    }

    /// Schneidet einen langen String hart auf `maxCharacters` ab und haengt
    /// "…" an, damit das Modell erkennen kann, dass der Tail abgeschnitten
    /// wurde. Kein Wort-Boundary-Match — der Tail soll deterministisch
    /// reproduzierbar sein.
    static func truncate(_ raw: String, maxCharacters: Int) -> String {
        guard maxCharacters > 1, raw.count > maxCharacters else { return raw }
        let prefix = raw.prefix(maxCharacters - 1)
        return String(prefix) + "…"
    }
}
