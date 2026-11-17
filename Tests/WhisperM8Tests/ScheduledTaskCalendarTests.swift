import XCTest
@testable import WhisperM8

/// WM8-110 Paket 1: Zeitplan-Rechnung (nächster Termin, fällig, nachholen, verpasst).
final class ScheduledTaskCalendarTests: XCTestCase {
    static let berlin = TimeZone(identifier: "Europe/Berlin")!

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = berlin
        calendar.firstWeekday = 1
        return calendar
    }

    /// „2026-11-17 07:00“ in Berlin (17.11.2026 ist ein Dienstag).
    static func date(_ text: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = berlin
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: text)!
    }

    private func date(_ text: String) -> Date { Self.date(text) }
    private var calendar: Calendar { Self.calendar }

    private func schedule(_ text: String) -> ScheduledTaskSchedule {
        guard case .success(let schedule) = ScheduledTaskSchedule.parse(text) else {
            XCTFail("Zeitplan \(text) nicht lesbar")
            return ScheduledTaskSchedule(kind: .daily)
        }
        return schedule
    }

    private func task(_ scheduleText: String, created: String, lastSlot: String? = nil,
                      catchUp: Bool = true, paused: Bool = false) -> ScheduledTask {
        ScheduledTask(name: "Probe", prompt: "Hallo", directory: "/tmp", account: "main",
                      schedule: schedule(scheduleText), catchUp: catchUp, paused: paused,
                      createdAt: date(created), lastSlot: lastSlot.map(date))
    }

    // MARK: Termine

    func testDailyNextAndLatest() {
        let s = schedule("täglich 07:00")
        let now = date("2026-11-17 06:00")
        XCTAssertEqual(ScheduledTaskCalendar.nextOccurrence(of: s, after: now, calendar: calendar), date("2026-11-17 07:00"))
        XCTAssertEqual(ScheduledTaskCalendar.latestOccurrence(of: s, atOrBefore: now, calendar: calendar), date("2026-11-16 07:00"))
    }

    func testSeveralTimesADay() {
        let s = schedule("daily 07:00, 22:30")
        let now = date("2026-11-17 12:00")
        XCTAssertEqual(ScheduledTaskCalendar.nextOccurrence(of: s, after: now, calendar: calendar), date("2026-11-17 22:30"))
        XCTAssertEqual(ScheduledTaskCalendar.latestOccurrence(of: s, atOrBefore: now, calendar: calendar), date("2026-11-17 07:00"))
    }

    func testWeekdaysSkipTheWeekend() {
        let s = schedule("werktags 07:00")
        let saturday = date("2026-11-21 10:00")
        XCTAssertEqual(ScheduledTaskCalendar.nextOccurrence(of: s, after: saturday, calendar: calendar), date("2026-11-23 07:00"))
        XCTAssertEqual(ScheduledTaskCalendar.latestOccurrence(of: s, atOrBefore: saturday, calendar: calendar), date("2026-11-20 07:00"))
    }

    func testWeeklyOnChosenDays() {
        let s = schedule("wöchentlich mo, mi 08:00")
        let tuesday = date("2026-11-17 09:00")
        XCTAssertEqual(ScheduledTaskCalendar.nextOccurrence(of: s, after: tuesday, calendar: calendar), date("2026-11-18 08:00"))
        XCTAssertEqual(ScheduledTaskCalendar.latestOccurrence(of: s, atOrBefore: tuesday, calendar: calendar), date("2026-11-16 08:00"))
    }

    func testHourlyAtMinute() {
        let s = schedule("stündlich :15")
        XCTAssertEqual(ScheduledTaskCalendar.nextOccurrence(of: s, after: date("2026-11-17 10:20"), calendar: calendar), date("2026-11-17 11:15"))
        XCTAssertEqual(ScheduledTaskCalendar.latestOccurrence(of: s, atOrBefore: date("2026-11-17 10:20"), calendar: calendar), date("2026-11-17 10:15"))
        // Genau auf dem Termin: der zählt als letzter, der nächste ist eine Stunde später.
        XCTAssertEqual(ScheduledTaskCalendar.latestOccurrence(of: s, atOrBefore: date("2026-11-17 10:15"), calendar: calendar), date("2026-11-17 10:15"))
        XCTAssertEqual(ScheduledTaskCalendar.nextOccurrence(of: s, after: date("2026-11-17 10:15"), calendar: calendar), date("2026-11-17 11:15"))
    }

    func testTimeThatDoesNotExistInSpringMovesForward() {
        // 29.03.2026: In Berlin springt die Uhr von 02:00 auf 03:00.
        let s = schedule("täglich 02:30")
        let next = ScheduledTaskCalendar.nextOccurrence(of: s, after: date("2026-03-29 00:00"), calendar: calendar)
        XCTAssertNotNil(next)
        XCTAssertEqual(calendar.component(.day, from: next!), 29)
        XCTAssertEqual(calendar.component(.hour, from: next!), 3)
    }

    // MARK: Entscheidung

    func testOnTimeRun() {
        let t = task("täglich 07:00", created: "2026-11-16 12:00")
        XCTAssertEqual(ScheduledTaskCalendar.decide(t, now: date("2026-11-17 07:02"), calendar: calendar),
                       .run(slot: date("2026-11-17 07:00"), catchUp: false))
    }

    func testLateRunIsCaughtUpWithinTwelveHours() {
        let t = task("täglich 07:00", created: "2026-11-16 12:00")
        XCTAssertEqual(ScheduledTaskCalendar.decide(t, now: date("2026-11-17 09:00"), calendar: calendar),
                       .run(slot: date("2026-11-17 07:00"), catchUp: true))
    }

    func testTooLateIsMissed() {
        let t = task("täglich 07:00", created: "2026-11-16 12:00")
        XCTAssertEqual(ScheduledTaskCalendar.decide(t, now: date("2026-11-17 20:00"), calendar: calendar),
                       .missed(slot: date("2026-11-17 07:00")))
    }

    func testWithoutCatchUpALateSlotIsMissed() {
        let t = task("täglich 07:00", created: "2026-11-16 12:00", catchUp: false)
        XCTAssertEqual(ScheduledTaskCalendar.decide(t, now: date("2026-11-17 07:30"), calendar: calendar),
                       .missed(slot: date("2026-11-17 07:00")))
    }

    func testSlotBeforeCreationNeverRuns() {
        let t = task("täglich 07:00", created: "2026-11-17 07:30")
        XCTAssertEqual(ScheduledTaskCalendar.decide(t, now: date("2026-11-17 07:31"), calendar: calendar),
                       .wait(next: date("2026-11-18 07:00")))
    }

    func testHandledSlotDoesNotRunTwice() {
        let t = task("täglich 07:00", created: "2026-11-16 12:00", lastSlot: "2026-11-17 07:00")
        XCTAssertEqual(ScheduledTaskCalendar.decide(t, now: date("2026-11-17 07:03"), calendar: calendar),
                       .wait(next: date("2026-11-18 07:00")))
    }

    func testSeveralMissedSlotsCountOnce() {
        // Montag und Dienstag verpasst: nur der jüngste Termin läuft, einmal.
        let t = task("werktags 07:00", created: "2026-11-13 12:00", lastSlot: "2026-11-13 07:00")
        XCTAssertEqual(ScheduledTaskCalendar.decide(t, now: date("2026-11-17 08:00"), calendar: calendar),
                       .run(slot: date("2026-11-17 07:00"), catchUp: true))
    }

    func testPausedNeverRuns() {
        let t = task("täglich 07:00", created: "2026-11-16 12:00", paused: true)
        XCTAssertEqual(ScheduledTaskCalendar.decide(t, now: date("2026-11-17 07:01"), calendar: calendar), .paused)
    }

    func testSlotMarkerSkipsWhatIsAlreadyPast() {
        let t = task("täglich 07:00", created: "2026-11-10 12:00", lastSlot: "2026-11-12 07:00")
        let marker = ScheduledTaskCalendar.slotMarker(for: t, now: date("2026-11-17 09:00"), calendar: calendar)
        XCTAssertEqual(marker, date("2026-11-17 07:00"))
        var resumed = t
        resumed.lastSlot = marker
        XCTAssertEqual(ScheduledTaskCalendar.decide(resumed, now: date("2026-11-17 09:00"), calendar: calendar),
                       .wait(next: date("2026-11-18 07:00")))
    }

    func testNextWakeIgnoresPausedTasks() {
        let active = task("täglich 09:00", created: "2026-11-16 12:00")
        let paused = task("täglich 08:00", created: "2026-11-16 12:00", paused: true)
        XCTAssertEqual(ScheduledTaskCalendar.nextWake(for: [active, paused], after: date("2026-11-17 07:00"), calendar: calendar),
                       date("2026-11-17 09:00"))
    }

    // MARK: Text

    func testScheduleTextRoundTrips() {
        for text in ["täglich 07:00", "werktags 07:00, 22:30", "wöchentlich Mo, Mi 08:00", "stündlich :05"] {
            XCTAssertEqual(schedule(text).text, text)
        }
        XCTAssertEqual(schedule("weekly wed,mon 8:00").text, "wöchentlich Mo, Mi 08:00")
        XCTAssertEqual(schedule("hourly 0").minute, 0)
    }

    func testScheduleParseErrors() {
        for bad in ["", "monatlich 07:00", "täglich", "täglich 25:00", "wöchentlich 08:00", "stündlich :75", "werktags mo 07:00"] {
            if case .success = ScheduledTaskSchedule.parse(bad) { XCTFail("\(bad) sollte nicht durchgehen") }
        }
    }

    func testScheduleCodableKeepsMinuteZero() throws {
        let original = ScheduledTaskSchedule(kind: .hourly, minute: 0)
        let data = try ScheduledTaskStore.makeEncoder().encode(original)
        XCTAssertEqual(try ScheduledTaskStore.makeDecoder().decode(ScheduledTaskSchedule.self, from: data), original)
    }

    // MARK: Rechte

    func testDefaultPermissionsReadAndWriteInProject() {
        XCTAssertEqual(ScheduledTaskPermissions().allowedTools, ["Read", "Glob", "Grep", "Edit(/**)", "Skill"])
        XCTAssertEqual(ScheduledTaskPermissions(access: .readOnly, extraTools: ["Bash(whisperm8 tickets *)", "Read"]).allowedTools,
                       ["Read", "Glob", "Grep", "Skill", "Bash(whisperm8 tickets *)"])
        XCTAssertEqual(ScheduledTaskPermissions(access: .custom, extraTools: ["mcp__linear__get_issue"]).allowedTools,
                       ["mcp__linear__get_issue"])
    }
}
