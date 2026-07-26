import Foundation

// MARK: - Folgeauftrags-Warteschlange (enqueue / queue / dequeue)

/// Pure Darstellungslogik der Warteschlange — ohne App und ohne Socket
/// testbar.
enum ChatsQueueSupport {
    /// Eine Zeile pro Auftrag. Position zählt nur OFFENE Aufträge; erledigte
    /// behalten keine Nummer, sonst sähe die Liste aus, als stünde noch etwas
    /// aus.
    static func line(for prompt: QueuedPrompt, position: Int?, now: Date) -> String {
        let head = String(prompt.prompt.replacingOccurrences(of: "\n", with: " ").prefix(60))
        let age = ChatsOutput.relative(from: prompt.enqueuedAt, to: now)
        let marker: String
        switch prompt.state {
        case .pending: marker = position.map { "\($0)." } ?? "–"
        case .delivering: marker = "→"
        case .delivered: marker = "✓"
        case .cancelled: marker = "×"
        case .failed: marker = "✗"
        case .unknown: marker = "⚠︎"
        }
        var text = "\(marker) \(head)"
        switch prompt.state {
        case .pending: text += "  (seit \(age), von \(prompt.enqueuedBy))"
        case .delivering: text += "  (wird gerade zugestellt)"
        case .delivered: text += "  (zugestellt)"
        case .cancelled: text += "  (storniert)"
        case .failed: text += "  (gescheitert: \(prompt.lastError ?? "unbekannt"))"
        case .unknown: text += "  (Ausgang unklar — App wurde während der Zustellung beendet)"
        }
        return text
    }

    /// Kurzstatus für `show`. `nil`, wenn nichts aussteht — dann soll `show`
    /// gar keine Zeile drucken. Erwartet die SICHTBARE Liste (wartende plus
    /// klärungsbedürftige) und trennt beides in der Aussage.
    static func summary(open visible: [QueuedPrompt]) -> String? {
        guard !visible.isEmpty else { return nil }
        let waiting = visible.filter(\.isOpen)
        let review = visible.filter(\.needsReview)

        var parts: [String] = []
        if !waiting.isEmpty {
            let delivering = waiting.contains { $0.state == .delivering }
            let suffix = delivering ? " (einer wird gerade zugestellt)" : ""
            parts.append(waiting.count == 1
                ? "1 Folgeauftrag wartet\(suffix)"
                : "\(waiting.count) Folgeaufträge warten\(suffix)")
        }
        if !review.isEmpty {
            parts.append(review.count == 1
                ? "1 Auftrag mit unklarem Ausgang"
                : "\(review.count) Aufträge mit unklarem Ausgang")
        }
        return parts.joined(separator: " · ")
    }

    static func json(for prompt: QueuedPrompt, position: Int?) -> [String: Any] {
        var dict: [String: Any] = [
            "id": prompt.id.uuidString,
            "state": prompt.state.rawValue,
            "prompt": prompt.prompt,
            "promptChars": prompt.prompt.count,
            "enqueuedAt": ChatsOutput.iso(prompt.enqueuedAt),
            "enqueuedBy": prompt.enqueuedBy,
        ]
        if let position { dict["position"] = position }
        if let delivered = prompt.deliveredAt { dict["deliveredAt"] = ChatsOutput.iso(delivered) }
        if let error = prompt.lastError { dict["lastError"] = error }
        return dict
    }
}

enum ChatsQueueCommand {
    /// `enqueue <ref> [--] "<prompt>"` — Folgeauftrag vormerken.
    static func enqueue(_ arguments: [String]) -> Int32 {
        var positionals: [String] = []
        var json = false
        var index = 0
        var afterSeparator = false
        while index < arguments.count {
            let arg = arguments[index]
            if afterSeparator {
                positionals.append(arg)
                index += 1
                continue
            }
            switch arg {
            case "--": afterSeparator = true
            case "--json": json = true
            default:
                if arg.hasPrefix("-") { CLIIO.err("Unbekannte Option: \(arg)"); return ChatsCLIExit.usage }
                positionals.append(arg)
            }
            index += 1
        }
        guard positionals.count >= 2 else {
            CLIIO.err("Usage: whisperm8 chats enqueue <ref> -- \"<prompt>\" [--json]")
            return ChatsCLIExit.usage
        }
        let ref = positionals[0]
        let prompt = positionals.dropFirst().joined(separator: " ")

        let targetID: UUID
        switch ChatsLiveSupport.resolveTarget(ref: ref) {
        case .resolved(let id, _): targetID = id
        case .failed(let code): return code
        }

        switch ChatsLiveSupport.perform(method: "queue.enqueue", params: [
            "targetSessionID": targetID.uuidString, "prompt": prompt,
        ]) {
        case .failed(let code): return code
        case .ok(let response):
            guard response.ok else { return ChatsLiveSupport.mapError(response) }
            ChatsLiveSupport.printResult(response, json: json) { result in
                let queued = result["queued"]?.intValue ?? 0
                if result["deliveredImmediately"]?.boolValue == true {
                    return "✓ direkt zugestellt (Chat war frei)"
                }
                let position = result["position"]?.intValue ?? queued
                let status = result["runtimeStatus"]?.stringValue ?? "unbekannt"
                return "✓ vorgemerkt als Nr. \(position) (Chat ist \(status); Zustellung beim nächsten Turn-Ende)"
            }
            return ChatsCLIExit.ok
        }
    }

    /// `queue [<ref>] [--json]` — Warteschlange anzeigen. Läuft app-unabhängig
    /// direkt von Disk, damit man auch bei geschlossener App sieht, was noch
    /// aussteht.
    static func list(_ arguments: [String]) -> Int32 {
        var refs: [String] = []
        var json = false
        for arg in arguments {
            switch arg {
            case "--json": json = true
            default:
                if arg.hasPrefix("-") { CLIIO.err("Unbekannte Option: \(arg)"); return ChatsCLIExit.usage }
                refs.append(arg)
            }
        }
        guard refs.count <= 1 else {
            CLIIO.err("Usage: whisperm8 chats queue [<ref>] [--json]")
            return ChatsCLIExit.usage
        }

        let context = ChatsCommandContext.load()
        let all = AgentPromptQueueStore.read(from: AgentPromptQueueStore.defaultFileURL())

        var sessionFilter: UUID?
        if let ref = refs.first {
            switch ChatsLiveSupport.resolveTarget(ref: ref, includeArchived: true) {
            case .resolved(let id, _): sessionFilter = id
            case .failed(let code): return code
            }
        }

        // Ohne Ref: nur was noch aussteht oder geklärt werden muss. Mit Ref:
        // die volle Historie dieser Session (inkl. zugestellter Aufträge).
        let relevant = all.filter { entry in
            guard sessionFilter == nil || entry.sessionID == sessionFilter else { return false }
            return sessionFilter != nil || entry.isOpen || entry.needsReview
        }
        let bySession = Dictionary(grouping: relevant, by: \.sessionID)

        if json {
            var sessions: [[String: Any]] = []
            for (sessionID, prompts) in bySession {
                let open = AgentPromptQueueLogic.openPrompts(for: sessionID, in: prompts)
                let entry = context.view.entries.first { $0.session.id == sessionID }
                var dict: [String: Any] = [
                    "sessionID": sessionID.uuidString,
                    "openCount": open.count,
                    "prompts": prompts
                        .sorted { $0.enqueuedAt < $1.enqueuedAt }
                        .map { prompt in
                            ChatsQueueSupport.json(
                                for: prompt,
                                position: open.firstIndex { $0.id == prompt.id }.map { $0 + 1 })
                        },
                ]
                if let entry {
                    dict["project"] = entry.projectName
                    dict["title"] = entry.session.title
                }
                sessions.append(dict)
            }
            sessions.sort { ($0["sessionID"] as? String ?? "") < ($1["sessionID"] as? String ?? "") }
            CLIIO.out(ChatsOutput.encodeJSON([
                "schemaVersion": 1,
                "generatedAt": ChatsOutput.iso(context.now),
                "openTotal": relevant.filter(\.isOpen).count,
                "sessions": sessions,
            ]))
            return ChatsCLIExit.ok
        }

        guard !bySession.isEmpty else {
            CLIIO.out("Keine vorgemerkten Folgeaufträge.")
            return ChatsCLIExit.ok
        }
        for (sessionID, prompts) in bySession.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            let entry = context.view.entries.first { $0.session.id == sessionID }
            let name = entry.map { "\($0.projectName)/\($0.session.title)" } ?? ChatsOutput.shortID(sessionID)
            let open = AgentPromptQueueLogic.openPrompts(for: sessionID, in: prompts)
            CLIIO.out("── \(name)  (\(open.count) offen)")
            for prompt in prompts.sorted(by: { $0.enqueuedAt < $1.enqueuedAt }) {
                let position = open.firstIndex { $0.id == prompt.id }.map { $0 + 1 }
                CLIIO.out("   " + ChatsQueueSupport.line(for: prompt, position: position, now: context.now))
            }
        }
        return ChatsCLIExit.ok
    }

    /// `dequeue <ref> [--id UUID]… [--all]` — offene Aufträge stornieren.
    static func cancel(_ arguments: [String]) -> Int32 {
        var refs: [String] = []
        var ids: [String] = []
        var all = false
        var json = false
        var index = 0
        while index < arguments.count {
            let arg = arguments[index]
            switch arg {
            case "--id":
                index += 1
                guard index < arguments.count else {
                    CLIIO.err("--id erwartet eine Auftrags-ID (siehe `chats queue --json`).")
                    return ChatsCLIExit.usage
                }
                ids.append(arguments[index])
            case "--all": all = true
            case "--json": json = true
            default:
                if arg.hasPrefix("-") { CLIIO.err("Unbekannte Option: \(arg)"); return ChatsCLIExit.usage }
                refs.append(arg)
            }
            index += 1
        }
        guard refs.count == 1 else {
            CLIIO.err("Usage: whisperm8 chats dequeue <ref> [--id UUID]… | --all [--json]")
            return ChatsCLIExit.usage
        }
        guard all || !ids.isEmpty else {
            CLIIO.err("Was soll storniert werden? --all für alle offenen oder --id <UUID> gezielt.")
            return ChatsCLIExit.usage
        }
        guard !(all && !ids.isEmpty) else {
            CLIIO.err("--all und --id schließen sich aus.")
            return ChatsCLIExit.usage
        }

        let targetID: UUID
        switch ChatsLiveSupport.resolveTarget(ref: refs[0], includeArchived: true) {
        case .resolved(let id, _): targetID = id
        case .failed(let code): return code
        }

        var params: [String: Any] = ["targetSessionID": targetID.uuidString]
        if !ids.isEmpty { params["ids"] = ids }

        switch ChatsLiveSupport.perform(method: "queue.cancel", params: params) {
        case .failed(let code): return code
        case .ok(let response):
            guard response.ok else { return ChatsLiveSupport.mapError(response) }
            ChatsLiveSupport.printResult(response, json: json) { result in
                let cancelled = result["cancelled"]?.intValue ?? 0
                let remaining = result["remaining"]?.intValue ?? 0
                if cancelled == 0 { return "– nichts zu stornieren (offen: \(remaining))" }
                return "✓ \(cancelled) Auftrag/Aufträge storniert (offen: \(remaining))"
            }
            return ChatsCLIExit.ok
        }
    }
}
