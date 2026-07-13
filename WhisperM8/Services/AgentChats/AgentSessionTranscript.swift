import Foundation

/// Minimaler, providerübergreifender Event-Typ einer JSONL-Zeile aus Claude
/// Code (`~/.claude/projects/.../<id>.jsonl`) oder Codex CLI
/// (`~/.codex/sessions/.../rollout-*.jsonl`).
///
/// Wir interessieren uns nicht für den Inhalt, nur für genug Struktur, um den
/// Live-Status der Session ableiten zu können.
enum AgentTranscriptEvent: Equatable {
    case userMessage(timestamp: Date?)
    case assistantMessageStopped(timestamp: Date?, stopReason: String?)
    /// Assistant-Message ohne `stop_reason` → Tool-Use offen oder Streaming.
    case assistantMessageOngoing(timestamp: Date?)
    case toolResult(timestamp: Date?)
    /// User hat den Turn per ESC abgebrochen — Claude schreibt dann eine
    /// user-Zeile `[Request interrupted by user]` (ggf. „… for tool use").
    /// Eigener Fall statt `.userMessage`, weil ein Abbruch das GEGENTEIL
    /// eines Turn-Starts ist: der Chat idlet danach am Prompt.
    case turnInterrupted(timestamp: Date?)
    case sessionMeta
    /// Statusneutrale Claude-Zeile (`mode`, `last-prompt`, `queue-operation`,
    /// `attachment`, `summary`, `system`, …). Wird beim `lastEvent`-Scan
    /// ÜBERSPRUNGEN: solche Zeilen folgen oft NACH der semantisch relevanten
    /// Zeile — sie als „letztes Event" zu werten stufte arbeitende Chats über
    /// die 30-s-mtime-Heuristik fälschlich auf idle herab.
    case meta
    case other
}

enum AgentTranscriptParser {
    /// Parsed eine einzelne JSONL-Zeile. Liefert `nil`, wenn die Zeile kein
    /// gültiges JSON-Objekt ist (Truncated-Reads bei Tail-Polling sind normal).
    static func parseLine(_ line: String, provider: AgentProvider) -> AgentTranscriptEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        switch provider {
        case .claude: return parseClaudeLine(obj)
        case .codex: return parseCodexLine(obj)
        }
    }

    /// Liefert das letzte parsebare, statusRELEVANTE Event aus einem Stück
    /// Transkript. Tail-Reads können mit einer halben Zeile beginnen — wir
    /// parsen daher nicht starr ab dem ersten Newline, sondern scannen
    /// rückwärts. `.meta`-Zeilen (mode/last-prompt/queue-operation/…) werden
    /// übersprungen: sie folgen häufig NACH der semantischen Zeile und würden
    /// den Status sonst verwässern. Nur-Meta-Tail → `nil` („keine Meinung").
    static func lastEvent(in tailText: String, provider: AgentProvider) -> AgentTranscriptEvent? {
        let lines = tailText.split(omittingEmptySubsequences: true) { $0.isNewline }
        for line in lines.reversed() {
            if let event = parseLine(String(line), provider: provider) {
                if case .meta = event { continue }
                return event
            }
        }
        return nil
    }

    // MARK: - Claude

    /// Marker, mit dem Claude einen User-Abbruch (ESC) ins Transkript schreibt.
    /// Prefix-Match, weil es Varianten gibt („… for tool use]").
    static let interruptMarkerPrefix = "[Request interrupted by user"

    private static func parseClaudeLine(_ obj: [String: Any]) -> AgentTranscriptEvent? {
        let type = obj["type"] as? String
        let timestamp = parseDate(obj["timestamp"])
        switch type {
        case "user":
            // Claude packt Tool-Results in user-Messages mit einem `tool_result`
            // Content-Block — nicht echte User-Eingabe.
            if let message = obj["message"] as? [String: Any],
               let content = message["content"] as? [[String: Any]] {
                if content.contains(where: { ($0["type"] as? String) == "tool_result" }) {
                    return .toolResult(timestamp: timestamp)
                }
                if content.contains(where: { block in
                    (block["type"] as? String) == "text"
                        && ((block["text"] as? String)?.hasPrefix(interruptMarkerPrefix) ?? false)
                }) {
                    return .turnInterrupted(timestamp: timestamp)
                }
            }
            // Ältere Zeilen tragen den Content auch als reinen String.
            if let message = obj["message"] as? [String: Any],
               let text = message["content"] as? String,
               text.hasPrefix(interruptMarkerPrefix) {
                return .turnInterrupted(timestamp: timestamp)
            }
            return .userMessage(timestamp: timestamp)
        case "assistant":
            let message = obj["message"] as? [String: Any]
            if let stopReason = message?["stop_reason"] as? String, !stopReason.isEmpty {
                return .assistantMessageStopped(timestamp: timestamp, stopReason: stopReason)
            }
            return .assistantMessageOngoing(timestamp: timestamp)
        default:
            // Alles Nicht-Semantische (`summary`, `system`, `mode`,
            // `last-prompt`, `queue-operation`, `attachment`,
            // `file-history-snapshot`, künftige Typen) ist Meta — wird beim
            // Rückwärts-Scan übersprungen statt den Status zu bestimmen.
            return .meta
        }
    }

    // MARK: - Codex

    private static func parseCodexLine(_ obj: [String: Any]) -> AgentTranscriptEvent? {
        let timestamp = parseDate(obj["timestamp"])
        let type = obj["type"] as? String
        let subtype = obj["subtype"] as? String

        switch (type, subtype) {
        case ("event", "turn.completed"),
             ("event", "agent_turn.completed"),
             ("event", "agent.message.completed"):
            return .assistantMessageStopped(timestamp: timestamp, stopReason: subtype)
        case ("event", _):
            // Andere Events (`turn.started`, `thread.started`, …) markieren
            // Aktivität, ändern aber den Status-Slot nicht.
            return .other
        case ("item", "user_message"):
            return .userMessage(timestamp: timestamp)
        case ("item", "agent_message"),
             ("item", "assistant_message"):
            return .assistantMessageOngoing(timestamp: timestamp)
        case ("item", "function_call"),
             ("item", "tool_call"),
             ("item", "reasoning"):
            return .assistantMessageOngoing(timestamp: timestamp)
        case ("item", "function_call_output"),
             ("item", "tool_call_output"):
            return .toolResult(timestamp: timestamp)
        case ("meta", _), (nil, "session.meta"):
            return .sessionMeta
        default:
            // Fallback: einige Codex-Versionen legen `role` direkt aufs Top-Level.
            if let role = obj["role"] as? String {
                switch role {
                case "user": return .userMessage(timestamp: timestamp)
                case "assistant", "agent": return .assistantMessageOngoing(timestamp: timestamp)
                default: return .other
                }
            }
            if obj["meta"] != nil || obj["session_id"] != nil || obj["id"] != nil && obj["model"] != nil {
                return .sessionMeta
            }
            return .other
        }
    }

    // MARK: - Helpers

    private static func parseDate(_ raw: Any?) -> Date? {
        if let str = raw as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: str) {
                return date
            }
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: str)
        }
        if let interval = raw as? TimeInterval {
            return Date(timeIntervalSince1970: interval)
        }
        return nil
    }
}

/// Reine State-Decider-Funktion. Übersetzt das letzte erkannte Transcript-Event
/// + die File-Aktivität in einen `AgentSessionRuntimeStatus`.
///
/// Bewusst pure (kein Filesystem, kein Process) damit testbar.
enum AgentTranscriptStatusDecider {
    struct Decision: Equatable {
        var status: AgentSessionRuntimeStatus
        /// `true`, wenn der Decider erkannt hat, dass gerade ein vollständiger
        /// Agent-Turn beendet wurde — Trigger für Auto-Naming und
        /// `AgentChatSession.lastTurnAt`-Update.
        var turnFinished: Bool
        /// `true`, wenn der User den Turn abgebrochen hat (ESC-Interrupt im
        /// Transkript). Wird vom Koordinator IMMER angewendet — auch bei
        /// hook-getrackten Sessions, weil der Stop-Hook bei Interrupts nicht
        /// feuert und der Chat sonst für immer als „arbeitet" pulsiert.
        var turnAborted: Bool = false
    }

    /// Schwellwert: ab wann gilt eine ruhige Session ohne erkannten Stop als idle.
    static let idleAfterSeconds: TimeInterval = 30

    /// Sicherheitsnetz für „working ohne Ausweg": Wenn die JSONL so lange
    /// nicht mehr geschrieben wurde, obwohl das letzte Event Aktivität nahelegt
    /// (userMessage/toolResult/ongoing/tool_use), stufen wir auf idle herunter.
    /// Betrifft nur den Heuristik-Pfad (Codex/externe Sessions ohne Hooks) —
    /// hook-getrackte Sessions ignorieren Decider-Statusmeinungen ohnehin.
    /// Trade-off: ein hook-loser Tool-Lauf, der länger als 2 Minuten nichts
    /// ins Transkript schreibt, wird vorübergehend als idle angezeigt —
    /// das ist bewusst das kleinere Übel gegenüber ewigem Grün-Puls.
    static let workingStallSeconds: TimeInterval = 120

    /// `stop_reason`-Werte einer Claude-Assistant-Message, die KEIN Turn-Ende
    /// bedeuten (Anthropic-API): der Agent hat nur einen Tool-Aufruf abgesetzt
    /// (`tool_use`) bzw. eine Server-seitige Pause (`pause_turn`) und arbeitet
    /// danach weiter. Echte Turn-Enden sind `end_turn`, `stop_sequence`,
    /// `max_tokens`, `refusal` (bzw. fehlendes/`null` stop_reason → `.ongoing`).
    ///
    /// Kern des „Agent fertig obwohl noch Whirlpooling"-Bugs: während ein
    /// langlaufendes Bash-/Tool-Kommando läuft, ist die letzte JSONL-Zeile
    /// genau die Assistant-Message mit `stop_reason == "tool_use"`. Sie als
    /// Turn-Ende zu werten meldete `turnFinished` und löste die Fertig-
    /// Notification aus, während der Turn noch lief.
    static let continuationStopReasons: Set<String> = ["tool_use", "pause_turn"]

    /// - Parameter lastEvent: das letzte parsebare Event aus dem Transcript-Tail.
    /// - Parameter fileMTime: `Date` der letzten Datei-Modifikation.
    /// - Parameter now: aktuelle Zeit (injizierbar für Tests).
    /// - Parameter priorTurnFinishedAt: Zeitstempel des letzten als-fertig-markierten
    ///   Turns. Wenn das aktuelle Stop-Event älter oder gleich diesem Zeitstempel
    ///   ist, melden wir `turnFinished = false` (Re-Detection wird unterdrückt).
    /// - Returns: `nil`, wenn kein parsebares Event vorliegt — „keine Meinung".
    ///   Früher galt das als `.working`; genau das ließ frisch geöffnete Chats
    ///   ohne Prompt dauerhaft als „arbeitet" pulsieren.
    static func decide(
        lastEvent: AgentTranscriptEvent?,
        fileMTime: Date?,
        now: Date,
        priorTurnFinishedAt: Date?
    ) -> Decision? {
        guard let event = lastEvent else {
            return nil
        }

        let mtime = fileMTime ?? now
        let secondsSinceWrite = now.timeIntervalSince(mtime)
        // Sicherheitsnetz gegen hängende working-Zustände (Interrupt ohne
        // Marker-Zeile, Netz-/API-Abbruch ohne finales end_turn, Crash):
        // Aktivität, deren Datei seit `workingStallSeconds` unangetastet ist,
        // gilt nicht mehr als Arbeit.
        let isStalled = secondsSinceWrite > workingStallSeconds

        switch event {
        case .userMessage:
            return Decision(status: isStalled ? .idle : .working, turnFinished: false)

        case .assistantMessageStopped(let timestamp, let stopReason):
            // Tool-Aufruf/Pause ist KEIN Turn-Ende — der Agent arbeitet weiter,
            // sobald das Tool-Result vorliegt. Ohne diese Weiche wertete jeder
            // laufende Bash-/Tool-Schritt (dessen Assistant-Zeile die letzte im
            // JSONL ist) fälschlich als Turn-Ende → Fertig-Notification trotz
            // noch laufendem Chat.
            if let stopReason, Self.continuationStopReasons.contains(stopReason) {
                return Decision(status: isStalled ? .idle : .working, turnFinished: false)
            }
            let turnFinished: Bool = {
                guard let prior = priorTurnFinishedAt else { return true }
                guard let timestamp else {
                    // Wir haben kein Event-Timestamp — fallback auf File-Mtime.
                    return mtime > prior
                }
                return timestamp > prior
            }()
            return Decision(status: .idle, turnFinished: turnFinished)

        case .assistantMessageOngoing:
            // Laufende Assistant-Antwort = arbeitet. Früher wurde nach 8 s
            // Stille fälschlich auf .awaitingInput eskaliert — das verwechselte
            // langes Arbeiten (langer Tool-/Reasoning-Schritt, der nichts ins
            // JSONL schreibt) mit Warten auf Permission. „Braucht Handlung"
            // kommt jetzt ausschließlich vom Notification-Hook.
            return Decision(status: isStalled ? .idle : .working, turnFinished: false)

        case .toolResult:
            return Decision(status: isStalled ? .idle : .working, turnFinished: false)

        case .turnInterrupted:
            // ESC-Abbruch: Chat idlet am Prompt. Kein `turnFinished` — ein
            // Abbruch soll weder Auto-Naming noch Fertig-Notification auslösen.
            return Decision(status: .idle, turnFinished: false, turnAborted: true)

        case .sessionMeta, .meta, .other:
            // `.meta` erreicht diesen Pfad nur, wenn ein Aufrufer das Event
            // direkt durchreicht (der Tail-Scan überspringt es) — dann gilt
            // dieselbe konservative mtime-Heuristik wie für `.other`.
            if secondsSinceWrite > idleAfterSeconds {
                return Decision(status: .idle, turnFinished: false)
            }
            return Decision(status: .working, turnFinished: false)
        }
    }
}

/// Findet die JSONL-Datei einer Agent-Session anhand `externalSessionID` und
/// CWD. Beide CLIs schreiben deterministisch genug, dass wir das ohne
/// Indexer-Roundtrip lokalisieren können.
enum AgentTranscriptLocator {
    /// - Parameter globFallback: `false` überspringt den Session-ID-Glob
    ///   (Stufe 2) — für Hot-Paths wie den Runtime-Watcher, die im Takt
    ///   auflösen und keine Directory-Listings pro Tick leisten sollen.
    static func locate(
        provider: AgentProvider,
        externalSessionID: String,
        cwd: String,
        globFallback: Bool = true
    ) -> URL? {
        switch provider {
        case .claude:
            return locateClaude(externalSessionID: externalSessionID, cwd: cwd, globFallback: globFallback)
        case .codex:
            return locateCodex(externalSessionID: externalSessionID)
        }
    }

    /// Claude legt seine Files unter `~/.claude/projects/<encoded-cwd>/<sessionID>.jsonl` ab.
    /// Encoding: jeder Nicht-Alphanumerik-Char wird zu `-`.
    static func encodeClaudeCwd(_ cwd: String) -> String {
        let standardized = URL(fileURLWithPath: cwd).standardizedFileURL.path
        var result = ""
        result.reserveCapacity(standardized.count)
        for char in standardized {
            if char.isLetter || char.isNumber {
                result.append(char)
            } else {
                result.append("-")
            }
        }
        return result
    }

    private static func locateClaude(externalSessionID: String, cwd: String, globFallback: Bool = true) -> URL? {
        locateClaude(
            externalSessionID: externalSessionID,
            cwd: cwd,
            roots: ClaudeAccountProfiles().claudeProjectsRoots(),
            globFallback: globFallback
        )
    }

    /// Zweistufiger Claude-Lookup, mit injizierbaren Roots testbar.
    ///
    /// Stufe 1 (99%-Fall): deterministischer Pfad `<root>/<encoded-cwd>/<id>.jsonl`
    /// über alle Roots (main + Profile), main zuerst.
    ///
    /// Stufe 2 (Verteidigungslinie): flache Suche nach `<id>.jsonl` über ALLE
    /// Projekt-Ordner aller Roots. `encodeClaudeCwd` repliziert Claudes
    /// Pfad-Encoding — ändert Anthropic das Schema oder wurde der Projekt-
    /// Ordner umbenannt/verschoben, findet Stufe 1 nichts, obwohl die Datei
    /// existiert. Die Session-ID (UUID) ist dateiweit eindeutig, der
    /// Ordnername nicht — deshalb ist der Glob sicher. Läuft nur bei
    /// Stufe-1-Miss (selten); Kosten: ein Directory-Listing pro Root.
    static func locateClaude(
        externalSessionID: String,
        cwd: String,
        roots: [URL],
        fileManager: FileManager = .default,
        globFallback: Bool = true
    ) -> URL? {
        let encoded = encodeClaudeCwd(cwd)
        let fileName = "\(externalSessionID).jsonl"
        for root in roots {
            let url = root
                .appendingPathComponent(encoded)
                .appendingPathComponent(fileName)
            if fileManager.fileExists(atPath: url.path) {
                return url
            }
        }
        guard globFallback else { return nil }

        for root in roots {
            guard let projectDirs = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for dir in projectDirs where dir.lastPathComponent != encoded {
                let candidate = dir.appendingPathComponent(fileName)
                guard fileManager.fileExists(atPath: candidate.path) else { continue }
                // Kandidaten-Verifikation (Review-Befund 2026-07-13): Der
                // Fund über die Session-ID allein könnte eine kopierte/
                // fremde Datei sein. Nur akzeptieren, wenn der JSONL-Kopf
                // denselben cwd traegt wie erwartet — sonst koennten Resume,
                // Reader und Summarizer den FALSCHEN Chat erwischen.
                guard transcriptHeadMatchesCwd(candidate, expectedCwd: cwd) else {
                    Logger.agentStore.warning(
                        "claude_transcript_fallback_cwd_mismatch session=\(externalSessionID, privacy: .public) dir=\(dir.lastPathComponent, privacy: .public)"
                    )
                    continue
                }
                Logger.agentStore.notice(
                    "claude_transcript_located_by_fallback session=\(externalSessionID, privacy: .public) dir=\(dir.lastPathComponent, privacy: .public) expected=\(encoded, privacy: .public)"
                )
                return candidate
            }
        }
        return nil
    }

    /// `true` wenn der Kopf der JSONL (erste 200 Zeilen / 1 MiB) einen
    /// `cwd`-Eintrag traegt, der dem erwarteten cwd entspricht. Konservativ:
    /// kein `cwd` im Kopf → kein Match. Gleiche Bounded-Read-Strategie wie
    /// der Indexer.
    static func transcriptHeadMatchesCwd(_ url: URL, expectedCwd: String) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 1_048_576),
              let text = String(data: data, encoding: .utf8) else { return false }
        let expected = URL(fileURLWithPath: expectedCwd).standardizedFileURL.path
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).prefix(200) {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let cwd = obj["cwd"] as? String else { continue }
            return URL(fileURLWithPath: cwd).standardizedFileURL.path == expected
        }
        return false
    }

    /// P3 S4: Einmal gefundene Codex-Pfade sind stabil (Dateien wandern
    /// nicht) — der Cache erspart den rekursiven Walk bei jedem Lookup.
    /// Negative Ergebnisse werden bewusst NICHT gecacht: die Datei kann
    /// jederzeit erscheinen. NSCache ist thread-safe (Lookups laufen auch
    /// aus Detached-Tasks).
    private static let codexPathCache = NSCache<NSString, NSURL>()

    /// Codex schreibt unter `~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<sessionID>.jsonl`.
    /// Wir scannen rekursiv nach dem File, dessen Name die Session-ID enthält.
    private static func locateCodex(externalSessionID: String) -> URL? {
        let cacheKey = externalSessionID as NSString
        if let cached = codexPathCache.object(forKey: cacheKey) {
            let url = cached as URL
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
            codexPathCache.removeObject(forKey: cacheKey)
        }

        let sessionsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex")
            .appendingPathComponent("sessions")
        guard FileManager.default.fileExists(atPath: sessionsDir.path) else { return nil }
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return nil }

        for case let url as URL in enumerator {
            if url.pathExtension == "jsonl"
                && url.lastPathComponent.contains(externalSessionID) {
                codexPathCache.setObject(url as NSURL, forKey: cacheKey)
                return url
            }
        }
        return nil
    }
}

/// Ermittelt „tote Zeiger" — abgeschlossene Chats, deren Transkript-JSONL nicht
/// mehr auf der Platte liegt (z.B. von Claudes eigenem 30-Tage-Cleanup
/// gelöscht). Die Sidebar graut solche Einträge aus + labelt sie, statt sie
/// stillschweigend zu verstecken oder als resumebar darzustellen.
///
/// Bewusst KONSERVATIV: nur abgeschlossene (`closed`/`archived`), bereits
/// gestartete Sessions mit gebundener `externalSessionID` werden geprüft.
/// Frische/ungebundene/laufende Sessions sind nie „tot" — ihre Datei kann
/// jederzeit noch erscheinen. So markieren wir niemals fälschlich einen
/// echten Chat als gelöscht.
enum AgentTranscriptPresence {
    static func missingTranscriptSessionIDs(
        sessions: [AgentChatSession],
        projectPathByID: [UUID: String],
        runningSessionIDs: Set<UUID>
    ) -> Set<UUID> {
        let presentCodexIDs = presentCodexSessionIDs()
        var missing = Set<UUID>()
        for session in sessions {
            guard session.isManuallyCreated,
                  session.status == .closed || session.status == .archived,
                  session.hasLaunchedInitialPrompt,
                  !runningSessionIDs.contains(session.id),
                  let ext = session.externalSessionID, !ext.isEmpty,
                  let cwd = projectPathByID[session.projectID]
            else { continue }

            switch session.provider {
            case .claude:
                // Direkter fileExists-Check — günstig.
                if AgentTranscriptLocator.locate(provider: .claude, externalSessionID: ext, cwd: cwd) == nil {
                    missing.insert(session.id)
                }
            case .codex:
                // Über den EINEN Verzeichnis-Scan auflösen statt pro Session
                // rekursiv zu walken.
                if !presentCodexIDs.contains(ext.lowercased()) {
                    missing.insert(session.id)
                }
            }
        }
        return missing
    }

    /// Set aller Codex-Session-IDs, deren JSONL aktuell auf der Platte liegt —
    /// EIN rekursiver Walk über `~/.codex/sessions`. Codex-Dateien heißen
    /// `rollout-<ts>-<uuid>.jsonl`; die ID sind die letzten 36 Zeichen des Stems.
    private static func presentCodexSessionIDs() -> Set<String> {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex")
            .appendingPathComponent("sessions")
        guard FileManager.default.fileExists(atPath: dir.path),
              let enumerator = FileManager.default.enumerator(
                at: dir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
              )
        else { return [] }

        var ids = Set<String>()
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let stem = url.deletingPathExtension().lastPathComponent
            guard stem.count >= 36 else { continue }
            let candidate = String(stem.suffix(36)).lowercased()
            if UUID(uuidString: candidate) != nil {
                ids.insert(candidate)
            }
        }
        return ids
    }
}
