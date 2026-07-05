import Foundation

/// Baut aus einem `AgentChatTranscript` die Runden-Projektion
/// (`TranscriptTimeline`) für die Timeline-Ansicht. Pur und ohne I/O —
/// vollständig unit-testbar.
///
/// Invarianten:
/// - Verlustfrei: jeder Block jeder Message landet in genau einer Runde
///   (Prompt/Attachment, Tool-Step, Thinking, Note, System oder Antwort).
/// - Rundenstart = User-Message mit mindestens einem Text-Block. User-
///   Messages, die NUR Tool-Results tragen (Claude-Konvention), gehören zur
///   Aktivität der laufenden Runde.
/// - Assistant-Texte VOR dem letzten Aktivitäts-Step werden `.note`-Steps
///   (Zwischenberichte); nur die Trailing-Texte sind „die Antwort".
/// - Tool-Results werden per FIFO dem ältesten noch offenen Tool-Step
///   zugeordnet (Claude sendet sie in Aufruf-Reihenfolge zurück).
/// - IDs sind aus Message-IDs + Block-Index abgeleitet → stabil über
///   Live-Reloads, solange die Message-IDs stabil sind.
enum TranscriptTimelineBuilder {

    static func build(from transcript: AgentChatTranscript) -> TranscriptTimeline {
        var rounds: [TranscriptRound] = []
        var current: RoundAccumulator?

        for message in transcript.messages {
            switch message.role {
            case .user:
                let textBlocks = message.blocks.compactMap { block -> String? in
                    if case .text(let text) = block { return text }
                    return nil
                }
                if textBlocks.isEmpty {
                    // Tool-Result-/Attachment-only → Aktivität der laufenden
                    // Runde (bzw. Orphan-Runde am angeschnittenen Anfang).
                    current = current ?? RoundAccumulator(id: message.id.uuidString, prompt: nil)
                    current?.absorb(activityOf: message)
                } else {
                    // Neuer Prompt: Tool-Results in derselben Message beziehen
                    // sich noch auf die VORHERIGE Runde — erst dort abladen.
                    if var previous = current {
                        previous.absorb(toolResultsOf: message)
                        rounds.append(previous.finish())
                    } else if message.blocks.contains(where: { if case .toolResult = $0 { return true }; return false }) {
                        // Tool-Results ohne vorherige Runde (Fenster-Schnitt):
                        // eigene Orphan-Runde, damit nichts verloren geht.
                        var orphan = RoundAccumulator(id: "orphan-\(message.id.uuidString)", prompt: nil)
                        orphan.absorb(toolResultsOf: message)
                        rounds.append(orphan.finish())
                    }
                    let attachments = message.blocks.compactMap { block -> TranscriptAttachment? in
                        if case .imagePlaceholder(let mediaType, let byteSize) = block {
                            return TranscriptAttachment(mediaType: mediaType, byteSize: byteSize)
                        }
                        return nil
                    }
                    let promptText = textBlocks.joined(separator: "\n\n")
                    current = RoundAccumulator(
                        id: message.id.uuidString,
                        prompt: TranscriptPrompt(
                            text: promptText,
                            attachments: attachments,
                            timestamp: message.timestamp,
                            teammate: TeammateMessageParser.parse(promptText)
                        )
                    )
                }
            case .assistant:
                current = current ?? RoundAccumulator(id: message.id.uuidString, prompt: nil)
                current?.absorb(assistant: message)
            case .system:
                current = current ?? RoundAccumulator(id: message.id.uuidString, prompt: nil)
                current?.absorb(system: message)
            }
        }

        if let current {
            rounds.append(current.finish())
        }

        return TranscriptTimeline(
            rounds: rounds,
            isLiveSourcePossible: transcript.isLiveSourcePossible,
            totalMessageCount: transcript.messages.count
        )
    }

    // MARK: - Runden-Akkumulator

    /// Sammelt die Bestandteile einer Runde in Message-Reihenfolge und löst
    /// beim Abschluss die Antwort-/Note-Trennung sowie die Stats auf.
    private struct RoundAccumulator {
        let id: String
        let prompt: TranscriptPrompt?
        private var steps: [TranscriptStep] = []
        /// Trailing-Assistant-Texte — werden zu Notes degradiert, sobald
        /// danach noch Aktivität folgt.
        private var provisionalAnswers: [TranscriptAnswer] = []
        /// Indizes der Tool-Steps ohne gepaartes Result (FIFO).
        private var openToolStepIndices: [Int] = []
        private var firstTimestamp: Date?
        private var lastTimestamp: Date?

        init(id: String, prompt: TranscriptPrompt?) {
            self.id = id
            self.prompt = prompt
            if let ts = prompt?.timestamp { register(timestamp: ts) }
        }

        mutating func absorb(assistant message: AgentChatMessage) {
            register(timestamp: message.timestamp)
            for (index, block) in message.blocks.enumerated() {
                let blockID = "\(message.id.uuidString)-\(index)"
                switch block {
                case .text(let text):
                    provisionalAnswers.append(TranscriptAnswer(id: blockID, text: text, timestamp: message.timestamp))
                case .thinking(let text):
                    demoteProvisionalAnswersToNotes()
                    steps.append(TranscriptStep(id: blockID, kind: .thinking(text), timestamp: message.timestamp))
                case .toolUse(let name, let input):
                    demoteProvisionalAnswersToNotes()
                    let derived = ToolCallClassifier.classify(name: name, input: input)
                    steps.append(TranscriptStep(
                        id: blockID,
                        kind: .tool(TranscriptToolStep(
                            name: name,
                            op: derived.op,
                            subject: derived.subject,
                            detail: derived.detail,
                            input: input,
                            result: nil,
                            isError: false
                        )),
                        timestamp: message.timestamp
                    ))
                    openToolStepIndices.append(steps.count - 1)
                case .toolResult(let content, let isError):
                    // Unüblich in Assistant-Messages, aber verlustfrei behandeln.
                    attachToolResult(content: content, isError: isError, blockID: blockID, timestamp: message.timestamp)
                case .imagePlaceholder(let mediaType, let byteSize):
                    steps.append(TranscriptStep(
                        id: blockID,
                        kind: .note("Bild · \(mediaType) · \(byteSize) Bytes"),
                        timestamp: message.timestamp
                    ))
                }
            }
        }

        /// Aktivitäts-Anteile einer User-Message (Tool-Results, verirrte
        /// Attachments) — für Result-only-Messages innerhalb der Runde.
        mutating func absorb(activityOf message: AgentChatMessage) {
            register(timestamp: message.timestamp)
            for (index, block) in message.blocks.enumerated() {
                let blockID = "\(message.id.uuidString)-\(index)"
                switch block {
                case .toolResult(let content, let isError):
                    attachToolResult(content: content, isError: isError, blockID: blockID, timestamp: message.timestamp)
                case .imagePlaceholder(let mediaType, let byteSize):
                    steps.append(TranscriptStep(
                        id: blockID,
                        kind: .note("Bild · \(mediaType) · \(byteSize) Bytes"),
                        timestamp: message.timestamp
                    ))
                case .text, .toolUse, .thinking:
                    break // Text-tragende User-Messages laufen über den Prompt-Pfad.
                }
            }
        }

        /// Nur die Tool-Results einer Prompt-Message (gehören zur Vorrunde).
        mutating func absorb(toolResultsOf message: AgentChatMessage) {
            for (index, block) in message.blocks.enumerated() {
                if case .toolResult(let content, let isError) = block {
                    attachToolResult(
                        content: content,
                        isError: isError,
                        blockID: "\(message.id.uuidString)-\(index)",
                        timestamp: message.timestamp
                    )
                }
            }
        }

        mutating func absorb(system message: AgentChatMessage) {
            register(timestamp: message.timestamp)
            for (index, block) in message.blocks.enumerated() {
                if case .text(let text) = block {
                    steps.append(TranscriptStep(
                        id: "\(message.id.uuidString)-\(index)",
                        kind: .system(text),
                        timestamp: message.timestamp
                    ))
                }
            }
        }

        func finish() -> TranscriptRound {
            var stats = TranscriptActivityStats()
            var files: Set<String> = []
            for step in steps {
                switch step.kind {
                case .tool(let tool):
                    stats.toolCallCount += 1
                    if tool.isError { stats.errorCount += 1 }
                    if [.read, .edit, .write].contains(tool.op), !tool.subject.isEmpty {
                        files.insert(tool.subject)
                    }
                case .thinking: stats.thinkingCount += 1
                case .note: stats.noteCount += 1
                case .system: break
                }
            }
            stats.fileCount = files.count
            if let first = firstTimestamp, let last = lastTimestamp, last > first {
                stats.duration = last.timeIntervalSince(first)
            }
            return TranscriptRound(
                id: id,
                prompt: prompt,
                steps: steps,
                answers: provisionalAnswers,
                stats: stats
            )
        }

        // MARK: Intern

        private mutating func attachToolResult(content: String, isError: Bool, blockID: String, timestamp: Date?) {
            register(timestamp: timestamp)
            if let stepIndex = openToolStepIndices.first,
               case .tool(var tool) = steps[stepIndex].kind {
                openToolStepIndices.removeFirst()
                tool.result = content
                tool.isError = isError
                steps[stepIndex].kind = .tool(tool)
            } else {
                // Result ohne offenen Aufruf (Fenster-Schnitt) → eigener Step,
                // damit der Inhalt sichtbar bleibt.
                steps.append(TranscriptStep(
                    id: blockID,
                    kind: .tool(TranscriptToolStep(
                        name: "Tool-Ergebnis",
                        op: .other,
                        subject: String(content.prefix(60)),
                        detail: nil,
                        input: "",
                        result: content,
                        isError: isError
                    )),
                    timestamp: timestamp
                ))
            }
        }

        /// Assistant-Texte, denen noch Aktivität folgt, sind Zwischenberichte —
        /// als `.note`-Steps einreihen (Reihenfolge bleibt erhalten).
        private mutating func demoteProvisionalAnswersToNotes() {
            guard !provisionalAnswers.isEmpty else { return }
            for answer in provisionalAnswers {
                steps.append(TranscriptStep(id: answer.id, kind: .note(answer.text), timestamp: answer.timestamp))
            }
            provisionalAnswers.removeAll()
        }

        private mutating func register(timestamp: Date?) {
            guard let timestamp else { return }
            if firstTimestamp == nil || timestamp < firstTimestamp! { firstTimestamp = timestamp }
            if lastTimestamp == nil || timestamp > lastTimestamp! { lastTimestamp = timestamp }
        }
    }
}

/// Leitet aus Tool-Name + Input-JSON die Op-Klasse und ein menschenlesbares
/// Subject für die Detail-Zeile ab. Kennt die Claude-Code-Tools, Codex'
/// `exec_command` und MCP-Namenskonventionen; Unbekanntes fällt tolerant auf
/// `.other` + bestmögliches Subject zurück.
enum ToolCallClassifier {
    struct Classification: Equatable {
        var op: TranscriptOp
        var subject: String
        var detail: String?
    }

    static func classify(name: String, input: String) -> Classification {
        let fields = parseInputFields(input)
        let lowered = name.lowercased()

        if lowered.hasPrefix("mcp__") {
            // mcp__server__tool → „server · tool", Kern-Argument als Detail.
            let pretty = name
                .replacingOccurrences(of: "mcp__", with: "")
                .replacingOccurrences(of: "__", with: " · ")
            return Classification(op: .mcp, subject: pretty, detail: primaryArgument(in: fields))
        }

        switch lowered {
        case "read", "notebookread":
            return fileClassification(op: .read, fields: fields, fallback: name)
        case "edit", "multiedit", "notebookedit":
            return fileClassification(op: .edit, fields: fields, fallback: name)
        case "write":
            return fileClassification(op: .write, fields: fields, fallback: name)
        case "bash", "bashoutput":
            return Classification(op: .bash, subject: commandSubject(fields["command"] ?? fields["cmd"]) ?? name, detail: nil)
        case "exec_command":
            // Codex: arguments = {"cmd": "...", "workdir": "..."}.
            return Classification(
                op: .bash,
                subject: commandSubject(fields["cmd"] ?? fields["command"]) ?? name,
                detail: (fields["workdir"] as? String).map { ($0 as NSString).lastPathComponent }
            )
        case "grep", "glob":
            let pattern = (fields["pattern"] as? String) ?? ""
            let path = (fields["path"] as? String).map { ($0 as NSString).lastPathComponent }
            return Classification(op: .search, subject: pattern.isEmpty ? name : pattern, detail: path)
        case "webfetch", "websearch", "tool_search":
            let subject = (fields["url"] as? String) ?? (fields["query"] as? String) ?? name
            return Classification(op: .web, subject: subject, detail: nil)
        case "task", "agent":
            let subject = (fields["description"] as? String)
                ?? (fields["prompt"] as? String).map { String($0.prefix(60)) }
                ?? name
            return Classification(op: .task, subject: subject, detail: fields["subagent_type"] as? String)
        default:
            return Classification(op: .other, subject: primaryArgument(in: fields) ?? name, detail: nil)
        }
    }

    // MARK: - Intern

    /// Input ist bei Claude ein (pretty-printed) JSON-Objekt, bei Codex ein
    /// kompakter JSON-String. Nicht-JSON → leere Felder (Subject-Fallback).
    private static func parseInputFields(_ input: String) -> [String: Any] {
        guard let data = input.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return obj
    }

    private static func fileClassification(op: TranscriptOp, fields: [String: Any], fallback: String) -> Classification {
        guard let path = (fields["file_path"] as? String) ?? (fields["path"] as? String), !path.isEmpty else {
            return Classification(op: op, subject: fallback, detail: nil)
        }
        let ns = path as NSString
        let directory = ns.deletingLastPathComponent as NSString
        return Classification(
            op: op,
            subject: ns.lastPathComponent,
            detail: directory.lastPathComponent.nilIfEmpty
        )
    }

    /// Erste Zeile des Kommandos, auf Zeilenlänge gekürzt.
    private static func commandSubject(_ raw: Any?) -> String? {
        guard let command = raw as? String else { return nil }
        let firstLine = command.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? command
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.count > 90 ? String(trimmed.prefix(90)) + "…" : trimmed
    }

    /// Bestmögliches Subject aus generischen Feldern.
    private static func primaryArgument(in fields: [String: Any]) -> String? {
        for key in ["file_path", "path", "command", "cmd", "pattern", "url", "query", "description", "title", "prompt"] {
            if let value = fields[key] as? String, !value.isEmpty {
                return value.count > 90 ? String(value.prefix(90)) + "…" : value
            }
        }
        return nil
    }
}
