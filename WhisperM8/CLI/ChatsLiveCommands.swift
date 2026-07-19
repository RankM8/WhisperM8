import Foundation

// MARK: - Live-/Mutations-Befehle (über den Control-Socket)

/// Gemeinsame Hülle: Ziel per RefResolver auflösen, Request schicken,
/// Response-Fehler auf Exit-Codes mappen.
enum ChatsLiveSupport {
    /// Ergebnis der Ziel-Auflösung (Int32 taugt nicht als Result-Error).
    enum TargetResolution {
        case resolved(UUID, String)
        case failed(Int32)
    }

    /// Ergebnis eines Socket-Requests.
    enum PerformResult {
        case ok(ChatsControlResponse)
        case failed(Int32)
    }

    /// Löst eine Referenz auf die Session-UUID auf (für Socket-Befehle: nie
    /// mehrdeutig). Gibt UUID + „projekt/titel"-Label zurück.
    ///
    /// Debounce-Race (E2E-Befund): Direkt nach `chats new` ist die Session
    /// noch nicht auf Disk geflusht (0,5-s-Debounce der App) — der Disk-
    /// Resolver fände sie nicht. Voll-UUIDs werden deshalb bei Miss
    /// DURCHGEREICHT: Der Server validiert ohnehin autoritativ gegen seinen
    /// In-Memory-Workspace und antwortet mit notFound, falls es sie wirklich
    /// nicht gibt. Gilt nur für Voll-UUIDs (eindeutig), nie für Fuzzy-Refs.
    static func resolveTarget(ref: String, includeArchived: Bool = false) -> TargetResolution {
        let context = ChatsCommandContext.load()
        // Voll-UUID zuerst (still, ohne stderr): auf Disk gefunden → mit Label;
        // sonst durchreichen (Debounce-Race), Server entscheidet.
        if let uuid = UUID(uuidString: ref.trimmingCharacters(in: .whitespacesAndNewlines)) {
            if let entry = context.view.entries.first(where: { $0.session.id == uuid }) {
                if !includeArchived && entry.session.status == .archived {
                    CLIIO.err("Session ist archiviert: \(entry.projectName)/\(entry.session.title)")
                    return .failed(ChatsCLIExit.notFound)
                }
                return .resolved(uuid, "\(entry.projectName)/\(entry.session.title)")
            }
            return .resolved(uuid, ref)
        }
        switch context.resolve(ref: ref, includeArchived: includeArchived) {
        case .success(let entry):
            return .resolved(entry.session.id, "\(entry.projectName)/\(entry.session.title)")
        case .failure(let code):
            return .failed(code)
        }
    }

    /// Führt einen Socket-Request aus und behandelt die App-nicht-erreichbar-
    /// Fehler einheitlich (Exit 5).
    static func perform(method: String, params: [String: Any]) -> PerformResult {
        do {
            let response = try ChatsControlClient.send(method: method, params: params)
            return .ok(response)
        } catch let ChatsControlClient.ClientError.appUnreachable(message) {
            CLIIO.err("Fehler: \(message)")
            return .failed(ChatsCLIExit.appUnreachable)
        } catch let ChatsControlClient.ClientError.protocolError(message) {
            CLIIO.err("Fehler: \(message)")
            return .failed(ChatsCLIExit.appUnreachable)
        } catch {
            CLIIO.err("Fehler: \(error.localizedDescription)")
            return .failed(ChatsCLIExit.appUnreachable)
        }
    }

    /// Response-Fehler → Exit-Code + stderr.
    static func mapError(_ response: ChatsControlResponse) -> Int32 {
        guard let error = response.error else { return ChatsCLIExit.conflict }
        CLIIO.err("Fehler: \(error.message)")
        let code = ChatsControlErrorCode(rawValue: error.code) ?? .internalError
        return code.exitCode
    }

    static func printResult(_ response: ChatsControlResponse, json: Bool, humanLine: (ChatsControlJSON) -> String) {
        if json {
            let payload = jsonObject(from: response)
            CLIIO.out(ChatsOutput.encodeJSON(payload))
        } else if let result = response.result {
            CLIIO.out(humanLine(result))
        }
    }

    /// Wandelt eine Response in ein [String: Any] für die --json-Ausgabe.
    static func jsonObject(from response: ChatsControlResponse) -> [String: Any] {
        var dict: [String: Any] = ["schemaVersion": 1, "ok": response.ok]
        if let result = response.result { dict["result"] = anyValue(result) }
        if let error = response.error {
            dict["error"] = ["code": error.code, "message": error.message]
        }
        return dict
    }

    static func anyValue(_ json: ChatsControlJSON) -> Any {
        switch json {
        case .string(let value): return value
        case .number(let value): return value
        case .bool(let value): return value
        case .null: return NSNull()
        case .array(let values): return values.map(anyValue)
        case .object(let dict): return dict.mapValues(anyValue)
        }
    }
}

// MARK: - send

enum ChatsSendCommand {
    static func run(_ arguments: [String]) -> Int32 {
        var positionals: [String] = []
        var ifStatus: [String]?
        var noSubmit = false
        var force = false
        var json = false
        var promptsOnly = false
        var index = 0
        while index < arguments.count {
            let arg = arguments[index]
            if promptsOnly { positionals.append(arg); index += 1; continue }
            switch arg {
            case "--": promptsOnly = true
            case "--if-status":
                index += 1
                guard index < arguments.count else { CLIIO.err("--if-status erwartet einen Wert."); return ChatsCLIExit.usage }
                ifStatus = arguments[index].split(separator: ",").map(String.init)
            case "--no-submit": noSubmit = true
            case "--force": force = true
            case "--json": json = true
            default:
                if arg.hasPrefix("-"), !promptsOnly { CLIIO.err("Unbekannte Option: \(arg)"); return ChatsCLIExit.usage }
                positionals.append(arg)
            }
            index += 1
        }
        guard positionals.count >= 2 else {
            CLIIO.err("Usage: whisperm8 chats send <ref> [--] \"<prompt>\" [--if-status S,S] [--no-submit] [--force]")
            return ChatsCLIExit.usage
        }
        let ref = positionals[0]
        let prompt = positionals[1...].joined(separator: " ")

        let targetID: UUID
        switch ChatsLiveSupport.resolveTarget(ref: ref) {
        case .resolved(let id, _): targetID = id
        case .failed(let code): return code
        }

        var params: [String: Any] = [
            "targetSessionID": targetID.uuidString,
            "prompt": prompt,
            "submit": !noSubmit,
            "force": force,
        ]
        if let ifStatus { params["ifStatus"] = ifStatus }

        switch ChatsLiveSupport.perform(method: "session.send", params: params) {
        case .failed(let code): return code
        case .ok(let response):
            guard response.ok else { return ChatsLiveSupport.mapError(response) }
            ChatsLiveSupport.printResult(response, json: json) { result in
                let title = result["target"]?["title"]?.stringValue ?? ref
                let ack = result["ack"]?.stringValue ?? "delivered"
                return "✓ \(ack) an \(title) (\(prompt.count) Zeichen)"
            }
            return ChatsCLIExit.ok
        }
    }
}

// MARK: - interrupt

enum ChatsInterruptCommand {
    static func run(_ arguments: [String]) -> Int32 {
        var ref: String?
        var force = false
        var json = false
        var index = 0
        while index < arguments.count {
            let arg = arguments[index]
            switch arg {
            case "--force": force = true
            case "--json": json = true
            default:
                if arg.hasPrefix("-") { CLIIO.err("Unbekannte Option: \(arg)"); return ChatsCLIExit.usage }
                if ref == nil { ref = arg } else { CLIIO.err("Zu viele Argumente."); return ChatsCLIExit.usage }
            }
            index += 1
        }
        guard let ref else {
            CLIIO.err("Usage: whisperm8 chats interrupt <ref> [--force]")
            return ChatsCLIExit.usage
        }
        let targetID: UUID
        switch ChatsLiveSupport.resolveTarget(ref: ref) {
        case .resolved(let id, _): targetID = id
        case .failed(let code): return code
        }
        let params: [String: Any] = ["targetSessionID": targetID.uuidString, "force": force]
        switch ChatsLiveSupport.perform(method: "session.interrupt", params: params) {
        case .failed(let code): return code
        case .ok(let response):
            guard response.ok else { return ChatsLiveSupport.mapError(response) }
            ChatsLiveSupport.printResult(response, json: json) { result in
                let title = result["target"]?["title"]?.stringValue ?? ref
                return "✓ Interrupt an \(title) gesendet (ESC)"
            }
            return ChatsCLIExit.ok
        }
    }
}

// MARK: - open

enum ChatsOpenCommand {
    static func run(_ arguments: [String]) -> Int32 {
        var ref: String?
        var json = false
        for arg in arguments {
            switch arg {
            case "--json": json = true
            default:
                if arg.hasPrefix("-") { CLIIO.err("Unbekannte Option: \(arg)"); return ChatsCLIExit.usage }
                if ref == nil { ref = arg } else { CLIIO.err("Zu viele Argumente."); return ChatsCLIExit.usage }
            }
        }
        guard let ref else { CLIIO.err("Usage: whisperm8 chats open <ref>"); return ChatsCLIExit.usage }
        let targetID: UUID
        switch ChatsLiveSupport.resolveTarget(ref: ref) {
        case .resolved(let id, _): targetID = id
        case .failed(let code): return code
        }
        switch ChatsLiveSupport.perform(method: "session.open", params: ["targetSessionID": targetID.uuidString]) {
        case .failed(let code): return code
        case .ok(let response):
            guard response.ok else { return ChatsLiveSupport.mapError(response) }
            ChatsLiveSupport.printResult(response, json: json) { result in
                "✓ \(result["target"]?["title"]?.stringValue ?? ref) fokussiert"
            }
            return ChatsCLIExit.ok
        }
    }
}

// MARK: - resume

enum ChatsResumeCommand {
    static func run(_ arguments: [String]) -> Int32 {
        var ref: String?
        var json = false
        for arg in arguments {
            switch arg {
            case "--json": json = true
            default:
                if arg.hasPrefix("-") { CLIIO.err("Unbekannte Option: \(arg)"); return ChatsCLIExit.usage }
                if ref == nil { ref = arg } else { CLIIO.err("Zu viele Argumente."); return ChatsCLIExit.usage }
            }
        }
        guard let ref else { CLIIO.err("Usage: whisperm8 chats resume <ref>"); return ChatsCLIExit.usage }
        let targetID: UUID
        switch ChatsLiveSupport.resolveTarget(ref: ref) {
        case .resolved(let id, _): targetID = id
        case .failed(let code): return code
        }
        switch ChatsLiveSupport.perform(method: "session.resume", params: ["targetSessionID": targetID.uuidString]) {
        case .failed(let code): return code
        case .ok(let response):
            guard response.ok else { return ChatsLiveSupport.mapError(response) }
            ChatsLiveSupport.printResult(response, json: json) { result in
                "✓ \(result["target"]?["title"]?.stringValue ?? ref) wird wiederaufgenommen (Resume)"
            }
            return ChatsCLIExit.ok
        }
    }
}

// MARK: - new

enum ChatsNewCommand {
    static func run(_ arguments: [String]) -> Int32 {
        var project: String?
        var provider = "claude"
        var title: String?
        var prompt: String?
        var json = false
        var index = 0
        func value(_ flag: String) -> String? {
            index += 1
            guard index < arguments.count else { CLIIO.err("\(flag) erwartet einen Wert."); return nil }
            return arguments[index]
        }
        while index < arguments.count {
            let arg = arguments[index]
            switch arg {
            case "--project": guard let v = value(arg) else { return ChatsCLIExit.usage }; project = v
            case "--provider": guard let v = value(arg) else { return ChatsCLIExit.usage }; provider = v
            case "--title": guard let v = value(arg) else { return ChatsCLIExit.usage }; title = v
            case "--prompt": guard let v = value(arg) else { return ChatsCLIExit.usage }; prompt = v
            case "--json": json = true
            default: CLIIO.err("Unbekannte Option: \(arg)"); return ChatsCLIExit.usage
            }
            index += 1
        }
        guard let project else {
            CLIIO.err("Usage: whisperm8 chats new --project <pfad|name> [--provider claude|codex] [--title T] [--prompt \"…\"]")
            return ChatsCLIExit.usage
        }
        guard provider == "claude" || provider == "codex" else {
            CLIIO.err("--provider muss claude oder codex sein.")
            return ChatsCLIExit.usage
        }
        var params: [String: Any] = ["project": project, "provider": provider]
        if let title { params["title"] = title }
        if let prompt { params["prompt"] = prompt }
        switch ChatsLiveSupport.perform(method: "session.new", params: params) {
        case .failed(let code): return code
        case .ok(let response):
            guard response.ok else { return ChatsLiveSupport.mapError(response) }
            ChatsLiveSupport.printResult(response, json: json) { result in
                let session = result["session"]
                let name = session?["project"]?.stringValue ?? project
                let sessionTitle = session?["title"]?.stringValue ?? "?"
                let id = session?["id"]?.stringValue ?? ""
                return "✓ Neue Session \(name)/\(sessionTitle) gestartet (\(ChatsOutput.shortID(UUID(uuidString: id) ?? UUID())))"
            }
            return ChatsCLIExit.ok
        }
    }
}

// MARK: - rename / group / archive

enum ChatsMutationCommand {
    static func run(_ arguments: [String], kind: Kind) -> Int32 {
        var positionals: [String] = []
        var force = false
        var clear = false
        var json = false
        for arg in arguments {
            switch arg {
            case "--force": force = true
            case "--clear": clear = true
            case "--json": json = true
            default:
                if arg.hasPrefix("-") { CLIIO.err("Unbekannte Option: \(arg)"); return ChatsCLIExit.usage }
                positionals.append(arg)
            }
        }
        guard let ref = positionals.first else {
            CLIIO.err("Usage: whisperm8 chats \(kind.verb) <ref> \(kind.argHint)")
            return ChatsCLIExit.usage
        }
        let targetID: UUID
        switch ChatsLiveSupport.resolveTarget(ref: ref) {
        case .resolved(let id, _): targetID = id
        case .failed(let code): return code
        }
        var params: [String: Any] = ["targetSessionID": targetID.uuidString, "force": force]
        switch kind {
        case .rename:
            guard positionals.count >= 2 else { CLIIO.err("Titel fehlt."); return ChatsCLIExit.usage }
            params["title"] = positionals[1...].joined(separator: " ")
        case .group:
            if clear {
                params["clear"] = true
            } else {
                guard positionals.count >= 2 else { CLIIO.err("Gruppe fehlt (oder --clear)."); return ChatsCLIExit.usage }
                params["group"] = positionals[1...].joined(separator: " ")
            }
        case .archive:
            break
        }
        switch ChatsLiveSupport.perform(method: kind.method, params: params) {
        case .failed(let code): return code
        case .ok(let response):
            guard response.ok else { return ChatsLiveSupport.mapError(response) }
            ChatsLiveSupport.printResult(response, json: json) { result in
                let before = result["before"]?.stringValue ?? ""
                let after = result["after"]?.stringValue ?? ""
                switch kind {
                case .rename: return "✓ umbenannt: „\(before)\" → „\(after)\""
                case .group: return after.isEmpty ? "✓ Gruppe entfernt" : "✓ Gruppe gesetzt: \(after)"
                case .archive: return "✓ archiviert"
                }
            }
            return ChatsCLIExit.ok
        }
    }

    enum Kind {
        case rename, group, archive
        var verb: String { self == .rename ? "rename" : self == .group ? "group" : "archive" }
        var method: String { self == .rename ? "workspace.rename" : self == .group ? "workspace.group" : "workspace.archive" }
        var argHint: String {
            switch self {
            case .rename: return "\"<titel>\""
            case .group: return "\"<gruppe>\" | --clear"
            case .archive: return "[--force]"
            }
        }
    }
}

// MARK: - workspace (Grid-Workspaces)

enum ChatsWorkspaceCommand {
    static func run(_ arguments: [String]) -> Int32 {
        guard let sub = arguments.first else {
            CLIIO.err("Usage: whisperm8 chats workspace list | rename <name|id> \"<neu>\"")
            return ChatsCLIExit.usage
        }
        let rest = Array(arguments.dropFirst())
        switch sub {
        case "list":
            return list(rest)
        case "rename":
            return rename(rest)
        default:
            CLIIO.err("Unbekannter workspace-Befehl: \(sub) (list | rename)")
            return ChatsCLIExit.usage
        }
    }

    private static func list(_ arguments: [String]) -> Int32 {
        let json = arguments.contains("--json")
        switch ChatsLiveSupport.perform(method: "gridWorkspace.list", params: [:]) {
        case .failed(let code): return code
        case .ok(let response):
            guard response.ok, let workspaces = response.result?["workspaces"]?.arrayValue else {
                return ChatsLiveSupport.mapError(response)
            }
            if json {
                CLIIO.out(ChatsOutput.encodeJSON(ChatsLiveSupport.jsonObject(from: response)))
            } else if workspaces.isEmpty {
                CLIIO.out("Keine Grid-Workspaces.")
            } else {
                for ws in workspaces {
                    let name = ws["name"]?.stringValue ?? "?"
                    let id = ws["id"]?.stringValue ?? ""
                    let short = String(id.replacingOccurrences(of: "-", with: "").lowercased().prefix(8))
                    CLIIO.out("\(short)  \(name)")
                }
            }
            return ChatsCLIExit.ok
        }
    }

    private static func rename(_ arguments: [String]) -> Int32 {
        var positionals: [String] = []
        var json = false
        for arg in arguments {
            if arg == "--json" { json = true }
            else if arg.hasPrefix("-") { CLIIO.err("Unbekannte Option: \(arg)"); return ChatsCLIExit.usage }
            else { positionals.append(arg) }
        }
        guard positionals.count >= 2 else {
            CLIIO.err("Usage: whisperm8 chats workspace rename <name|id> \"<neuer name>\"")
            return ChatsCLIExit.usage
        }
        let ref = positionals[0]
        let newName = positionals[1...].joined(separator: " ")
        switch ChatsLiveSupport.perform(method: "gridWorkspace.rename", params: ["ref": ref, "name": newName]) {
        case .failed(let code): return code
        case .ok(let response):
            guard response.ok else { return ChatsLiveSupport.mapError(response) }
            ChatsLiveSupport.printResult(response, json: json) { result in
                let before = result["before"]?.stringValue ?? ref
                let after = result["after"]?.stringValue ?? newName
                return "✓ Workspace umbenannt: „\(before)\" → „\(after)\""
            }
            return ChatsCLIExit.ok
        }
    }
}

// MARK: - audit

enum ChatsAuditCommand {
    static func run(_ arguments: [String]) -> Int32 {
        var limit = 20
        var sessionFilter: String?
        var json = false
        var index = 0
        while index < arguments.count {
            let arg = arguments[index]
            switch arg {
            case "--limit":
                index += 1
                guard index < arguments.count, let value = Int(arguments[index]), value > 0 else {
                    CLIIO.err("--limit erwartet eine positive Ganzzahl."); return ChatsCLIExit.usage
                }
                limit = value
            case "--session":
                index += 1
                guard index < arguments.count else { CLIIO.err("--session erwartet einen Wert."); return ChatsCLIExit.usage }
                sessionFilter = arguments[index]
            case "--json": json = true
            default: CLIIO.err("Unbekannte Option: \(arg)"); return ChatsCLIExit.usage
            }
            index += 1
        }

        var targetLabel: String?
        if let sessionFilter {
            switch ChatsLiveSupport.resolveTarget(ref: sessionFilter, includeArchived: true) {
            case .resolved(_, let label): targetLabel = label
            case .failed(let code): return code
            }
        }

        let entries = ChatsAuditLog.shared.recent(limit: limit, targetFilter: targetLabel)
        if json {
            let payload: [String: Any] = [
                "schemaVersion": 1,
                "entries": entries.map { entry -> [String: Any] in
                    var dict: [String: Any] = [
                        "at": ChatsOutput.iso(entry.at),
                        "actor": entry.actor,
                        "verified": entry.verified,
                        "method": entry.method,
                        "outcome": entry.outcome,
                    ]
                    if let target = entry.target { dict["target"] = target }
                    if let chars = entry.promptChars { dict["promptChars"] = chars }
                    if let head = entry.promptHead { dict["promptHead"] = head }
                    return dict
                },
            ]
            CLIIO.out(ChatsOutput.encodeJSON(payload))
        } else if entries.isEmpty {
            CLIIO.out("Kein Audit-Log vorhanden.")
        } else {
            for entry in entries {
                let time = ChatsOutput.iso(entry.at)
                let target = entry.target.map { " → \($0)" } ?? ""
                let head = entry.promptHead.map { "  „\($0)\"" } ?? ""
                CLIIO.out("\(time)  \(entry.actor)  \(entry.method)\(target)  [\(entry.outcome)]\(head)")
            }
        }
        return ChatsCLIExit.ok
    }
}
