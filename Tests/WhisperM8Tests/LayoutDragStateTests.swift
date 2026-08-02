import XCTest
@testable import WhisperM8

/// Prueft die Zug-Zustandsmaschine.
///
/// Der wichtigste Fall ist der unscheinbarste: **Ein Klick darf nicht
/// versehentlich zum Zug werden.** Wer eine Flaeche anklickt, zittert leicht —
/// wuerde das schon als Ziehen gelten, verschoebe sich bei jedem Klick etwas.
final class LayoutDragStateTests: XCTestCase {
    private let session = UUID()
    private let cellA = UUID(), cellB = UUID()

    private var frames: [UUID: CGRect] {
        [
            cellA: CGRect(x: 0, y: 0, width: 400, height: 400),
            cellB: CGRect(x: 400, y: 0, width: 400, height: 400),
        ]
    }

    // MARK: - Klick bleibt Klick

    func testMovementBelowThresholdStaysPending() {
        var state = LayoutDragState()
        state.begin(session: session, at: CGPoint(x: 100, y: 100))
        state.move(to: CGPoint(x: 102, y: 101), frames: frames, sourceCellID: cellA)

        XCTAssertFalse(state.isDragging, "2 Punkte Zittern sind kein Zug")
        XCTAssertNil(state.end(), "Ein Klick darf nichts anwenden")
    }

    func testMovementAtThresholdStartsDrag() {
        var state = LayoutDragState()
        state.begin(session: session, at: CGPoint(x: 100, y: 100))
        state.move(to: CGPoint(x: 104, y: 100), frames: frames, sourceCellID: cellA)
        XCTAssertTrue(state.isDragging)
    }

    /// Diagonal zaehlt die Strecke, nicht die einzelne Achse — sonst waeren
    /// 3 Punkte nach rechts UND 3 nach unten (Strecke 4,2) noch ein Klick.
    func testDiagonalMovementUsesDistance() {
        var state = LayoutDragState()
        state.begin(session: session, at: .zero)
        state.move(to: CGPoint(x: 3, y: 3), frames: frames, sourceCellID: nil)
        XCTAssertTrue(state.isDragging, "Strecke 4,24 liegt ueber der Schwelle")
    }

    func testMoveWithoutBeginDoesNothing() {
        var state = LayoutDragState()
        state.move(to: CGPoint(x: 500, y: 500), frames: frames, sourceCellID: nil)
        XCTAssertFalse(state.isDragging)
        XCTAssertNil(state.end())
    }

    // MARK: - Zielverfolgung

    func testTargetFollowsPointer() {
        var state = LayoutDragState()
        state.begin(session: session, at: CGPoint(x: 200, y: 200))
        state.move(to: CGPoint(x: 600, y: 200), frames: frames, sourceCellID: cellA)
        XCTAssertEqual(state.target, .stack(cellID: cellB))

        state.move(to: CGPoint(x: 795, y: 200), frames: frames, sourceCellID: cellA)
        XCTAssertEqual(state.target, .edge(cellID: cellB, edge: .trailing))
    }

    func testTargetIsNoneOutsideFrames() {
        var state = LayoutDragState()
        state.begin(session: session, at: CGPoint(x: 200, y: 200))
        state.move(to: CGPoint(x: 900, y: 900), frames: frames, sourceCellID: cellA)
        XCTAssertTrue(state.isDragging, "Der Zug laeuft weiter…")
        XCTAssertEqual(state.target, .none, "…hat aber kein Ziel")
    }

    /// Ohne Ziel darf beim Loslassen nichts passieren.
    func testEndWithoutTargetAppliesNothing() {
        var state = LayoutDragState()
        state.begin(session: session, at: CGPoint(x: 200, y: 200))
        state.move(to: CGPoint(x: 900, y: 900), frames: frames, sourceCellID: cellA)
        XCTAssertNil(state.end())
    }

    func testEndWithTargetReturnsIt() {
        var state = LayoutDragState()
        state.begin(session: session, at: CGPoint(x: 200, y: 200))
        state.move(to: CGPoint(x: 600, y: 200), frames: frames, sourceCellID: cellA)

        let ergebnis = state.end()
        XCTAssertEqual(ergebnis?.session, session)
        XCTAssertEqual(ergebnis?.target, .stack(cellID: cellB))
    }

    // MARK: - Aufraeumen

    func testStateResetsAfterEnd() {
        var state = LayoutDragState()
        state.begin(session: session, at: CGPoint(x: 200, y: 200))
        state.move(to: CGPoint(x: 600, y: 200), frames: frames, sourceCellID: cellA)
        _ = state.end()

        XCTAssertFalse(state.isDragging)
        XCTAssertEqual(state.target, .none)
        XCTAssertNil(state.draggedSession)
    }

    func testCancelDiscardsEverything() {
        var state = LayoutDragState()
        state.begin(session: session, at: CGPoint(x: 200, y: 200))
        state.move(to: CGPoint(x: 600, y: 200), frames: frames, sourceCellID: cellA)
        state.cancel()

        XCTAssertFalse(state.isDragging)
        XCTAssertNil(state.end(), "Nach dem Abbruch darf nichts mehr angewendet werden")
    }

    /// Zweimal beenden darf nicht zweimal anwenden — sonst landete ein Chat
    /// bei einem verschluckten Ereignis doppelt.
    func testEndIsIdempotent() {
        var state = LayoutDragState()
        state.begin(session: session, at: CGPoint(x: 200, y: 200))
        state.move(to: CGPoint(x: 600, y: 200), frames: frames, sourceCellID: cellA)

        XCTAssertNotNil(state.end())
        XCTAssertNil(state.end())
    }

    // MARK: - Zusammenspiel mit der Engine

    /// Der ganze Weg: ziehen, loslassen, anwenden — und das Ergebnis ist
    /// gueltig.
    func testFullDragAppliesToLayout() {
        let a = UUID(), b = UUID()
        let layout = WorkspaceLayout(cells: [
            WorkspaceLayout.Cell(id: cellA, session: a),
            WorkspaceLayout.Cell(id: cellB, session: b),
        ])

        var state = LayoutDragState()
        state.begin(session: a, at: CGPoint(x: 200, y: 200))
        state.move(to: CGPoint(x: 600, y: 200), frames: frames, sourceCellID: cellA)

        guard let ergebnis = state.end() else { return XCTFail("Zug lieferte kein Ziel") }
        let result = LayoutDropResolver.apply(ergebnis.target, session: ergebnis.session, to: layout)

        XCTAssertEqual(result.cells.count, 1, "a wandert zu b, die alte Zelle faellt weg")
        XCTAssertEqual(result.cells.first?.sessions, [b, a])
        XCTAssertEqual(LayoutNormalizer.normalize(result), result)
    }
}
