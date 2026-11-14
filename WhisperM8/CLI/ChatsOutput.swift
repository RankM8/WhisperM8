import Foundation

// MARK: - Text- und JSON-Ausgabe der chats-Befehle

enum ChatsOutput {
    // MARK: JSON

    /// JSONSerialization + sortedKeys (Vorbild `AgentJobOutput`) — stabile,
    /// diffbare Ausgabe ohne Encoder-Konfigurationstanz.
    static func encodeJSON(_ object: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// - Parameter totalInScope: Sessions im Scope VOR dem Limit.
    /// - Parameter truncated: `true`, wenn das Limit gegriffen hat — der
    ///   Aufrufer darf `sessions` dann nicht als vollständige Menge lesen.
    /// - Parameter countsCoverFullScope: `false`, wenn vor dem Proben limitiert
    ///   wurde (Fast-Path). `counts` beschreibt dann nur die ausgegebenen
    ///   Zeilen und ist kein Lagebild des ganzen Scopes — für das ist
    ///   `overview` da.
    static func listJSON(
        items: [ChatsAttentionItem],
        counts: [ChatsAttentionCategory: Int],
        selfID: UUID?,
        generatedAt: Date,
        live: Bool = false,
        openTabIDs: Set<UUID> = [],
        pinnedIDs: Set<UUID> = [],
        totalInScope: Int? = nil,
        truncated: Bool = false,
        countsCoverFullScope: Bool = true,
        queuedCounts: [UUID: Int] = [:],
        liveStatuses: ChatsLiveSnapshot? = nil,
        orderInfo: [UUID: [String: Any]] = [:]
    ) -> [String: Any] {
        var countsDict: [String: Any] = [:]
        for category in ChatsAttentionCategory.allCases {
            countsDict[category.rawValue] = counts[category] ?? 0
        }
        return [
            "schemaVersion": 1,
            "generatedAt": iso(generatedAt),
            "live": live,
            "self": selfID?.uuidString ?? NSNull(),
            "counts": countsDict,
            "countsCoverFullScope": countsCoverFullScope,
            "totalInScope": totalInScope ?? items.count,
            "returned": items.count,
            "truncated": truncated,
            // Gesamtzahl vorgemerkter Folgeaufträge über ALLE Sessions — auch
            // über die, die dieser Scope nicht zeigt. Sonst wirkte eine
            // gefilterte Ansicht wie „nichts steht aus".
            "queuedTotal": queuedCounts.values.reduce(0, +),
            "sessions": items.map { item -> [String: Any] in
                // Live-Status pro Session durchreichen: ohne ihn meldete jede
                // Zeile `canSend: false` und `isAttachedPTY: null`, auch für
                // laufende Sessions — ein Orchestrator hätte daraus nie eine
                // Sendeentscheidung ableiten können.
                var dict = sessionJSON(entry: item.entry, runtime: item.runtime, selfID: selfID, live: live, attention: item,
                                       liveStatus: liveStatuses?[item.entry.session.id],
                                       isOpen: openTabIDs.contains(item.entry.session.id),
                                       isPinned: pinnedIDs.contains(item.entry.session.id))
                if let queued = queuedCounts[item.entry.session.id], queued > 0 {
                    dict["queued"] = queued
                }
                if let order = orderInfo[item.entry.session.id] { dict["order"] = order }
                return dict
            },
        ]
    }

    static func sessionJSON(
        entry: ChatsSessionEntry,
        runtime: ChatsRuntimeInfo,
        selfID: UUID?,
        live: Bool,
        attention: ChatsAttentionItem? = nil,
        liveStatus: ChatsLiveStatus? = nil,
        isOpen: Bool = false,
        isPinned: Bool = false
    ) -> [String: Any] {
        let session = entry.session
        var runtimeDict: [String: Any] = [
            "status": runtime.status?.rawValue ?? "unknown",
            "source": runtime.source,
        ]
        if let since = runtime.since { runtimeDict["since"] = iso(since) }
        // Eigener Zustand „am Limit bis …“ (WM8-69), neben dem Status: der
        // Chat ruht, nimmt aber nichts an. Nur ergänzt, nichts umbenannt.
        if let limit = session.activeUsageLimit() {
            runtimeDict["usageLimit"] = usageLimitJSON(limit)
        }
        if let revision = runtime.revision { runtimeDict["revision"] = revision }
        if let pid = liveStatus?.pid { runtimeDict["pid"] = pid }

        var transcriptDict: [String: Any] = ["availability": runtime.availability.rawValue]
        if let path = runtime.transcriptPath { transcriptDict["path"] = path }
        if let size = runtime.transcriptSizeBytes { transcriptDict["sizeBytes"] = size }

        // Capabilities: offline konservativ (keine PTY-Info); mit Live-Merge
        // die autoritativen App-Werte.
        let capabilities: [String: Any] = [
            "canSend": liveStatus?.canSend ?? false,
            "canInterrupt": liveStatus?.canInterrupt ?? false,
            "canOpen": session.status != .archived,
            "isAttachedPTY": liveStatus.map { $0.isAttachedPTY } as Any? ?? NSNull(),
        ]

        var dict: [String: Any] = [
            "id": session.id.uuidString,
            "shortID": shortID(session.id),
            "project": ["name": entry.projectName, "path": entry.projectPath],
            "title": session.title,
            "group": session.groupName ?? NSNull(),
            "provider": session.provider.rawValue,
            "kind": session.effectiveKind.rawValue,
            "status": session.status.rawValue,
            "runtime": runtimeDict,
            "capabilities": capabilities,
            "isSelf": session.id == selfID,
            "isOpen": isOpen,
            "isPinned": isPinned,
            "lastActivityAt": iso(session.lastActivityAt),
            "transcript": transcriptDict,
            "externalSessionID": session.externalSessionID ?? NSNull(),
            "backgroundShortID": session.backgroundShortID ?? NSNull(),
        ]
        let account = claudeAccount(session: session, transcriptPath: runtime.transcriptPath)
        dict["account"] = account?.name ?? NSNull()
        if let account, let stamped = account.stampedName {
            // Stempel und realer Ablageort weichen ab — der nächste Start folgt
            // dem Ablageort (Resume-Selbstheilung), der Stempel wird nachgezogen.
            dict["accountStamp"] = stamped
        }
        dict["workingCopy"] = session.workingCopy.map(workingCopyJSON) ?? NSNull()
        if let attention {
            dict["attention"] = ["category": attention.category.rawValue, "rank": attention.rank]
        }
        if let line = tierOneLine(entry: entry, runtime: runtime) {
            dict["lastAssistantLine"] = line
        }
        return dict
    }

    /// Status für Tabelle und Board: am Limit „limit bis 04:20“ statt des
    /// ruhenden Status (WM8-69).
    static func statusText(_ status: AgentSessionRuntimeStatus?, session: AgentChatSession, now: Date) -> String {
        if let limit = session.activeUsageLimit(at: now) {
            let until = limit.resetsAt.map { " bis " + ChatsUsageLimitFormat.clock($0, now: now) } ?? ""
            return "limit" + until + (limit.autoContinues == true ? ", dann weiter" : "")
        }
        return status?.rawValue ?? "unknown"
    }

    /// `kind` (five_hour, seven_day, model_requires_usage_credits), `resetsAt`.
    static func usageLimitJSON(_ limit: AgentUsageLimit) -> [String: Any] {
        ["kind": limit.kind, "resetsAt": limit.resetsAt.map(iso) ?? NSNull(),
         "autoContinues": limit.autoContinues.map { $0 as Any } ?? NSNull()]
    }

    /// Für `chats show`: welches Limit, bis wann.
    static func usageLimitLine(_ limit: AgentUsageLimit, now: Date) -> String {
        let kind: String
        switch limit.kind {
        case "five_hour": kind = "5-Stunden-Limit"
        case "seven_day": kind = "Wochenlimit"
        default: kind = "Guthaben-Limit (\(limit.kind))"
        }
        let until = limit.resetsAt.map { " bis " + ChatsUsageLimitFormat.clock($0, now: now) } ?? ""
        if limit.autoContinues == true {
            return "Konto am \(kind)\(until), läuft dann von selbst weiter — Nachrichten werden vorgemerkt, "
                + "eine Nachricht jetzt würde das Weitermachen abbrechen"
        }
        return "Konto am \(kind)\(until) — Nachrichten werden vorgemerkt, nicht verbraucht"
    }

    /// Wo der Chat zuletzt gearbeitet hat (WM8-60): `kind` main | worktree |
    /// other (Hauptordner, Arbeitskopie, Ordner außerhalb des Projekts), dazu
    /// Name, Pfad, Branch und ob das der Standard-Branch ist.
    static func workingCopyJSON(_ copy: AgentWorkingCopy) -> [String: Any] {
        [
            "kind": workingCopyKind(copy.kind),
            "name": copy.name ?? NSNull(),
            "path": copy.path,
            "branch": copy.branch ?? NSNull(),
            "defaultBranch": copy.defaultBranch ?? NSNull(),
            "isDefaultBranch": copy.branch == nil ? NSNull() : copy.isOnDefaultBranch as Any,
        ]
    }

    static func workingCopyKind(_ kind: AgentWorkingCopy.Kind) -> String {
        switch kind {
        case .mainFolder: return "main"
        case .worktree: return "worktree"
        case .otherFolder: return "other"
        }
    }

    /// Knapp für Tabellen: `main` (Hauptordner, Standard-Branch),
    /// `main@<branch>` (Hauptordner, anderer Branch), `wt:<name>@<branch>`,
    /// `other:<name>`; `-` wenn unbekannt. Ein Branch, den der Name schon
    /// nennt, steht nur einmal da.
    static func workingCopyShort(_ copy: AgentWorkingCopy?) -> String {
        guard let copy else { return "-" }
        switch copy.kind {
        case .mainFolder:
            guard let branch = copy.branch, !copy.isOnDefaultBranch else { return "main" }
            return "main@" + branch
        case .worktree, .otherFolder:
            let place = (copy.kind == .worktree ? "wt:" : "other:") + (copy.name ?? "?")
            guard let branch = copy.branch, !copy.nameRepeatsBranch else { return place }
            return place + "@" + branch
        }
    }

    /// Kürzt in der Mitte, damit Anfang (Ort) und Ende (Branch) lesbar bleiben.
    static func truncateMiddle(_ text: String, _ length: Int) -> String {
        guard text.count > length, length > 1 else { return text }
        let head = (length - 1) / 2
        let tail = length - 1 - head
        return String(text.prefix(head)) + "…" + String(text.suffix(tail))
    }

    /// Für `chats show`: Ort ausgeschrieben, Ordner in Klammern.
    static func workingCopyLine(_ copy: AgentWorkingCopy) -> String {
        let place: String
        switch copy.kind {
        case .mainFolder: place = "Hauptordner"
        case .worktree: place = "Arbeitskopie \(copy.name ?? "?")"
        case .otherFolder: place = "Ordner außerhalb des Projekts: \(copy.name ?? "?")"
        }
        var branch = copy.branch.map { " · Branch \($0)" } ?? ""
        if copy.branch != nil, !copy.isOnDefaultBranch, copy.kind == .mainFolder { branch += " (nicht der Standard-Branch)" }
        return "\(place)\(branch)  (\(copy.path))"
    }

    /// Claude-Konto eines Chats, wie es die CLI zeigt.
    struct ClaudeAccountDisplay: Equatable {
        /// Profilname; `main` für das Hauptkonto (nie `nil` wie der Stempel).
        var name: String
        /// Gesetzt, wenn der Stempel der Session ein anderes Konto nennt als
        /// der Ort, an dem das Transcript wirklich liegt.
        var stampedName: String?
    }

    /// `nil` für alles ohne Claude-Konto (Codex, Terminal, Agent View).
    /// Maßgeblich ist der reale Ablageort des Transcripts: dort sucht
    /// `claude --resume`, und dorthin folgt auch der nächste Start
    /// (`AgentCommandBuilder`, Resume-Selbstheilung). Ohne Transcript (neuer
    /// Chat vor der ersten Antwort) gilt der Stempel.
    static func claudeAccount(session: AgentChatSession, transcriptPath: String?) -> ClaudeAccountDisplay? {
        guard session.provider == .claude else { return nil }
        switch session.effectiveKind {
        case .terminal, .agentView: return nil
        case .chat, .backgroundChat, .subagentJob: break
        }
        let main = ClaudeAccountProfiles.mainProfileName
        let stamped = AccountMovePlanner.normalize(session.claudeProfileName) ?? main
        guard let transcriptPath, transcriptPath.contains("/projects/") else {
            return ClaudeAccountDisplay(name: stamped)
        }
        let actual = ClaudeAccountProfiles.profileName(forTranscriptPath: transcriptPath) ?? main
        return ClaudeAccountDisplay(name: actual, stampedName: actual == stamped ? nil : stamped)
    }

    /// Angezeigtes Modell eines Chats. `session.model` ist bei jedem Chat
    /// mit dem Codex-Standardmodell vorbelegt (`createSession`), auch bei
    /// Claude-Chats — dort sagt es nichts. Claude-Chats zeigen deshalb das
    /// Modell der letzten Antwort aus dem Transcript, GPT-Backend-Chats ihren
    /// GPT-Stempel (`claudeBackendModel`).
    struct ModelDisplay: Equatable {
        enum Source: String {
            case session, gptStamp, transcript, unknown
        }
        /// `nil` = unbekannt (Claude-Chat ohne Antwort im Transcript).
        var model: String?
        var source: Source
        /// Modell der letzten Antwort, falls es vom GPT-Stempel abweicht
        /// (z. B. Stempel `auto`).
        var lastTranscriptModel: String?

        var text: String {
            guard let model else { return "unbekannt (noch keine Antwort im Transcript)" }
            switch source {
            case .gptStamp:
                let last = lastTranscriptModel.map { ", zuletzt \($0)" } ?? ""
                return "\(model) (GPT-Stempel\(last))"
            case .transcript:
                return "\(model) (letzte Antwort)"
            case .session, .unknown:
                return model
            }
        }
    }

    static func modelDisplay(session: AgentChatSession, transcriptModel: String?) -> ModelDisplay {
        guard session.provider == .claude else {
            return ModelDisplay(model: session.model, source: .session)
        }
        func trimmed(_ value: String?) -> String? {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { return nil }
            return value
        }
        let transcriptModel = trimmed(transcriptModel)
        if let stamp = trimmed(session.claudeBackendModel) {
            return ModelDisplay(
                model: stamp, source: .gptStamp,
                lastTranscriptModel: transcriptModel == stamp ? nil : transcriptModel)
        }
        if let transcriptModel {
            return ModelDisplay(model: transcriptModel, source: .transcript)
        }
        return ModelDisplay(model: nil, source: .unknown)
    }

    static func detailJSON(entry: ChatsSessionEntry, transcriptModel: String? = nil) -> [String: Any] {
        let session = entry.session
        let model = modelDisplay(session: session, transcriptModel: transcriptModel)
        return [
            "model": model.model ?? NSNull(),
            "modelSource": model.source.rawValue,
            "lastTranscriptModel": model.lastTranscriptModel ?? NSNull(),
            "reasoningEffort": session.reasoningEffort,
            "createdAt": iso(session.createdAt),
            "lastTurnAt": session.lastTurnAt.map(iso) ?? NSNull(),
            "archivedAt": session.archivedAt.map(iso) ?? NSNull(),
            "titleIsAutoGenerated": session.titleIsAutoGenerated ?? NSNull(),
            "claudeProfileName": session.claudeProfileName ?? NSNull(),
            "claudeBackendModel": session.claudeBackendModel ?? NSNull(),
            "gptProfileName": session.gptProfileName ?? NSNull(),
            "forkSourceSessionID": session.forkSourceSessionID ?? NSNull(),
            "subagentParentSessionID": session.subagentParentSessionID ?? NSNull(),
            "subagentCwd": session.subagentCwd ?? NSNull(),
            "summary": session.summary?.headline ?? NSNull(),
        ]
    }

    // MARK: Text

    static func printTable(items: [ChatsAttentionItem], selfID: UUID?, now: Date,
                           openTabIDs: Set<UUID> = [], pinnedIDs: Set<UUID> = []) {
        guard !items.isEmpty else {
            CLIIO.out("Keine Sessions im Scope. (--all zeigt archivierte und ältere.)")
            return
        }
        CLIIO.out(pad("REF", 10) + pad("PROJEKT/TITEL", 42) + pad("STATUS", 15) + pad("SEIT", 8)
                  + pad("ORT", 28) + "FLAGS")
        for item in items {
            let session = item.entry.session
            let name = truncate("\(item.entry.projectName)/\(session.title)", 40)
            let status = statusText(item.runtime.status, session: session, now: now)
            let since = item.runtime.since.map { relative(from: $0, to: now) } ?? "–"
            let place = truncateMiddle(workingCopyShort(session.workingCopy), 26)
            CLIIO.out(pad(shortID(session.id), 10) + pad(name, 42) + pad(status, 15) + pad(since, 8)
                      + pad(place, 28)
                      + flags(session.id, selfID: selfID, openTabIDs: openTabIDs, pinnedIDs: pinnedIDs))
        }
        CLIIO.err("\(items.count) Sessions · ORT: main=Hauptordner wt:=Arbeitskopie other:=außerhalb des Projekts, @Branch"
                  + " · ⊙=offener Tab 📌=gepinnt (du)=diese Session")
    }

    /// Flag-Kürzel pro Zeile: offener Tab, gepinnt, Selbst-Markierung.
    private static func flags(_ id: UUID, selfID: UUID?, openTabIDs: Set<UUID>, pinnedIDs: Set<UUID>) -> String {
        var parts: [String] = []
        if openTabIDs.contains(id) { parts.append("⊙") }
        if pinnedIDs.contains(id) { parts.append("📌") }
        if id == selfID { parts.append("(du)") }
        return parts.isEmpty ? "–" : parts.joined(separator: " ")
    }

    static func printBoard(
        items: [ChatsAttentionItem],
        counts: [ChatsAttentionCategory: Int],
        selfID: UUID?,
        showAll: Bool,
        now: Date,
        openTabIDs: Set<UUID> = [],
        pinnedIDs: Set<UUID> = [],
        queuedCounts: [UUID: Int] = [:]
    ) {
        let grouped = Dictionary(grouping: items, by: \.category)
        var printedAny = false
        for category in ChatsAttentionCategory.allCases {
            guard let group = grouped[category], !group.isEmpty else { continue }
            if category == .idle && !showAll {
                CLIIO.out(boardHeader(category.boardTitle, count: group.count) + " (--all zeigt sie)")
                continue
            }
            CLIIO.out(boardHeader(category.boardTitle, count: group.count))
            for item in group {
                let session = item.entry.session
                let symbol = statusSymbol(item.runtime.status)
                let name = truncate("\(item.entry.projectName)/\(session.title)", 34)
                let status = statusText(item.runtime.status, session: session, now: now)
                let since = item.runtime.since.map { "seit \(relative(from: $0, to: now))" } ?? ""
                var marks = ""
                if openTabIDs.contains(session.id) { marks += " ⊙" }
                if pinnedIDs.contains(session.id) { marks += " 📌" }
                // Vorgemerkte Folgeaufträge sichtbar machen: „arbeitet, und
                // danach warten noch 2" ist eine andere Lage als „arbeitet".
                if let queued = queuedCounts[session.id], queued > 0 { marks += " ⏳\(queued)" }
                if session.id == selfID { marks += " (du)" }
                let estimate = item.runtime.source == "transcriptEstimate" ? " · geschätzt" : ""
                CLIIO.out("\(symbol) \(pad(name, 36))\(pad(status, 15))\(since)\(estimate)\(marks)")
                if category == .needsYou || category == .freshDone,
                   let line = tierOneLine(entry: item.entry, runtime: item.runtime) {
                    CLIIO.out("  „\(line)\"")
                }
            }
            CLIIO.out("")
            printedAny = true
        }
        if !printedAny && items.isEmpty {
            CLIIO.out("Keine Sessions im Scope. (--all zeigt archivierte und ältere.)")
        }
    }

    static func printShow(entry: ChatsSessionEntry, runtime: ChatsRuntimeInfo, selfID: UUID?, now: Date,
                          isOpen: Bool = false, isPinned: Bool = false, transcriptModel: String? = nil) {
        let session = entry.session
        var titleMarks = ""
        if isOpen { titleMarks += "  ⊙ offener Tab" }
        if isPinned { titleMarks += "  📌 gepinnt" }
        if session.id == selfID { titleMarks += "  (du)" }
        CLIIO.out("── IDENTITÄT " + String(repeating: "─", count: 40))
        CLIIO.out("Titel        \(session.title)\(titleMarks)")
        CLIIO.out("Projekt      \(entry.projectName)  (\(entry.projectPath))")
        if let copy = session.workingCopy { CLIIO.out("Ort          \(workingCopyLine(copy))") }
        CLIIO.out("Ref          \(shortID(session.id))  ·  \(session.id.uuidString)")
        CLIIO.out("Provider     \(session.provider.rawValue) · \(session.effectiveKind.displayName) · Modell \(modelDisplay(session: session, transcriptModel: transcriptModel).text)")
        if let group = session.groupName { CLIIO.out("Gruppe       \(group)") }
        if let account = claudeAccount(session: session, transcriptPath: runtime.transcriptPath) {
            let note = account.stampedName.map { " (Stempel: \($0), Transcript liegt hier)" } ?? ""
            CLIIO.out("Konto        \(account.name)\(note)")
        }
        CLIIO.out("")
        CLIIO.out("── LAUFZEIT " + String(repeating: "─", count: 41))
        CLIIO.out("Status       \(session.status.rawValue) / runtime: \(runtime.status?.rawValue ?? "unknown") (\(runtime.source))")
        if let limit = session.activeUsageLimit(at: now) {
            CLIIO.out("Limit        \(usageLimitLine(limit, now: now))")
        }
        if let since = runtime.since { CLIIO.out("Seit         \(relative(from: since, to: now)) (\(iso(since)))") }
        CLIIO.out("Aktivität    \(relative(from: session.lastActivityAt, to: now)) (\(iso(session.lastActivityAt)))")
        if let lastTurn = session.lastTurnAt { CLIIO.out("Letzter Turn \(relative(from: lastTurn, to: now))") }
        CLIIO.out("")
        CLIIO.out("── TRANSCRIPT " + String(repeating: "─", count: 39))
        CLIIO.out("Verfügbar    \(runtime.availability.rawValue)")
        if let path = runtime.transcriptPath { CLIIO.out("Pfad         \(path)") }
        if let size = runtime.transcriptSizeBytes { CLIIO.out("Größe        \(byteString(size)) (revision \(size))") }
        if let ext = session.externalSessionID { CLIIO.out("Extern-ID    \(ext)") }
        if let short = session.backgroundShortID { CLIIO.out("BG-Short-ID  \(short)") }
    }

    // MARK: Bausteine

    /// Tier-1-Einzeiler: letzte Assistant-Zeile aus dem Transcript-Tail.
    /// Bewusst mit kleinem Tail-Read (16 KB) — läuft pro Board-Zeile.
    static func tierOneLine(entry: ChatsSessionEntry, runtime: ChatsRuntimeInfo) -> String? {
        guard runtime.availability == .available, let path = runtime.transcriptPath else { return nil }
        let fileURL = URL(fileURLWithPath: path)
        let transcript = entry.session.provider == .claude || entry.session.effectiveKind == .backgroundChat
            ? ClaudeTranscriptReader.readTail(fileURL: fileURL, tailBytes: 16_384)
            : CodexTranscriptReader.readTail(fileURL: fileURL, tailBytes: 16_384)
        return ChatsTailFormatter.lastAssistantLine(transcript: transcript)
    }

    static func shortID(_ id: UUID) -> String {
        String(id.uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(8))
    }

    static func iso(_ date: Date) -> String {
        isoFormatter.string(from: date)
    }

    /// Gegenstück zu `iso`, mit und ohne Sekundenbruchteile.
    static func parseISO(_ text: String) -> Date? {
        if let date = isoFormatter.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }

    static func relative(from date: Date, to now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "\(Int(seconds)) s" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min" }
        if seconds < 86_400 { return "\(Int(seconds / 3600)) h" }
        return "\(Int(seconds / 86_400)) d"
    }

    static func byteString(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1_048_576 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }

    private static func boardHeader(_ title: String, count: Int) -> String {
        let label = "── \(title) "
        let padded = label.padding(toLength: 44, withPad: "─", startingAt: 0)
        return "\(padded) \(count) ──"
    }

    private static func statusSymbol(_ status: AgentSessionRuntimeStatus?) -> String {
        switch status {
        case .awaitingInput: return "◆"
        case .errored: return "✖"
        case .working: return "▶"
        case .idle: return "●"
        case .stopped: return "■"
        case nil: return "·"
        }
    }

    private static func pad(_ text: String, _ width: Int) -> String {
        if text.count >= width { return text + " " }
        return text + String(repeating: " ", count: width - text.count)
    }

    private static func truncate(_ text: String, _ maxChars: Int) -> String {
        if text.count <= maxChars { return text }
        return String(text.prefix(maxChars - 1)) + "…"
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
