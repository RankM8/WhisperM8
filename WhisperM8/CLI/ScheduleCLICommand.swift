import Foundation

// MARK: - whisperm8 schedule (Geplante Aufgaben, WM8-110)

/// `list` und `show` lesen `scheduled-tasks.json` und die Lauf-Ordner direkt
/// von Disk. Alles, was ändert oder startet, geht über den Socket an die App
/// (einziger Schreiber).
enum ScheduleCLICommand {
    static let help = """
    whisperm8 schedule — geplante Claude-Läufe (Labs, Einstellungen › Labs › Scheduled tasks)

      list [--json]                 alle Aufgaben mit Zeitplan, nächstem Termin und letztem Lauf
      show <aufgabe> [--json]       eine Aufgabe mit ihren letzten Läufen (Sitzung, Ergebnis)
      add  --name N --dir ORDNER --account KONTO --schedule "werktags 07:00"
           (--prompt TEXT | --prompt-file DATEI)
           [--access project|read-only|custom] [--allow WERKZEUG]… [--no-catch-up] [--paused]
      edit <aufgabe> [dieselben Optionen] [--catch-up] [--clear-allow]
      remove <aufgabe>              Aufgabe löschen; die Chats ihrer Läufe bleiben
      run <aufgabe>                 jetzt starten (nicht, solange ein Lauf arbeitet)
      pause <aufgabe> | resume <aufgabe>

    <aufgabe>: Name, ID oder ID-Anfang (mindestens 4 Zeichen).
    Zeitplan: täglich 07:00 · werktags 07:00, 22:30 · wöchentlich mo, mi 08:00 · stündlich :15
    Rechte ab Werk (--access project): lesen (Read gilt für die ganze Platte, nicht nur den Ordner) und im
    Projektordner schreiben: Read, Glob, Grep, Edit(/**), Skill. Bash, WebFetch, WebSearch und alle MCP-Werkzeuge
    sind gesperrt, auch wenn das Konto sie in seiner settings.json erlaubt. Eine Familie geht nur ausdrücklich
    auf: --allow "Bash(whisperm8 tickets *)" öffnet Bash (dann gelten auch die Bash-Freigaben des Kontos),
    --allow mcp__linear__get_issue öffnet MCP (dann lädt der Lauf die MCP-Server des Kontos).
    Ebenso gesperrt, offen nur einzeln per --allow: SendMessage, ListAgents (andere lokale Sitzungen),
    RemoteTrigger (Cloud-Routinen), CronCreate, CronDelete, PushNotification, DesignSync,
    EnterWorktree, ExitWorktree (anderer Arbeitsordner).
    Läufe starten nur, solange WhisperM8 läuft; Verpasstes wird bis 12 Stunden später nachgeholt.
    """

    static func run(arguments: [String]) async -> Int32 {
        let parsed: ScheduleCLIArguments
        do {
            parsed = try ScheduleCLIArguments.parse(arguments)
        } catch let error as ScheduleCLIArguments.ParseError {
            CLIIO.err(error.message)
            return ChatsCLIExit.usage
        } catch {
            CLIIO.err("\(error)")
            return ChatsCLIExit.usage
        }
        let output = execute(parsed, store: ScheduledTaskStore(), now: Date(), calendar: .current,
                             enabled: AppPreferences.appDomain().isScheduledTasksEnabled,
                             send: sendViaSocket)
        if !output.stdout.isEmpty { CLIIO.out(output.stdout) }
        if !output.stderr.isEmpty { CLIIO.err(output.stderr) }
        return output.exitCode
    }

    /// `Error`, damit `resolve` eine fertige Fehlerausgabe als `Result` liefern kann.
    struct Output: Equatable, Error {
        var exitCode: Int32
        var stdout: String = ""
        var stderr: String = ""
    }

    enum SendResult {
        case ok(ChatsControlJSON?)
        case failed(String, Int32)
    }

    typealias Sender = (_ method: String, _ params: [String: Any]) -> SendResult

    static func sendViaSocket(method: String, params: [String: Any]) -> SendResult {
        do {
            let response = try ChatsControlClient.send(method: method, params: params)
            guard response.ok else {
                let message = response.error?.message ?? "Unbekannter Fehler."
                let code = response.error.flatMap { ChatsControlErrorCode(rawValue: $0.code) }?.exitCode ?? ChatsCLIExit.conflict
                return .failed(message, code)
            }
            return .ok(response.result)
        } catch ChatsControlClient.ClientError.appUnreachable(let message) {
            return .failed(message, ChatsCLIExit.appUnreachable)
        } catch ChatsControlClient.ClientError.outcomeUnknown(let message) {
            return .failed(message + " Stand prüfen mit `whisperm8 schedule show <aufgabe>`.", ChatsCLIExit.outcomeUnknown)
        } catch {
            return .failed("Fehler: \(error)", ChatsCLIExit.appUnreachable)
        }
    }

    // MARK: Ausführen (rein bis auf Disk-Lesen und `send`)

    static func execute(_ arguments: ScheduleCLIArguments, store: ScheduledTaskStore, now: Date, calendar: Calendar,
                        enabled: Bool, send: Sender,
                        isProcessAlive: @escaping (Int32, Date?) -> Bool = { ScheduledTaskRunEvaluator.isProcessAlive(pid: $0, startedAt: $1) },
                        readFile: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }) -> Output {
        let file: ScheduledTasksFile
        do {
            file = try store.load()
        } catch {
            return Output(exitCode: ChatsCLIExit.conflict, stderr: error.localizedDescription)
        }
        let context = ScheduleCLIFormatter.Context(store: store, now: now, calendar: calendar, isProcessAlive: isProcessAlive)

        func resolve(_ ref: String) -> Result<ScheduledTask, Output> {
            switch ScheduleCLIArguments.resolve(ref, in: file.tasks) {
            case .found(let task): return .success(task)
            case .none: return .failure(Output(exitCode: ChatsCLIExit.notFound, stderr: "Keine geplante Aufgabe „\(ref)“."))
            case .ambiguous(let candidates):
                let list = candidates.map { "  \($0.shortID)  \($0.name)" }.joined(separator: "\n")
                return .failure(Output(exitCode: ChatsCLIExit.notFound, stderr: "„\(ref)“ ist mehrdeutig:\n\(list)"))
            }
        }

        func mutate(_ method: String, params: [String: Any], success: (ChatsControlJSON?) -> String) -> Output {
            switch send(method, params) {
            case .ok(let result): return Output(exitCode: ChatsCLIExit.ok, stdout: success(result))
            case .failed(let message, let code): return Output(exitCode: code, stderr: message)
            }
        }

        let disabledNote = enabled ? "" : "Hinweis: Geplante Aufgaben sind aus (Einstellungen › Labs › Scheduled tasks). Es startet nichts."

        switch arguments {
        case .help:
            return Output(exitCode: ChatsCLIExit.ok, stdout: help)
        case .list(let json):
            let text = json ? ScheduleCLIFormatter.listJSON(file.tasks, context: context)
                : ScheduleCLIFormatter.list(file.tasks, context: context)
            return Output(exitCode: ChatsCLIExit.ok, stdout: text, stderr: json ? "" : disabledNote)
        case .show(let ref, let json):
            switch resolve(ref) {
            case .failure(let output): return output
            case .success(let task):
                let text = json ? ScheduleCLIFormatter.detailJSON(task, context: context)
                    : ScheduleCLIFormatter.detail(task, context: context)
                return Output(exitCode: ChatsCLIExit.ok, stdout: text, stderr: json ? "" : disabledNote)
            }
        case .add(var options):
            if let path = options.promptFile {
                guard let text = readFile(path) else {
                    return Output(exitCode: ChatsCLIExit.usage, stderr: "Datei nicht lesbar: \(path)")
                }
                options.draft.prompt = text
            }
            if let directory = options.draft.directory {
                options.draft.directory = ScheduledTaskValidation.normalizedDirectory(directory)
            }
            return mutate("schedule.add", params: ["draftJSON": draftJSON(options.draft)]) { result in
                let name = result?["name"]?.stringValue ?? options.draft.name ?? ""
                let short = result?["shortID"]?.stringValue ?? ""
                return "Angelegt: \(name) (\(short)), \(result?["schedule"]?.stringValue ?? "")."
            }
        case .edit(let ref, var options):
            switch resolve(ref) {
            case .failure(let output): return output
            case .success(let task):
                if let path = options.promptFile {
                    guard let text = readFile(path) else {
                        return Output(exitCode: ChatsCLIExit.usage, stderr: "Datei nicht lesbar: \(path)")
                    }
                    options.draft.prompt = text
                }
                if let directory = options.draft.directory {
                    options.draft.directory = ScheduledTaskValidation.normalizedDirectory(directory)
                }
                guard !options.draft.isEmpty else {
                    return Output(exitCode: ChatsCLIExit.usage, stderr: "Nichts zu ändern. Optionen: whisperm8 schedule help")
                }
                return mutate("schedule.edit", params: ["id": task.id.uuidString, "draftJSON": draftJSON(options.draft)]) { _ in
                    "Geändert: \(task.name) (\(task.shortID))."
                }
            }
        case .remove(let ref), .run(let ref), .pause(let ref), .resume(let ref):
            switch resolve(ref) {
            case .failure(let output): return output
            case .success(let task):
                let method: String
                switch arguments {
                case .remove: method = "schedule.remove"
                case .run: method = "schedule.run"
                case .pause: method = "schedule.pause"
                default: method = "schedule.resume"
                }
                var notStarted = false
                var output = mutate(method, params: ["id": task.id.uuidString]) { result in
                    notStarted = method == "schedule.run" && result?["started"]?.boolValue == false
                    return ScheduleCLIFormatter.mutationMessage(method: method, task: task, result: result)
                }
                if notStarted {
                    // Vorab-Prüfung (Login, Ordner, Konto) hat den Start verhindert.
                    output = Output(exitCode: ChatsCLIExit.conflict, stderr: output.stdout)
                }
                return output
            }
        }
    }

    static func draftJSON(_ draft: ScheduledTaskDraft) -> String {
        guard let data = try? ScheduledTaskStore.makeEncoder().encode(draft) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Argumente

enum ScheduleCLIArguments: Equatable {
    struct DraftOptions: Equatable {
        var draft = ScheduledTaskDraft()
        var promptFile: String?
    }

    case help
    case list(json: Bool)
    case show(String, json: Bool)
    case add(DraftOptions)
    case edit(String, DraftOptions)
    case remove(String)
    case run(String)
    case pause(String)
    case resume(String)

    struct ParseError: Error, Equatable {
        var message: String
    }

    static func parse(_ arguments: [String]) throws -> ScheduleCLIArguments {
        guard let command = arguments.first else { return .help }
        var rest = Array(arguments.dropFirst())
        func takeJSON() -> Bool {
            guard let index = rest.firstIndex(of: "--json") else { return false }
            rest.remove(at: index)
            return true
        }
        func singleRef() throws -> String {
            guard rest.count == 1, let ref = rest.first, !ref.hasPrefix("--") else {
                throw ParseError(message: "\(command) braucht genau eine Aufgabe (Name oder ID).")
            }
            return ref
        }
        switch command {
        case "help", "--help", "-h": return .help
        case "list":
            let json = takeJSON()
            guard rest.isEmpty else { throw ParseError(message: "list kennt nur --json.") }
            return .list(json: json)
        case "show":
            let json = takeJSON()
            return .show(try singleRef(), json: json)
        case "add":
            let options = try parseDraft(rest, forAdd: true)
            let draft = options.draft
            var missing: [String] = []
            if draft.name == nil { missing.append("--name") }
            if draft.prompt == nil, options.promptFile == nil { missing.append("--prompt oder --prompt-file") }
            if draft.directory == nil { missing.append("--dir") }
            if draft.account == nil { missing.append("--account") }
            if draft.schedule == nil { missing.append("--schedule") }
            guard missing.isEmpty else {
                throw ParseError(message: "add braucht: " + missing.joined(separator: ", ") + ".")
            }
            return .add(options)
        case "edit":
            guard let ref = rest.first, !ref.hasPrefix("--") else {
                throw ParseError(message: "edit braucht zuerst die Aufgabe (Name oder ID).")
            }
            return .edit(ref, try parseDraft(Array(rest.dropFirst()), forAdd: false))
        case "remove", "delete": return .remove(try singleRef())
        case "run": return .run(try singleRef())
        case "pause": return .pause(try singleRef())
        case "resume": return .resume(try singleRef())
        default:
            throw ParseError(message: "Unbekannter Unterbefehl „\(command)“. Hilfe: whisperm8 schedule help")
        }
    }

    static func parseDraft(_ arguments: [String], forAdd: Bool) throws -> DraftOptions {
        var options = DraftOptions()
        var index = 0
        func value(_ flag: String) throws -> String {
            index += 1
            guard index < arguments.count else { throw ParseError(message: "\(flag) braucht einen Wert.") }
            return arguments[index]
        }
        var allow: [String] = []
        var clearAllow = false
        while index < arguments.count {
            let flag = arguments[index]
            switch flag {
            case "--name": options.draft.name = try value(flag)
            case "--prompt": options.draft.prompt = try value(flag)
            case "--prompt-file": options.promptFile = try value(flag)
            case "--dir": options.draft.directory = try value(flag)
            case "--account": options.draft.account = try value(flag)
            case "--schedule":
                switch ScheduledTaskSchedule.parse(try value(flag)) {
                case .success(let schedule): options.draft.schedule = schedule
                case .failure(let error): throw ParseError(message: error.message)
                }
            case "--access":
                let raw = try value(flag)
                switch raw {
                case "project": options.draft.access = .projectWrite
                case "read-only", "readonly": options.draft.access = .readOnly
                case "custom": options.draft.access = .custom
                default: throw ParseError(message: "--access: project, read-only oder custom, nicht „\(raw)“.")
                }
            case "--allow": allow.append(try value(flag))
            case "--clear-allow":
                guard !forAdd else { throw ParseError(message: "--clear-allow gibt es nur bei edit.") }
                clearAllow = true
            case "--catch-up": options.draft.catchUp = true
            case "--no-catch-up": options.draft.catchUp = false
            case "--paused":
                guard forAdd else { throw ParseError(message: "Zum Pausieren: whisperm8 schedule pause <aufgabe>.") }
                options.draft.paused = true
            default:
                throw ParseError(message: "Unbekannte Option „\(flag)“. Hilfe: whisperm8 schedule help")
            }
            index += 1
        }
        if options.draft.prompt != nil, options.promptFile != nil {
            throw ParseError(message: "Entweder --prompt oder --prompt-file, nicht beides.")
        }
        if clearAllow, !allow.isEmpty {
            throw ParseError(message: "--clear-allow und --allow schließen sich aus; --allow ersetzt die Liste ohnehin.")
        }
        if clearAllow { options.draft.extraTools = [] }
        if !allow.isEmpty { options.draft.extraTools = allow }
        return options
    }

    enum Resolution: Equatable {
        case found(ScheduledTask)
        case none
        case ambiguous([ScheduledTask])
    }

    /// Name (ohne Groß/klein), volle ID oder ID-Anfang ab 4 Zeichen.
    static func resolve(_ ref: String, in tasks: [ScheduledTask]) -> Resolution {
        let needle = ref.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return .none }
        if let task = tasks.first(where: { $0.id.uuidString.lowercased() == needle }) { return .found(task) }
        if let task = tasks.first(where: { $0.name.lowercased() == needle }) { return .found(task) }
        guard needle.count >= 4 else { return .none }
        let matches = tasks.filter { $0.id.uuidString.lowercased().hasPrefix(needle) }
        switch matches.count {
        case 0: return .none
        case 1: return .found(matches[0])
        default: return .ambiguous(matches)
        }
    }
}

// MARK: - Ausgabe

enum ScheduleCLIFormatter {
    struct Context {
        var store: ScheduledTaskStore
        var now: Date
        var calendar: Calendar
        var isProcessAlive: (Int32, Date?) -> Bool

        /// Arbeitet ein Lauf, zählt er (auch wenn danach Termine übersprungen
        /// wurden); sonst der jüngste Eintrag, auch „verpasst“.
        func latestRun(_ task: ScheduledTask) -> (files: ScheduledTaskRunFiles, outcome: ScheduledTaskRunOutcome)? {
            if let started = store.latestStartedRun(for: task.id) {
                let outcome = ScheduledTaskRunEvaluator.outcome(of: started, now: now, isProcessAlive: isProcessAlive)
                if outcome.isActive { return (started, outcome) }
            }
            guard let files = store.recentRuns(for: task.id, limit: 1).first else { return nil }
            return (files, ScheduledTaskRunEvaluator.outcome(of: files, now: now, isProcessAlive: isProcessAlive))
        }
    }

    static func dateText(_ date: Date, calendar: Calendar) -> String {
        ScheduledTaskCalendar.shortText(date, calendar: calendar)
    }

    static func homeAbbreviated(_ path: String) -> String {
        let home = AppInstance.home.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    static func nextText(_ task: ScheduledTask, context: Context) -> String {
        if task.paused { return "pausiert" }
        guard let next = ScheduledTaskCalendar.nextOccurrence(of: task.schedule, after: context.now, calendar: context.calendar) else {
            return "kein Termin"
        }
        return dateText(next, calendar: context.calendar)
    }

    static func runLine(_ files: ScheduledTaskRunFiles, outcome: ScheduledTaskRunOutcome, calendar: Calendar) -> String {
        let record = files.record
        var parts = [dateText(record.createdAt, calendar: calendar), outcome.label]
        switch record.trigger {
        case .catchUp: parts.append("nachgeholt")
        case .manual: parts.append("von Hand")
        case .schedule: break
        }
        if let exit = files.exit, let ended = exit.endedAt {
            let seconds = Int(ended.timeIntervalSince(record.processStartedAt ?? record.createdAt))
            if seconds >= 0 { parts.append(durationText(seconds)) }
        }
        return parts.joined(separator: " · ")
    }

    static func durationText(_ seconds: Int) -> String {
        seconds < 60 ? "\(seconds) Sek." : "\(seconds / 60) Min. \(String(format: "%02d", seconds % 60)) Sek."
    }

    static func list(_ tasks: [ScheduledTask], context: Context) -> String {
        guard !tasks.isEmpty else {
            return "Keine geplanten Aufgaben. Anlegen: whisperm8 schedule add (Hilfe: whisperm8 schedule help)"
        }
        return tasks.map { task in
            var lines = [
                "\(task.shortID)  \(task.name)",
                "          \(task.schedule.text) · Konto \(task.account) · \(homeAbbreviated(task.directory))",
                "          nächster Termin: \(nextText(task, context: context))",
            ]
            if let latest = context.latestRun(task) {
                lines.append("          letzter Lauf: " + runLine(latest.files, outcome: latest.outcome, calendar: context.calendar))
                if let detail = latest.outcome.detail { lines.append("          " + detail) }
            } else {
                lines.append("          noch kein Lauf")
            }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    static func detail(_ task: ScheduledTask, context: Context) -> String {
        var lines = [
            "\(task.name)  (\(task.id.uuidString.lowercased()))",
            "Zeitplan:        \(task.schedule.text)" + (task.paused ? " · pausiert" : ""),
            "Nächster Termin: \(nextText(task, context: context))",
            "Konto:           \(task.account)",
            "Ordner:          \(task.directory)",
            "Darf:            \(task.permissions.summary)",
            "Verpasst:        " + (task.catchUp ? "nachholen, bis 12 Std. später" : "nicht nachholen"),
            "Auftrag:         \(task.prompt)",
            "",
            "Läufe (neueste zuerst):",
        ]
        let runs = context.store.recentRuns(for: task.id, limit: 10)
        if runs.isEmpty { lines.append("  noch keiner") }
        for files in runs {
            let outcome = ScheduledTaskRunEvaluator.outcome(of: files, now: context.now, isProcessAlive: context.isProcessAlive)
            lines.append("  " + runLine(files, outcome: outcome, calendar: context.calendar))
            if let detail = outcome.detail { lines.append("    " + detail) }
            if let session = files.record.sessionID { lines.append("    Sitzung \(session.uuidString.lowercased())") }
            lines.append("    \(files.directory.path)")
        }
        return lines.joined(separator: "\n")
    }

    static func runDictionary(_ files: ScheduledTaskRunFiles, outcome: ScheduledTaskRunOutcome) -> [String: Any] {
        var dict: [String: Any] = [
            "runID": files.record.runID,
            "trigger": files.record.trigger.rawValue,
            "createdAt": ISO8601DateFormatter().string(from: files.record.createdAt),
            "outcome": outcome.label,
            "active": outcome.isActive,
            "failed": outcome.isFailure,
            "directory": files.directory.path,
        ]
        if let detail = outcome.detail { dict["detail"] = detail }
        if let session = files.record.sessionID { dict["sessionID"] = session.uuidString.lowercased() }
        if let code = files.exit?.code { dict["exitCode"] = Int(code) }
        return dict
    }

    static func taskDictionary(_ task: ScheduledTask, context: Context) -> [String: Any] {
        var dict: [String: Any] = [
            "id": task.id.uuidString.lowercased(),
            "name": task.name,
            "schedule": task.schedule.text,
            "account": task.account,
            "directory": task.directory,
            "paused": task.paused,
            "catchUp": task.catchUp,
            "allowedTools": task.permissions.allowedTools,
            "disallowedTools": task.permissions.disallowedTools,
            "next": nextText(task, context: context),
        ]
        if let latest = context.latestRun(task) {
            dict["lastRun"] = runDictionary(latest.files, outcome: latest.outcome)
        }
        return dict
    }

    static func listJSON(_ tasks: [ScheduledTask], context: Context) -> String {
        jsonString(["tasks": tasks.map { taskDictionary($0, context: context) }])
    }

    static func detailJSON(_ task: ScheduledTask, context: Context) -> String {
        var dict = taskDictionary(task, context: context)
        dict["prompt"] = task.prompt
        dict["runs"] = context.store.recentRuns(for: task.id, limit: 10).map { files in
            runDictionary(files, outcome: ScheduledTaskRunEvaluator.outcome(of: files, now: context.now, isProcessAlive: context.isProcessAlive))
        }
        return jsonString(dict)
    }

    static func jsonString(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func mutationMessage(method: String, task: ScheduledTask, result: ChatsControlJSON?) -> String {
        switch method {
        case "schedule.remove": return "Gelöscht: \(task.name). Die Chats ihrer Läufe bleiben."
        case "schedule.pause": return "Pausiert: \(task.name)."
        case "schedule.resume": return "Fortgesetzt: \(task.name). Vergangene Termine werden nicht nachgeholt."
        default:
            if result?["started"]?.boolValue == false {
                return "Nicht gestartet: \(result?["message"]?.stringValue ?? "unbekannter Grund")"
            }
            let session = result?["sessionID"]?.stringValue ?? "?"
            return "Gestartet: \(task.name), Sitzung \(session). Stand: whisperm8 schedule show \(task.shortID)"
        }
    }
}
