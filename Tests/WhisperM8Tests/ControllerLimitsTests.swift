import Foundation
import XCTest
@testable import WhisperM8

/// Limits-Karte und App-Raute der Dynamic Island (Insel-Paket), pur im Kern.
final class ControllerLimitsTests: XCTestCase {
    private func row(_ kind: ControllerAccountChoice.Kind, _ name: String, current: Bool = false) -> ControllerAccountLimitRow {
        ControllerAccountLimitRow(kind: kind, name: name, fiveHour: 10, week: 20, isCurrentChat: current)
    }

    /// Claude vor GPT, Reihenfolge innerhalb bleibt; Abschnitte beginnen am
    /// Wechsel der Art.
    func testCardOrdersClaudeBeforeGPTAndMarksSections() {
        let card = ControllerLimitsCard(
            rows: [row(.gpt, "g1"), row(.claude, "c1"), row(.claude, "c2"), row(.gpt, "g2")],
            updatedAt: nil, isLoading: false)
        XCTAssertEqual(card.rows.map(\.name), ["c1", "c2", "g1", "g2"])
        XCTAssertEqual(card.rows.filter(card.startsSection).map(\.name), ["c1", "g1"])
        XCTAssertFalse(card.canScroll)
        XCTAssertEqual(card.hiddenBelow, 0)
    }

    /// Höchstens sechs Konten sichtbar, scrollen ohne Umlauf, das Konto des
    /// Chats ist beim Öffnen zu sehen.
    func testCardScrollsAndShowsTheCurrentAccount() {
        let rows = (0..<9).map { row($0 < 5 ? .claude : .gpt, "k\($0)", current: $0 == 8) }
        var card = ControllerLimitsCard(rows: rows, updatedAt: nil, isLoading: false)
        XCTAssertEqual(card.visibleRows.count, 6)
        XCTAssertTrue(card.visibleRows.contains { $0.name == "k8" }, "Konto des Chats sichtbar")
        XCTAssertEqual(card.hiddenAbove, 3)
        XCTAssertFalse(card.scroll(1), "unten am Rand")
        XCTAssertTrue(card.scroll(-1))
        XCTAssertEqual(card.hiddenAbove, 2)
        XCTAssertEqual(card.hiddenBelow, 1)
        card.scroll(-10)
        XCTAssertEqual(card.hiddenAbove, 0)
        XCTAssertTrue(card.canScroll)
    }

    /// Neue Zahlen behalten die Lage, soweit sie passt.
    func testUpdateKeepsTheScrollPosition() {
        let rows = (0..<9).map { row(.claude, "k\($0)") }
        var card = ControllerLimitsCard(rows: rows, updatedAt: nil, isLoading: true)
        card.scroll(2)
        card.update(rows: rows, updatedAt: Date(timeIntervalSince1970: 5), isLoading: false)
        XCTAssertEqual(card.hiddenAbove, 2)
        XCTAssertFalse(card.isLoading)
        card.update(rows: Array(rows.prefix(7)), updatedAt: nil, isLoading: false)
        XCTAssertEqual(card.hiddenAbove, 1, "weniger Zeilen: an den Rand gezogen")
    }

    /// Ampel wie das Popover: unter 50 grün, ab 50 gelb, ab 80 rot.
    func testLevelThresholds() {
        XCTAssertNil(ControllerLimitLevel(percent: nil))
        XCTAssertEqual(ControllerLimitLevel(percent: 0), .low)
        XCTAssertEqual(ControllerLimitLevel(percent: 49.9), .low)
        XCTAssertEqual(ControllerLimitLevel(percent: 50), .medium)
        XCTAssertEqual(ControllerLimitLevel(percent: 79.9), .medium)
        XCTAssertEqual(ControllerLimitLevel(percent: 80), .high)
    }

    /// Unter einem Tag als Dauer, sonst Wochentag und Uhrzeit.
    func testResetStyle() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertNil(ControllerResetStyle.of(nil, now: now))
        XCTAssertEqual(ControllerResetStyle.of(now.addingTimeInterval(2 * 3600 + 600), now: now), .duration(minutes: 130))
        XCTAssertEqual(ControllerResetStyle.of(now.addingTimeInterval(-30), now: now), .duration(minutes: 0))
        XCTAssertEqual(ControllerResetStyle.of(now.addingTimeInterval(86_400), now: now), .duration(minutes: 1440))
        XCTAssertEqual(ControllerResetStyle.of(now.addingTimeInterval(86_401), now: now), .dayAndTime)
    }

    /// Die App-Raute in der Lage des Steuerkreuzes; nur Glocke und Wach
    /// bleiben sind Schalter.
    func testAppSlotsFollowTheDPad() {
        for slot in ControllerAppSlot.allCases {
            XCTAssertEqual(ControllerAppSlot(direction: slot.direction), slot)
        }
        XCTAssertEqual(ControllerAppSlot.allCases.filter(\.isToggle), [.alerts, .stayAwake])
        XCTAssertEqual(ControllerAwakeStage.always.next, .off)
        XCTAssertEqual(ControllerToggleConfirmation.awakeNeedsPermission.slot, .stayAwake)
        XCTAssertEqual(ControllerToggleConfirmation.alert(.off, next: .all).slot, .alerts)
    }

    /// Zeilen aus dem Store: Claude, dann GPT; Probleme als Text, und nur
    /// Login-Probleme ersetzen die Zahlen.
    @MainActor
    func testRowsFromTheStore() {
        let limits: [String: AccountLimitsStore.Limit] = [
            "main": .init(fiveHour: 42, week: 61),
            "alt": .init(fiveHour: 10, week: 5, problem: .claude(.network)),
            "gone": .init(fiveHour: 30, week: 30, problem: .claude(.loginExpired)),
            "g": .init(fiveHour: nil, week: nil, problem: .gptFetchFailed),
            "g2": .init(fiveHour: 20, week: 40, problem: .gptFetchFailed),
        ]
        let rows = ControllerLimitRows.rows(
            claude: ["main", "alt", "gone", "fresh"], gpt: ["g", "g2"], limit: { limits[$1] })
        XCTAssertEqual(rows.map(\.name), ["main", "alt", "gone", "fresh", "g", "g2"])
        XCTAssertEqual(rows[0].fiveHour, 42)
        XCTAssertNil(rows[0].problem)
        XCTAssertNotNil(rows[1].problem)
        XCTAssertFalse(rows[1].problemReplacesNumbers, "offline: letzte Zahlen bleiben")
        XCTAssertTrue(rows[2].problemReplacesNumbers, "Login beendet: Text statt Balken")
        XCTAssertFalse(rows[3].hasNumbers)
        XCTAssertFalse(rows[4].problemReplacesNumbers, "GPT ohne Zahlen: Text, weil keine da sind")
        XCTAssertFalse(rows[4].hasNumbers)
        XCTAssertEqual(rows[4].problem, AccountLimitsStore.Problem.gptFetchFailedText(hasNumbers: false))
        XCTAssertEqual(rows[4].kind, .gpt)
        XCTAssertTrue(rows[5].hasNumbers, "GPT mit alten Zahlen: Balken bleiben")
        XCTAssertEqual(rows[5].problem, AccountLimitsStore.Problem.gptFetchFailedText(hasNumbers: true))
    }

    // MARK: - Konto eines Chats

    /// Review Insel-Paket, Befund 6: Ein GPT-Stempel zählt nur mit
    /// eingeschaltetem GPT-Backend, das GPT-Konto nur mit eingeschalteten
    /// GPT-Konten — dieselben Schalter wie beim Start.
    @MainActor
    func testUsageAccountFollowsTheGPTSwitches() {
        let gpt = AgentChatSession(
            provider: .claude, projectID: UUID(), title: "GPT", claudeProfileName: "work",
            claudeBackendModel: "gpt-5.6-sol", gptProfileName: "gpt-2")
        XCTAssertEqual(ControllerUsageAccount.of(gpt, gptBackendEnabled: true, gptProfilesEnabled: true),
                       ControllerUsageAccount(kind: .gpt, name: "gpt-2"))
        XCTAssertEqual(ControllerUsageAccount.of(gpt, gptBackendEnabled: true, gptProfilesEnabled: false),
                       ControllerUsageAccount(kind: .gpt, name: GPTAccountProfiles.mainProfileName))
        XCTAssertEqual(ControllerUsageAccount.of(gpt, gptBackendEnabled: false, gptProfilesEnabled: true),
                       ControllerUsageAccount(kind: .claude, name: "work"), "Backend aus: läuft als Claude")
        let claude = AgentChatSession(provider: .claude, projectID: UUID(), title: "Claude")
        XCTAssertEqual(ControllerUsageAccount.of(claude, gptBackendEnabled: true, gptProfilesEnabled: true),
                       ControllerUsageAccount(kind: .claude, name: ClaudeAccountProfiles.mainProfileName))
        let codex = AgentChatSession(provider: .codex, projectID: UUID(), title: "Codex")
        XCTAssertNil(ControllerUsageAccount.of(codex, gptBackendEnabled: true, gptProfilesEnabled: true))
    }

    // MARK: - Store: Fehlschläge behalten den letzten Stand

    private func claudeUsage(
        _ fiveHour: Double?, _ week: Double?, resets: Date? = nil, problem: ClaudeUsageFetchProblem? = nil
    ) -> ClaudeAccountUsage {
        ClaudeAccountUsage(
            fiveHourPercent: fiveHour, fiveHourResetsAt: resets, sevenDayPercent: week, sevenDayResetsAt: resets,
            fetchedAt: Date(timeIntervalSince1970: 0), isLive: problem == nil, liveFetchProblem: problem)
    }

    private func codexUsage(_ fiveHour: Double, resets: Date) -> CodexUsage {
        CodexUsage(primary: CodexUsage.Window(usedPercent: fiveHour, windowMinutes: 300, resetsAt: resets), isLive: true)
    }

    /// Ein gescheiterter GPT-Abruf behält Zahlen und Rücksetzzeit, nennt
    /// keinen erfundenen Grund und rückt den Stand-Zeitpunkt nicht vor.
    @MainActor
    func testGPTFailureKeepsTheLastNumbersAndTime() {
        var clock = Date(timeIntervalSince1970: 1_000)
        let store = AccountLimitsStore(now: { clock })
        let reset = Date(timeIntervalSince1970: 9_000)
        store.record(gpt: "main", usage: codexUsage(30, resets: reset))
        XCTAssertEqual(store.updatedAt, clock)
        clock = clock.addingTimeInterval(600)
        store.recordFailure(gpt: "main")
        let limit = store.limit(kind: .gpt, name: "main")
        XCTAssertEqual(limit?.fiveHour, 30)
        XCTAssertEqual(limit?.fiveHourResetsAt, reset)
        XCTAssertEqual(limit?.problem, .gptFetchFailed)
        XCTAssertEqual(store.updatedAt, Date(timeIntervalSince1970: 1_000), "kein neuer Stand ohne Zahlen")
        XCTAssertFalse(limit?.problem?.displayText(hasNumbers: true).contains("token") ?? true)

        store.recordFailure(gpt: "new")
        XCTAssertNil(store.limit(kind: .gpt, name: "new")?.fiveHour)
        XCTAssertEqual(store.updatedAt, Date(timeIntervalSince1970: 1_000))
        store.record(gpt: "main", usage: codexUsage(35, resets: reset))
        XCTAssertNil(store.limit(kind: .gpt, name: "main")?.problem, "neue Zahlen räumen den Hinweis weg")
        XCTAssertEqual(store.updatedAt, clock)
    }

    /// Claude offline: Die letzten Zahlen und Rücksetzzeiten bleiben, der
    /// Grund kommt dazu. Login beendet: Die Zahlen gelten nichts mehr.
    @MainActor
    func testClaudeProblemKeepsNumbersUnlessTheLoginEnded() {
        var clock = Date(timeIntervalSince1970: 1_000)
        let store = AccountLimitsStore(now: { clock })
        let reset = Date(timeIntervalSince1970: 5_000)
        store.record(claude: "main", usage: claudeUsage(42, 61, resets: reset))
        clock = clock.addingTimeInterval(300)
        store.record(claude: "main", usage: claudeUsage(nil, nil, problem: .network))
        var limit = store.limit(kind: .claude, name: "main")
        XCTAssertEqual(limit?.fiveHour, 42)
        XCTAssertEqual(limit?.week, 61)
        XCTAssertEqual(limit?.fiveHourResetsAt, reset)
        XCTAssertEqual(limit?.problem, .claude(.network))
        XCTAssertEqual(store.updatedAt, Date(timeIntervalSince1970: 1_000))

        store.record(claude: "main", usage: claudeUsage(nil, nil, problem: .loginExpired))
        limit = store.limit(kind: .claude, name: "main")
        XCTAssertNil(limit?.fiveHour, "Login beendet: Text statt alter Zahlen")
        XCTAssertEqual(limit?.problem, .claude(.loginExpired))
    }

    /// Die Store-Abbildung: Rücksetzzeiten und Problem aus dem Abruf.
    @MainActor
    func testStoreKeepsResetsAndProblems() {
        let reset = Date(timeIntervalSince1970: 2_000)
        let usage = ClaudeAccountUsage(
            fiveHourPercent: 12, fiveHourResetsAt: reset, sevenDayPercent: 34, sevenDayResetsAt: nil,
            fetchedAt: Date(), isLive: false, liveFetchProblem: .loginExpired)
        let limit = AccountLimitsStore.limit(usage)
        XCTAssertEqual(limit.fiveHour, 12)
        XCTAssertEqual(limit.fiveHourResetsAt, reset)
        XCTAssertEqual(limit.week, 34)
        XCTAssertEqual(limit.problem, .claude(.loginExpired))
    }

    /// Mit zwei Rauten rund 700 pt breit; an der Notch nie schmaler als sie,
    /// und die Dynamic Island bleibt ganz auf dem Bildschirm.
    @MainActor
    func testWideIslandStaysOnScreen() {
        var slots = ControllerQuickDrawSlots(setup: ControllerMenuSetup())
        slots.account = nil
        let model = ControllerIslandModel(target: ControllerIslandTarget(), content: .quickDraw(slots))
        let display = ControllerIslandDisplay(style: .pill, model: model)
        XCTAssertGreaterThanOrEqual(display.bodyWidth, 680)
        XCTAssertLessThanOrEqual(display.bodyWidth, 720)

        let small = CGRect(x: 0, y: 0, width: 1000, height: 700)
        let pill = NotchScreenInfo(displayID: 1, frame: small, visibleFrame: small, safeAreaTop: 0,
                                   auxiliaryLeftWidth: nil, auxiliaryRightWidth: nil, isBuiltIn: false)
        let body = CGSize(width: display.bodyWidth, height: 300)
        let left = ControllerIslandGeometry.frame(screen: pill, bodySize: body, stored: NotchPillPosition(x: 0.02, y: 0.98))
        XCTAssertGreaterThanOrEqual(left.minX, small.minX)
        XCTAssertLessThanOrEqual(left.maxX, small.maxX)

        let notch = NotchScreenInfo(displayID: 2, frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                    visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950), safeAreaTop: 32,
                                    auxiliaryLeftWidth: 664, auxiliaryRightWidth: 664, isBuiltIn: true)
        let atNotch = ControllerIslandGeometry.frame(screen: notch, bodySize: body)
        XCTAssertEqual(atNotch.midX, 756)
        XCTAssertGreaterThanOrEqual(atNotch.minX, 0)
        XCTAssertLessThanOrEqual(atNotch.maxX, 1512)
    }
}
