import XCTest
@testable import WhisperM8

/// LR-AU-004: Mit nur importierten Projekten startete „Neuer Chat“ in einem
/// unsichtbaren Projekt.
final class AgentProjectSelectionResolverTests: XCTestCase {
    func testOnlyImportedProjectsGiveNoFallback() {
        let imported = AgentProject(name: "home", path: "/Users/x")
        XCTAssertNil(AgentProjectSelectionResolver.project(selectedID: nil, in: [imported]))
        XCTAssertTrue(AgentProjectSelectionResolver.initiallyExpandedIDs(in: [imported]).isEmpty)
    }

    func testFallbackIsAManualProjectAndExplicitSelectionWins() {
        let imported = AgentProject(name: "alt", path: "/Users/x/alt")
        var manual = AgentProject(name: "neu", path: "/Users/x/neu")
        manual.createdManually = true
        XCTAssertEqual(AgentProjectSelectionResolver.project(selectedID: nil, in: [imported, manual])?.id, manual.id)
        XCTAssertEqual(AgentProjectSelectionResolver.project(selectedID: imported.id, in: [imported, manual])?.id, imported.id)
        XCTAssertEqual(AgentProjectSelectionResolver.project(selectedID: UUID(), in: [imported, manual])?.id, manual.id)
    }
}

/// LR-AU-029: Der Leerzustand nannte „Resume“, obwohl der Knopf „Start“ hieß,
/// und zeigte Markdown-Sternchen wörtlich.
final class TranscriptEmptyStateTextTests: XCTestCase {
    func testDetailNamesTheActualButtonAndRendersBold() {
        let fresh = AgentChatSession(provider: .claude, projectID: UUID(), title: "Neu")
        XCTAssertEqual(TranscriptEmptyStateView.launchButtonLabel(for: fresh), "Start")
        var resumed = fresh
        resumed.externalSessionID = "abc"
        XCTAssertEqual(TranscriptEmptyStateView.launchButtonLabel(for: resumed), "Resume")

        let detail = TranscriptEmptyStateView.detailText(
            isOrphanedBackgroundChat: false, isTruncatedOnly: false, launchLabel: "Start", providerName: "Claude")
        XCTAssertTrue(detail.contains("Start"))
        XCTAssertFalse(detail.contains("Resume"))
        let rendered = String(TranscriptEmptyStateView.renderMarkdown(detail).characters)
        XCTAssertFalse(rendered.contains("**"))
    }
}

/// LR-AU-034: Ein Chat mit gelöschtem Verlauf bekommt einen dauerhaften Hinweis
/// statt „Klick Resume“.
final class TranscriptDeletedStateTests: XCTestCase {
    func testDeletedHistoryIsRecognized() {
        var session = AgentChatSession(provider: .claude, projectID: UUID(), title: "Alt")
        XCTAssertFalse(TranscriptEmptyStateView.isTranscriptDeleted(transcript: nil, session: session), "nie gestartet")
        session.externalSessionID = "abc"
        XCTAssertTrue(TranscriptEmptyStateView.isTranscriptDeleted(transcript: nil, session: session))
    }
}
