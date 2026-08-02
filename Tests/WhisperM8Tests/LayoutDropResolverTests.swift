import XCTest
@testable import WhisperM8

/// Prueft die Zug-Zielbestimmung — jede Zone, jede Kante, jeder Randfall.
///
/// Die Maus-Interaktion selbst laesst sich nicht automatisiert pruefen, die
/// Entscheidung „was passiert beim Loslassen" dagegen schon. Genau dort sitzen
/// die Fehler, die man sonst erst im Betrieb bemerkt.
final class LayoutDropResolverTests: XCTestCase {
    private let cellA = UUID(), cellB = UUID()

    /// Eine Flaeche, gross genug dass Kante und Kern klar getrennt sind.
    private var frames: [UUID: CGRect] {
        [
            cellA: CGRect(x: 0, y: 0, width: 400, height: 400),
            cellB: CGRect(x: 400, y: 0, width: 400, height: 400),
        ]
    }

    // MARK: - Zonen

    func testCenterStacks() {
        let ziel = LayoutDropResolver.resolve(point: CGPoint(x: 200, y: 200), frames: frames)
        XCTAssertEqual(ziel, .stack(cellID: cellA))
    }

    /// Zwischen Kern und Kante liegt der Ring — dort wird ersetzt.
    func testRingReplaces() {
        // 400 breit: Kante bis 64 (18 % = 72, gedeckelt auf 64),
        // Kern von 100 bis 300. Also liegt x=80 im Ring.
        let ziel = LayoutDropResolver.resolve(point: CGPoint(x: 80, y: 200), frames: frames)
        XCTAssertEqual(ziel, .replace(cellID: cellA))
    }

    func testLeadingEdge() {
        let ziel = LayoutDropResolver.resolve(point: CGPoint(x: 10, y: 200), frames: frames)
        XCTAssertEqual(ziel, .edge(cellID: cellA, edge: .leading))
    }

    func testTrailingEdge() {
        let ziel = LayoutDropResolver.resolve(point: CGPoint(x: 395, y: 200), frames: frames)
        XCTAssertEqual(ziel, .edge(cellID: cellA, edge: .trailing))
    }

    func testTopEdge() {
        let ziel = LayoutDropResolver.resolve(point: CGPoint(x: 200, y: 5), frames: frames)
        XCTAssertEqual(ziel, .edge(cellID: cellA, edge: .top))
    }

    func testBottomEdge() {
        let ziel = LayoutDropResolver.resolve(point: CGPoint(x: 200, y: 396), frames: frames)
        XCTAssertEqual(ziel, .edge(cellID: cellA, edge: .bottom))
    }

    /// In der Ecke sind zwei Kanten getroffen — die naeherliegende gewinnt,
    /// damit das Ergebnis nicht von der Prueferreihenfolge abhaengt.
    func testCornerPicksNearerEdge() {
        let nahLinks = LayoutDropResolver.resolve(point: CGPoint(x: 3, y: 20), frames: frames)
        XCTAssertEqual(nahLinks, .edge(cellID: cellA, edge: .leading))

        let nahOben = LayoutDropResolver.resolve(point: CGPoint(x: 20, y: 3), frames: frames)
        XCTAssertEqual(nahOben, .edge(cellID: cellA, edge: .top))
    }

    // MARK: - Zuordnung zur richtigen Flaeche

    func testResolvesToCorrectCell() {
        let ziel = LayoutDropResolver.resolve(point: CGPoint(x: 600, y: 200), frames: frames)
        XCTAssertEqual(ziel, .stack(cellID: cellB))
    }

    func testPointOutsideAllFrames() {
        let ziel = LayoutDropResolver.resolve(point: CGPoint(x: 900, y: 900), frames: frames)
        XCTAssertEqual(ziel, .none)
    }

    /// Ein Chat auf seine eigene Flaeche zu ziehen ergaebe nichts.
    func testSourceCellIsExcluded() {
        let ziel = LayoutDropResolver.resolve(
            point: CGPoint(x: 200, y: 200), frames: frames, excluding: cellA
        )
        XCTAssertEqual(ziel, .none, "Die Quellflaeche darf kein Ziel sein")
    }

    // MARK: - Determinismus

    /// Ohne feste Sortierung haenge das Ergebnis von der
    /// Dictionary-Reihenfolge ab — die wechselt zwischen Laeufen.
    func testResultIsDeterministicForOverlappingFrames() {
        let ueberlappend: [UUID: CGRect] = [
            cellA: CGRect(x: 0, y: 0, width: 400, height: 400),
            cellB: CGRect(x: 0, y: 0, width: 400, height: 400),
        ]
        let ergebnisse = (0..<20).map { _ in
            LayoutDropResolver.resolve(point: CGPoint(x: 200, y: 200), frames: ueberlappend)
        }
        XCTAssertTrue(ergebnisse.allSatisfy { $0 == ergebnisse[0] },
                      "Ergebnis schwankt zwischen Laeufen")
    }

    // MARK: - Randfaelle

    func testEmptyFramesYieldNone() {
        XCTAssertEqual(LayoutDropResolver.resolve(point: .zero, frames: [:]), .none)
    }

    func testZeroSizedFrameYieldsNone() {
        let entartet = [cellA: CGRect(x: 0, y: 0, width: 0, height: 0)]
        XCTAssertEqual(LayoutDropResolver.resolve(point: .zero, frames: entartet), .none)
    }

    /// Bei sehr schmalen Flaechen darf die Kante nicht die ganze Breite
    /// verschlucken — sonst waere Ersetzen unerreichbar.
    func testNarrowFrameStillHasCenter() {
        let schmal = [cellA: CGRect(x: 0, y: 0, width: 100, height: 400)]
        let mitte = LayoutDropResolver.resolve(point: CGPoint(x: 50, y: 200), frames: schmal)
        XCTAssertEqual(mitte, .stack(cellID: cellA), "Die Mitte muss treffbar bleiben")
    }

    // MARK: - Anwendung aufs Layout

    func testApplyStackPutsSessionOnStack() {
        let session = UUID(), fremd = UUID()
        let layout = WorkspaceLayout(cells: [WorkspaceLayout.Cell(id: cellA, session: session)])
        let result = LayoutDropResolver.apply(.stack(cellID: cellA), session: fremd, to: layout)
        XCTAssertEqual(result.cells.first?.sessions, [session, fremd])
    }

    func testApplyReplaceSwapsContent() {
        let session = UUID(), fremd = UUID()
        let layout = WorkspaceLayout(cells: [WorkspaceLayout.Cell(id: cellA, session: session)])
        let result = LayoutDropResolver.apply(.replace(cellID: cellA), session: fremd, to: layout)
        XCTAssertEqual(result.cells.first?.sessions, [fremd])
    }

    /// Wer die Kante trifft, bestimmt die Anordnung selbst — sie wird manuell.
    func testApplyEdgeCreatesCellAndTurnsManual() {
        let session = UUID(), fremd = UUID()
        let layout = WorkspaceLayout(cells: [WorkspaceLayout.Cell(id: cellA, session: session)])
        let result = LayoutDropResolver.apply(
            .edge(cellID: cellA, edge: .trailing), session: fremd, to: layout
        )
        XCTAssertEqual(result.cells.count, 2)
        XCTAssertFalse(result.arrangement.isAutomatic)
    }

    func testApplyNoneChangesNothing() {
        let layout = WorkspaceLayout(cells: [WorkspaceLayout.Cell(id: cellA, session: UUID())])
        XCTAssertEqual(LayoutDropResolver.apply(.none, session: UUID(), to: layout), layout)
    }

    /// Der Vertrag gilt auch hier: Was herauskommt, ist normalisiert.
    func testApplyAlwaysReturnsNormalizedLayout() {
        let session = UUID(), fremd = UUID()
        let layout = WorkspaceLayout(cells: [WorkspaceLayout.Cell(id: cellA, session: session)])
        for ziel: LayoutDropResolver.Target in [
            .stack(cellID: cellA), .replace(cellID: cellA),
            .edge(cellID: cellA, edge: .bottom),
        ] {
            let result = LayoutDropResolver.apply(ziel, session: fremd, to: layout)
            XCTAssertEqual(LayoutNormalizer.normalize(result), result, "\(ziel)")
        }
    }
}
