import SwiftUI
import XCTest
@testable import WhisperM8

/// Prueft, wie sich eine Zeile auf die Spalten-Spuren aufteilt.
///
/// Der Fehler, den diese Tests fuer immer ausschliessen sollen: Der Renderer
/// lief stur `rows × columns` durch und zeichnete dadurch Flaechen fuer Slots,
/// die es im Modell nicht gibt — bei fuenf Chats ein „Slot 6", das jeden Drop
/// ablehnte und nebenbei die Growzone unterdrueckte.
///
/// Die zweite Zusicherung ist die spurenbuendige Verteilung: Jeder Block endet
/// auf einer Spaltengrenze. Nur so bleiben die Trennlinien gerade und die
/// Spalten-Griffe gueltig.
final class GridRowBlockTests: XCTestCase {

    private func blocks(_ capacity: Int, row: Int) -> [AgentGridSplitContainer<EmptyView>.RowBlock] {
        AgentGridSplitContainer<EmptyView>.blocks(
            inRow: row, layout: AgentGridAutoLayout.forCapacity(capacity)
        )
    }

    // MARK: - Keine Phantom-Slots

    /// Die Kernzusicherung: Ueber alle Zeilen zusammen entstehen exakt so
    /// viele Panes, wie der Workspace Slots hat — nie mehr.
    func testTotalPanesNeverExceedCapacity() {
        for capacity in AgentGridWorkspace.allowedCapacities {
            let layout = AgentGridAutoLayout.forCapacity(capacity)
            let slots = (0 ..< layout.rows).flatMap { blocks(capacity, row: $0).map(\.slot) }

            XCTAssertEqual(slots.count, capacity, "Kapazitaet \(capacity): Anzahl Panes")
            XCTAssertEqual(slots.sorted(), Array(0 ..< capacity),
                           "Kapazitaet \(capacity): jeder Slot genau einmal, keine Phantome")
        }
    }

    // MARK: - Spurenbuendig und lueckenlos

    func testBlocksCoverEveryTrackWithoutOverlap() {
        for capacity in AgentGridWorkspace.allowedCapacities {
            let layout = AgentGridAutoLayout.forCapacity(capacity)
            for row in 0 ..< layout.rows {
                let reihe = blocks(capacity, row: row)
                guard !reihe.isEmpty else { continue }
                let spuren = reihe.flatMap { Array($0.tracks) }

                XCTAssertEqual(spuren.sorted(), Array(0 ..< layout.columns),
                               "Kapazitaet \(capacity), Zeile \(row): Spuren lueckenlos und ohne Ueberlappung")
                XCTAssertEqual(reihe.first?.tracks.lowerBound, 0, "Zeile beginnt links")
                XCTAssertEqual(reihe.last?.tracks.upperBound, layout.columns - 1, "Zeile endet rechts")
            }
        }
    }

    func testBlocksAreContiguousInReadingOrder() {
        for capacity in AgentGridWorkspace.allowedCapacities {
            let layout = AgentGridAutoLayout.forCapacity(capacity)
            for row in 0 ..< layout.rows {
                let reihe = blocks(capacity, row: row)
                for (links, rechts) in zip(reihe, reihe.dropFirst()) {
                    XCTAssertEqual(rechts.tracks.lowerBound, links.tracks.upperBound + 1,
                                   "Kapazitaet \(capacity), Zeile \(row): Bloecke stossen aneinander")
                    XCTAssertEqual(rechts.slot, links.slot + 1, "Slots in Lesereihenfolge")
                }
            }
        }
    }

    // MARK: - Die konkreten Faelle

    /// Drei Chats bleiben exakt wie bisher: zwei oben, einer ueber die volle
    /// Breite. Das war frueher ein Sonderfall im Renderer.
    func testThreeChatsKeepTheWideBottomPane() {
        XCTAssertEqual(blocks(3, row: 0).map(\.tracks), [0 ... 0, 1 ... 1])
        XCTAssertEqual(blocks(3, row: 1).map(\.tracks), [0 ... 1])
        XCTAssertEqual(blocks(3, row: 1).map(\.slot), [2])
    }

    /// Der Fall aus dem Nutzerbefund: fuenf Chats, kein leerer Platz.
    func testFiveChatsFillTheBottomRow() {
        XCTAssertEqual(blocks(5, row: 0).map(\.slot), [0, 1, 2])
        XCTAssertEqual(blocks(5, row: 1).map(\.slot), [3, 4])
        // Der Rest wandert nach vorn: unten links zwei Spuren, rechts eine.
        XCTAssertEqual(blocks(5, row: 1).map(\.tracks), [0 ... 1, 2 ... 2])
    }

    func testSevenChatsEndWithOneWidePane() {
        XCTAssertEqual(blocks(7, row: 2).map(\.slot), [6])
        XCTAssertEqual(blocks(7, row: 2).map(\.tracks), [0 ... 2])
    }

    func testEightChatsEndWithTwoPanes() {
        XCTAssertEqual(blocks(8, row: 2).map(\.slot), [6, 7])
        XCTAssertEqual(blocks(8, row: 2).map(\.tracks), [0 ... 1, 2 ... 2])
    }

    func testFullStagesUseOneTrackPerPane() {
        for capacity in [2, 4, 6, 9] {
            let layout = AgentGridAutoLayout.forCapacity(capacity)
            for row in 0 ..< layout.rows {
                XCTAssertTrue(blocks(capacity, row: row).allSatisfy { $0.tracks.count == 1 },
                              "Kapazitaet \(capacity): volle Zeilen brauchen keine Bloecke")
            }
        }
    }

    /// Zeilen jenseits der Kapazitaet gibt es nicht — der alte Renderer
    /// erzeugte hier die Geisterflaechen.
    func testRowsBeyondCapacityAreEmpty() {
        XCTAssertTrue(blocks(5, row: 2).isEmpty)
        XCTAssertTrue(blocks(2, row: 1).isEmpty)
    }
}
