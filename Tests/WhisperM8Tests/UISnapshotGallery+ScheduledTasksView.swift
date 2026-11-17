import SwiftUI
@testable import WhisperM8

/// Fixtures der Ansicht „Geplant“ (WM8-110, Pakete 2 und 3): Abschnitt in der
/// Seitenleiste, Detail im Inhaltsbereich, Blatt zum Anlegen und Ändern,
/// Login-Warnung und die Leiste beim Mitlesen.
/// Erfundene Aufgaben, Projekte und Konten (öffentliches Repo).
extension UISnapshotGallery {
    @MainActor
    static func scheduledTasksViewFixtures() -> [Fixture] {
        let fixture = ScheduledTasksFixtureData()
        let on: [String: Any] = [PreferenceKeys.scheduledTasksEnabled: true]
        let sidebarSize = CGSize(width: 270, height: 420)
        let detailSize = CGSize(width: 820, height: 760)
        let sheetSize = CGSize(width: 620, height: 720)

        func sidebar(expanded: Set<UUID>, selected: UUID? = nil, model: ScheduledTasksOverviewModel? = nil) -> AnyView {
            AnyView(
                ScheduledTasksSidebarSection(
                    selectedTaskID: selected, selectedRunSessionID: nil,
                    model: model ?? fixture.model(), expandedTaskIDs: expanded)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(AgentTheme.sidebar)
            )
        }

        func detail(_ id: UUID, loginEndsAt: @escaping (String) -> Date? = {
            $0 == "main" ? fixture.now.addingTimeInterval(14 * 86_400) : fixture.now.addingTimeInterval(4 * 86_400)
        }) -> AnyView {
            AnyView(ScheduledTaskDetailView(taskID: id, model: fixture.model(), loginEndsAt: loginEndsAt))
        }

        func sheet(_ task: ScheduledTask?) -> AnyView {
            var dependencies = ScheduledTaskEditorSheet.Dependencies.live
            dependencies.loginEndsAt = { _ in fixture.now.addingTimeInterval(13 * 86_400) }
            dependencies.directoryExists = { _ in true }
            return AnyView(ScheduledTaskEditorSheet(
                target: ScheduledTaskEditorTarget(task: task),
                projects: [ScheduledTaskEditorProject(name: "beispiel-app", path: "/Users/demo/repos/beispiel-app"),
                           ScheduledTaskEditorProject(name: "whisperm8", path: "/Users/demo/repos/whisperm8")],
                existing: fixture.tasks, dependencies: dependencies, now: fixture.now,
                accounts: ["main", "Zweitkonto"])
            .background(AgentTheme.panel))
        }

        let empty = ScheduledTasksOverviewModel(dependencies: .fixture { .init() })
        empty.apply(.init(), at: fixture.now)

        return [
            Fixture(name: "geplant-seitenleiste", size: sidebarSize, storage: on) {
                sidebar(expanded: [fixture.failing.id, fixture.running.id])
            },
            Fixture(name: "geplant-seitenleiste-auswahl", size: sidebarSize, storage: on) {
                sidebar(expanded: [fixture.morning.id], selected: fixture.morning.id)
            },
            Fixture(name: "geplant-seitenleiste-zu", size: CGSize(width: 270, height: 120),
                    storage: on.merging(["agentScheduledTasksSectionCollapsed": true]) { a, _ in a }) {
                sidebar(expanded: [])
            },
            Fixture(name: "geplant-seitenleiste-leer", size: CGSize(width: 270, height: 120), storage: on) {
                sidebar(expanded: [], model: empty)
            },
            Fixture(name: "geplant-detail-fehler", size: detailSize, storage: on) { detail(fixture.failing.id) },
            Fixture(name: "geplant-detail-arbeitet", size: detailSize, storage: on) { detail(fixture.running.id) },
            Fixture(name: "geplant-detail-pausiert", size: detailSize, storage: on) { detail(fixture.paused.id) },
            Fixture(name: "geplant-detail-geklappt", size: detailSize, storage: on) { detail(fixture.morning.id) },
            // Paket 3: Login endet heute Abend, der nächste Lauf ist morgen früh.
            Fixture(name: "geplant-detail-login", size: detailSize, storage: on) {
                detail(fixture.morning.id, loginEndsAt: { _ in fixture.now.addingTimeInterval(4 * 3600) })
            },
            Fixture(name: "geplant-mitlesen-leiste", size: CGSize(width: 820, height: 44), storage: on) {
                AnyView(AgentReadAlongBanner(writer: .init(pid: 48211, account: "Zweitkonto", scheduledTask: "Abhängigkeiten prüfen"))
                    .frame(maxHeight: .infinity, alignment: .top).background(AgentTheme.background))
            },
            Fixture(name: "geplant-mitlesen-leiste-fremd", size: CGSize(width: 820, height: 44), storage: on) {
                AnyView(AgentReadAlongBanner(writer: .init(pid: 48211, account: "Zweitkonto", scheduledTask: nil))
                    .frame(maxHeight: .infinity, alignment: .top).background(AgentTheme.background))
            },
            Fixture(name: "geplant-blatt-neu", size: sheetSize, storage: on) { sheet(nil) },
            Fixture(name: "geplant-blatt-aendern", size: sheetSize, storage: on) { sheet(fixture.failing) },
        ]
    }
}

extension ScheduledTasksOverviewModel.Dependencies {
    static func fixture(_ load: @escaping @Sendable () -> ScheduledTaskOverviewLoader.Snapshot) -> Self {
        Self(load: load, scheduler: { nil }, afterChange: {})
    }
}

/// Vier Aufgaben in allen Zuständen der Ansicht.
struct ScheduledTasksFixtureData {
    /// Montag, 16.11.2026, 15:50 Ortszeit.
    let now: Date
    let morning: ScheduledTask
    let failing: ScheduledTask
    let running: ScheduledTask
    let paused: ScheduledTask

    var tasks: [ScheduledTask] { [morning, failing, running, paused] }

    init() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 15, minute: 50))!
        let created = now.addingTimeInterval(-30 * 86_400)
        func time(_ text: String) -> ScheduledTaskClockTime { ScheduledTaskClockTime(parsing: text)! }
        morning = ScheduledTask(
            id: UUID(uuidString: "0A000000-0000-0000-0000-000000000001")!, name: "Morgenbericht",
            prompt: "/morgenbericht Stand aller offenen Punkte", directory: "/Users/demo/repos/beispiel-app",
            account: "main", schedule: ScheduledTaskSchedule(kind: .daily, times: [time("07:00")]), createdAt: created)
        failing = ScheduledTask(
            id: UUID(uuidString: "0A000000-0000-0000-0000-000000000002")!, name: "Release-Notizen sammeln",
            prompt: "Sammle die Änderungen seit dem letzten Release und schreib sie nach docs/release-notizen.md.",
            directory: "/Users/demo/repos/beispiel-app", account: "Zweitkonto",
            schedule: ScheduledTaskSchedule(kind: .weekdays, times: [time("17:30")]),
            permissions: ScheduledTaskPermissions(access: .projectWrite, extraTools: ["Bash(git log *)"]), createdAt: created)
        running = ScheduledTask(
            id: UUID(uuidString: "0A000000-0000-0000-0000-000000000003")!, name: "Abhängigkeiten prüfen",
            prompt: "Prüfe, ob es neue Versionen der Pakete gibt. Ändere nichts am Code.",
            directory: "/Users/demo/repos/whisperm8", account: "Zweitkonto",
            schedule: ScheduledTaskSchedule(kind: .weekly, times: [time("15:45")], days: [1]),
            permissions: ScheduledTaskPermissions(access: .readOnly), createdAt: created)
        paused = ScheduledTask(
            id: UUID(uuidString: "0A000000-0000-0000-0000-000000000004")!, name: "Wochenrückblick",
            prompt: "Fass zusammen, was diese Woche fertig wurde und was hängt.", directory: "/Users/demo/repos/whisperm8",
            account: "main", schedule: ScheduledTaskSchedule(kind: .weekly, times: [time("18:00")], days: [5]),
            paused: true, createdAt: created)
    }

    @MainActor func model() -> ScheduledTasksOverviewModel {
        let snapshot = self.snapshot()
        let model = ScheduledTasksOverviewModel(dependencies: .fixture { snapshot })
        model.apply(snapshot, at: now)
        return model
    }

    func run(_ id: String, _ ago: TimeInterval, _ outcome: ScheduledTaskRunOutcome,
             trigger: ScheduledTaskRunRecord.Trigger = .schedule, seconds: Int? = nil, chat: Bool = true) -> ScheduledTaskRunSummary {
        ScheduledTaskRunSummary(id: id, createdAt: now.addingTimeInterval(-ago), trigger: trigger,
                                sessionID: chat ? UUID() : nil, outcome: outcome, durationSeconds: seconds)
    }

    func snapshot() -> ScheduledTaskOverviewLoader.Snapshot {
        let hour: TimeInterval = 3600
        let day: TimeInterval = 86_400
        func overview(_ task: ScheduledTask, next: Date?, runs: [ScheduledTaskRunSummary],
                      archived: Int = 0) -> ScheduledTaskOverview {
            ScheduledTaskOverview(task: task, next: next, runs: runs,
                                  state: ScheduledTaskOverview.state(paused: task.paused, runs: runs), archivedCount: archived)
        }
        return .init(overviews: [
            overview(morning, next: now.addingTimeInterval(15 * hour + 10 * 60), runs: [
                run("m1", 8 * hour + 50 * 60, .succeeded(summary: "Der Bericht steht in docs/morgenbericht.md."), seconds: 171),
                run("m2", day + 7 * hour, .succeeded(summary: "Keine offenen Punkte."), trigger: .catchUp, seconds: 184),
                run("m3", 2 * day + 8 * hour, .succeededWithNotes(summary: "Bericht geschrieben.", deniedTools: ["Write"]), seconds: 203),
                run("m4", 3 * day + 8 * hour, .succeeded(summary: nil), seconds: 160),
            ], archived: 12),
            overview(failing, next: now.addingTimeInterval(day + 100 * 60), runs: [
                run("f1", 3 * day - 20 * 60, .failed(message: "Die Datei docs/release-notizen.md ist schreibgeschützt."), seconds: 42),
                run("f2", 4 * day, .succeeded(summary: "Zwei Änderungen eingetragen."), seconds: 95),
                run("f3", 5 * day, .notStarted(.loginExpired, message: nil), chat: false),
            ]),
            overview(running, next: now.addingTimeInterval(7 * day - 5 * 60), runs: [
                run("r1", 5 * 60, .running, seconds: nil),
                run("r2", 7 * day + 5 * 60, .succeeded(summary: "Keine neuen Versionen."), seconds: 63),
            ]),
            overview(paused, next: nil, runs: [
                run("p1", 10 * day, .succeeded(summary: "Rückblick geschrieben."), seconds: 118),
            ]),
        ])
    }
}
