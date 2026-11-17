import Foundation

/// Texte der Ansicht „Geplant“ (WM8-110, Paket 2). Englisch im Code, Deutsch im
/// Katalog. Zeiten stehen fest da („morgen 07:00“), nie mitlaufend („in 3 Std“):
/// Sie ändern sich nur, wenn die Übersicht neu lädt (Plan, Teil 2).
enum ScheduledTaskTexts {
    /// Sprache der Datumsangaben: die der App-Texte (englisch oder deutsch),
    /// Region und Formate aus dem System (Prüfung WM8-110, K5). Mit
    /// `Locale.current` stünde in einer englischen App auf einem deutsch
    /// eingestellten Mac „Mo., 16. Nov.“ neben „tomorrow“.
    static let appLocale: Locale = {
        let language = Bundle.main.preferredLocalizations.first ?? "en"
        var components = Locale.Components(locale: .current)
        components.languageComponents = Locale.Language.Components(identifier: language)
        return Locale(components: components)
    }()

    struct Clock {
        var now: Date
        var calendar: Calendar
        var locale: Locale

        init(now: Date, calendar: Calendar = .current, locale: Locale = ScheduledTaskTexts.appLocale) {
            self.now = now
            self.calendar = calendar
            self.locale = locale
        }

        static var current: Clock { Clock(now: Date()) }

        /// Formatierer je Vorlage, Sprache und Zeitzone, einmal gebaut
        /// (Prüfung WM8-110, K6a): Ein `DateFormatter` kostet beim Anlegen
        /// mehr als hundert Formatierungen, und die Seitenleiste formatiert je
        /// Aufgabe und Lauf.
        func formatter(_ template: String) -> DateFormatter {
            FormatterCache.shared.formatter(template: template, locale: locale, calendar: calendar)
        }

        func time(_ date: Date) -> String {
            FormatterCache.shared.formatter(fixedFormat: "HH:mm", calendar: calendar).string(from: date)
        }

        /// 0 = heute, 1 = morgen, -1 = gestern.
        func dayOffset(_ date: Date) -> Int {
            let from = calendar.startOfDay(for: now)
            let to = calendar.startOfDay(for: date)
            return calendar.dateComponents([.day], from: from, to: to).day ?? 0
        }
    }

    /// Gemeinsamer Speicher der Formatierer. `DateFormatter` ist ab macOS 10.9
    /// zum Formatieren threadsicher; das Wörterbuch schützt ein Lock.
    final class FormatterCache: @unchecked Sendable {
        static let shared = FormatterCache()

        private let lock = NSLock()
        private var formatters: [String: DateFormatter] = [:]
        private var durationFormatters: [String: DateComponentsFormatter] = [:]

        func formatter(template: String, locale: Locale, calendar: Calendar) -> DateFormatter {
            let key = "t|\(template)|\(locale.identifier)|\(calendar.identifier)|\(calendar.timeZone.identifier)"
            return cached(key) {
                let formatter = DateFormatter()
                formatter.locale = locale
                formatter.calendar = calendar
                formatter.timeZone = calendar.timeZone
                formatter.setLocalizedDateFormatFromTemplate(template)
                return formatter
            }
        }

        func formatter(fixedFormat: String, calendar: Calendar) -> DateFormatter {
            let key = "f|\(fixedFormat)|\(calendar.timeZone.identifier)"
            return cached(key) {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = calendar.timeZone
                formatter.dateFormat = fixedFormat
                return formatter
            }
        }

        func durationFormatter(units: NSCalendar.Unit, locale: Locale) -> DateComponentsFormatter {
            let key = "\(units.rawValue)|\(locale.identifier)"
            lock.lock()
            defer { lock.unlock() }
            if let formatter = durationFormatters[key] { return formatter }
            let formatter = DateComponentsFormatter()
            var calendar = Calendar.current
            calendar.locale = locale
            formatter.calendar = calendar
            formatter.allowedUnits = units
            formatter.unitsStyle = .abbreviated
            durationFormatters[key] = formatter
            return formatter
        }

        private func cached(_ key: String, make: () -> DateFormatter) -> DateFormatter {
            lock.lock()
            defer { lock.unlock() }
            if let formatter = formatters[key] { return formatter }
            let formatter = make()
            formatters[key] = formatter
            return formatter
        }
    }

    // MARK: Zeiten

    /// Rechts in der Seitenleiste: „07:00“, „tomorrow 07:00“, „Mon 17:30“, „22 Nov“.
    static func nextShort(_ date: Date, clock: Clock) -> String {
        let time = clock.time(date)
        switch clock.dayOffset(date) {
        case 0: return time
        case 1: return String(localized: "tomorrow \(time)")
        case 2...6: return clock.formatter("EEE").string(from: date) + " " + time
        default: return clock.formatter("dMMM").string(from: date)
        }
    }

    /// Detail: „today, 07:00“, „tomorrow, 07:00“, sonst „Mon, 16 Nov, 17:30“.
    static func dateTime(_ date: Date, clock: Clock) -> String {
        let time = clock.time(date)
        switch clock.dayOffset(date) {
        case 0: return String(localized: "today, \(time)")
        case 1: return String(localized: "tomorrow, \(time)")
        case -1: return String(localized: "yesterday, \(time)")
        default: return clock.formatter("EEEdMMM").string(from: date) + ", " + time
        }
    }

    /// Lauf unter seiner Aufgabe: „today 07:00“, „yesterday 22:30“, „15 Nov, 07:00“.
    static func runShort(_ date: Date, clock: Clock) -> String {
        let time = clock.time(date)
        switch clock.dayOffset(date) {
        case 0: return String(localized: "today \(time)")
        case -1: return String(localized: "yesterday \(time)")
        default: return clock.formatter("dMMM").string(from: date) + ", " + time
        }
    }

    static func duration(_ seconds: Int, locale: Locale = appLocale) -> String {
        let units: NSCalendar.Unit = seconds >= 3600 ? [.hour, .minute] : (seconds >= 60 ? [.minute, .second] : [.second])
        let formatter = FormatterCache.shared.durationFormatter(units: units, locale: locale)
        return formatter.string(from: TimeInterval(seconds)) ?? "\(seconds) s"
    }

    // MARK: Zeitplan

    static func dayName(_ isoDay: Int, clock: Clock) -> String {
        // 2026-11-16 ist ein Montag; Tag 1…7 = Mo…So.
        var components = DateComponents()
        components.year = 2026
        components.month = 11
        components.day = 15 + isoDay
        components.hour = 12
        guard let date = clock.calendar.date(from: components) else { return "\(isoDay)" }
        return clock.formatter("EEE").string(from: date)
    }

    /// „Daily 07:00“, „Weekdays 07:00, 22:30“, „Weekly Mon, Wed 08:00“, „Hourly at :15“.
    static func schedule(_ schedule: ScheduledTaskSchedule, clock: Clock) -> String {
        let times = schedule.times.map(\.text).joined(separator: ", ")
        switch schedule.kind {
        case .daily: return String(localized: "Daily \(times)")
        case .weekdays: return String(localized: "Weekdays \(times)")
        case .weekly:
            let days = schedule.days.map { dayName($0, clock: clock) }.joined(separator: ", ")
            return String(localized: "Weekly \(days) \(times)")
        case .hourly: return String(localized: "Hourly at :\(String(format: "%02d", schedule.minute ?? 0))")
        }
    }

    // MARK: Rechte

    /// Was der Lauf darf, ehrlich wie die CLI-Hilfe: Lesen gilt für die ganze
    /// Platte, und eine Familie, die per Freigabe offen ist, steht nicht als
    /// gesperrt da.
    static func permissions(_ permissions: ScheduledTaskPermissions) -> String {
        var parts: [String] = []
        switch permissions.access {
        case .projectWrite:
            parts.append(String(localized: "Read (whole disk) and write in the project folder, never in .claude, .git or .mcp.json"))
        case .readOnly:
            parts.append(String(localized: "Read only (whole disk)"))
        case .custom:
            parts.append(String(localized: "Only the listed tools"))
        }
        if !permissions.extraTools.isEmpty {
            parts.append(String(localized: "also \(permissions.extraTools.joined(separator: ", "))"))
        }
        let blocked = blockedFamilies(permissions)
        if !blocked.isEmpty {
            parts.append(String(localized: "no \(blocked.joined(separator: ", "))"))
        }
        return parts.joined(separator: " · ")
    }

    /// Gesperrte Familien in Klartext: „Bash“, „web“, „MCP“.
    static func blockedFamilies(_ permissions: ScheduledTaskPermissions) -> [String] {
        let disallowed = Set(permissions.disallowedTools)
        var result: [String] = []
        if disallowed.contains("Bash") { result.append("Bash") }
        if disallowed.contains("WebFetch") || disallowed.contains("WebSearch") { result.append(String(localized: "web")) }
        if disallowed.contains(ScheduledTaskPermissions.allMCPTools) { result.append("MCP") }
        return result
    }

    // MARK: Ergebnis

    /// Kurz, für die Zeile unter der Aufgabe: „succeeded“, „failed“, „working“ …
    static func outcomeShort(_ outcome: ScheduledTaskRunOutcome) -> String {
        switch outcome {
        case .starting: return String(localized: "starting")
        case .running: return String(localized: "working")
        case .succeeded: return String(localized: "succeeded")
        case .succeededWithNotes: return String(localized: "with notes")
        case .failed: return String(localized: "failed")
        case .aborted: return String(localized: "aborted")
        case .notStarted(let reason, _):
            switch reason {
            case .missed: return String(localized: "missed")
            case .stillRunning: return String(localized: "skipped")
            default: return String(localized: "not started")
            }
        }
    }

    /// Erste Zeile im Detail: „Succeeded“, „Not started: login expired“ …
    static func outcomeTitle(_ outcome: ScheduledTaskRunOutcome) -> String {
        switch outcome {
        case .starting: return String(localized: "Starting")
        case .running: return String(localized: "Working")
        case .succeeded: return String(localized: "Succeeded")
        case .succeededWithNotes(_, let tools):
            return String(localized: "Succeeded with notes (\(tools.count) tools denied)")
        case .failed: return String(localized: "Failed")
        case .aborted: return String(localized: "Aborted")
        case .notStarted(let reason, _):
            switch reason {
            case .missed: return String(localized: "Missed")
            case .stillRunning: return String(localized: "Skipped, the previous run was still working")
            case .loginExpired: return String(localized: "Not started: login expired")
            case .accountMissing: return String(localized: "Not started: account missing")
            case .folderMissing: return String(localized: "Not started: folder missing")
            case .claudeMissing: return String(localized: "Not started: Claude Code not found")
            case .launchFailed: return String(localized: "Not started")
            }
        }
    }

    /// Zweite Zeile: letzter Satz, Fehlermeldung oder verweigerte Werkzeuge.
    /// Meldungen aus dem Lauf selbst bleiben in seiner Sprache.
    static func outcomeDetail(_ outcome: ScheduledTaskRunOutcome) -> String? {
        switch outcome {
        case .succeeded(let summary): return summary
        case .succeededWithNotes(let summary, let tools):
            let denied = String(localized: "Denied: \(tools.joined(separator: ", "))")
            return [denied, summary].compactMap { $0 }.joined(separator: " · ")
        case .failed(let message): return message
        case .aborted: return String(localized: "The process ended without a result (Mac restarted or the run was quit).")
        case .notStarted(let reason, let message):
            switch reason {
            case .missed: return String(localized: "Too long ago to catch up, or catching up is off.")
            case .stillRunning: return nil
            case .loginExpired: return String(localized: "Renew the login under Settings › Accounts. There is no chat for this run.")
            case .accountMissing: return String(localized: "The Claude account no longer exists. There is no chat for this run.")
            case .folderMissing: return String(localized: "The project folder no longer exists. There is no chat for this run.")
            case .claudeMissing: return String(localized: "Claude Code is not installed or not in the PATH.")
            case .launchFailed: return message
            }
        case .starting, .running: return nil
        }
    }

    /// Text im Fehler-Kasten unter „Failed · Datum“: die Meldung selbst, bei
    /// „nicht gestartet“ zuerst der Grund.
    static func failureText(_ outcome: ScheduledTaskRunOutcome) -> String {
        let detail = outcomeDetail(outcome)
        switch outcome {
        case .notStarted:
            return [outcomeTitle(outcome), detail].compactMap { $0 }.joined(separator: ". ")
        default:
            return detail ?? outcomeTitle(outcome)
        }
    }

    static func trigger(_ trigger: ScheduledTaskRunRecord.Trigger) -> String? {
        switch trigger {
        case .schedule: return nil
        case .catchUp: return String(localized: "caught up")
        case .manual: return String(localized: "started by hand")
        }
    }

    /// „succeeded · caught up · 2m 51s“ unter dem Datum eines Laufs im Detail.
    static func runLine(_ run: ScheduledTaskRunSummary) -> String {
        var parts = [outcomeShort(run.outcome)]
        if let trigger = trigger(run.trigger) { parts.append(trigger) }
        if let seconds = run.durationSeconds { parts.append(duration(seconds)) }
        return parts.joined(separator: " · ")
    }

    // MARK: Zustand der Aufgabe

    /// Rechts in der Seitenleiste.
    static func sidebarTrailing(_ overview: ScheduledTaskOverview, clock: Clock) -> String {
        switch overview.state {
        case .running: return String(localized: "running")
        case .failed: return String(localized: "error")
        case .paused: return String(localized: "paused")
        case .scheduled, .succeeded, .succeededWithNotes:
            guard let next = overview.next else { return String(localized: "no date") }
            return nextShort(next, clock: clock)
        }
    }

    // MARK: Login vor dem nächsten Lauf (Paket 3)

    /// „Login of PowerUser ends today, before the next run.“
    static func loginWarningTitle(_ warning: ScheduledTaskLoginWarning, account: String, clock: Clock) -> String {
        if warning.hasEnded { return String(localized: "Login of \(account) has ended.") }
        let ends: String
        switch clock.dayOffset(warning.endsAt) {
        case 0: ends = String(localized: "today, \(clock.time(warning.endsAt))")
        case 1: ends = String(localized: "tomorrow, \(clock.time(warning.endsAt))")
        default: ends = clock.formatter("EEEdMMM").string(from: warning.endsAt)
        }
        return String(localized: "Login of \(account) ends \(ends), before the next run.")
    }

    static func loginWarningDetail(next: Date, clock: Clock) -> String {
        String(localized: "Without a new login, the next run (\(dateTime(next, clock: clock))) does not start and reports a failure.")
    }

    // MARK: Meldungen des Planers (Prüfung WM8-110, K4)

    static func problem(_ problem: ScheduledTaskValidationProblem) -> String {
        switch problem {
        case .fieldsMissing:
            return String(localized: "Name, prompt, folder, account and schedule are required.")
        case .nameMissing: return String(localized: "The name is missing.")
        case .nameTooLong(let max): return String(localized: "The name is longer than \(max) characters.")
        case .nameMultiline: return String(localized: "The name must be a single line.")
        case .nameTaken(let name): return String(localized: "There is already a task called “\(name)”.")
        case .promptMissing: return String(localized: "The prompt is missing.")
        case .promptStartsWithDash:
            return String(localized: "The prompt must not start with “-” (Claude would read it as an option).")
        case .directoryNotAbsolute: return String(localized: "The folder must be an absolute path.")
        case .directoryMissing(let path): return String(localized: "The folder does not exist: \(path)")
        case .accountMissing(let account): return String(localized: "The Claude account “\(account)” does not exist.")
        case .schedule(let problem): return scheduleProblem(problem)
        case .toolEmptyOrMultiline: return String(localized: "An allowed tool is empty or spans several lines.")
        case .toolStartsWithDash:
            return String(localized: "A tool must not start with “-” (Claude would read it as an option).")
        case .customListEmpty: return String(localized: "A custom list needs at least one tool.")
        }
    }

    static func scheduleProblem(_ problem: ScheduledTaskSchedule.Problem) -> String {
        switch problem {
        case .missingTime: return String(localized: "Enter at least one time, like 07:00.")
        case .missingWeekday: return String(localized: "Pick at least one weekday.")
        case .invalidWeekday: return String(localized: "Weekdays run from 1 (Monday) to 7 (Sunday).")
        case .invalidMinute: return String(localized: "The minute must be 0 to 59.")
        }
    }

    static func schedulerError(_ error: ScheduledTaskScheduler.SchedulerError) -> String {
        switch error {
        case .disabled:
            return String(localized: "Scheduled tasks are off. Turn them on under Settings › Labs › Scheduled tasks.")
        case .notLeader:
            return String(localized: "Another WhisperM8 instance is planning the tasks right now; this one changes nothing.")
        case .notFound:
            return String(localized: "This scheduled task no longer exists.")
        case .invalid(let problem): return self.problem(problem)
        case .conflict(let name):
            return String(localized: "A run of “\(name)” is still working. Two runs of the same task never run at once.")
        case .storage(.runFolder):
            return String(localized: "The folder for the run could not be created.")
        case .storage(.store(let error)): return storeError(error)
        case .storage(.other(let message)): return message
        }
    }

    static func storeError(_ error: ScheduledTaskStore.StoreError) -> String {
        switch error {
        case .unreadable(let detail):
            return String(localized: "scheduled-tasks.json can’t be read (\(detail)). WhisperM8 leaves it unchanged.")
        case .writeFailed(let detail):
            return String(localized: "scheduled-tasks.json could not be saved: \(detail)")
        }
    }

    /// Beliebiger Fehler aus einer Aktion der Ansicht.
    static func error(_ error: Error) -> String {
        if let error = error as? ScheduledTaskScheduler.SchedulerError { return schedulerError(error) }
        if let error = error as? ScheduledTaskStore.StoreError { return storeError(error) }
        return error.localizedDescription
    }
}
