import Foundation

/// Texte der Ansicht „Geplant“ (WM8-110, Paket 2). Englisch im Code, Deutsch im
/// Katalog. Zeiten stehen fest da („morgen 07:00“), nie mitlaufend („in 3 Std“):
/// Sie ändern sich nur, wenn die Übersicht neu lädt (Plan, Teil 2).
enum ScheduledTaskTexts {
    struct Clock {
        var now: Date
        var calendar: Calendar
        var locale: Locale

        static var current: Clock { Clock(now: Date(), calendar: .current, locale: .current) }

        func formatter(_ template: String) -> DateFormatter {
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.setLocalizedDateFormatFromTemplate(template)
            return formatter
        }

        func time(_ date: Date) -> String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = calendar.timeZone
            formatter.dateFormat = "HH:mm"
            return formatter.string(from: date)
        }

        /// 0 = heute, 1 = morgen, -1 = gestern.
        func dayOffset(_ date: Date) -> Int {
            let from = calendar.startOfDay(for: now)
            let to = calendar.startOfDay(for: date)
            return calendar.dateComponents([.day], from: from, to: to).day ?? 0
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

    static func duration(_ seconds: Int) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : (seconds >= 60 ? [.minute, .second] : [.second])
        formatter.unitsStyle = .abbreviated
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
}
