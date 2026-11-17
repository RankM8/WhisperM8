import Foundation

// MARK: - Zeitplan-Rechnung (rein, getestet)

/// Rechnet Termine eines Zeitplans und entscheidet, ob eine Aufgabe jetzt
/// laufen soll. Keine Uhr, kein I/O: `now` und `calendar` kommen von außen.
///
/// Regeln (Plan geplante-aufgaben.md, Paket 1):
/// - Ein Termin gilt als pünktlich bis `onTimeGrace` nach der Startzeit.
/// - Später, aber höchstens `catchUpWindow` danach, wird er nachgeholt, wenn die
///   Aufgabe Nachholen erlaubt. Sonst gilt er als verpasst.
/// - Mehrere verpasste Termine zählen als einer: Es zählt nur der jüngste.
/// - Termine vor dem Anlegen und vor `lastSlot` zählen nie.
enum ScheduledTaskCalendar {
    static let onTimeGrace: TimeInterval = 5 * 60
    static let catchUpWindow: TimeInterval = 12 * 3600

    enum Decision: Equatable {
        case paused
        /// Nichts fällig; `next` ist der nächste Termin.
        case wait(next: Date?)
        /// Jetzt starten. `catchUp` = verspätet nachgeholt.
        case run(slot: Date, catchUp: Bool)
        /// Zu spät zum Nachholen: als verpasst eintragen, nicht starten.
        case missed(slot: Date)
    }

    static func decide(_ task: ScheduledTask, now: Date, calendar: Calendar) -> Decision {
        if task.paused { return .paused }
        let reference = max(task.lastSlot ?? task.createdAt, task.createdAt)
        guard let latest = latestOccurrence(of: task.schedule, atOrBefore: now, calendar: calendar),
              latest > reference else {
            return .wait(next: nextOccurrence(of: task.schedule, after: now, calendar: calendar))
        }
        let lateness = now.timeIntervalSince(latest)
        if lateness <= onTimeGrace { return .run(slot: latest, catchUp: false) }
        if task.catchUp, lateness <= catchUpWindow { return .run(slot: latest, catchUp: true) }
        return .missed(slot: latest)
    }

    /// Frühester nächster Termin über alle aktiven Aufgaben (für den Zeitgeber).
    static func nextWake(for tasks: [ScheduledTask], after now: Date, calendar: Calendar) -> Date? {
        tasks.filter { !$0.paused }
            .compactMap { nextOccurrence(of: $0.schedule, after: now, calendar: calendar) }
            .min()
    }

    /// `lastSlot` nach Fortsetzen oder geändertem Zeitplan: Was vorher fällig
    /// war, holt die Aufgabe nicht nach (sonst liefe sie sofort los).
    static func slotMarker(for task: ScheduledTask, now: Date, calendar: Calendar) -> Date? {
        let latest = latestOccurrence(of: task.schedule, atOrBefore: now, calendar: calendar)
        switch (task.lastSlot, latest) {
        case let (old?, new?): return max(old, new)
        case let (old, new): return old ?? new
        }
    }

    // MARK: Termine

    /// Erster Termin echt nach `date`.
    static func nextOccurrence(of schedule: ScheduledTaskSchedule, after date: Date, calendar: Calendar) -> Date? {
        guard schedule.validationError == nil else { return nil }
        if schedule.kind == .hourly {
            guard let candidate = hourlyCandidate(schedule, near: date, calendar: calendar) else { return nil }
            return candidate > date ? candidate : calendar.date(byAdding: .hour, value: 1, to: candidate)
        }
        let start = calendar.startOfDay(for: date)
        for offset in 0...8 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: start) else { continue }
            if let hit = occurrences(of: schedule, onDay: day, calendar: calendar).first(where: { $0 > date }) {
                return hit
            }
        }
        return nil
    }

    /// Letzter Termin am oder vor `date`.
    static func latestOccurrence(of schedule: ScheduledTaskSchedule, atOrBefore date: Date, calendar: Calendar) -> Date? {
        guard schedule.validationError == nil else { return nil }
        if schedule.kind == .hourly {
            guard let candidate = hourlyCandidate(schedule, near: date, calendar: calendar) else { return nil }
            return candidate <= date ? candidate : calendar.date(byAdding: .hour, value: -1, to: candidate)
        }
        let start = calendar.startOfDay(for: date)
        for offset in 0...8 {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: start) else { continue }
            if let hit = occurrences(of: schedule, onDay: day, calendar: calendar).last(where: { $0 <= date }) {
                return hit
            }
        }
        return nil
    }

    /// Termine an einem Kalendertag, aufsteigend. Eine Uhrzeit, die es wegen
    /// der Sommerzeit nicht gibt, rutscht auf die nächste gültige.
    static func occurrences(of schedule: ScheduledTaskSchedule, onDay day: Date, calendar: Calendar) -> [Date] {
        let iso = isoWeekday(of: day, calendar: calendar)
        switch schedule.kind {
        case .daily: break
        case .weekdays: guard iso <= 5 else { return [] }
        case .weekly: guard schedule.days.contains(iso) else { return [] }
        case .hourly: return []
        }
        return schedule.times.compactMap { time in
            calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: day,
                          matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward)
        }.sorted()
    }

    /// „Mi 18.11., 07:00“ für CLI und Lauf-Meldungen. Den Wochentag nehmen wir
    /// aus der eigenen Liste: ICU schreibt im Deutschen „Mi.“ mit Punkt.
    static func shortText(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "dd.MM., HH:mm"
        let day = ScheduledTaskSchedule.dayAbbreviations[isoWeekday(of: date, calendar: calendar) - 1]
        return "\(day) \(formatter.string(from: date))"
    }

    /// 1 = Montag … 7 = Sonntag, unabhängig vom ersten Wochentag des Kalenders.
    static func isoWeekday(of date: Date, calendar: Calendar) -> Int {
        let weekday = calendar.component(.weekday, from: date) // 1 = Sonntag
        return ((weekday + 5) % 7) + 1
    }

    private static func hourlyCandidate(_ schedule: ScheduledTaskSchedule, near date: Date, calendar: Calendar) -> Date? {
        guard let minute = schedule.minute,
              let hour = calendar.dateInterval(of: .hour, for: date)?.start else { return nil }
        return hour.addingTimeInterval(TimeInterval(minute * 60))
    }
}
