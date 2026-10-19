import XCTest
@testable import WhisperM8

/// LR-AU-009: Status nicht nur über Farbe, VoiceOver-Texte.
final class AgentStatusAccessibilityTests: XCTestCase {
    private let visible: [AgentSessionRuntimeStatus] = [.working, .awaitingInput, .idle, .errored]

    func testEveryVisibleStatusHasDistinctNonEmptyLabelAndHelp() {
        let labels = visible.map { AgentStatusAccessibility.label(for: $0) ?? "" }
        XCTAssertFalse(labels.contains(""))
        XCTAssertEqual(Set(labels).count, labels.count)
        let helps = visible.map { AgentStatusAccessibility.help(for: $0) ?? "" }
        XCTAssertFalse(helps.contains(""))
        XCTAssertEqual(Set(helps).count, helps.count)
    }

    func testLabelsAreTheDocumentedFourWords() {
        XCTAssertEqual(AgentStatusAccessibility.label(for: .working), "Working")
        XCTAssertEqual(AgentStatusAccessibility.label(for: .awaitingInput), "Waiting for you")
        XCTAssertEqual(AgentStatusAccessibility.label(for: .idle), "Ready")
        XCTAssertEqual(AgentStatusAccessibility.label(for: .errored), "Error")
    }

    func testStoppedAndUnknownStaySilent() {
        XCTAssertNil(AgentStatusAccessibility.label(for: .stopped))
        XCTAssertNil(AgentStatusAccessibility.label(for: nil))
    }

    func testShapesAreDistinctWithoutColor() {
        let shapes = visible.map { AgentStatusAccessibility.shape(for: $0) }
        XCTAssertEqual(Set(shapes.map { "\($0)" }).count, shapes.count, "working/awaiting/idle/errored brauchen vier Formen")
        XCTAssertEqual(AgentStatusAccessibility.shape(for: .awaitingInput), .diamond)
    }

    func testRowSummaryHasTitleStatusAndProject() {
        XCTAssertEqual(
            AgentRowAccessibility.summary(title: "Fix login", status: .awaitingInput, project: "whisperm8"),
            "Fix login, Waiting for you, whisperm8")
        XCTAssertEqual(AgentRowAccessibility.summary(title: "Chat", status: nil, project: nil), "Chat")
        XCTAssertFalse(AgentRowAccessibility.summary(title: "Chat", status: .idle, project: "").isEmpty)
    }
}

/// Relative Zeiten laufen über `RelativeDateTimeFormatter` (LR-AU-030).
final class SidebarRelativeTimeLocalizedTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    func testEnglishAndGermanDiffer() {
        let date = now.addingTimeInterval(-5 * 60)
        let en = SidebarRelativeTime.short(date, now: now, locale: Locale(identifier: "en"))
        let de = SidebarRelativeTime.short(date, now: now, locale: Locale(identifier: "de"))
        XCTAssertTrue(en.contains("ago"), en)
        XCTAssertTrue(de.hasPrefix("vor"), de)
    }

    func testUnderAMinuteIsNow() {
        let en = SidebarRelativeTime.short(now.addingTimeInterval(-5), now: now, locale: Locale(identifier: "en"))
        XCTAssertEqual(en, "now")
    }
}
