import XCTest
@testable import WhisperM8

/// Prueft die Uebersetzung v4 → v5.
///
/// Die Migration ist die einzige unumkehrbare Stelle des Umbaus. Der Anspruch
/// ist deshalb nicht „laeuft durch", sondern: **Jeder Chat liegt danach exakt
/// dort, wo er vorher lag.** Wer sein Raster muehsam gebaut hat, darf davon
/// nichts merken.
final class WorkspaceLayoutMigrationTests: XCTestCase {
    private let s1 = UUID(), s2 = UUID(), s3 = UUID(), s4 = UUID()

    private func old(
        slots: [UUID?],
        capacity: Int,
        columns: [Double]? = nil,
        rows: [Double]? = nil
    ) -> AgentGridWorkspace {
        AgentGridWorkspace(
            id: UUID(),
            name: "Test",
            colorHex: "#6E6ADE",
            slots: slots,
            capacity: capacity,
            columnFractions: columns ?? AgentGridWorkspace.equalFractions(
                count: AgentGridWorkspace.columns(forCapacity: capacity)),
            rowFractions: rows ?? AgentGridWorkspace.equalFractions(
                count: AgentGridWorkspace.rows(forCapacity: capacity))
        )
    }

    // MARK: - Inhalt bleibt erhalten

    func testAllSessionsSurviveMigration() {
        let result = WorkspaceLayoutMigration.migrate(old(slots: [s1, s2, s3, s4], capacity: 4))
        XCTAssertEqual(Set(result.allSessions), [s1, s2, s3, s4])
    }

    func testIdentityAndNameAreKept() {
        let source = old(slots: [s1], capacity: 2)
        let result = WorkspaceLayoutMigration.migrate(source)
        XCTAssertEqual(result.id, source.id, "Die Entity bleibt dieselbe — Fensterbezüge zeigen weiter darauf")
        XCTAssertEqual(result.name, source.name)
        XCTAssertEqual(result.colorHex, source.colorHex)
    }

    /// `nil`-Slots waren nie Inhalt, sondern Luecke. Sie zu uebernehmen hiesse,
    /// den Konstruktionsfehler mitzunehmen.
    func testEmptySlotsBecomeNothing() {
        let result = WorkspaceLayoutMigration.migrate(old(slots: [s1, nil, s2, nil], capacity: 4))
        XCTAssertEqual(result.cells.count, 2)
        XCTAssertEqual(result.allSessions, [s1, s2])
    }

    func testCompletelyEmptyWorkspaceBecomesEmptyLayout() {
        let result = WorkspaceLayoutMigration.migrate(old(slots: [nil, nil], capacity: 2))
        XCTAssertTrue(result.cells.isEmpty)
        XCTAssertTrue(result.arrangement.isAutomatic)
    }

    /// Sessions jenseits der sichtbaren Kapazitaet gab es regulaer nicht —
    /// falls die Datei sie doch traegt, duerfen sie nicht verschwinden.
    func testSessionsBeyondCapacityAreKept() {
        let result = WorkspaceLayoutMigration.migrate(old(slots: [s1, s2, s3], capacity: 2))
        XCTAssertEqual(Set(result.allSessions), [s1, s2, s3])
    }

    // MARK: - Anordnung bleibt erhalten

    /// Die zentrale Zusage: Der Bestand wird nicht umgeordnet.
    func testExistingArrangementBecomesManual() {
        let result = WorkspaceLayoutMigration.migrate(old(slots: [s1, s2], capacity: 2))
        XCTAssertFalse(result.arrangement.isAutomatic,
                       "Bestand muss manuell bleiben, sonst ordnet das Update ungefragt um")
    }

    /// Bei einer einzigen Zelle gibt es keine Aufteilung, die zu bewahren
    /// waere — dann ist `automatic` ehrlicher.
    func testSingleCellStaysAutomatic() {
        let result = WorkspaceLayoutMigration.migrate(old(slots: [s1, nil], capacity: 2))
        XCTAssertTrue(result.arrangement.isAutomatic)
    }

    /// Zwei Plaetze nebeneinander ergeben dieselbe Geometrie wie vorher.
    func testTwoSlotsKeepSideBySideGeometry() {
        let source = old(slots: [s1, s2], capacity: 2, columns: [0.7, 0.3])
        let layout = WorkspaceLayoutMigration.migrate(source)
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 500)
        let frames = LayoutGeometry.frames(for: layout, in: bounds)

        let sortiert = frames.values.sorted { $0.minX < $1.minX }
        XCTAssertEqual(sortiert.count, 2)
        XCTAssertEqual(sortiert[0].width, 700, accuracy: 1, "Gewichte bleiben erhalten")
        XCTAssertEqual(sortiert[1].width, 300, accuracy: 1)
    }

    /// 2×2 bleibt 2×2 — und die Flaeche wird lueckenlos gefuellt.
    func testFourSlotsKeepGridGeometry() {
        let layout = WorkspaceLayoutMigration.migrate(old(slots: [s1, s2, s3, s4], capacity: 4))
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let frames = LayoutGeometry.frames(for: layout, in: bounds)

        XCTAssertEqual(frames.count, 4)
        let flaeche = frames.values.reduce(0) { $0 + $1.width * $1.height }
        XCTAssertEqual(flaeche, bounds.width * bounds.height, accuracy: 1)

        // Zwei oben, zwei unten
        let obere = frames.values.filter { $0.minY < 1 }
        XCTAssertEqual(obere.count, 2)
    }

    /// Der Sonderfall des alten Modells: „zwei oben, einer breit unten".
    func testThreeSlotsKeepWideBottomCell() {
        let layout = WorkspaceLayoutMigration.migrate(old(slots: [s1, s2, s3], capacity: 3))
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let frames = LayoutGeometry.frames(for: layout, in: bounds)

        XCTAssertEqual(frames.count, 3)
        let unten = frames.values.filter { $0.minY > 1 }
        XCTAssertEqual(unten.count, 1, "Unten liegt genau eine Zelle")
        XCTAssertEqual(unten.first?.width ?? 0, 1000, accuracy: 1, "…und sie ist voll breit")

        let flaeche = frames.values.reduce(0) { $0 + $1.width * $1.height }
        XCTAssertEqual(flaeche, bounds.width * bounds.height, accuracy: 1)
    }

    func testNineSlotsKeepThreeByThree() {
        let sessions = (0..<9).map { _ in UUID() }
        let layout = WorkspaceLayoutMigration.migrate(old(slots: sessions, capacity: 9))
        let bounds = CGRect(x: 0, y: 0, width: 900, height: 900)
        let frames = LayoutGeometry.frames(for: layout, in: bounds)

        XCTAssertEqual(frames.count, 9)
        for frame in frames.values {
            XCTAssertEqual(frame.width, 300, accuracy: 1)
            XCTAssertEqual(frame.height, 300, accuracy: 1)
        }
    }

    /// Ein Raster mit Luecken darf keine leeren Flaechen erzeugen — die
    /// verbliebenen Chats fuellen den Platz.
    func testGridWithGapsProducesNoEmptyAreas() {
        let layout = WorkspaceLayoutMigration.migrate(old(slots: [s1, nil, nil, s2], capacity: 4))
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let frames = LayoutGeometry.frames(for: layout, in: bounds)

        XCTAssertEqual(frames.count, 2)
        let flaeche = frames.values.reduce(0) { $0 + $1.width * $1.height }
        XCTAssertEqual(flaeche, bounds.width * bounds.height, accuracy: 1,
                       "Die Luecke des alten Rasters darf nicht als leere Flaeche ueberleben")
    }

    // MARK: - Robustheit

    func testInvalidFractionsDoNotProduceBrokenLayout() {
        let source = old(slots: [s1, s2], capacity: 2, columns: [.nan, 0])
        let layout = WorkspaceLayoutMigration.migrate(source)
        let frames = LayoutGeometry.frames(for: layout, in: CGRect(x: 0, y: 0, width: 1000, height: 500))
        for frame in frames.values {
            XCTAssertTrue(frame.width.isFinite && frame.width > 0, "Flaeche mit Breite 0 oder NaN")
        }
    }

    func testMigrationResultIsNormalized() {
        let layout = WorkspaceLayoutMigration.migrate(old(slots: [s1, s2, s3], capacity: 3))
        XCTAssertEqual(LayoutNormalizer.normalize(layout), layout)
    }

    func testMigratingSeveralWorkspacesKeepsOrder() {
        let a = old(slots: [s1], capacity: 2)
        let b = old(slots: [s2], capacity: 2)
        let result = WorkspaceLayoutMigration.migrate([a, b])
        XCTAssertEqual(result.map(\.id), [a.id, b.id])
    }

    // MARK: - Einbindung in den Schema-Pfad

    func testStateMigrationFillsLayoutsOnce() {
        var state = AgentUIState(
            schemaVersion: 4,
            gridWorkspaces: [old(slots: [s1, s2], capacity: 2)]
        )
        state.migrateIfNeeded(workspace: .empty)

        XCTAssertEqual(state.schemaVersion, AgentUIState.currentSchemaVersion)
        XCTAssertEqual(state.layouts.count, 1)
        XCTAssertEqual(Set(state.layouts[0].allSessions), [s1, s2])

        // Ein zweiter Lauf muss dasselbe Ergebnis liefern — sonst waere jedes
        // Laden eine Aenderung, und in SwiftUI hiesse das neu gebaute
        // Ansichten samt neuer Terminals.
        let vorher = state.layouts
        state.migrateIfNeeded(workspace: .empty)
        XCTAssertEqual(state.layouts, vorher, "Ableitung muss deterministisch sein")
    }

    /// **Uebergangszustand:** Solange die Oberflaeche noch `gridWorkspaces`
    /// schreibt, wird `layouts` bei jedem Laden daraus abgeleitet. Sonst
    /// driften beide auseinander, sobald nach der Migration jemand einen Chat
    /// verschiebt — und der spaetere Umstieg uebernaehme eine veraltete
    /// Anordnung.
    ///
    /// Dieser Test kehrt sich mit S6 um: Ab dann ist `layouts` fuehrend und
    /// darf nicht mehr ueberschrieben werden.
    func testStateMigrationDerivesLayoutsFromGridWorkspaces() {
        let bestehend = WorkspaceLayout(cells: [WorkspaceLayout.Cell(session: s3)])
        var state = AgentUIState(
            schemaVersion: 4,
            gridWorkspaces: [old(slots: [s1, s2], capacity: 2)],
            layouts: [bestehend]
        )
        state.migrateIfNeeded(workspace: .empty)
        XCTAssertEqual(state.layouts.map { Set($0.allSessions) }, [[s1, s2]],
                       "Die Ableitung gewinnt, solange gridWorkspaces fuehrend ist")
    }

    /// Zell-IDs muessen aus dem Inhalt folgen, nicht zufaellig sein — sonst
    /// bekaeme jede Ableitung neue Identitaeten.
    func testCellIDsAreDeterministic() {
        let source = old(slots: [s1, s2], capacity: 2)
        let a = WorkspaceLayoutMigration.migrate(source)
        let b = WorkspaceLayoutMigration.migrate(source)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.cells.map(\.id), [s1, s2], "Zell-ID folgt der Session")
    }
}
