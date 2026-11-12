import Foundation
import XCTest
@testable import WhisperM8

/// Stufenwähler und Flächenmessung als eigene View (Leistungsbefund
/// grid.build, 12.11.2026): Die Fläche darf nur bei echter Änderung
/// geschrieben werden, die Passt-Regel bleibt wie vorher.
@MainActor
final class GridCapacityPickerTests: XCTestCase {
    func testAreaBoxWritesOnlyRealChanges() {
        let box = GridAreaSizeBox()
        var changes = 0
        func observe() {
            withObservationTracking { _ = box.size } onChange: { changes += 1 }
        }
        observe()
        box.update(.zero)
        XCTAssertEqual(changes, 0, "gleicher Wert löst nichts aus")
        box.update(CGSize(width: 800, height: 600))
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(box.size, CGSize(width: 800, height: 600))
    }

    func testStageFitsMatchesGridGeometry() {
        let size = CGSize(width: 700, height: 450)
        XCTAssertTrue(GridCapacityPicker.stageFits(1, in: size))
        XCTAssertTrue(GridCapacityPicker.stageFits(4, in: size))
        XCTAssertFalse(GridCapacityPicker.stageFits(9, in: size), "drei Zeilen à 200 pt passen nicht")
        XCTAssertTrue(GridCapacityPicker.stageFits(9, in: .zero), "ungemessen: alles anbieten")
    }

    func testLiveSyncFingerprintFollowsArchiving() {
        var session = AgentChatSession(
            id: UUID(), provider: .claude, projectID: UUID(), title: "Chat",
            lastActivityAt: Date(timeIntervalSince1970: 1), createdManually: true
        )
        let before = ProjectViewLiveSync.sessionsFingerprint([session])
        XCTAssertEqual(before, ProjectViewLiveSync.sessionsFingerprint([session]))
        session.status = .archived
        XCTAssertNotEqual(before, ProjectViewLiveSync.sessionsFingerprint([session]))
        session.title = "Neuer Titel"
        XCTAssertEqual(ProjectViewLiveSync.sessionsFingerprint([session]),
                       ProjectViewLiveSync.sessionsFingerprint([session]))
    }
}
