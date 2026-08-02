import XCTest
@testable import WhisperM8

/// Prueft die Engine-Operationen — Normalfall und Randfall je Funktion.
///
/// Die Engine ist der Kern des Workspace-Umbaus: Wenn sie stimmt, ist der
/// spaetere Umbau der Oberflaeche mechanisch. Deshalb wird hier auch das
/// Verhalten geprueft, das die ENTSCHEIDUNGEN aus dem Plan festlegen — nicht
/// nur die technische Korrektheit.
final class LayoutEngineTests: XCTestCase {
    private let a = UUID(), b = UUID(), c = UUID(), d = UUID()

    private func layout(_ sessions: [UUID]) -> WorkspaceLayout {
        WorkspaceLayout(cells: sessions.map { WorkspaceLayout.Cell(session: $0) })
    }

    // MARK: - add

    func testAddCreatesOwnCellWhenAutomatic() {
        let result = LayoutEngine.add(b, to: layout([a]))
        XCTAssertEqual(result.cells.count, 2)
        XCTAssertEqual(result.cells.map(\.active), [a, b])
    }

    /// Bei manueller Anordnung wuerde eine neue Zelle den Baum des Nutzers
    /// sprengen — deshalb landet der Chat auf dem Stapel der fokussierten
    /// Zelle. Automatik ordnet Unentschiedenes, ueberschreibt aber nie
    /// Entschiedenes.
    func testAddStacksWhenManual() {
        var base = layout([a, b])
        base.arrangement = .manual(LayoutEngine.automaticTree(for: base.cells))
        let result = LayoutEngine.add(c, to: base, focused: a)

        XCTAssertEqual(result.cells.count, 2, "Keine neue Zelle bei manueller Anordnung")
        XCTAssertEqual(result.cells[0].sessions, [a, c])
        XCTAssertEqual(result.cells[0].active, c)
        XCTAssertEqual(result.bindings[c], a, "Bewusste Stapelung wird gemerkt")
    }

    func testAddIsIdempotentForExistingSession() {
        let base = layout([a, b])
        XCTAssertEqual(LayoutEngine.add(a, to: base), base)
    }

    func testAddToEmptyLayout() {
        let result = LayoutEngine.add(a, to: WorkspaceLayout())
        XCTAssertEqual(result.cells.count, 1)
        XCTAssertEqual(result.cells.first?.active, a)
    }

    // MARK: - remove (E10)

    /// Das × am Tab nimmt den Chat nur aus DIESEM Workspace — er laeuft weiter.
    func testRemoveDropsCellAndCompacts() {
        let result = LayoutEngine.remove(b, from: layout([a, b, c]))
        XCTAssertEqual(result.cells.count, 2)
        XCTAssertEqual(result.cells.map(\.active), [a, c], "Kein Loch, kein Platzhalter")
    }

    func testRemoveFromStackKeepsCell() {
        var base = layout([a])
        base.cells[0].sessions = [a, b]
        let result = LayoutEngine.remove(b, from: base)
        XCTAssertEqual(result.cells.count, 1)
        XCTAssertEqual(result.cells[0].sessions, [a])
        XCTAssertEqual(result.cells[0].active, a, "Aktiver Chat wird nachgezogen")
    }

    func testRemoveLastSessionEmptiesLayout() {
        XCTAssertTrue(LayoutEngine.remove(a, from: layout([a])).cells.isEmpty)
    }

    func testRemoveUnknownSessionChangesNothing() {
        let base = layout([a, b])
        XCTAssertEqual(LayoutEngine.remove(UUID(), from: base), base)
    }

    /// Bei abgeleiteten Layouts waere echtes Entfernen sinnlos — die
    /// Mitgliedschaft folgt dem Projekt und kaeme beim naechsten Abgleich
    /// zurueck. Deshalb ausblenden.
    func testRemoveHidesInDerivedLayout() {
        var base = layout([a, b])
        base.source = .project(UUID())
        let result = LayoutEngine.remove(b, from: base)
        XCTAssertEqual(result.cells.count, 1)
        XCTAssertEqual(result.hidden, [b])
    }

    // MARK: - purge (E8)

    /// Zwingende Folge aus E8: Ein beendeter Chat muss aus ALLEN Layouts
    /// verschwinden — sonst bleibt eine Leiche in einem Workspace zurueck, den
    /// man gerade nicht ansieht.
    func testPurgeRemovesFromEveryLayout() {
        let layouts = [layout([a, b]), layout([b, c]), layout([d])]
        let result = LayoutEngine.purge(b, from: layouts)

        XCTAssertEqual(result[0].allSessions, [a])
        XCTAssertEqual(result[1].allSessions, [c])
        XCTAssertEqual(result[2].allSessions, [d], "Unbeteiligtes Layout bleibt unberuehrt")
    }

    func testPurgeAlsoClearsHidden() {
        var derived = layout([a])
        derived.source = .project(UUID())
        derived.hidden = [b]
        let result = LayoutEngine.purge(b, from: [derived])
        XCTAssertTrue(result[0].hidden.isEmpty, "Ausgeblendeter, beendeter Chat waere eine zweite Leiche")
    }

    // MARK: - swap

    func testSwapExchangesOrderWhenAutomatic() {
        let base = layout([a, b, c])
        let result = LayoutEngine.swap(base.cells[0].id, base.cells[2].id, in: base)
        XCTAssertEqual(result.cells.map(\.active), [c, b, a])
    }

    /// Bei manueller Anordnung tauschen nur die Blaetter — die eingestellten
    /// Groessen bleiben an ihrem Platz.
    func testSwapKeepsTreeShapeWhenManual() {
        var base = layout([a, b])
        let idA = base.cells[0].id, idB = base.cells[1].id
        base.arrangement = .manual(.split(axis: .horizontal,
                                          children: [.leaf(cellID: idA), .leaf(cellID: idB)],
                                          fractions: [0.7, 0.3]))
        let result = LayoutEngine.swap(idA, idB, in: base)

        guard case let .split(_, _, fractions) = result.arrangement.tree else {
            return XCTFail("Baumform muss erhalten bleiben")
        }
        XCTAssertEqual(fractions, [0.7, 0.3], "Groessen bleiben, Inhalte tauschen")
        XCTAssertEqual(result.arrangement.tree?.leafIDs, [idB, idA])
    }

    func testSwapWithUnknownCellChangesNothing() {
        let base = layout([a, b])
        XCTAssertEqual(LayoutEngine.swap(base.cells[0].id, UUID(), in: base), base)
    }

    // MARK: - drop (F2)

    func testDropReplacesContent() {
        let base = layout([a, b])
        let result = LayoutEngine.drop(c, onto: base.cells[1].id, mode: .replace, in: base)
        XCTAssertEqual(result.cells.count, 2)
        XCTAssertEqual(result.cells[1].sessions, [c])
        XCTAssertFalse(result.allSessions.contains(b), "Der Verdraengte ist nicht mehr Mitglied")
    }

    func testDropStacksOntoCell() {
        let base = layout([a, b])
        let result = LayoutEngine.drop(c, onto: base.cells[0].id, mode: .stack, in: base)
        XCTAssertEqual(result.cells[0].sessions, [a, c])
        XCTAssertEqual(result.cells[0].active, c)
        XCTAssertEqual(result.bindings[c], a)
    }

    /// Ein Chat aus demselben Layout darf nicht doppelt auftauchen.
    func testDropMovesSessionFromItsOldCell() {
        let base = layout([a, b, c])
        let result = LayoutEngine.drop(a, onto: base.cells[2].id, mode: .stack, in: base)
        XCTAssertEqual(result.cells.count, 2, "Die alte Zelle von a faellt weg")
        XCTAssertEqual(result.allSessions.filter { $0 == a }.count, 1)
    }

    // MARK: - insert (E7)

    /// Wer eine Kante trifft, will genau dort etwas haben — deshalb wird die
    /// Anordnung dabei manuell.
    func testInsertAtEdgeCreatesCellAndTurnsManual() {
        let base = layout([a, b])
        let result = LayoutEngine.insert(c, atEdge: .trailing, of: base.cells[0].id, in: base)

        XCTAssertEqual(result.cells.count, 3)
        XCTAssertFalse(result.arrangement.isAutomatic, "Kante = ausdrueckliche Anordnung")
        XCTAssertEqual(result.cells[1].active, c, "Neue Zelle liegt hinter dem Anker")
    }

    func testInsertLeadingPlacesBeforeAnchor() {
        let base = layout([a, b])
        let result = LayoutEngine.insert(c, atEdge: .leading, of: base.cells[0].id, in: base)
        XCTAssertEqual(result.cells.map(\.active), [c, a, b])
    }

    func testInsertVerticalUsesVerticalAxis() {
        let base = layout([a])
        let result = LayoutEngine.insert(b, atEdge: .bottom, of: base.cells[0].id, in: base)
        guard case let .split(axis, _, _) = result.arrangement.tree else {
            return XCTFail("Ein Split wird erwartet")
        }
        XCTAssertEqual(axis, .vertical)
    }

    func testInsertWithUnknownAnchorChangesNothing() {
        let base = layout([a])
        XCTAssertEqual(LayoutEngine.insert(b, atEdge: .trailing, of: UUID(), in: base), base)
    }

    // MARK: - resetToAutomatic (F6)

    /// Der sichtbare Schalter, ueber den Bestandsnutzer nach der Migration
    /// ueberhaupt erst in die neue Bedienung kommen.
    func testResetToAutomaticKeepsCellsAndStacks() {
        var base = layout([a, b])
        base.cells[0].sessions = [a, c]
        base.arrangement = .manual(LayoutEngine.automaticTree(for: base.cells))

        let result = LayoutEngine.resetToAutomatic(base)
        XCTAssertTrue(result.arrangement.isAutomatic)
        XCTAssertEqual(result.cells.count, 2)
        XCTAssertEqual(result.cells[0].sessions, [a, c], "Stapel bleiben erhalten")
    }

    // MARK: - activate

    func testActivateSwitchesVisibleSessionInStack() {
        var base = layout([a])
        base.cells[0].sessions = [a, b]
        let result = LayoutEngine.activate(b, in: base)
        XCTAssertEqual(result.cells[0].active, b)
    }

    func testActivateUnknownSessionChangesNothing() {
        let base = layout([a])
        XCTAssertEqual(LayoutEngine.activate(UUID(), in: base), base)
    }

    // MARK: - Ergebnis ist immer gueltig

    /// Der Vertrag der Engine: Was sie liefert, ist normalisiert. Aufrufer
    /// muessen keine Invarianten kennen.
    func testEveryOperationReturnsNormalizedLayout() {
        let base = layout([a, b, c])
        let ergebnisse: [WorkspaceLayout] = [
            LayoutEngine.add(d, to: base),
            LayoutEngine.remove(a, from: base),
            LayoutEngine.swap(base.cells[0].id, base.cells[1].id, in: base),
            LayoutEngine.drop(d, onto: base.cells[0].id, mode: .replace, in: base),
            LayoutEngine.drop(d, onto: base.cells[0].id, mode: .stack, in: base),
            LayoutEngine.insert(d, atEdge: .trailing, of: base.cells[0].id, in: base),
            LayoutEngine.resetToAutomatic(base),
        ]
        for (index, ergebnis) in ergebnisse.enumerated() {
            XCTAssertEqual(LayoutNormalizer.normalize(ergebnis), ergebnis,
                           "Operation \(index) liefert einen nicht normalisierten Zustand")
        }
    }
}
