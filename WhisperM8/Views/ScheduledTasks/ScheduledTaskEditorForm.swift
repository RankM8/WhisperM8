import Foundation

/// Was das Blatt anlegen oder ändern soll.
struct ScheduledTaskEditorTarget: Identifiable {
    let id = UUID()
    /// `nil` = neue Aufgabe.
    var task: ScheduledTask?
}

/// Projektordner zur Auswahl im Blatt (aus den Projekten der Seitenleiste).
struct ScheduledTaskEditorProject: Hashable, Identifiable {
    var name: String
    var path: String
    var id: String { path }
}

/// Felder des Blatts, rein und getestet (`ScheduledTaskEditorFormTests`).
/// Dieselben Felder und Prüfungen wie `whisperm8 schedule add|edit`
/// (`ScheduledTaskValidation`), nur mit übersetzten Meldungen; was das Blatt
/// nicht vorab sieht, prüft der Planer beim Speichern noch einmal.
struct ScheduledTaskEditorForm: Equatable {
    var name = ""
    var prompt = ""
    var directory = ""
    var account = ClaudeAccountProfiles.mainProfileName
    var kind: ScheduledTaskSchedule.Kind = .weekdays
    var timesText = "07:00"
    var days: Set<Int> = [1]
    var minuteText = "0"
    var access: ScheduledTaskPermissions.Access = .projectWrite
    var extraToolsText = ""
    var catchUp = true

    init() {}

    init(task: ScheduledTask) {
        name = task.name
        prompt = task.prompt
        directory = task.directory
        account = task.account
        kind = task.schedule.kind
        timesText = task.schedule.times.map(\.text).joined(separator: ", ")
        if timesText.isEmpty { timesText = "07:00" }
        days = Set(task.schedule.days)
        if days.isEmpty { days = [1] }
        minuteText = String(task.schedule.minute ?? 0)
        access = task.permissions.access
        extraToolsText = task.permissions.extraTools.joined(separator: ", ")
        catchUp = task.catchUp
    }

    // MARK: Lesen

    /// Werkzeuge, getrennt durch Komma oder Zeilenumbruch; Kommas in Klammern
    /// gehören zur Regel (`Bash(git log, status)`).
    var extraTools: [String] {
        var result: [String] = []
        var current = ""
        var depth = 0
        for character in extraToolsText {
            switch character {
            case "(": depth += 1; current.append(character)
            case ")": depth = max(0, depth - 1); current.append(character)
            case ",", "\n":
                if depth > 0 {
                    current.append(character)
                } else {
                    result.append(current)
                    current = ""
                }
            default: current.append(character)
            }
        }
        result.append(current)
        return result.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    var permissions: ScheduledTaskPermissions {
        ScheduledTaskPermissions(access: access, extraTools: extraTools)
    }

    /// Zeitplan aus den Feldern oder eine übersetzte Meldung.
    func schedule() -> Result<ScheduledTaskSchedule, ScheduledTaskSaveError> {
        if kind == .hourly {
            let digits = minuteText.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            guard digits.count <= 2, let minute = Int(digits), (0...59).contains(minute) else {
                return .failure(.init(message: String(localized: "The minute must be 0 to 59.")))
            }
            return .success(ScheduledTaskSchedule(kind: .hourly, minute: minute))
        }
        let tokens = timesText.replacingOccurrences(of: ",", with: " ")
            .split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !tokens.isEmpty else {
            return .failure(.init(message: String(localized: "Enter at least one time, like 07:00.")))
        }
        var times: [ScheduledTaskClockTime] = []
        for token in tokens {
            guard let time = ScheduledTaskClockTime(parsing: token) else {
                return .failure(.init(message: String(localized: "“\(token)” is not a time. Write it like 07:00.")))
            }
            times.append(time)
        }
        if kind == .weekly, days.isEmpty {
            return .failure(.init(message: String(localized: "Pick at least one weekday.")))
        }
        return .success(ScheduledTaskSchedule(kind: kind, times: times, days: kind == .weekly ? Array(days) : []))
    }

    // MARK: Prüfen

    /// Erster Fehler in Klartext oder `nil`; dieselben Regeln wie die CLI.
    func problem(others: [ScheduledTask], accounts: [String]?, directoryExists: (String) -> Bool) -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return String(localized: "The name is missing.") }
        if name.count > ScheduledTaskValidation.maxNameLength {
            return String(localized: "The name is longer than \(ScheduledTaskValidation.maxNameLength) characters.")
        }
        if name.contains(where: \.isNewline) { return String(localized: "The name must be a single line.") }
        if others.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return String(localized: "There is already a task called “\(name)”.")
        }
        if prompt.isEmpty { return String(localized: "The prompt is missing.") }
        if prompt.hasPrefix("-") {
            return String(localized: "The prompt must not start with “-” (Claude would read it as an option).")
        }
        if directory.isEmpty { return String(localized: "Choose a project folder.") }
        let normalized = ScheduledTaskValidation.normalizedDirectory(directory)
        if !directoryExists(normalized) { return String(localized: "The folder does not exist: \(normalized)") }
        if let accounts, !accounts.contains(account) {
            return String(localized: "The Claude account “\(account)” does not exist.")
        }
        if case .failure(let error) = schedule() { return error.message }
        let tools = extraTools
        if tools.contains(where: { $0.hasPrefix("-") }) {
            return String(localized: "A tool must not start with “-” (Claude would read it as an option).")
        }
        if access == .custom, tools.isEmpty {
            return String(localized: "A custom list needs at least one tool.")
        }
        return nil
    }

    /// Entwurf für den Planer; bei `original` nur die geänderten Felder, damit
    /// ein unveränderter Zeitplan seinen Stand (`lastSlot`) behält.
    func draft(original: ScheduledTask?) -> Result<ScheduledTaskDraft, ScheduledTaskSaveError> {
        let schedule: ScheduledTaskSchedule
        switch self.schedule() {
        case .success(let value): schedule = value
        case .failure(let error): return .failure(error)
        }
        var draft = ScheduledTaskDraft()
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let directory = ScheduledTaskValidation.normalizedDirectory(directory)
        let tools = extraTools
        if original?.name != name { draft.name = name }
        if original?.prompt != prompt { draft.prompt = prompt }
        if original?.directory != directory { draft.directory = directory }
        if original?.account != account { draft.account = account }
        if original?.schedule != schedule { draft.schedule = schedule }
        if original?.permissions.access != access { draft.access = access }
        if original?.permissions.extraTools != tools { draft.extraTools = tools }
        if original?.catchUp != catchUp { draft.catchUp = catchUp }
        return .success(draft)
    }
}
