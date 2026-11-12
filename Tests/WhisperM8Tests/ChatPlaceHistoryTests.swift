import Foundation
import XCTest
@testable import WhisperM8

/// L2 getippt, „zurück dorthin, wo ich vorher war“: Gedächtnis der letzten
/// beiden Orte (Chat oder Workspace) und wie ein Fenster seinen Ort ergibt.
final class ChatPlaceHistoryTests: XCTestCase {
    private let a = ChatPlace.chat(UUID())
    private let b = ChatPlace.chat(UUID())
    private let c = ChatPlace.chat(UUID())
    private let w = ChatPlace.workspace(UUID())

    private let always: (ChatPlace) -> Bool = { _ in true }

    private func history(_ places: ChatPlace?...) -> ChatPlaceHistory {
        var history = ChatPlaceHistory()
        for place in places { history.record(place, isAvailable: always) }
        return history
    }

    // MARK: - Verlauf

    func testEmptyHistoryHasNoTarget() {
        XCTAssertNil(ChatPlaceHistory().target(isAvailable: always))
    }

    func testFirstPlaceAloneHasNoTarget() {
        XCTAssertNil(history(a).target(isAvailable: always))
    }

    func testSecondPlacePointsBackToFirst() {
        XCTAssertEqual(history(a, w).target(isAvailable: always), a)
        XCTAssertEqual(history(w, a).target(isAvailable: always), w)
    }

    /// Hin und her wie ein kurzes Alt-Tab: Nach dem Rücksprung ist der
    /// verlassene Ort das Ziel.
    func testJumpingBackAndForthAlternates() {
        var history = history(w, a)
        history.record(w, isAvailable: always)
        XCTAssertEqual(history.target(isAvailable: always), a)
        history.record(a, isAvailable: always)
        XCTAssertEqual(history.target(isAvailable: always), w)
    }

    func testOnlyTheLastTwoCount() {
        XCTAssertEqual(history(a, b, c).target(isAvailable: always), b)
    }

    func testRecordingSamePlaceAgainChangesNothing() {
        XCTAssertEqual(history(a, w, w).target(isAvailable: always), a)
    }

    /// Workspace gelöscht, Chat archiviert oder geschlossen: kein Ziel.
    func testUnavailableTargetIsNotOffered() {
        XCTAssertNil(history(w, a).target(isAvailable: { $0 != self.w }))
    }

    /// Kurz keine Auswahl (letzter Tab zu, dann neuer Chat): Der vorige Ort
    /// bleibt das Rücksprungziel.
    func testEmptySelectionKeepsPreviousAsTarget() {
        var history = history(a, nil)
        XCTAssertEqual(history.target(isAvailable: always), a)
        history.record(b, isAvailable: always)
        XCTAssertEqual(history.target(isAvailable: always), a)
    }

    /// Den aktuellen Ort schließen: Er wird nicht zum Ziel, L2 führt dorthin,
    /// wo man davor war.
    func testClosedCurrentPlaceDoesNotBecomeTarget() {
        var history = history(w, a)
        history.record(b, isAvailable: { $0 != self.a })
        XCTAssertEqual(history.target(isAvailable: always), w)
    }

    // MARK: - Ort eines Fensters

    func testVisibleGridIsTheWorkspace() {
        let workspace = UUID(), chat = UUID()
        XCTAssertEqual(
            ChatPlace.of(selectedSessionID: chat, showsGrid: true, workspaceID: workspace, isWorkspaceMember: { _ in true }),
            .workspace(workspace))
        // Auch ein leeres Raster ist ein Ort.
        XCTAssertEqual(
            ChatPlace.of(selectedSessionID: nil, showsGrid: true, workspaceID: workspace, isWorkspaceMember: { _ in false }),
            .workspace(workspace))
    }

    /// Kachel groß (L3): gehört weiter zum Workspace.
    func testMaximizedTileBelongsToTheWorkspace() {
        let workspace = UUID(), tile = UUID()
        XCTAssertEqual(
            ChatPlace.of(selectedSessionID: tile, showsGrid: false, workspaceID: workspace,
                         isWorkspaceMember: { $0 == tile }),
            .workspace(workspace))
    }

    /// Ein Chat außerhalb des gemerkten Workspace ist ein eigener Ort.
    func testOtherChatInSingleViewIsAChat() {
        let workspace = UUID(), chat = UUID()
        XCTAssertEqual(
            ChatPlace.of(selectedSessionID: chat, showsGrid: false, workspaceID: workspace, isWorkspaceMember: { _ in false }),
            .chat(chat))
        XCTAssertEqual(
            ChatPlace.of(selectedSessionID: chat, showsGrid: false, workspaceID: nil, isWorkspaceMember: { _ in true }),
            .chat(chat))
        XCTAssertNil(ChatPlace.of(selectedSessionID: nil, showsGrid: false, workspaceID: nil, isWorkspaceMember: { _ in true }))
    }

    /// Raster ohne gültigen Workspace gibt es nicht: dann zählt der Chat.
    func testGridWithoutWorkspaceFallsBackToChat() {
        let chat = UUID()
        XCTAssertEqual(
            ChatPlace.of(selectedSessionID: chat, showsGrid: true, workspaceID: nil, isWorkspaceMember: { _ in true }),
            .chat(chat))
    }
}
