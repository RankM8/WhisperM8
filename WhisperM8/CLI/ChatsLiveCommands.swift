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
        var clearInput = false
        var json = false
        var index = 0
        while index < arguments.count {
            let arg = arguments[index]
            switch arg {
            case "--force": force = true
            case "--clear-input": clearInput = true
            case "--json": json = true
            default:
                if arg.hasPrefix("-") { CLIIO.err("Unbekannte Option: \(arg)"); return ChatsCLIExit.usage }
                if ref == nil { ref = arg } else { CLIIO.err("Zu viele Argumente."); return ChatsCLIExit.usage }
            }
            index += 1
        }
        guard let ref else {
            CLIIO.err("Usage: whisperm8 chats interrupt <ref> [--force] [--clear-input]")
            return ChatsCLIExit.usage
        }
        let targetID: UUID
        switch ChatsLiveSupport.resolveTarget(ref: ref) {
        case .resolved(let id, _): targetID = id
        case .failed(let code): return code
        }
        var params: [String: Any] = ["targetSessionID": targetID.uuidString, "force": force]
        if clearInput { params["clearInput"] = true }
        switch ChatsLiveSupport.perform(method: "session.interrupt", params: params) {
        case .failed(let code): return code
        case .ok(let response):
            guard response.ok else { return ChatsLiveSupport.mapError(response) }
            ChatsLiveSupport.printResult(response, json: json) { result in
                let title = result["target"]?["title"]?.stringValue ?? ref
                let cleared = result["clearInput"]?.boolValue == true
                    ? " · Composer wird geleert" : ""
                return "✓ Interrupt an \(title) gesendet (ESC)\(cleared)"
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

// MARK: - close

/// Ergebnis eines close-Ziels, aus der Server-Response geparst. Pur und
/// Equatable — Exit-Code-Ableitung und Zeilen-Format sind damit testbar.
struct ChatsCloseResultItem: Equatable {
    var id: String
    var title: String?
    var project: String?
    var outcome: String     // closed | alreadyClosed | notFound
    var ptyRunning: Bool
    var runtimeStatus: String?
    var isPinned: Bool
    /// `true`, wenn `--stop` einen laufenden Agenten tatsächlich beendet hat.
    /// Unabhängig vom Tab-`outcome`: eine Session ohne offenen Tab meldet
    /// `alreadyClosed` und trotzdem `stopped: true`.
    var stopped = false
    /// Der Stop schlug fehl (Supervisor-Job eines Hintergrund-Agenten) — der
    /// Tab ist zu, der Agent läuft weiter.
    var stopFailed = false
}

enum ChatsCloseSupport {
    static func items(from result: ChatsControlJSON?) -> [ChatsCloseResultItem] {
        guard let results = result?["results"]?.arrayValue else { return [] }
        return results.map { entry in
            ChatsCloseResultItem(
                id: entry["id"]?.stringValue ?? "?",
                title: entry["title"]?.stringValue,
                project: entry["project"]?.stringValue,
                outcome: entry["outcome"]?.stringValue ?? "notFound",
                ptyRunning: entry["ptyRunning"]?.boolValue ?? false,
                runtimeStatus: entry["runtimeStatus"]?.stringValue,
                isPinned: entry["isPinned"]?.boolValue ?? false,
                stopped: entry["stopped"]?.boolValue ?? false,
                stopFailed: entry["stopFailed"]?.boolValue ?? false)
        }
    }

    /// `alreadyClosed` ist idempotenter Erfolg (Batch-Retry darf nicht an
    /// bereits geschlossenen Tabs scheitern); nur `notFound` schlägt fehl.
    static func exitCode(for items: [ChatsCloseResultItem]) -> Int32 {
        items.contains { $0.outcome == "notFound" } ? ChatsCLIExit.notFound : ChatsCLIExit.ok
    }

    /// Menschliche Ergebnis-Zeile pro Ziel. `fallbackLabel` = das Label aus
    /// der CLI-seitigen Ref-Auflösung (der Server kennt bei notFound keins).
    static func humanLine(for item: ChatsCloseResultItem, fallbackLabel: String?) -> String {
        let label = [item.project, item.title].compactMap { $0 }.joined(separator: "/")
        let name = label.isEmpty ? (fallbackLabel ?? item.id) : label
        let pin = item.isPinned ? " · 📌 Pin bleibt" : ""
        // Fehlgeschlagener Stop zuerst: der Tab ist zu, der Agent läuft aber
        // weiter — das darf keine Erfolgsmeldung überdecken.
        if item.stopFailed {
            return "⚠︎ Tab geschlossen, Agent läuft WEITER: \(name) "
                + "(Supervisor-Job nicht gestoppt — `claude stop <short-id>` prüfen)"
        }
        switch item.outcome {
        case "closed" where item.stopped:
            return "✓ Tab geschlossen · Agent gestoppt: \(name) (Verlauf bleibt, resume möglich\(pin))"
        case "closed":
            var suffix = "Session bleibt erhalten"
            if item.ptyRunning {
                suffix = "läuft weiter" + (item.runtimeStatus.map { ", \($0)" } ?? "")
            }
            return "✓ Tab geschlossen: \(name) (\(suffix)\(pin))"
        case "alreadyClosed" where item.stopped:
            // Kein Tab offen, aber ein Prozess lief im Hintergrund weiter —
            // genau der Fall, für den `--stop` gedacht ist.
            return "✓ Agent gestoppt: \(name) (kein offener Tab, Verlauf bleibt\(pin))"
        case "alreadyClosed":
            return "– kein offener Tab: \(name)"
        default:
            return "✗ nicht gefunden: \(name)"
        }
    }
}

enum ChatsCloseCommand {
    static func run(_ arguments: [String]) -> Int32 {
        let options: ChatsCloseOptions
        do {
            options = try ChatsCLIParser.parseClose(arguments)
        } catch {
            CLIIO.err(error.localizedDescription)
            CLIIO.err("Usage: whisperm8 chats close <ref> [<ref>…] [--stop [--force]] [--json]")
            return ChatsCLIExit.usage
        }

        // Alle Refs VOR dem Request auflösen — alles-oder-nichts: eine
        // mehrdeutige oder unbekannte Ref bricht ab, BEVOR irgendein Tab
        // schließt (Batch-Sicherheit für den Jarvis-Aufräum-Fall).
        var targetIDs: [UUID] = []
        var labelByID: [UUID: String] = [:]
        for ref in options.refs {
            switch ChatsLiveSupport.resolveTarget(ref: ref) {
            case .resolved(let id, let label):
                if !targetIDs.contains(id) { targetIDs.append(id) }
                labelByID[id] = label
            case .failed(let code):
                return code
            }
        }

        let params: [String: Any] = [
            "targetSessionIDs": targetIDs.map(\.uuidString),
            "mode": options.mode,
            "stop": options.stop,
            "force": options.force,
        ]
        switch ChatsLiveSupport.perform(method: "session.close", params: params) {
        case .failed(let code):
            return code
        case .ok(let response):
            guard response.ok else { return ChatsLiveSupport.mapError(response) }
            let items = ChatsCloseSupport.items(from: response.result)
            if options.json {
                CLIIO.out(ChatsOutput.encodeJSON(ChatsLiveSupport.jsonObject(from: response)))
            } else if items.isEmpty {
                CLIIO.out("Nichts zu schließen.")
            } else {
                for item in items {
                    let fallback = UUID(uuidString: item.id).flatMap { labelByID[$0] }
                    CLIIO.out(ChatsCloseSupport.humanLine(for: item, fallbackLabel: fallback))
                }
            }
            return ChatsCloseSupport.exitCode(for: items)
        }
    }
}

// MARK: - reopen

enum ChatsReopenCommand {
    static func run(_ arguments: [String]) -> Int32 {
        var json = false
        for arg in arguments {
            switch arg {
            case "--json": json = true
            default: CLIIO.err("Unbekannte Option: \(arg)"); return ChatsCLIExit.usage
            }
        }
        switch ChatsLiveSupport.perform(method: "session.reopen", params: [:]) {
        case .failed(let code): return code
        case .ok(let response):
            guard response.ok else { return ChatsLiveSupport.mapError(response) }
            ChatsLiveSupport.printResult(response, json: json) { result in
                "✓ Tab wiederhergestellt: \(result["target"]?["title"]?.stringValue ?? "?")"
            }
            return ChatsCLIExit.ok
        }
    }
}

// MARK: - pin / unpin

enum ChatsPinCommand {
    static func run(_ arguments: [String], pinned: Bool) -> Int32 {
        let verb = pinned ? "pin" : "unpin"
        let options: ChatsRefListOptions
        do {
            options = try ChatsCLIParser.parseRefList(arguments)
        } catch {
            CLIIO.err(error.localizedDescription)
            CLIIO.err("Usage: whisperm8 chats \(verb) <ref> [<ref>…] [--json]")
            return ChatsCLIExit.usage
        }

        // Wie close: alles-oder-nichts bei der Auflösung.
        var targetIDs: [UUID] = []
        var labelByID: [UUID: String] = [:]
        for ref in options.refs {
            switch ChatsLiveSupport.resolveTarget(ref: ref) {
            case .resolved(let id, let label):
                if !targetIDs.contains(id) { targetIDs.append(id) }
                labelByID[id] = label
            case .failed(let code):
                return code
            }
        }

        let params: [String: Any] = [
            "targetSessionIDs": targetIDs.map(\.uuidString),
            "pinned": pinned,
        ]
        switch ChatsLiveSupport.perform(method: "session.pin", params: params) {
        case .failed(let code): return code
        case .ok(let response):
            guard response.ok else { return ChatsLiveSupport.mapError(response) }
            let items = ChatsCloseSupport.items(from: response.result)
            if options.json {
                CLIIO.out(ChatsOutput.encodeJSON(ChatsLiveSupport.jsonObject(from: response)))
            } else {
                for item in items {
                    let label = [item.project, item.title].compactMap { $0 }.joined(separator: "/")
                    let name = label.isEmpty
                        ? (UUID(uuidString: item.id).flatMap { labelByID[$0] } ?? item.id)
                        : label
                    switch item.outcome {
                    case "pinned": CLIIO.out("📌 gepinnt: \(name)")
                    case "unpinned": CLIIO.out("✓ Pin entfernt: \(name)")
                    case "unchanged": CLIIO.out("– unverändert: \(name)")
                    default: CLIIO.out("✗ nicht gefunden: \(name)")
                    }
                }
            }
            return ChatsCloseSupport.exitCode(for: items)
        }
    }
}

// MARK: - move

enum ChatsMoveCommand {
    static func run(_ arguments: [String]) -> Int32 {
        var ref: String?
        var windowRef: String?
        var json = false
        var index = 0
        while index < arguments.count {
            let arg = arguments[index]
            switch arg {
            case "--window":
                index += 1
                guard index < arguments.count else { CLIIO.err("--window erwartet einen Wert."); return ChatsCLIExit.usage }
                windowRef = arguments[index]
            case "--json": json = true
            default:
                if arg.hasPrefix("-") { CLIIO.err("Unbekannte Option: \(arg)"); return ChatsCLIExit.usage }
                if ref == nil { ref = arg } else { CLIIO.err("Zu viele Argumente."); return ChatsCLIExit.usage }
            }
            index += 1
        }
        guard let ref, let windowRef else {
            CLIIO.err("Usage: whisperm8 chats move <ref> --window <primary|fenster-id> [--json]")
            return ChatsCLIExit.usage
        }
        let targetID: UUID
        switch ChatsLiveSupport.resolveTarget(ref: ref) {
        case .resolved(let id, _): targetID = id
        case .failed(let code): return code
        }
        let params: [String: Any] = ["targetSessionID": targetID.uuidString, "windowRef": windowRef]
        switch ChatsLiveSupport.perform(method: "session.move", params: params) {
        case .failed(let code): return code
        case .ok(let response):
            guard response.ok else { return ChatsLiveSupport.mapError(response) }
            ChatsLiveSupport.printResult(response, json: json) { result in
                "✓ \(result["target"]?["title"]?.stringValue ?? ref) verschoben (Fenster \(ChatsWindowCommand.shortWindowID(result["windowID"]?.stringValue)))"
            }
            return ChatsCLIExit.ok
        }
    }
}

// MARK: - window (Fenster-Inventar)

enum ChatsWindowCommand {
    static func run(_ arguments: [String]) -> Int32 {
        guard let sub = arguments.first else {
            CLIIO.err("Usage: whisperm8 chats window list [--json]")
            return ChatsCLIExit.usage
        }
        switch sub {
        case "list":
            return list(Array(arguments.dropFirst()))
        default:
            CLIIO.err("Unbekannter window-Befehl: \(sub) (list)")
            return ChatsCLIExit.usage
        }
    }

    static func shortWindowID(_ id: String?) -> String {
        guard let id else { return "?" }
        return String(id.replacingOccurrences(of: "-", with: "").lowercased().prefix(8))
    }

    private static func list(_ arguments: [String]) -> Int32 {
        let json = arguments.contains("--json")
        switch ChatsLiveSupport.perform(method: "window.list", params: [:]) {
        case .failed(let code): return code
        case .ok(let response):
            guard response.ok, let windows = response.result?["windows"]?.arrayValue else {
                return ChatsLiveSupport.mapError(response)
            }
            if json {
                CLIIO.out(ChatsOutput.encodeJSON(ChatsLiveSupport.jsonObject(from: response)))
            } else {
                for window in windows {
                    let short = shortWindowID(window["id"]?.stringValue)
                    let primary = window["isPrimary"]?.boolValue == true ? " (primär)" : ""
                    let titles = window["tabTitles"]?.arrayValue?.compactMap(\.stringValue) ?? []
                    let preview = titles.prefix(4).joined(separator: " · ")
                        + (titles.count > 4 ? " · …" : "")
                    CLIIO.out("\(short)\(primary)  \(titles.count) Tabs  \(preview)"
                              + ChatsWorkspaceViewSupport.windowSuffix(for: window))
                }
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

/// Reines Argument-Parsing fuer `chats new` — getrennt vom Kommando, damit
/// der Vertrag (Flags, Pflichtfelder, Fehlermeldungen) ohne Socket testbar
/// bleibt.
struct ChatsNewArguments: Equatable {
    var project: String
    var provider: String
    var title: String?
    var prompt: String?
    /// Ausdrueckliches Account-Profil. `nil` = das in den Einstellungen
    /// aktive Profil (Default-Regel, siehe docs/features/agent-chats-cli.md).
    var account: String?
    var json: Bool

    static let usage = "Usage: whisperm8 chats new --project <pfad|name> [--provider claude|codex] [--title T] [--prompt \"…\"] [--account <profil>]"

    enum ParseError: Error, Equatable {
        case missingValue(String)
        case unknownOption(String)
        case projectMissing
        case invalidProvider(String)

        var message: String {
            switch self {
            case .missingValue(let flag): return "\(flag) erwartet einen Wert."
            case .unknownOption(let option): return "Unbekannte Option: \(option)"
            case .projectMissing: return ChatsNewArguments.usage
            case .invalidProvider: return "--provider muss claude oder codex sein."
            }
        }
    }

    static func parse(_ arguments: [String]) -> Result<ChatsNewArguments, ParseError> {
        var project: String?
        var provider = "claude"
        var title: String?
        var prompt: String?
        var account: String?
        var json = false
        var index = 0
        while index < arguments.count {
            let arg = arguments[index]
            func value() -> String? {
                index += 1
                guard index < arguments.count else { return nil }
                return arguments[index]
            }
            switch arg {
            case "--project":
                guard let v = value() else { return .failure(.missingValue(arg)) }
                project = v
            case "--provider":
                guard let v = value() else { return .failure(.missingValue(arg)) }
                provider = v
            case "--title":
                guard let v = value() else { return .failure(.missingValue(arg)) }
                title = v
            case "--prompt":
                guard let v = value() else { return .failure(.missingValue(arg)) }
                prompt = v
            case "--account":
                guard let v = value() else { return .failure(.missingValue(arg)) }
                account = v
            case "--json":
                json = true
            default:
                return .failure(.unknownOption(arg))
            }
            index += 1
        }
        guard let project, !project.isEmpty else { return .failure(.projectMissing) }
        guard provider == "claude" || provider == "codex" else {
            return .failure(.invalidProvider(provider))
        }
        return .success(ChatsNewArguments(
            project: project, provider: provider, title: title,
            prompt: prompt, account: account, json: json))
    }

    /// Params fuer `session.new`. Leere Optionalwerte bleiben weg, damit der
    /// Handler „nicht angegeben" von „ausdruecklich leer" unterscheiden kann.
    var controlParams: [String: Any] {
        var params: [String: Any] = ["project": project, "provider": provider]
        if let title { params["title"] = title }
        if let prompt { params["prompt"] = prompt }
        if let account { params["account"] = account }
        return params
    }
}

enum ChatsNewCommand {
    static func run(_ arguments: [String]) -> Int32 {
        let parsed: ChatsNewArguments
        switch ChatsNewArguments.parse(arguments) {
        case .failure(let error):
            CLIIO.err(error.message)
            return ChatsCLIExit.usage
        case .success(let value):
            parsed = value
        }
        let project = parsed.project
        let json = parsed.json
        let params = parsed.controlParams
        switch ChatsLiveSupport.perform(method: "session.new", params: params) {
        case .failed(let code): return code
        case .ok(let response):
            guard response.ok else { return ChatsLiveSupport.mapError(response) }
            ChatsLiveSupport.printResult(response, json: json) { result in
                let session = result["session"]
                let name = session?["project"]?.stringValue ?? project
                let sessionTitle = session?["title"]?.stringValue ?? "?"
                let id = session?["id"]?.stringValue ?? ""
                let account = session?["account"]?.stringValue ?? "?"
                return "✓ Neue Session \(name)/\(sessionTitle) gestartet (\(ChatsOutput.shortID(UUID(uuidString: id) ?? UUID())), Account: \(account))"
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

/// Pure Ausgabelogik von `workspace open` — die Fallunterscheidung
/// (aktiviert / war schon sichtbar / anderes Fenster) ist die eigentliche
/// Aussage des Befehls und bleibt ohne laufende App testbar.
enum ChatsWorkspaceOpenSupport {
    static func humanLine(
        name: String,
        outcome: String?,
        slot: Int?,
        slotOccupied: Bool?,
        focusedTitle: String?
    ) -> String {
        let head: String
        switch outcome {
        case "activated":
            head = "✓ Workspace „\(name)\" geöffnet"
        case "alreadyVisible":
            head = "– Workspace „\(name)\" war schon sichtbar"
        case "focusedOwnerWindow":
            // Wichtig zu benennen: ein anderes Fenster besitzt ihn, wir haben
            // nur fokussiert — es wurde nichts umgehängt.
            head = "✓ Workspace „\(name)\" im besitzenden Fenster nach vorn geholt"
        default:
            head = "✓ Workspace „\(name)\""
        }
        guard let slot else { return head }
        if slotOccupied == false {
            return head + " · Slot \(slot) ist leer"
        }
        if let focusedTitle, !focusedTitle.isEmpty {
            return head + " · Slot \(slot) fokussiert: \(focusedTitle)"
        }
        return head + " · Slot \(slot) fokussiert"
    }
}

/// Pure Ausgabelogik von `workspace add`/`remove` — die Outcome-Sprache
/// (aufgenommen/verschoben/ersetzt/erweitert/Slot bleibt leer) ist die
/// eigentliche Aussage des Befehls und bleibt ohne laufende App testbar.
enum ChatsWorkspaceMembershipSupport {
    static func humanLine(
        name: String,
        outcome: String?,
        slot: Int?,
        fromSlot: Int?,
        grewTo: Int?,
        keptSlot: Bool
    ) -> String {
        let grow = grewTo.map { " · Grid auf \($0) erweitert" } ?? ""
        switch outcome {
        case "added":
            let position = slot.map { " (Slot \($0))" } ?? ""
            return "✓ in Workspace „\(name)\" aufgenommen\(position)\(grow)"
        case "moved":
            let from = fromSlot.map { " (vorher Slot \($0))" } ?? ""
            let target = slot.map { "auf Slot \($0) " } ?? ""
            return "✓ in „\(name)\" \(target)verschoben\(from)\(grow)"
        case "replaced":
            let position = slot.map { "Slot \($0)" } ?? "Slot"
            return "✓ \(position) in „\(name)\" ersetzt — der bisherige Chat bleibt Tab\(grow)"
        case "alreadyMember":
            let position = slot.map { " (Slot \($0))" } ?? ""
            return "– schon Mitglied von „\(name)\"\(position)"
        case "removed":
            return keptSlot
                ? "✓ aus Workspace „\(name)\" entfernt · Slot bleibt leer"
                : "✓ aus Workspace „\(name)\" entfernt"
        default:
            return "– war kein Mitglied von „\(name)\""
        }
    }
}

enum ChatsWorkspaceCommand {
    static func run(_ arguments: [String]) -> Int32 {
        guard let sub = arguments.first else {
            CLIIO.err("Usage: whisperm8 chats workspace list | create \"<name>\" [--color #RRGGBB] [<ref>…] | open <name|id> [--slot N] | rename <name|id> \"<neu>\" | add <name|id> <ref> [--slot N] | remove <name|id> <ref> [--keep-slot] | delete <name|id> [--force]")
            return ChatsCLIExit.usage
        }
        let rest = Array(arguments.dropFirst())
        switch sub {
        case "list":
            return list(rest)
        case "create":
            return create(rest)
        case "open":
            return open(rest)
        case "rename":
            return rename(rest)
        case "add":
            return membership(rest, add: true)
        case "remove":
            return membership(rest, add: false)
        case "delete":
            return delete(rest)
        default:
            CLIIO.err("Unbekannter workspace-Befehl: \(sub) (list | create | open | rename | add | remove | delete)")
            return ChatsCLIExit.usage
        }
    }

    /// `workspace open <ws> [--slot N]` — Workspace sichtbar machen und Fenster
    /// nach vorn holen. Rein visuell: startet keine Prozesse und ändert keine
    /// Slot-Mitgliedschaften.
    private static func open(_ arguments: [String]) -> Int32 {
        var positionals: [String] = []
        var slot: Int?
        var json = false
        var index = 0
        while index < arguments.count {
            let arg = arguments[index]
            switch arg {
            case "--slot":
                index += 1
                guard index < arguments.count, let value = Int(arguments[index]), value >= 1 else {
                    CLIIO.err("--slot erwartet eine Slot-Nummer >= 1.")
                    return ChatsCLIExit.usage
                }
                slot = value - 1    // menschlich 1-basiert → Slot-Index
            case "--json": json = true
            default:
                if arg.hasPrefix("-") { CLIIO.err("Unbekannte Option: \(arg)"); return ChatsCLIExit.usage }
                positionals.append(arg)
            }
            index += 1
        }
        guard positionals.count == 1 else {
            CLIIO.err("Usage: whisperm8 chats workspace open <name|id> [--slot N] [--json]")
            return ChatsCLIExit.usage
        }
        var params: [String: Any] = ["workspaceRef": positionals[0]]
        if let slot { params["slot"] = slot }

        switch ChatsLiveSupport.perform(method: "gridWorkspace.open", params: params) {
        case .failed(let code): return code
        case .ok(let response):
            guard response.ok else { return ChatsLiveSupport.mapError(response) }
            ChatsLiveSupport.printResult(response, json: json) { result in
                ChatsWorkspaceOpenSupport.humanLine(
                    name: result["workspace"]?["name"]?.stringValue ?? positionals[0],
                    outcome: result["outcome"]?.stringValue,
                    slot: result["slot"].flatMap { json -> Int? in
                        if case .number(let value) = json { return Int(value) }
                        return nil
                    },
                    slotOccupied: result["slotOccupied"]?.boolValue,
                    focusedTitle: result["focused"]?["title"]?.stringValue)
            }
            return ChatsCLIExit.ok
        }
    }

    /// `workspace add <ws> <ref> [--slot N]` / `workspace remove <ws> <ref>
    /// [--keep-slot]`. Nur die Slot-MITGLIEDSCHAFT ändert sich — Tabs und
    /// Prozesse bleiben (identisch zur Sidebar-Aktion in der App).
    /// `--slot N` jenseits der aktuellen Stufe erweitert das Grid (bis 3×3);
    /// ein vorhandenes Mitglied wird mit `--slot N` verschoben/getauscht.
    /// `--keep-slot` lässt beim Entfernen den Slot leer stehen (nichts rückt
    /// nach), statt der Default-Kompaktierung.
    private static func membership(_ arguments: [String], add: Bool) -> Int32 {
        var positionals: [String] = []
        var slot: Int?
        var keepSlot = false
        var json = false
        var index = 0
        while index < arguments.count {
            let arg = arguments[index]
            switch arg {
            case "--slot":
                index += 1
                guard add, index < arguments.count, let value = Int(arguments[index]), value >= 1 else {
                    CLIIO.err(add ? "--slot erwartet eine Slot-Nummer >= 1." : "--slot gibt es nur bei add.")
                    return ChatsCLIExit.usage
                }
                slot = value - 1    // menschlich 1-basiert → Slot-Index
            case "--keep-slot":
                guard !add else {
                    CLIIO.err("--keep-slot gibt es nur bei remove.")
                    return ChatsCLIExit.usage
                }
                keepSlot = true
            case "--json": json = true
            default:
                if arg.hasPrefix("-") { CLIIO.err("Unbekannte Option: \(arg)"); return ChatsCLIExit.usage }
                positionals.append(arg)
            }
            index += 1
        }
        guard positionals.count == 2 else {
            CLIIO.err("Usage: whisperm8 chats workspace \(add ? "add" : "remove") <name|id> <ref>\(add ? " [--slot N]" : " [--keep-slot]")")
            return ChatsCLIExit.usage
        }
        let workspaceRef = positionals[0]
        let targetID: UUID
        switch ChatsLiveSupport.resolveTarget(ref: positionals[1]) {
        case .resolved(let id, _): targetID = id
        case .failed(let code): return code
        }
        var params: [String: Any] = ["workspaceRef": workspaceRef, "targetSessionID": targetID.uuidString]
        if let slot { params["slot"] = slot }
        if keepSlot { params["keepSlot"] = true }
        switch ChatsLiveSupport.perform(method: add ? "gridWorkspace.add" : "gridWorkspace.remove", params: params) {
        case .failed(let code): return code
        case .ok(let response):
            guard response.ok else { return ChatsLiveSupport.mapError(response) }
            ChatsLiveSupport.printResult(response, json: json) { result in
                ChatsWorkspaceMembershipSupport.humanLine(
                    name: result["workspace"]?["name"]?.stringValue ?? workspaceRef,
                    outcome: result["outcome"]?.stringValue,
                    slot: intValue(result["slot"]),
                    fromSlot: intValue(result["fromSlot"]),
                    grewTo: intValue(result["grewTo"]),
                    keptSlot: result["keptSlot"]?.boolValue ?? false)
            }
            return ChatsCLIExit.ok
        }
    }

    /// `workspace create "<name>" [--color #RRGGBB] [<ref> …]` — legt einen
    /// Grid-Workspace an; weitere Positionals sind Initial-Mitglieder
    /// (Slots in Reihenfolge, Kapazität wächst passend mit).
    private static func create(_ arguments: [String]) -> Int32 {
        var positionals: [String] = []
        var colorHex: String?
        var json = false
        var index = 0
        while index < arguments.count {
            let arg = arguments[index]
            switch arg {
            case "--color":
                index += 1
                guard index < arguments.count else {
                    CLIIO.err("--color erwartet eine Farbe im Format #RRGGBB.")
                    return ChatsCLIExit.usage
                }
                colorHex = arguments[index]
            case "--json": json = true
            default:
                if arg.hasPrefix("-") { CLIIO.err("Unbekannte Option: \(arg)"); return ChatsCLIExit.usage }
                positionals.append(arg)
            }
            index += 1
        }
        guard let name = positionals.first,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            CLIIO.err("Usage: whisperm8 chats workspace create \"<name>\" [--color #RRGGBB] [<ref> …] [--json]")
            return ChatsCLIExit.usage
        }
        var memberIDs: [String] = []
        for ref in positionals.dropFirst() {
            switch ChatsLiveSupport.resolveTarget(ref: ref) {
            case .resolved(let id, _): memberIDs.append(id.uuidString)
            case .failed(let code): return code
            }
        }
        var params: [String: Any] = ["name": name]
        if let colorHex { params["colorHex"] = colorHex }
        if !memberIDs.isEmpty { params["memberSessionIDs"] = memberIDs }
        switch ChatsLiveSupport.perform(method: "gridWorkspace.create", params: params) {
        case .failed(let code): return code
        case .ok(let response):
            guard response.ok else { return ChatsLiveSupport.mapError(response) }
            ChatsLiveSupport.printResult(response, json: json) { result in
                let createdName = result["workspace"]?["name"]?.stringValue ?? name
                let id = result["workspace"]?["id"]?.stringValue ?? ""
                let short = String(id.replacingOccurrences(of: "-", with: "").lowercased().prefix(8))
                let members = intValue(result["members"]) ?? 0
                let capacity = intValue(result["capacity"]) ?? 2
                let filling = members == 0
                    ? "leer" : "\(members) Mitglied\(members == 1 ? "" : "er")"
                return "✓ Workspace „\(createdName)\" angelegt (\(short)) · \(filling) · Kapazität \(capacity)"
            }
            return ChatsCLIExit.ok
        }
    }

    /// `workspace delete <name|id> [--force]` — löscht die kuratierte
    /// Gruppe. Slots sind nur Referenzen: Chats, Tabs und Prozesse bleiben.
    /// Belegte Workspaces verlangen `--force` (Tippfehler-Schutz).
    private static func delete(_ arguments: [String]) -> Int32 {
        var positionals: [String] = []
        var force = false
        var json = false
        for arg in arguments {
            if arg == "--force" { force = true }
            else if arg == "--json" { json = true }
            else if arg.hasPrefix("-") { CLIIO.err("Unbekannte Option: \(arg)"); return ChatsCLIExit.usage }
            else { positionals.append(arg) }
        }
        guard positionals.count == 1 else {
            CLIIO.err("Usage: whisperm8 chats workspace delete <name|id> [--force] [--json]")
            return ChatsCLIExit.usage
        }
        var params: [String: Any] = ["ref": positionals[0]]
        if force { params["force"] = true }
        switch ChatsLiveSupport.perform(method: "gridWorkspace.delete", params: params) {
        case .failed(let code): return code
        case .ok(let response):
            guard response.ok else { return ChatsLiveSupport.mapError(response) }
            ChatsLiveSupport.printResult(response, json: json) { result in
                let name = result["workspace"]?["name"]?.stringValue ?? positionals[0]
                let freed = intValue(result["freedSlots"]) ?? 0
                return freed == 0
                    ? "✓ Workspace „\(name)\" gelöscht"
                    : "✓ Workspace „\(name)\" gelöscht (\(freed) Slot\(freed == 1 ? "" : "s") freigegeben — Chats/Tabs bleiben)"
            }
            return ChatsCLIExit.ok
        }
    }

    private static func intValue(_ json: ChatsControlJSON?) -> Int? {
        guard case .number(let value) = json else { return nil }
        return Int(value)
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
                    CLIIO.out("\(short)  \(name)\(ChatsWorkspaceViewSupport.suffix(for: ws))")
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
