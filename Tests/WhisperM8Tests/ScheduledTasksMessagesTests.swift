import Foundation
import XCTest
@testable import WhisperM8

/// Geplante Aufgaben, Paket 3 (WM8-110): Meldungen des Planers, Datumsformat,
/// Laden der Übersicht.
@MainActor
final class ScheduledTasksMessagesTests: XCTestCase {
    private var berlin: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }

    private func date(_ text: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = berlin.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: text)!
    }

    private func task(_ name: String = "Probe") -> ScheduledTask {
        ScheduledTask(name: name, prompt: "Prüfe etwas.", directory: "/tmp", account: "main",
                      schedule: ScheduledTaskSchedule(kind: .daily, times: [ScheduledTaskClockTime(hour: 7, minute: 0)!]),
                      createdAt: date("2026-11-01 08:00"))
    }

    // MARK: K4 Meldungen als Fälle

    func testValidationReturnsCasesWithGermanCLIAndTranslatedViewText() {
        var bad = task()
        bad.name = ""
        let problem = ScheduledTaskValidation.problem(in: bad, others: [], directoryExists: { _ in true }, accountExists: { _ in true })
        XCTAssertEqual(problem, .nameMissing)
        XCTAssertEqual(problem?.cliText, "Name fehlt.", "die CLI bleibt deutsch")
        XCTAssertEqual(ScheduledTaskTexts.problem(.nameMissing), "The name is missing.", "die Ansicht übersetzt")

        var hourly = task()
        hourly.schedule = ScheduledTaskSchedule(kind: .hourly, minute: 75)
        XCTAssertEqual(ScheduledTaskValidation.problem(in: hourly, others: [], directoryExists: { _ in true }, accountExists: { _ in true }),
                       .schedule(.invalidMinute))
        XCTAssertEqual(hourly.schedule.validationError, "Stündlich braucht eine Minute 0 bis 59.")

        let taken = ScheduledTaskValidation.problem(in: task("Probe"), others: [task("probe")],
                                                    directoryExists: { _ in true }, accountExists: { _ in true })
        XCTAssertEqual(taken, .nameTaken("Probe"))
    }

    func testSchedulerErrorsTranslateForTheView() {
        let conflict = ScheduledTaskScheduler.SchedulerError.conflict(taskName: "Bericht")
        XCTAssertEqual(conflict.errorDescription, "Ein Lauf von „Bericht“ arbeitet noch. Zwei Läufe derselben Aufgabe gibt es nicht.")
        XCTAssertEqual(ScheduledTaskTexts.schedulerError(conflict),
                       "A run of “Bericht” is still working. Two runs of the same task never run at once.")
        XCTAssertEqual(ScheduledTaskTexts.error(ScheduledTaskScheduler.SchedulerError.storage(.store(.writeFailed("voll")))),
                       "scheduled-tasks.json could not be saved: voll")
        XCTAssertFalse(ScheduledTaskTexts.schedulerError(.disabled).contains("Geplante"), "kein Deutsch in der englischen Ansicht")
    }

    // MARK: K5, K6a Datumsformat

    func testClockUsesTheAppLanguageAndCachesFormatters() {
        let clock = ScheduledTaskTexts.Clock(now: date("2026-11-16 12:00"), calendar: berlin)
        let appLanguage = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en").language.languageCode
        XCTAssertEqual(clock.locale.language.languageCode, appLanguage, "Sprache der App, nicht des Systems")
        XCTAssertTrue(clock.formatter("dMMM") === clock.formatter("dMMM"), "ein Formatierer je Vorlage")
        XCTAssertFalse(clock.formatter("dMMM") === clock.formatter("EEE"))
        var german = clock
        german.locale = Locale(identifier: "de_DE")
        XCTAssertFalse(clock.formatter("dMMM") === german.formatter("dMMM"), "je Sprache ein eigener")
        XCTAssertEqual(clock.time(date("2026-11-16 07:05")), "07:05")
        XCTAssertEqual(german.formatter("dMMM").string(from: date("2026-11-16 07:05")), "16. Nov.")
    }

    // MARK: K6b, K-C Laden

    func testLoadedAtOnlyMovesOnChangeOrNewDay() {
        let model = ScheduledTasksOverviewModel(dependencies: .init(load: { .init() }, scheduler: { nil }, afterChange: {}),
                                                calendar: berlin)
        let snapshot = ScheduledTaskOverviewLoader.Snapshot(overviews: [
            ScheduledTaskOverview(task: task(), next: nil, runs: [], state: .scheduled),
        ])
        model.apply(snapshot, at: date("2026-11-16 09:00"))
        XCTAssertEqual(model.loadedAt, date("2026-11-16 09:00"))
        model.apply(snapshot, at: date("2026-11-16 18:00"))
        XCTAssertEqual(model.loadedAt, date("2026-11-16 09:00"), "nichts geändert, selber Tag: Ansicht rechnet nicht neu")
        model.apply(snapshot, at: date("2026-11-17 00:05"))
        XCTAssertEqual(model.loadedAt, date("2026-11-17 00:05"), "neuer Tag: „morgen“ wird zu „heute“")
        model.apply(.init(), at: date("2026-11-17 08:00"))
        XCTAssertEqual(model.loadedAt, date("2026-11-17 08:00"), "Übersicht geändert")
    }

    func testOlderLoadDoesNotDisplaceAFreshlySavedTask() {
        let model = ScheduledTasksOverviewModel(dependencies: .init(load: { .init() }, scheduler: { nil }, afterChange: {}),
                                                calendar: berlin)
        // Ein Laden beginnt (Stand 0), dann wird angelegt, dann kommt das Laden ohne die Aufgabe an.
        let created = task("Neu")
        model.insertOrReplace(created, now: date("2026-11-16 12:00"), calendar: berlin)
        model.finishLoad(.init(), generation: 0)
        XCTAssertNotNil(model.overview(id: created.id), "veraltetes Laden verworfen")
    }

    // MARK: Login vor dem nächsten Lauf

    func testLoginWarningOnlyWhenTheLoginEndsBeforeTheNextRun() {
        let now = date("2026-11-16 12:00")
        let next = date("2026-11-17 07:00")
        XCTAssertNil(ScheduledTaskLoginWarning.check(loginEndsAt: date("2026-11-30 10:00"), next: next, now: now))
        XCTAssertNil(ScheduledTaskLoginWarning.check(loginEndsAt: nil, next: next, now: now), "Ende unbekannt")
        XCTAssertNil(ScheduledTaskLoginWarning.check(loginEndsAt: date("2026-11-16 18:00"), next: nil, now: now),
                     "pausiert: nichts startet")
        let soon = ScheduledTaskLoginWarning.check(loginEndsAt: date("2026-11-16 18:00"), next: next, now: now)
        XCTAssertEqual(soon, ScheduledTaskLoginWarning(endsAt: date("2026-11-16 18:00"), next: next, hasEnded: false))
        XCTAssertEqual(ScheduledTaskLoginWarning.check(loginEndsAt: date("2026-11-15 09:00"), next: next, now: now)?.hasEnded, true)

        let clock = ScheduledTaskTexts.Clock(now: now, calendar: berlin, locale: Locale(identifier: "en_US"))
        XCTAssertEqual(ScheduledTaskTexts.loginWarningTitle(soon!, account: "PowerUser", clock: clock),
                       "Login of PowerUser ends today, 18:00, before the next run.")
        XCTAssertEqual(ScheduledTaskTexts.loginWarningDetail(next: next, clock: clock),
                       "Without a new login, the next run (tomorrow, 07:00) does not start and reports a failure.")
    }

    // MARK: Mitlesen (über die echten Quellen, Prüfung Mara M1)

    private func runChat(_ external: String) -> AgentChatSession {
        AgentChatSession(provider: .claude, projectID: UUID(), externalSessionID: external,
                         title: "Bericht · 17.11.", status: .closed, hasLaunchedInitialPrompt: true)
    }

    func testReadAlongFromALiveRegistryEntry() {
        let external = UUID().uuidString.lowercased()
        let chat = runChat(external)
        let registry = ClaudeRegistryStatusSource(rootsProvider: { [] })
        let model = ScheduledTasksOverviewModel(dependencies: .init(load: { .init() }, scheduler: { nil }, afterChange: {}))
        var changed: [String] = []
        let subscription = registry.changes.sink { changed.append($0) }
        defer { subscription.cancel() }
        XCTAssertNil(AgentSessionReadAlong.liveWriter(session: chat, ownProcessRunning: false, registry: registry, scheduled: model))

        registry.apply(pid: 4711, record: ClaudeSessionRecord(profileName: "Zweitkonto", pid: 4711,
                                                                 sessionID: external.uppercased(), kind: "interactive"))
        XCTAssertEqual(changed, [external], "Ansicht prüft bei Registry-Änderungen neu")
        let writer = AgentSessionReadAlong.liveWriter(session: chat, ownProcessRunning: false, registry: registry, scheduled: model)
        XCTAssertEqual(writer, AgentSessionReadAlong.Writer(pid: 4711, account: "Zweitkonto", scheduledTask: nil),
                       "fremder Prozess: Start gesperrt")
        XCTAssertNil(AgentSessionReadAlong.liveWriter(session: chat, ownProcessRunning: true, registry: registry, scheduled: model),
                     "eigener Tab-Prozess: das ist der Chat selbst")
        XCTAssertTrue(AgentSessionReadAlong.bannerText(writer!).contains("4711"), "Leiste nennt den Prozess")

        registry.apply(pid: 4711, record: nil)
        XCTAssertNil(AgentSessionReadAlong.liveWriter(session: chat, ownProcessRunning: false, registry: registry, scheduled: model),
                     "Prozess beendet: fortsetzen geht wieder")

        registry.apply(pid: 4712, record: ClaudeSessionRecord(profileName: "main", pid: 4712, sessionID: external, kind: "bg"))
        XCTAssertNil(AgentSessionReadAlong.liveWriter(session: chat, ownProcessRunning: false, registry: registry, scheduled: model),
                     "Hintergrund-Agent der Sitzung zählt nicht")
    }

    func testReadAlongFromAnActiveScheduledRunWithoutRegistryEntry() throws {
        let session = UUID()
        let chat = runChat(session.uuidString.lowercased())
        let registry = ClaudeRegistryStatusSource(rootsProvider: { [] })
        let model = ScheduledTasksOverviewModel(dependencies: .init(load: { .init() }, scheduler: { nil }, afterChange: {}),
                                                calendar: berlin)
        let posted = expectation(forNotification: ScheduledTasksOverviewModel.activeRunsDidChange, object: model)
        let running = ScheduledTaskRunSummary(id: "r1", createdAt: date("2026-11-17 07:00"), sessionID: session, outcome: .running)
        model.apply(.init(overviews: [ScheduledTaskOverview(task: task("Bericht"), next: nil, runs: [running], state: .running)]))
        wait(for: [posted], timeout: 1)
        XCTAssertEqual(AgentSessionReadAlong.liveWriter(session: chat, ownProcessRunning: false, registry: registry, scheduled: model),
                       AgentSessionReadAlong.Writer(pid: nil, account: nil, scheduledTask: "Bericht"))

        var other = runChat(UUID().uuidString.lowercased())
        XCTAssertNil(AgentSessionReadAlong.liveWriter(session: other, ownProcessRunning: false, registry: registry, scheduled: model))
        other.kind = .backgroundChat
        XCTAssertNil(AgentSessionReadAlong.writer(session: other, ownProcessRunning: false, registry: [],
                                                  activeRunTasks: [other.externalSessionID!: "X"]))

        // Lauf zu Ende: Beleg weg.
        let done = ScheduledTaskRunSummary(id: "r1", createdAt: date("2026-11-17 07:00"), sessionID: session,
                                           outcome: .succeeded(summary: nil))
        model.apply(.init(overviews: [ScheduledTaskOverview(task: task("Bericht"), next: nil, runs: [done], state: .succeeded)]))
        XCTAssertNil(AgentSessionReadAlong.liveWriter(session: chat, ownProcessRunning: false, registry: registry, scheduled: model))
    }

    // MARK: Läufe nicht in der Chat-Liste (Entwurf, Variante A „nur hier“)

    /// Ein Lauf ist ein `claude -p`-Chat, den der Indexer findet; in der App
    /// angelegt ist er nicht (`createdManually` leer). Die Chat-Liste zeigt nur
    /// in der App angelegte Chats — der Lauf steht also nur unter seiner
    /// Aufgabe, auch wenn er gerade arbeitet, offen ist oder die Suche ihn träfe.
    func testScheduledRunsStayOutOfTheChatListCountsAndSearch() {
        let project = AgentProject(name: "whisperm8", path: "/tmp/whisperm8", createdManually: true)
        let chat = AgentChatSession(provider: .claude, projectID: project.id, externalSessionID: UUID().uuidString.lowercased(),
                                    title: "Bericht vorbereiten", status: .closed, hasLaunchedInitialPrompt: true,
                                    createdManually: true)
        let run = AgentChatSession(provider: .claude, projectID: project.id, externalSessionID: UUID().uuidString.lowercased(),
                                   title: "Bericht · 17.11.", status: .closed, hasLaunchedInitialPrompt: true)
        let workspace = AgentWorkspace(projects: [project], sessions: [chat, run])
        for layout in [SidebarLayout.grouped, .flat] {
            for query in ["", "Bericht"] {
                let snapshot = AgentSidebarModelBuilder.snapshot(
                    workspace: workspace, pinnedSessionIDs: [],
                    scope: SidebarScopeFilter(scope: .all, runningSessionIDs: [run.id], openTabIDs: [run.id],
                                              now: Date(), recentWindow: SidebarScopeFilter.defaultRecentWindow),
                    layout: layout, query: query, flatVisibleLimit: 50, selectedSessionID: nil)
                let listed = snapshot.visibleFlatSessions.map(\.id) + snapshot.sessionsByProject.values.flatMap { $0.map(\.id) }
                XCTAssertTrue(listed.contains(chat.id), "\(layout) „\(query)“")
                XCTAssertFalse(listed.contains(run.id), "\(layout) „\(query)“: Lauf steht nicht unter dem Projekt")
                XCTAssertEqual(snapshot.scopeCounts.all, 1, "Zähler ohne Lauf")
                XCTAssertFalse(snapshot.activeSessionIDsByProject[project.id]?.contains(run.id) ?? false)
            }
        }
    }
}
