import XCTest
@testable import WhisperM8

/// Prueft die Umrechnung von Layout zu Rechtecken.
///
/// Der wichtigste Punkt ist nicht „sieht huebsch aus", sondern **es gibt keine
/// Fugen**: Benachbarte Flaechen muessen luecken- und ueberlappungsfrei
/// aneinanderstossen. Sonst sieht man Striche zwischen den Terminals oder
/// Zeichen werden abgeschnitten.
final class LayoutGeometryTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 1600, height: 900)

    private func layout(_ count: Int) -> WorkspaceLayout {
        WorkspaceLayout(cells: (0..<count).map { _ in WorkspaceLayout.Cell(session: UUID()) })
    }

    // MARK: - Vollstaendigkeit und Fugenfreiheit

    func testEveryCellGetsAFrame() {
        for count in 1...9 {
            let frames = LayoutGeometry.frames(for: layout(count), in: bounds)
            XCTAssertEqual(frames.count, count, "\(count) Zellen")
        }
    }

    /// Die Summe aller Flaechen muss die Gesamtflaeche ergeben — sonst gibt es
    /// Luecken oder Ueberlappungen.
    func testFramesCoverBoundsWithoutGaps() {
        for count in [1, 2, 3, 4, 6, 9] {
            let frames = LayoutGeometry.frames(for: layout(count), in: bounds)
            let flaeche = frames.values.reduce(0) { $0 + $1.width * $1.height }
            XCTAssertEqual(flaeche, bounds.width * bounds.height, accuracy: 1,
                           "\(count) Zellen lassen Flaeche ungenutzt oder ueberlappen")
        }
    }

    func testFramesDoNotOverlap() {
        let frames = Array(LayoutGeometry.frames(for: layout(6), in: bounds).values)
        for i in frames.indices {
            for j in frames.indices where j > i {
                let schnitt = frames[i].intersection(frames[j])
                XCTAssertTrue(schnitt.isNull || schnitt.width < 1 || schnitt.height < 1,
                              "Flaechen ueberlappen: \(frames[i]) und \(frames[j])")
            }
        }
    }

    /// Kanten werden gerundet und Groessen daraus abgeleitet — nicht Position
    /// und Groesse getrennt. Sonst entstehen Fugen von einem Pixel.
    func testFramesAreIntegral() {
        let frames = LayoutGeometry.frames(for: layout(3), in: CGRect(x: 0, y: 0, width: 1001, height: 777))
        for frame in frames.values {
            XCTAssertEqual(frame.minX, frame.minX.rounded(), accuracy: 0.001)
            XCTAssertEqual(frame.width, frame.width.rounded(), accuracy: 0.001)
        }
    }

    // MARK: - Determinismus

    /// Gleiche Eingaben, gleiche Rechtecke. Weicht das ab, wuerde jede
    /// Neuberechnung die Terminals unnoetig neu umbrechen lassen — und jede
    /// Groessenaenderung zwingt die laufenden Programme zum Neuzeichnen.
    func testFramesAreDeterministic() {
        let l = layout(5)
        XCTAssertEqual(LayoutGeometry.frames(for: l, in: bounds),
                       LayoutGeometry.frames(for: l, in: bounds))
    }

    // MARK: - Automatische Anordnung

    func testSingleCellFillsBounds() {
        let l = layout(1)
        let frame = LayoutGeometry.frames(for: l, in: bounds).values.first
        XCTAssertEqual(frame, bounds)
    }

    /// Auf einem breiten Fenster liegen zwei Flaechen nebeneinander, auf einem
    /// hohen uebereinander.
    func testArrangementFollowsAspectRatio() {
        let breit = LayoutGeometry.automaticArrangement(cellCount: 2, aspect: 2.0)
        XCTAssertEqual(breit.columns, 2, "Breites Fenster teilt senkrecht")

        let hoch = LayoutGeometry.automaticArrangement(cellCount: 2, aspect: 0.5)
        XCTAssertEqual(hoch.rows, 2, "Hohes Fenster teilt waagerecht")
    }

    func testArrangementCoversAllCells() {
        for count in 1...12 {
            let (columns, rows) = LayoutGeometry.automaticArrangement(cellCount: count, aspect: 1.6)
            XCTAssertGreaterThanOrEqual(columns * rows, count,
                                        "\(count) Zellen passen nicht in \(columns)×\(rows)")
        }
    }

    // MARK: - Mindestgroesse (F7)

    /// Passt eine weitere Flaeche nicht mehr in Mindestgroesse, wird nicht
    /// weiter geteilt. Der Nutzer wird nie blockiert, das Bild bleibt lesbar.
    func testMinimumSizeLimitsColumns() {
        let schmal = CGRect(x: 0, y: 0, width: 900, height: 900)
        let frames = LayoutGeometry.frames(
            for: layout(4), in: schmal,
            minimum: CGSize(width: 480, height: 260)
        )
        for frame in frames.values where frame.width > 0 {
            XCTAssertGreaterThanOrEqual(frame.width, 400,
                                        "Flaeche unter Mindestbreite: \(frame)")
        }
    }

    // MARK: - Manuelle Anordnung

    func testManualTreeRespectsFractions() {
        var l = layout(2)
        let idA = l.cells[0].id, idB = l.cells[1].id
        l.arrangement = .manual(.split(axis: .horizontal,
                                       children: [.leaf(cellID: idA), .leaf(cellID: idB)],
                                       fractions: [0.75, 0.25]))
        let frames = LayoutGeometry.frames(for: l, in: bounds)
        XCTAssertEqual(frames[idA]?.width ?? 0, 1200, accuracy: 1)
        XCTAssertEqual(frames[idB]?.width ?? 0, 400, accuracy: 1)
    }

    func testNestedTreeIsPlacedCorrectly() {
        var l = layout(3)
        let ids = l.cells.map(\.id)
        l.arrangement = .manual(.split(
            axis: .horizontal,
            children: [
                .leaf(cellID: ids[0]),
                .split(axis: .vertical,
                       children: [.leaf(cellID: ids[1]), .leaf(cellID: ids[2])],
                       fractions: [0.5, 0.5]),
            ],
            fractions: [0.5, 0.5]
        ))
        let frames = LayoutGeometry.frames(for: l, in: bounds)

        XCTAssertEqual(frames[ids[0]]?.width ?? 0, 800, accuracy: 1)
        XCTAssertEqual(frames[ids[1]]?.height ?? 0, 450, accuracy: 1)
        XCTAssertEqual(frames[ids[2]]?.minY ?? 0, 450, accuracy: 1)

        let flaeche = frames.values.reduce(0) { $0 + $1.width * $1.height }
        XCTAssertEqual(flaeche, bounds.width * bounds.height, accuracy: 1)
    }

    // MARK: - Randfaelle

    func testEmptyLayoutYieldsNoFrames() {
        XCTAssertTrue(LayoutGeometry.frames(for: WorkspaceLayout(), in: bounds).isEmpty)
    }

    func testZeroBoundsYieldNoFrames() {
        XCTAssertTrue(LayoutGeometry.frames(for: layout(3), in: .zero).isEmpty)
    }
}
