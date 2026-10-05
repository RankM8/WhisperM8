import Foundation

/// „Woran ist der Chat gerade?" — die Stand-Zeile des Tab-Switchers
/// (Plan `docs/plans/tab-switcher-workspace.md`, Abschnitt „Was die Zeile
/// zeigt"). Ephemer, wird nie persistiert.
///
/// Zwei Quellen fließen zusammen: `detail` kommt aus dem Transcript-Tail
/// (`AgentTranscriptActivityExtractor`, beide Provider), die Warte-Art aus
/// dem Hook-Pfad (nur Claude — Codex hat keine Hooks). Die fertige Zeile
/// baut erst `line(for:)`, weil sie vom aktuellen Status abhängt („› schreibt
/// Antwort" beim Arbeiten, der Antwortsatz erst im Ruhezustand).
struct AgentSessionActivity: Equatable, Sendable {
    enum Detail: Equatable, Sendable {
        /// Letzter Tool-Aufruf: Name + erstes Argument (bereits gekürzt,
        /// Pfade auf den Dateinamen reduziert).
        case tool(name: String, argument: String?)
        /// Offene Frage (`AskUserQuestion`), nur deren erste Zeile.
        case question(String)
        /// Erster Satz der letzten Antwort.
        case reply(String)
    }

    /// Obergrenze jeder Stand-Zeile (Plan: „auf 80 Zeichen gekappt").
    static let maxLength = 80

    var detail: Detail?
    /// Warte-Art aus dem Hook-Pfad (`AgentSessionStateMachine`), `nil`
    /// außerhalb von `awaitingInput` und bei Codex.
    var awaitingKind: AwaitingInputKind?
    /// Tool-Name aus dem `PermissionRequest`-Hook — für „Freigabe: Bash …".
    var awaitingToolName: String?

    init(detail: Detail? = nil, awaitingKind: AwaitingInputKind? = nil, awaitingToolName: String? = nil) {
        self.detail = detail
        self.awaitingKind = awaitingKind
        self.awaitingToolName = awaitingToolName
    }

    /// Nichts mehr drin → der Store entfernt den Eintrag.
    var isEmpty: Bool {
        detail == nil && awaitingKind == nil && awaitingToolName == nil
    }

    /// Die anzuzeigende Zeile für den gegebenen Status, oder `nil`, wenn es
    /// nichts Sinnvolles zu sagen gibt (dann zeigt die Kachel nur den Status).
    /// Die Dauer („· 2 min") ist Sache der View — sie tickt nur im offenen
    /// Switcher.
    func line(for status: AgentSessionRuntimeStatus?) -> String? {
        let raw: String?
        switch status {
        case .stopped:
            raw = "gestoppt"
        case .errored:
            raw = "Fehler"
        case .awaitingInput:
            raw = awaitingLine
        case .working:
            switch detail {
            case .tool:
                raw = toolLine
            case .question(let text):
                raw = "Frage: \(text)"
            case .reply:
                raw = "› schreibt Antwort"
            case nil:
                raw = nil
            }
        case .idle, nil:
            switch detail {
            case .reply(let text):
                raw = text
            case .question(let text):
                raw = "Frage: \(text)"
            case .tool, nil:
                // Ein Tool ohne Antwort danach im Ruhezustand (Abbruch,
                // Stau-Heilung) wäre veraltet — lieber nichts.
                raw = nil
            }
        }
        return raw.map { AgentTranscriptActivityExtractor.capped($0) }
    }

    private var awaitingLine: String? {
        switch awaitingKind {
        case .planApproval:
            return "Plan zur Freigabe"
        case .question:
            if case .question(let text) = detail { return "Frage: \(text)" }
            return "Frage"
        case .permission:
            // Der Tail kennt das Argument, der Hook den sicheren Namen. Passen
            // beide zusammen, gewinnt die ausführliche Form. Der Hook liefert
            // MCP-Tools voll (`mcp__srv__tool`), der Tail gekürzt — verglichen
            // und angezeigt wird deshalb beides in der Anzeigeform.
            let hookName = awaitingToolName.map(AgentTranscriptActivityExtractor.displayToolName)
            if case .tool(let name, let argument) = detail,
               hookName == nil || hookName == name {
                return "Freigabe: " + [name, argument].compactMap { $0 }.joined(separator: " ")
            }
            return hookName.map { "Freigabe: \($0)" } ?? "Freigabe"
        case nil:
            // Codex (keine Hooks): Art unbekannt, nur was der Tail weiß.
            switch detail {
            case .question(let text): return "Frage: \(text)"
            case .tool: return toolLine
            case .reply, nil: return nil
            }
        }
    }

    private var toolLine: String? {
        guard case .tool(let name, let argument) = detail else { return nil }
        if name == "ExitPlanMode" { return "Plan zur Freigabe" }
        return "› " + [name, argument].compactMap { $0 }.joined(separator: " ")
    }
}

/// Pure Ableitung der Stand-Zeile aus dem Transcript-Tail, den der
/// `AgentSessionRuntimeWatcher` ohnehin liest (keine eigene Datei-I/O).
///
/// Läuft rückwärts über die Zeilen, die erste Fundstelle gewinnt — bei
/// arbeitenden Chats steht sie fast immer in den letzten Zeilen, der Scan
/// bricht also früh ab. Ein Byte-Vorfilter (`memmem`) spart das JSON-Parsen
/// der vielen irrelevanten Zeilen (Tool-Ergebnisse, Reasoning, Token-Zähler,
/// Meta-Zeilen).
///
/// **Turn-Grenze:** Eine echte Nutzer-Eingabe beendet die Suche ohne
/// Treffer. Sonst zeigte ein Chat direkt nach dem Prompt das Tool oder die
/// Antwort des VORIGEN Turns als aktuellen Stand.
///
/// Die erste Zeile eines Tails ist meist abgeschnitten — sie ist kein
/// gültiges JSON und fällt beim Parsen von selbst heraus.
enum AgentTranscriptActivityExtractor {
    static func activity(in tail: String, provider: AgentProvider) -> AgentSessionActivity? {
        // Bewusst auf den UTF-8-Bytes statt auf `Character`s: Zeilen per
        // memrchr finden und per memmem vorfiltern kostet einen Bruchteil
        // der Graphem-Zerlegung — der Tail ist bis zu 64 KB groß und läuft
        // bei jedem Transcript-Write jeder aktiven Session.
        var tail = tail
        return tail.withUTF8 { buffer -> AgentSessionActivity? in
            guard let base = buffer.baseAddress, !buffer.isEmpty else { return nil }
            var end = buffer.count
            while end > 0 {
                // Letztes „\n" vor `end` (macOS kennt kein memrchr); ein
                // „\r" davor schluckt der JSON-Parser als Whitespace.
                var start = end
                while start > 0, base[start - 1] != 0x0A {
                    start -= 1
                }
                if start < end {
                    let line = UnsafeRawBufferPointer(start: base + start, count: end - start)
                    let outcome: Outcome
                    switch provider {
                    case .claude: outcome = claudeOutcome(line)
                    case .codex: outcome = codexOutcome(line)
                    }
                    switch outcome {
                    case .skip: break
                    case .boundary: return nil
                    case .found(let detail): return AgentSessionActivity(detail: detail)
                    }
                }
                end = start - 1
            }
            return nil
        }
    }

    /// Byte-Suche ohne String-Brücke (`memmem`).
    private static func contains(_ line: UnsafeRawBufferPointer, _ needle: StaticString) -> Bool {
        guard let base = line.baseAddress else { return false }
        return memmem(base, line.count, needle.utf8Start, needle.utf8CodeUnitCount) != nil
    }

    private enum Outcome {
        case skip
        case boundary
        case found(AgentSessionActivity.Detail)
    }

    // MARK: - Claude

    private static func claudeOutcome(_ line: UnsafeRawBufferPointer) -> Outcome {
        let isAssistant = contains(line, #""type":"assistant""#)
        let isUser = !isAssistant && contains(line, #""type":"user""#)
        guard isAssistant || isUser else { return .skip }
        // Tool-Ergebnisse sind die mit Abstand größten Zeilen — nie parsen.
        if isUser, contains(line, #""tool_result""#) { return .skip }
        guard let object = jsonObject(line),
              let message = object["message"] as? [String: Any] else { return .skip }

        switch object["type"] as? String {
        case "user":
            // System-Einschübe (`isMeta`) sind keine Eingabe des Nutzers.
            if object["isMeta"] as? Bool == true { return .skip }
            if object["isSidechain"] as? Bool == true { return .skip }
            // Tool-Ergebnis, das der Byte-Vorfilter nicht erkannt hat (der
            // Ergebnis-Text enthält selbst `"type":"assistant"`, dann gilt die
            // Zeile oben als Assistant-Kandidat): keine Turn-Grenze.
            if let blocks = message["content"] as? [[String: Any]],
               blocks.contains(where: { $0["type"] as? String == "tool_result" }) {
                return .skip
            }
            return .boundary
        case "assistant":
            if object["isSidechain"] as? Bool == true { return .skip }
            guard let blocks = message["content"] as? [[String: Any]] else {
                if let text = message["content"] as? String, let sentence = firstSentence(of: text) {
                    return .found(.reply(sentence))
                }
                return .skip
            }
            // Innerhalb einer Nachricht ebenfalls der jüngste Block zuerst;
            // reine Thinking-Zeilen werden übersprungen.
            for block in blocks.reversed() {
                switch block["type"] as? String {
                case "tool_use":
                    let name = block["name"] as? String ?? "Tool"
                    let input = block["input"] as? [String: Any] ?? [:]
                    return .found(claudeToolDetail(name: name, input: input))
                case "text":
                    if let text = block["text"] as? String, let sentence = firstSentence(of: text) {
                        return .found(.reply(sentence))
                    }
                default:
                    continue
                }
            }
            return .skip
        default:
            return .skip
        }
    }

    private static func claudeToolDetail(name: String, input: [String: Any]) -> AgentSessionActivity.Detail {
        if name == "AskUserQuestion" {
            let questions = input["questions"] as? [[String: Any]]
            let question = (questions?.first?["question"] as? String) ?? (input["question"] as? String)
            if let first = question.flatMap(firstLine(of:)) {
                return .question(capped(first))
            }
        }
        if name == "ExitPlanMode" {
            return .tool(name: name, argument: nil)
        }
        return .tool(name: displayToolName(name), argument: firstArgument(of: input))
    }

    /// MCP-Tools heißen `mcp__<server>__<tool>` — für eine 80-Zeichen-Zeile
    /// reicht der Tool-Teil.
    static func displayToolName(_ name: String) -> String {
        guard name.hasPrefix("mcp__"),
              let range = name.range(of: "__", options: .backwards),
              range.upperBound < name.endIndex else { return name }
        return String(name[range.upperBound...])
    }

    // MARK: - Codex

    /// Muster, nach denen eine Zeile überhaupt geparst wird. `"function_call"`
    /// mit schließendem Anführungszeichen trifft bewusst NICHT
    /// `function_call_output`.
    private static let codexCandidates: [StaticString] = [
        #""function_call""#, #""custom_tool_call""#, #""local_shell_call""#,
        #""web_search_call""#, #""message""#, #""user_message""#, #""agent_message""#,
    ]

    private static func codexOutcome(_ line: UnsafeRawBufferPointer) -> Outcome {
        guard codexCandidates.contains(where: { contains(line, $0) }),
              let object = jsonObject(line),
              let payload = object["payload"] as? [String: Any] else { return .skip }
        let payloadType = payload["type"] as? String

        switch (object["type"] as? String, payloadType) {
        case ("event_msg", "user_message"):
            return .boundary
        case ("event_msg", "agent_message"):
            if let text = payload["message"] as? String, let sentence = firstSentence(of: text) {
                return .found(.reply(sentence))
            }
            return .skip
        case ("response_item", "message"):
            switch payload["role"] as? String {
            case "user":
                return .boundary
            case "assistant":
                let blocks = payload["content"] as? [[String: Any]] ?? []
                for block in blocks.reversed() {
                    if let text = block["text"] as? String, let sentence = firstSentence(of: text) {
                        return .found(.reply(sentence))
                    }
                }
                return .skip
            default:
                // developer/system: Anweisungen, kein Stand.
                return .skip
            }
        case ("response_item", "function_call"):
            let name = payload["name"] as? String ?? "Tool"
            let arguments = (payload["arguments"] as? String).flatMap { jsonObject($0) } ?? [:]
            return .found(codexFunctionDetail(name: name, arguments: arguments))
        case ("response_item", "custom_tool_call"):
            let name = payload["name"] as? String ?? "Tool"
            return .found(codexCustomDetail(name: name, input: payload["input"] as? String ?? ""))
        case ("response_item", "local_shell_call"):
            let action = payload["action"] as? [String: Any] ?? [:]
            return .found(.tool(name: "Bash", argument: shellArgument(action["command"])))
        case ("response_item", "web_search_call"):
            let action = payload["action"] as? [String: Any] ?? [:]
            return .found(.tool(name: "WebSearch", argument: (action["query"] as? String).map(normalizedArgument)))
        default:
            return .skip
        }
    }

    /// Shell-Werkzeuge heißen bei Codex je nach Version verschieden — in der
    /// Zeile einheitlich „Bash" wie bei Claude, damit der Switcher über beide
    /// Provider gleich liest.
    private static let codexShellTools: Set<String> = ["shell", "exec_command", "shell_command", "container.exec"]

    private static func codexFunctionDetail(name: String, arguments: [String: Any]) -> AgentSessionActivity.Detail {
        if codexShellTools.contains(name) {
            return .tool(name: "Bash", argument: shellArgument(arguments["cmd"] ?? arguments["command"]))
        }
        if name == "apply_patch", let patch = arguments["input"] as? String {
            return .tool(name: "Edit", argument: patchTarget(patch))
        }
        return .tool(name: displayToolName(name), argument: firstArgument(of: arguments))
    }

    /// Freiform-Tools: `apply_patch` (Patch-Text) und `exec` (JavaScript, das
    /// seinerseits `tools.exec_command({cmd:"…"})` ruft).
    private static func codexCustomDetail(name: String, input: String) -> AgentSessionActivity.Detail {
        if name == "apply_patch" {
            return .tool(name: "Edit", argument: patchTarget(input))
        }
        if let inner = innerToolCall(in: input) {
            let innerName = codexShellTools.contains(inner.name) ? "Bash" : inner.name
            return .tool(name: innerName, argument: inner.argument.map(normalizedArgument))
        }
        return .tool(name: name, argument: firstLine(of: input).map(normalizedArgument))
    }

    /// Erste geänderte Datei eines Patches (`*** Update File: pfad`).
    private static func patchTarget(_ patch: String) -> String? {
        for prefix in ["*** Update File: ", "*** Add File: ", "*** Delete File: "] {
            if let range = patch.range(of: prefix) {
                let rest = patch[range.upperBound...]
                let path = rest.prefix { !$0.isNewline }
                return capped(fileName(String(path)))
            }
        }
        return nil
    }

    /// `tools.<name>({cmd:"…"` bzw. `({"cmd":"…"` aus dem JS eines
    /// `exec`-Aufrufs — ohne Regex-Engine, das hier läuft im Poll-Pfad.
    private static func innerToolCall(in input: String) -> (name: String, argument: String?)? {
        guard let toolsRange = input.range(of: "tools.") else { return nil }
        let afterTools = input[toolsRange.upperBound...]
        let name = afterTools.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
        guard !name.isEmpty else { return nil }
        let call = afterTools.dropFirst(name.count).prefix(4096)
        var argument: String?
        for key in ["cmd:", #""cmd":"#, "command:", #""command":"#] {
            guard let keyRange = call.range(of: key) else { continue }
            let value = call[keyRange.upperBound...].drop { $0 == " " }
            guard let quote = value.first, quote == "\"" || quote == "'" || quote == "`" else { continue }
            var result = ""
            var escaped = false
            for character in value.dropFirst() {
                if escaped {
                    result.append(character == "n" || character == "t" ? " " : character)
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == quote {
                    break
                } else {
                    result.append(character)
                }
                if result.count > AgentSessionActivity.maxLength * 4 { break }
            }
            argument = result
            break
        }
        return (String(name), argument)
    }

    /// `["bash", "-lc", "swift test"]` → `swift test`; ein String bleibt.
    private static func shellArgument(_ raw: Any?) -> String? {
        if let string = raw as? String { return normalizedArgument(string) }
        guard var parts = raw as? [String], !parts.isEmpty else { return nil }
        if parts.count >= 3, ["bash", "zsh", "sh", "/bin/bash", "/bin/zsh", "/bin/sh"].contains(parts[0]),
           parts[1].hasPrefix("-"), parts[1].contains("c") {
            parts = Array(parts.dropFirst(2))
        }
        return normalizedArgument(parts.joined(separator: " "))
    }

    // MARK: - Argumente und Kürzung

    /// Reihenfolge, in der ein Argument als „das erste" gilt. Die
    /// JSON-Schlüsselreihenfolge taugt dafür nicht (`Edit` beginnt mit
    /// `replace_all`, und `JSONSerialization` liefert ohnehin ungeordnet).
    private static let argumentPriority = [
        "file_path", "notebook_path", "command", "cmd", "pattern", "query", "url",
        "path", "skill", "description", "subject", "prompt", "to", "target",
    ]
    private static let pathKeys: Set<String> = ["file_path", "notebook_path", "path"]

    private static func firstArgument(of input: [String: Any]) -> String? {
        for key in argumentPriority {
            guard let value = input[key] as? String, !value.isEmpty else { continue }
            if pathKeys.contains(key) {
                return capped(fileName(value))
            }
            return normalizedArgument(value)
        }
        // Unbekanntes Tool: erster String-Wert, für stabile Ausgabe nach
        // Schlüssel sortiert.
        for key in input.keys.sorted() {
            if let value = input[key] as? String, !value.isEmpty {
                return normalizedArgument(value)
            }
        }
        return nil
    }

    /// Einzeilig, Pfade auf den Dateinamen, gekappt.
    static func normalizedArgument(_ raw: String) -> String {
        // Vorab begrenzen: ein Heredoc-Bash kann Zehntausende Zeichen haben.
        let words = collapsedWhitespace(String(raw.prefix(AgentSessionActivity.maxLength * 4)))
            .split(separator: " ")
            .map { shortenedPathToken(String($0)) }
        return capped(words.joined(separator: " "))
    }

    /// `/Users/x/repo/Store.swift` → `Store.swift`; auch `~/…`, `./…` und in
    /// Anführungszeichen. Kommandos wie `/usr/bin/env` werden genauso
    /// gekürzt — gewollt, die Zeile soll kurz sein.
    private static func shortenedPathToken(_ token: String) -> String {
        let quoteSet = CharacterSet(charactersIn: "\"'`")
        let bare = token.trimmingCharacters(in: quoteSet)
        guard bare.hasPrefix("/") || bare.hasPrefix("~/") || bare.hasPrefix("./") || bare.hasPrefix("../"),
              bare.dropFirst().contains("/") else { return token }
        let name = fileName(bare)
        return name.isEmpty ? token : name
    }

    private static func fileName(_ path: String) -> String {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        return (trimmed as NSString).lastPathComponent
    }

    /// Kappt auf `maxLength` Zeichen (inkl. „…").
    static func capped(_ text: String) -> String {
        guard text.count > AgentSessionActivity.maxLength else { return text }
        let head = text.prefix(AgentSessionActivity.maxLength - 1)
        return head.trimmingCharacters(in: .whitespaces) + "…"
    }

    private static func collapsedWhitespace(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }

    private static func firstLine(of text: String) -> String? {
        text.split(whereSeparator: \.isNewline)
            .lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }

    // MARK: - Erster Satz einer Antwort

    /// Kurzformen, an deren Punkt kein Satz endet.
    private static let abbreviations: Set<String> = [
        "z", "b", "d", "h", "u", "a", "s", "o", "e", "g", "i", "ca", "vgl", "bzw", "usw",
        "ggf", "inkl", "evtl", "etc", "nr", "bspw", "max", "min", "mind", "sog", "zb",
    ]

    /// Erster Satz der ersten inhaltlichen Zeile — Aufzählungszeichen,
    /// Hervorhebungen und Code-Zäune fallen weg. Überschriften („## Ergebnis")
    /// sind kein Satz: sie zählen nur, wenn die Antwort aus nichts anderem
    /// besteht.
    static func firstSentence(of text: String) -> String? {
        var headingFallback: String?
        for rawLine in text.prefix(4096).split(whereSeparator: \.isNewline) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") { continue }
            if line.allSatisfy({ "-=*_|: ".contains($0) }) { continue }
            let isHeading = line.hasPrefix("#")
            line = String(line.drop { "#>-*+ ".contains($0) })
            line = line.replacingOccurrences(of: "**", with: "")
                .replacingOccurrences(of: "__", with: "")
                .replacingOccurrences(of: "`", with: "")
            // Pfade auch im Fließtext auf den Dateinamen („Erfolg: /tmp/…/x.png").
            line = collapsedWhitespace(line)
                .split(separator: " ")
                .map { shortenedPathToken(String($0)) }
                .joined(separator: " ")
            guard !line.isEmpty else { continue }
            if isHeading {
                if headingFallback == nil { headingFallback = capped(line) }
                continue
            }
            return capped(sentencePrefix(of: line))
        }
        return headingFallback
    }

    private static func sentencePrefix(of line: String) -> String {
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            let next = line.index(after: index)
            if ".!?".contains(character), next == line.endIndex || line[next] == " " {
                if character != "." || !endsWithAbbreviation(line[..<index]) {
                    return String(line[...index])
                }
            }
            index = next
        }
        return line
    }

    private static func endsWithAbbreviation(_ head: Substring) -> Bool {
        let word = head.reversed().prefix { $0.isLetter || $0 == "." }
        let letters = String(word.reversed()).replacingOccurrences(of: ".", with: "").lowercased()
        if letters.isEmpty { return true } // „1." in Aufzählungen, „..."
        return abbreviations.contains(letters)
    }

    // MARK: - JSON

    private static func jsonObject(_ line: UnsafeRawBufferPointer) -> [String: Any]? {
        // Abgeschnittene erste Tail-Zeile o. ä.: ohne „{" gar nicht erst parsen.
        guard line.first == UInt8(ascii: "{") else { return nil }
        let data = Data(line)
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func jsonObject(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
