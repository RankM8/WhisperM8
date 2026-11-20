import Foundation

// MARK: - Geplante Aufgaben: Datenmodell (WM8-110, Paket 1)

/// Eine geplante Aufgabe: ein wiederkehrender `claude -p`-Lauf in festem
/// Projektordner und Konto. Steht in `scheduled-tasks.json`; geschrieben wird
/// nur von der App (`ScheduledTaskScheduler`), die CLI liest von Disk.
///
/// Felder nur ergänzen, nie umbenennen: Eine ältere App, die eine neuere Datei
/// nicht lesen kann, schreibt sie nicht (siehe `ScheduledTaskStore`).
struct ScheduledTask: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    /// Auftrag, wie er nach `claude -p` steht (Text oder `/skill …`).
    var prompt: String
    /// Absoluter Projektordner. Hier startet der Lauf, unter diesem Projekt
    /// steht sein Chat.
    var directory: String
    /// Claude-Konto (`main` oder Name eines Profils unter `~/.claude-profiles`).
    var account: String
    var schedule: ScheduledTaskSchedule
    var permissions: ScheduledTaskPermissions
    /// Verpasste Termine (Mac schlief, App war zu) bis 12 Stunden später nachholen.
    var catchUp: Bool
    var paused: Bool
    var createdAt: Date
    var updatedAt: Date
    /// Letzter abgearbeiteter Termin: gestartet, nachgeholt, verpasst oder
    /// übersprungen. Wird VOR dem Start geschrieben, damit kein Termin zweimal
    /// läuft (höchstens einmal, auch nach einem Absturz).
    var lastSlot: Date?
    /// Lauf-Ordner gehen nach so vielen Tagen ins Archiv
    /// (`scheduled-tasks/archive/`), 0 = nie (Paket 3). Die jüngsten drei
    /// bleiben immer, damit die Seitenleiste etwas zu zeigen hat.
    var runArchiveDays: Int

    static let defaultRunArchiveDays = 14
    /// Wahl im Blatt und in der CLI (`--archive-runs 14|7|never`).
    static let runArchiveDayChoices = [14, 7, 0]

    init(
        id: UUID = UUID(), name: String, prompt: String, directory: String, account: String,
        schedule: ScheduledTaskSchedule, permissions: ScheduledTaskPermissions = .init(),
        catchUp: Bool = true, paused: Bool = false, createdAt: Date, updatedAt: Date? = nil,
        lastSlot: Date? = nil, runArchiveDays: Int = ScheduledTask.defaultRunArchiveDays
    ) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.directory = directory
        self.account = account
        self.schedule = schedule
        self.permissions = permissions
        self.catchUp = catchUp
        self.paused = paused
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.lastSlot = lastSlot
        self.runArchiveDays = runArchiveDays
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        prompt = try c.decode(String.self, forKey: .prompt)
        directory = try c.decode(String.self, forKey: .directory)
        account = try c.decode(String.self, forKey: .account)
        schedule = try c.decode(ScheduledTaskSchedule.self, forKey: .schedule)
        permissions = try c.decodeIfPresent(ScheduledTaskPermissions.self, forKey: .permissions) ?? .init()
        catchUp = try c.decodeIfPresent(Bool.self, forKey: .catchUp) ?? true
        paused = try c.decodeIfPresent(Bool.self, forKey: .paused) ?? false
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        lastSlot = try c.decodeIfPresent(Date.self, forKey: .lastSlot)
        runArchiveDays = try c.decodeIfPresent(Int.self, forKey: .runArchiveDays) ?? Self.defaultRunArchiveDays
    }

    /// Kurze Kennung für CLI und Logs (erste acht Zeichen der ID).
    var shortID: String { String(id.uuidString.lowercased().prefix(8)) }
}

/// Inhalt von `scheduled-tasks.json`.
struct ScheduledTasksFile: Codable, Equatable {
    static let currentVersion = 1
    var version: Int = ScheduledTasksFile.currentVersion
    var tasks: [ScheduledTask] = []
}

// MARK: - Rechte eines Laufs

/// Was ein Lauf darf. Ein `-p`-Lauf kann nicht nachfragen; was nicht erlaubt
/// ist, verweigert Claude (`--permission-mode dontAsk`) und meldet es in
/// `permission_denials`.
///
/// Nur die Freigaben der Aufgabe (Entscheidung Giuliano 17.11.2026, Paket 4):
/// Freigaben aus den Einstellungen von Konto und Projekt gelten nicht
/// (`ScheduledTaskRunConfig`), `allowed-tools` und `hooks` im Kopf eines
/// Skills ebenso wenig. Ab Werk: lesen und im Projektordner schreiben. Bash,
/// MCP und Web nur per ausdrücklicher Freigabe je Aufgabe; jeder Lauf sperrt
/// diese Familien zusätzlich per `--disallowedTools`, solange `extraTools`
/// sie nicht nennt. Eine Sperre schlägt jede Freigabe.
struct ScheduledTaskPermissions: Codable, Equatable {
    enum Access: String, Codable, CaseIterable {
        /// Lesen und im Projektordner schreiben.
        case projectWrite
        /// Nur lesen.
        case readOnly
        /// Nur die Werkzeuge aus `extraTools`.
        case custom
    }

    var access: Access = .projectWrite
    /// Zusätzlich erlaubte Werkzeuge in Claudes Regel-Schreibweise, etwa
    /// `Bash(whisperm8 tickets *)` oder `mcp__linear__get_issue`.
    var extraTools: [String] = []

    init(access: Access = .projectWrite, extraTools: [String] = []) {
        self.access = access
        self.extraTools = extraTools
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        access = (try? c.decodeIfPresent(Access.self, forKey: .access)) ?? .projectWrite
        extraTools = try c.decodeIfPresent([String].self, forKey: .extraTools) ?? []
    }

    /// Lesen. `Skill`, damit ein Auftrag wie `/pm-analyse` seinen Skill laden kann.
    static let readOnlyTools = ["Read", "Glob", "Grep", "Skill"]
    /// `Edit(/**)` deckt Edit und Write im Projektordner: Eine Pfadregel mit
    /// einem führenden `/` hängt bei CLI-Optionen am Startordner der Sitzung
    /// (Claude-Code-Doku „permissions“, Abschnitt „Where a pattern anchors“).
    static let projectWriteTools = ["Read", "Glob", "Grep", "Edit(/**)", "Skill"]

    /// Die Liste für `--allowedTools`, ohne Doppelte, Reihenfolge stabil.
    var allowedTools: [String] {
        let base: [String]
        switch access {
        case .projectWrite: base = Self.projectWriteTools
        case .readOnly: base = Self.readOnlyTools
        case .custom: base = []
        }
        var seen = Set<String>()
        return (base + extraTools).compactMap { raw in
            let tool = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tool.isEmpty, seen.insert(tool).inserted else { return nil }
            return tool
        }
    }

    /// Werkzeug-Familien, die nur per `--allow` gehen (Befehle und Netz).
    /// `Monitor` führt ebenfalls Befehle aus; es öffnet mit Bash oder per
    /// eigenem `--allow Monitor`.
    static let gatedFamilies = ["Bash", "Monitor", "WebFetch", "WebSearch"]
    /// Dateien, die der nächste Lauf ausführen oder als Einstellung lesen
    /// würde (Hooks, `settings.local.json`, Git-Hooks, MCP-Server). Schriebe
    /// ein Lauf sie, liefe im nächsten unbeaufsichtigten Lauf beliebiger Code
    /// an der Bash-Sperre vorbei. Edit-Regeln gelten für alle Werkzeuge, die
    /// Dateien ändern (Edit, Write, NotebookEdit); führendes `/` = Projektordner.
    static let protectedPaths = ["Edit(/.claude/**)", "Edit(/.git/**)", "Edit(/.mcp.json)"]
    /// Einzelne Werkzeuge, die an der Bash-Sperre vorbei nach außen wirken
    /// (Probelauf 17.11.2026): Nachrichten an andere lokale Claude-Sitzungen,
    /// die Bash haben (`SendMessage`, `ListAgents`), Cloud-Routinen auf
    /// claude.ai (`RemoteTrigger`), Zeitpläne in Claude Code (`CronCreate`,
    /// `CronDelete`), Mitteilungen aufs Telefon (`PushNotification`), das
    /// Design-Werkzeug von claude.ai (`DesignSync`) und der Wechsel in einen
    /// anderen Arbeitsordner (`EnterWorktree`, `ExitWorktree`), der die
    /// Projekt-Anker der Schreibregeln verschöbe (Prüfung 17.11.2026).
    /// Gesperrt, solange `extraTools` sie nicht nennt. `Agent` und `Workflow`
    /// bleiben: Subagents erben die Sperren des Laufs.
    static let gatedTools = ["SendMessage", "ListAgents", "RemoteTrigger", "CronCreate", "CronDelete", "PushNotification",
                             "DesignSync", "EnterWorktree", "ExitWorktree"]
    /// Sperrt die Werkzeuge aller MCP-Server (Claude Code ab 2.1.3xx).
    static let allMCPTools = "mcp__*"
    /// Werkzeuge, die das Plugin `whisperm8` selbst anmeldet.
    static let ownMCPPrefix = "mcp__whisperm8__"

    /// Nennt `extraTools` ein MCP-Werkzeug oder einen MCP-Server?
    var allowsMCP: Bool {
        extraTools.contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("mcp__") }
    }

    /// Die Liste für `--disallowedTools`: jede gesperrte Familie, die
    /// `extraTools` nicht ausdrücklich freigibt (`Bash` oder `Bash(…)`).
    var disallowedTools: [String] {
        let extras = extraTools.map { $0.trimmingCharacters(in: .whitespaces) }
        func names(_ family: String) -> Bool {
            extras.contains { $0 == family || $0.hasPrefix(family + "(") }
        }
        var result = Self.gatedFamilies.filter { family in
            family == "Monitor" ? !(names("Monitor") || names("Bash")) : !names(family)
        }
        if !allowsMCP {
            result.append(Self.allMCPTools)
        } else if !extras.contains(where: { $0.hasPrefix(Self.ownMCPPrefix) }) {
            // Mit einer MCP-Freigabe fällt `mcp__*`; die Werkzeuge des eigenen
            // Plugins (Zwischenablage-Verlauf, Board) bleiben trotzdem zu.
            result.append(Self.ownMCPPrefix + "*")
        }
        // Immer, auch ohne Edit in der Liste: Eine eigene Liste oder ein
        // breites Edit(…) könnte sie öffnen, und eine Sperre schlägt jede
        // Freigabe.
        return result + Self.protectedPaths + Self.gatedTools.filter { !names($0) }
    }

    /// Oberste Ordner, die als Projektordner-Pfad unwahrscheinlich sind: Eine
    /// Regel wie `Read(/Users/…)` meint fast sicher den absoluten Pfad, Claude
    /// liest das führende `/` bei CLI-Freigaben aber als Projektordner. Nicht
    /// `tmp`, `var` oder `Library`: Die gibt es oft auch im Projekt.
    static let rootFolderNames: Set<String> = ["Users", "Volumes", "private"]
    /// Werkzeuge mit Pfad-Regeln.
    static let pathRuleTools = ["Read", "Edit", "Write", "Glob", "Grep", "NotebookEdit"]

    /// Eine Regel, die nie greift (gemessen mit Claude Code 2.1.329):
    /// `Write(…)` (Schreiben prüft Claude nur gegen Edit-Regeln) und
    /// `Read(/Users/…)` mit einem `/` (hängt am Projektordner).
    static func ruleProblem(in rules: [String]) -> ScheduledTaskValidationProblem? {
        for raw in rules {
            let rule = raw.trimmingCharacters(in: .whitespaces)
            guard let open = rule.firstIndex(of: "("), rule.hasSuffix(")") else { continue }
            let tool = String(rule[..<open])
            guard pathRuleTools.contains(tool) else { continue }
            let path = rule[rule.index(after: open)..<rule.index(before: rule.endIndex)]
            if path.hasPrefix("/"), !path.hasPrefix("//"),
               let first = path.dropFirst().split(separator: "/").first, rootFolderNames.contains(String(first)) {
                return .pathRuleAnchoredAtProject(rule)
            }
            if tool == "Write" { return .writeRuleNeverMatches(rule) }
        }
        return nil
    }

    /// Kurzbeschreibung für die CLI.
    var summary: String {
        let label: String
        switch access {
        case .projectWrite: label = "lesen, im Projektordner schreiben (nicht .claude, .git), ohne Bash, Web und MCP"
        case .readOnly: label = "nur lesen, ohne Bash, Web und MCP"
        case .custom: label = "eigene Liste"
        }
        guard !extraTools.isEmpty else { return label }
        return label + " + " + extraTools.joined(separator: ", ")
    }
}

// MARK: - Zeitplan

/// Uhrzeit `HH:MM`, als Text gespeichert.
struct ScheduledTaskClockTime: Codable, Equatable, Hashable, Comparable {
    var hour: Int
    var minute: Int

    init?(hour: Int, minute: Int) {
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        self.hour = hour
        self.minute = minute
    }

    /// Liest `7:00`, `07:00` und `0730` nicht (bewusst nur mit Doppelpunkt).
    init?(parsing raw: String) {
        let parts = raw.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, (1...2).contains(parts[0].count), parts[1].count == 2,
              let hour = Int(parts[0]), let minute = Int(parts[1]) else { return nil }
        self.init(hour: hour, minute: minute)
    }

    var text: String { String(format: "%02d:%02d", hour, minute) }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.hour, lhs.minute) < (rhs.hour, rhs.minute)
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let value = Self(parsing: raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Uhrzeit \(raw)"))
        }
        self = value
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(text)
    }
}

/// Zeitplan wie im Entwurf (Entscheidung Giuliano 17.11.2026): täglich,
/// werktags, wöchentlich an gewählten Tagen, stündlich zur Minute. Mehrere
/// Uhrzeiten je Aufgabe sind erlaubt (PM-Analyse: 07:00 und 22:30).
struct ScheduledTaskSchedule: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case daily, weekdays, weekly, hourly
    }

    var kind: Kind
    /// Uhrzeiten für täglich, werktags und wöchentlich (sortiert, ohne Doppelte).
    var times: [ScheduledTaskClockTime]
    /// Wochentage für wöchentlich, ISO: 1 = Montag … 7 = Sonntag.
    var days: [Int]
    /// Minute für stündlich.
    var minute: Int?

    init(kind: Kind, times: [ScheduledTaskClockTime] = [], days: [Int] = [], minute: Int? = nil) {
        self.kind = kind
        self.times = Array(Set(times)).sorted()
        self.days = Array(Set(days)).sorted()
        self.minute = minute
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            kind: try c.decode(Kind.self, forKey: .kind),
            times: try c.decodeIfPresent([ScheduledTaskClockTime].self, forKey: .times) ?? [],
            days: try c.decodeIfPresent([Int].self, forKey: .days) ?? [],
            minute: try c.decodeIfPresent(Int.self, forKey: .minute)
        )
    }

    /// Warum ein Zeitplan nie einen Termin ergäbe. Die CLI zeigt `cliText`,
    /// die Ansicht übersetzt den Fall (`ScheduledTaskTexts.problem`).
    enum Problem: Equatable {
        case missingTime
        case missingWeekday
        case invalidWeekday
        case invalidMinute

        var cliText: String {
            switch self {
            case .missingTime: return "Zeitplan braucht mindestens eine Uhrzeit."
            case .missingWeekday: return "Wöchentlich braucht mindestens einen Wochentag."
            case .invalidWeekday: return "Wochentage 1 (Mo) bis 7 (So)."
            case .invalidMinute: return "Stündlich braucht eine Minute 0 bis 59."
            }
        }
    }

    /// Fall, wenn der Zeitplan nie einen Termin ergäbe.
    var validationProblem: Problem? {
        switch kind {
        case .daily, .weekdays:
            return times.isEmpty ? .missingTime : nil
        case .weekly:
            if times.isEmpty { return .missingTime }
            if days.isEmpty { return .missingWeekday }
            if days.contains(where: { !(1...7).contains($0) }) { return .invalidWeekday }
            return nil
        case .hourly:
            guard let minute, (0...59).contains(minute) else { return .invalidMinute }
            return nil
        }
    }

    /// Fehlertext für die CLI.
    var validationError: String? { validationProblem?.cliText }

    // MARK: Text (CLI)

    static let dayAbbreviations = ["Mo", "Di", "Mi", "Do", "Fr", "Sa", "So"]

    /// „werktags 07:00, 22:30“, „wöchentlich Mo, Mi 08:00“, „stündlich :15“.
    /// Dieselbe Form liest `init(parsing:)` zurück.
    var text: String {
        let clock = times.map(\.text).joined(separator: ", ")
        switch kind {
        case .daily: return "täglich \(clock)"
        case .weekdays: return "werktags \(clock)"
        case .weekly:
            let names = days.compactMap { (1...7).contains($0) ? Self.dayAbbreviations[$0 - 1] : nil }
            return "wöchentlich \(names.joined(separator: ", ")) \(clock)"
        case .hourly: return String(format: "stündlich :%02d", minute ?? 0)
        }
    }

    enum ParseError: Error, Equatable {
        case invalid(String)

        var message: String {
            switch self { case .invalid(let text): return text }
        }
    }

    /// Liest die Zeitplan-Angabe der CLI, deutsch oder englisch:
    /// `täglich 07:00`, `daily 7:00,22:30`, `werktags 07:00`, `weekdays 07:00`,
    /// `wöchentlich mo,mi 08:00`, `weekly mon,wed 08:00`, `stündlich :15`,
    /// `hourly 15`.
    static func parse(_ raw: String) -> Result<ScheduledTaskSchedule, ParseError> {
        let tokens = raw.lowercased()
            .replacingOccurrences(of: ",", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard let head = tokens.first else {
            return .failure(.invalid("Zeitplan fehlt, etwa \"werktags 07:00\"."))
        }
        let rest = Array(tokens.dropFirst())
        let kind: Kind
        switch head {
        case "täglich", "taeglich", "daily": kind = .daily
        case "werktags", "weekdays": kind = .weekdays
        case "wöchentlich", "woechentlich", "weekly": kind = .weekly
        case "stündlich", "stuendlich", "hourly": kind = .hourly
        default:
            return .failure(.invalid("Unbekannte Art \"\(head)\": täglich, werktags, wöchentlich oder stündlich."))
        }

        if kind == .hourly {
            guard rest.count == 1 else { return .failure(.invalid("Stündlich braucht genau eine Minute, etwa \"stündlich :15\".")) }
            let digits = rest[0].hasPrefix(":") ? String(rest[0].dropFirst()) : rest[0]
            guard digits.count <= 2, let minute = Int(digits), (0...59).contains(minute) else {
                return .failure(.invalid("Minute \"\(rest[0])\" ist ungültig (0 bis 59)."))
            }
            return .success(ScheduledTaskSchedule(kind: .hourly, minute: minute))
        }

        var times: [ScheduledTaskClockTime] = []
        var days: [Int] = []
        for token in rest {
            if token.contains(":") {
                guard let time = ScheduledTaskClockTime(parsing: token) else {
                    return .failure(.invalid("Uhrzeit \"\(token)\" ist ungültig, erwartet etwa 07:00."))
                }
                times.append(time)
            } else if kind == .weekly, let day = dayNumber(token) {
                days.append(day)
            } else {
                return .failure(.invalid("\"\(token)\" verstehe ich nicht im Zeitplan."))
            }
        }
        let schedule = ScheduledTaskSchedule(kind: kind, times: times, days: days)
        if let error = schedule.validationError { return .failure(.invalid(error)) }
        return .success(schedule)
    }

    /// Wochentag aus deutschem oder englischem Namen (erste zwei Buchstaben).
    static func dayNumber(_ token: String) -> Int? {
        let key = String(token.prefix(2))
        switch key {
        case "mo": return 1
        case "di", "tu": return 2
        case "mi", "we": return 3
        case "do", "th": return 4
        case "fr": return 5
        case "sa": return 6
        case "so", "su": return 7
        default: return nil
        }
    }
}
