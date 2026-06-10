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
    case sessionMeta
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

    /// Liefert das letzte parsebare Event aus einem Stück Transkript. Tail-Reads
    /// können mit einer halben Zeile beginnen — wir parsen daher nicht starr ab
    /// dem ersten Newline, sondern nehmen die letzten N vollständig parsebaren
    /// Zeilen.
    static func lastEvent(in tailText: String, provider: AgentProvider) -> AgentTranscriptEvent? {
        let lines = tailText.split(omittingEmptySubsequences: true) { $0.isNewline }
        for line in lines.reversed() {
            if let event = parseLine(String(line), provider: provider) {
                return event
            }
        }
        return nil
    }

    // MARK: - Claude

    private static func parseClaudeLine(_ obj: [String: Any]) -> AgentTranscriptEvent? {
        let type = obj["type"] as? String
        let timestamp = parseDate(obj["timestamp"])
        switch type {
        case "user":
            // Claude packt Tool-Results in user-Messages mit einem `tool_result`
            // Content-Block — nicht echte User-Eingabe.
            if let message = obj["message"] as? [String: Any],
               let content = message["content"] as? [[String: Any]],
               content.contains(where: { ($0["type"] as? String) == "tool_result" }) {
                return .toolResult(timestamp: timestamp)
            }
            return .userMessage(timestamp: timestamp)
        case "assistant":
            let message = obj["message"] as? [String: Any]
            if let stopReason = message?["stop_reason"] as? String, !stopReason.isEmpty {
                return .assistantMessageStopped(timestamp: timestamp, stopReason: stopReason)
            }
            return .assistantMessageOngoing(timestamp: timestamp)
        case "summary":
            return .sessionMeta
        case "system":
            return .other
        default:
            return .other
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
    }

    /// Schwellwert: ab wann gilt ein offener Tool-Use als „wartet auf User-Input"
    /// (Permission-Prompt-Heuristik).
    static let awaitingInputAfterSeconds: TimeInterval = 8

    /// Schwellwert: ab wann gilt eine ruhige Session ohne erkannten Stop als idle.
    static let idleAfterSeconds: TimeInterval = 30

    /// - Parameter lastEvent: das letzte parsebare Event aus dem Transcript-Tail.
    /// - Parameter fileMTime: `Date` der letzten Datei-Modifikation.
    /// - Parameter now: aktuelle Zeit (injizierbar für Tests).
    /// - Parameter priorTurnFinishedAt: Zeitstempel des letzten als-fertig-markierten
    ///   Turns. Wenn das aktuelle Stop-Event älter oder gleich diesem Zeitstempel
    ///   ist, melden wir `turnFinished = false` (Re-Detection wird unterdrückt).
    static func decide(
        lastEvent: AgentTranscriptEvent?,
        fileMTime: Date?,
        now: Date,
        priorTurnFinishedAt: Date?
    ) -> Decision {
        guard let event = lastEvent else {
            return Decision(status: .working, turnFinished: false)
        }

        let mtime = fileMTime ?? now
        let secondsSinceWrite = now.timeIntervalSince(mtime)

        switch event {
        case .userMessage:
            return Decision(status: .working, turnFinished: false)

        case .assistantMessageStopped(let timestamp, _):
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
            if secondsSinceWrite > awaitingInputAfterSeconds {
                return Decision(status: .awaitingInput, turnFinished: false)
            }
            return Decision(status: .working, turnFinished: false)

        case .toolResult:
            return Decision(status: .working, turnFinished: false)

        case .sessionMeta, .other:
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
    static func locate(provider: AgentProvider, externalSessionID: String, cwd: String) -> URL? {
        switch provider {
        case .claude:
            return locateClaude(externalSessionID: externalSessionID, cwd: cwd)
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

    private static func locateClaude(externalSessionID: String, cwd: String) -> URL? {
        let encoded = encodeClaudeCwd(cwd)
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
            .appendingPathComponent("projects")
            .appendingPathComponent(encoded)
            .appendingPathComponent("\(externalSessionID).jsonl")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
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
