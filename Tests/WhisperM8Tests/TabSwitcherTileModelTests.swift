import Foundation
import XCTest
@testable import WhisperM8

/// Pure Anzeige-Daten der Switcher-Kachel (`TabSwitcherTileModel`):
/// Statuswort, Symbol, Dauer, Stand-Zeile.
final class TabSwitcherTileModelTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func model(
        status: AgentSessionRuntimeStatus?,
        activity: AgentSessionActivity? = nil,
        since: TimeInterval? = nil,
        lastActivity: TimeInterval? = nil
    ) -> TabSwitcherTileModel {
        TabSwitcherTileModel(
            title: "Store-Migration",
            status: status,
            activity: activity,
            statusSince: since.map { now.addingTimeInterval(-$0) },
            lastActivityAt: lastActivity.map { now.addingTimeInterval(-$0) },
            now: now
        )
    }

    // MARK: - Statuswort + Symbol

    func testEveryStatusHasWordAndSymbol() {
        let expected: [(AgentSessionRuntimeStatus?, String, String)] = [
            (.working, "Working", "circle.fill"),
            (.awaitingInput, "Waiting for you", "circle.lefthalf.filled"),
            (.idle, "Ready", "circle"),
            (.stopped, "Stopped", "stop.circle"),
            (.errored, "Error", "exclamationmark.circle.fill"),
            (nil, "Stopped", "stop.circle"),
        ]
        for (status, word, symbol) in expected {
            let tile = model(status: status)
            XCTAssertEqual(tile.statusWord, word, "\(String(describing: status))")
            XCTAssertEqual(tile.symbolName, symbol, "\(String(describing: status))")
        }
        // Jeder echte Status ist ohne Farbe unterscheidbar: Wörter und Symbole eindeutig.
        let all: [AgentSessionRuntimeStatus] = [.working, .awaitingInput, .idle, .stopped, .errored]
        XCTAssertEqual(Set(all.map(TabSwitcherTileModel.statusWord(for:))).count, all.count)
        XCTAssertEqual(Set(all.map(TabSwitcherTileModel.symbolName(for:))).count, all.count)
    }

    // MARK: - Dauer

    func testRunningStatesShowElapsedSinceStatusChange() {
        XCTAssertEqual(model(status: .working, since: 30).header(detail: .full), "Working · 30 s")
        XCTAssertEqual(model(status: .working, since: 150).header(detail: .full), "Working · 2 min")
        XCTAssertEqual(model(status: .awaitingInput, since: 4 * 60 + 59).header(detail: .full), "Waiting for you · 4 min")
        XCTAssertEqual(model(status: .working, since: 3 * 3600 + 10).durationText, "3 h")
        XCTAssertEqual(model(status: .working, since: 2 * 86_400 + 5).durationText, "2 d")
    }

    func testRunningStateWithoutStatusSinceShowsNoGuessedDuration() {
        // lastActivityAt ist kein Startpunkt des Arbeitens — lieber keine Dauer.
        let tile = model(status: .working, lastActivity: 600)
        XCTAssertNil(tile.durationText)
        XCTAssertEqual(tile.header(detail: .full), "Working")
    }

    func testRestingStatesShowTimeAgo() {
        XCTAssertEqual(model(status: .idle, since: 12 * 60).header(detail: .full), "Ready · 12 min ago")
        XCTAssertEqual(model(status: .idle, since: 20).durationText, "just now")
        XCTAssertEqual(model(status: .errored, since: 2 * 3600).durationText, "2 h ago")
    }

    func testRestingStatesFallBackToLastActivity() {
        XCTAssertEqual(model(status: .stopped, lastActivity: 5 * 60).durationText, "5 min ago")
        XCTAssertEqual(model(status: nil, lastActivity: 90).durationText, "1 min ago")
        // statusSince gewinnt vor lastActivityAt.
        XCTAssertEqual(model(status: .idle, since: 60, lastActivity: 3600).durationText, "1 min ago")
        XCTAssertNil(model(status: .idle).durationText)
    }

    func testNegativeIntervalsClampToZero() {
        XCTAssertEqual(model(status: .working, since: -30).durationText, "0 s")
        XCTAssertEqual(model(status: .idle, since: -30).durationText, "just now")
    }

    func testDurationFormattingBoundaries() {
        XCTAssertEqual(TabSwitcherTileModel.elapsed(59.9), "59 s")
        XCTAssertEqual(TabSwitcherTileModel.elapsed(60), "1 min")
        XCTAssertEqual(TabSwitcherTileModel.elapsed(3599), "59 min")
        XCTAssertEqual(TabSwitcherTileModel.elapsed(3600), "1 h")
        XCTAssertEqual(TabSwitcherTileModel.elapsed(86_399), "23 h")
        XCTAssertEqual(TabSwitcherTileModel.elapsed(86_400), "1 d")
        XCTAssertEqual(TabSwitcherTileModel.ago(59), "just now")
        XCTAssertEqual(TabSwitcherTileModel.ago(60), "1 min ago")
    }

    func testStatusAndTitleStageDropsDuration() {
        let tile = model(status: .working, since: 150)
        XCTAssertEqual(tile.header(detail: .full), "Working · 2 min")
        XCTAssertEqual(tile.header(detail: .withoutActivity), "Working · 2 min")
        XCTAssertEqual(tile.header(detail: .statusAndTitle), "Working")
    }

    // MARK: - Stand-Zeile

    func testActivityLineComesFromActivity() {
        let working = model(
            status: .working,
            activity: AgentSessionActivity(detail: .tool(name: "Edit", argument: "Store.swift"))
        )
        XCTAssertEqual(working.activityLine, AgentSessionActivity(detail: .tool(name: "Edit", argument: "Store.swift")).line(for: .working))
        XCTAssertNotNil(working.activityLine)

        let idle = model(status: .idle, activity: AgentSessionActivity(detail: .reply("Alle Tests grün.")))
        XCTAssertEqual(idle.activityLine, "Alle Tests grün.")

        let plan = model(status: .awaitingInput, activity: AgentSessionActivity(awaitingKind: .planApproval))
        XCTAssertEqual(plan.activityLine, "Plan awaiting approval")
    }

    func testActivityLineRepeatingStatusWordIsDropped() {
        // Die Activity liefert für gestoppt/Fehler das Statuswort selbst — nicht doppelt zeigen.
        let reply = AgentSessionActivity(detail: .reply("Fertig."))
        XCTAssertNil(model(status: .stopped, activity: reply).activityLine)
        XCTAssertNil(model(status: .errored, activity: reply).activityLine)
    }

    func testNoActivityMeansNoLine() {
        XCTAssertNil(model(status: .working).activityLine)
        XCTAssertNil(model(status: .idle).activityLine)
        // Tool im Ruhezustand wäre veraltet → keine Zeile.
        XCTAssertNil(model(status: .idle, activity: AgentSessionActivity(detail: .tool(name: "Bash", argument: "ls"))).activityLine)
    }
}

/// Projekt-Liste des Switchers (Situation C): eine Spalte, scrollt erst bei Platzmangel.
final class TabSwitcherListLayoutTests: XCTestCase {
    func testSingleColumnAndFullHeightWhenRowsFit() {
        let metrics = TabSwitcherListLayout.metrics(count: 4, availableSize: CGSize(width: 1400, height: 900))
        XCTAssertEqual(metrics.rows, 4)
        XCTAssertEqual(metrics.visibleRows, 4)
        XCTAssertFalse(metrics.needsScroll)
        XCTAssertEqual(metrics.width, TabSwitcherListLayout.maxWidth)
        XCTAssertEqual(metrics.height, 4 * 56 + 3 * 6)
    }

    func testScrollsWhenRowsExceedSpace() {
        // 400 pt Höhe − 132 Chrome = 268 pt → 4 Zeilen à 56 + 6.
        let metrics = TabSwitcherListLayout.metrics(count: 12, availableSize: CGSize(width: 900, height: 400))
        XCTAssertEqual(metrics.rows, 12)
        XCTAssertEqual(metrics.visibleRows, 4)
        XCTAssertEqual(metrics.height, 4 * 56 + 3 * 6)
        XCTAssertTrue(metrics.needsScroll)
    }

    func testWidthClampedBetweenMinAndMax() {
        XCTAssertEqual(
            TabSwitcherListLayout.metrics(count: 2, availableSize: CGSize(width: 300, height: 600)).width,
            TabSwitcherListLayout.minWidth
        )
        XCTAssertEqual(
            TabSwitcherListLayout.metrics(count: 2, availableSize: CGSize(width: 546, height: 600)).width,
            450
        )
    }

    func testEmptyAndTinyAreas() {
        let empty = TabSwitcherListLayout.metrics(count: 0, availableSize: CGSize(width: 900, height: 900))
        XCTAssertEqual(empty.rows, 0)
        XCTAssertEqual(empty.width, 0)
        XCTAssertEqual(empty.height, 0)
        let tiny = TabSwitcherListLayout.metrics(count: 3, availableSize: CGSize(width: 100, height: 50))
        XCTAssertEqual(tiny.visibleRows, 1)
        XCTAssertTrue(tiny.needsScroll)
    }
}
