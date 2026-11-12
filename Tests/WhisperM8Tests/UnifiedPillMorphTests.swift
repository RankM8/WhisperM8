import XCTest
@testable import WhisperM8

/// Übergang zwischen ruhender Pille und Diktat (`UnifiedPillMorph`): der
/// reine Ablauf samt Unterbrechungen, ohne Fenster.
final class UnifiedPillMorphTests: XCTestCase {
    private typealias Effect = UnifiedPillMorph.Effect

    /// Plant der Ablauf einen Folgeschritt, liefert das seine Generation.
    private func scheduled(_ effects: [Effect], _ step: UnifiedPillMorph.Step) -> Int? {
        for effect in effects {
            if case .schedule(let planned, let generation) = effect, planned == step { return generation }
        }
        return nil
    }

    /// Ruhe → Wachsen → Diktat → Zurückziehen → Ruhe, mit den Schritten in
    /// der richtigen Reihenfolge: Die Status-Pille geht erst, wenn das
    /// Diktat-Fenster ihr Bild zeigt, und kommt zurück, bevor es schließt.
    func testFullCycleHandsOverWithoutAGap() throws {
        var morph = UnifiedPillMorph()
        let shown = morph.show(morph: true)
        XCTAssertEqual(morph.phase, .handoverIn)
        XCTAssertTrue(shown.contains(.showRestLook))
        XCTAssertFalse(shown.contains(.hideStatus), "Status-Pille steht noch, bis das Bild da ist")

        let drawn = morph.step(.frameDrawn, generation: try XCTUnwrap(scheduled(shown, .frameDrawn)))
        XCTAssertEqual(morph.phase, .growing)
        XCTAssertEqual(Array(drawn.prefix(2)), [.hideStatus, .grow])

        XCTAssertEqual(morph.step(.animationDone, generation: try XCTUnwrap(scheduled(drawn, .animationDone))), [])
        XCTAssertEqual(morph.phase, .dictation)

        let hidden = morph.hide(morph: true)
        XCTAssertEqual(morph.phase, .shrinking)
        XCTAssertTrue(hidden.contains(.shrink))
        XCTAssertFalse(hidden.contains(.showStatus), "erst zurückziehen, dann die Status-Pille")
        XCTAssertFalse(hidden.contains(.closeWindow))

        let shrunk = morph.step(.animationDone, generation: try XCTUnwrap(scheduled(hidden, .animationDone)))
        XCTAssertEqual(morph.phase, .handoverOut)
        XCTAssertTrue(shrunk.contains(.showStatus))
        XCTAssertFalse(shrunk.contains(.closeWindow), "Fenster bleibt, bis die Status-Pille gezeichnet ist")

        let closed = morph.step(.frameDrawn, generation: try XCTUnwrap(scheduled(shrunk, .frameDrawn)))
        XCTAssertEqual(closed, [.closeWindow])
        XCTAssertEqual(morph.phase, .idle)
    }

    /// Ohne ruhende Pille an der Stelle (anderer Bildschirm, Status aus,
    /// Kill-Switch): wie bisher direkt da und direkt weg.
    func testWithoutRestPillTheDictationAppearsDirectly() {
        var morph = UnifiedPillMorph()
        XCTAssertEqual(morph.show(morph: false), [.hideStatus])
        XCTAssertEqual(morph.phase, .dictation)
        XCTAssertEqual(morph.hide(morph: false), [.closeWindow, .showStatus])
        XCTAssertEqual(morph.phase, .idle)
    }

    /// Stopp, bevor das Fenster sein erstes Bild hatte: Die Status-Pille war
    /// nie weg, das Fenster geht einfach zu; der geplante Schritt verpufft.
    func testStopDuringHandoverInClosesWithoutTouchingTheStatus() throws {
        var morph = UnifiedPillMorph()
        let shown = morph.show(morph: true)
        XCTAssertEqual(morph.hide(morph: true), [.closeWindow])
        XCTAssertEqual(morph.phase, .idle)
        XCTAssertEqual(morph.step(.frameDrawn, generation: try XCTUnwrap(scheduled(shown, .frameDrawn))), [])
        XCTAssertEqual(morph.phase, .idle)
    }

    /// Stopp mitten im Wachsen: zieht sich aus dem jetzigen Stand zurück,
    /// das Ende des Wachsens ist überholt.
    func testStopDuringGrowReversesAndDropsTheOldStep() throws {
        var morph = UnifiedPillMorph()
        let shown = morph.show(morph: true)
        let drawn = morph.step(.frameDrawn, generation: try XCTUnwrap(scheduled(shown, .frameDrawn)))
        let growDone = try XCTUnwrap(scheduled(drawn, .animationDone))
        let hidden = morph.hide(morph: true)
        XCTAssertEqual(morph.phase, .shrinking)
        XCTAssertEqual(morph.step(.animationDone, generation: growDone), [], "Ende des Wachsens ist überholt")
        XCTAssertEqual(morph.phase, .shrinking)
        XCTAssertNotNil(scheduled(hidden, .animationDone))
    }

    /// Neues Diktat, während sich das alte zurückzieht: dasselbe Fenster
    /// wächst wieder, die Status-Pille bleibt weg.
    func testStartDuringShrinkGrowsAgain() throws {
        var morph = UnifiedPillMorph()
        _ = morph.show(morph: false)
        let hidden = morph.hide(morph: true)
        let shrinkDone = try XCTUnwrap(scheduled(hidden, .animationDone))
        let again = morph.show(morph: true)
        XCTAssertEqual(morph.phase, .growing)
        XCTAssertTrue(again.contains(.grow))
        XCTAssertFalse(again.contains(.hideStatus), "war nie wieder da")
        XCTAssertEqual(morph.step(.animationDone, generation: shrinkDone), [], "Ende des Zurückziehens ist überholt")
        XCTAssertEqual(morph.phase, .growing)
    }

    /// Neues Diktat, nachdem die Status-Pille schon zurück ist, das Fenster
    /// aber noch steht: Status wieder weg, das Fenster schließt nicht.
    func testStartDuringHandoverOutKeepsTheWindow() throws {
        var morph = UnifiedPillMorph()
        _ = morph.show(morph: false)
        let hidden = morph.hide(morph: true)
        let shrunk = morph.step(.animationDone, generation: try XCTUnwrap(scheduled(hidden, .animationDone)))
        let closeStep = try XCTUnwrap(scheduled(shrunk, .frameDrawn))
        let again = morph.show(morph: true)
        XCTAssertEqual(Array(again.prefix(2)), [.hideStatus, .grow])
        XCTAssertEqual(morph.step(.frameDrawn, generation: closeStep), [], "Fenster bleibt")
        XCTAssertEqual(morph.phase, .growing)
    }

    /// `show` ruft vorher `hide` (Wiederholen, Schnellaktion): im selben Lauf
    /// zurück und wieder vor, am Ende wieder das Diktat.
    func testHideAndShowInTheSameTurnEndsInDictation() throws {
        var morph = UnifiedPillMorph()
        _ = morph.show(morph: false)
        _ = morph.hide(morph: true)
        let again = morph.show(morph: true)
        XCTAssertEqual(morph.step(.animationDone, generation: try XCTUnwrap(scheduled(again, .animationDone))), [])
        XCTAssertEqual(morph.phase, .dictation)
    }

    func testRepeatedHideAndShowAreHarmless() {
        var morph = UnifiedPillMorph()
        XCTAssertEqual(morph.hide(morph: true), [], "nichts zu verstecken")
        _ = morph.show(morph: false)
        XCTAssertEqual(morph.show(morph: true), [], "steht schon")
        _ = morph.hide(morph: true)
        XCTAssertEqual(morph.hide(morph: true), [], "zieht sich schon zurück")
        XCTAssertTrue(morph.isRetiring)
    }

    /// Bildschirm gewechselt: neu aufbauen ohne Übergang; alte Schritte verpuffen.
    func testScreenChangeRebuildsWithoutMorph() throws {
        var morph = UnifiedPillMorph()
        let shown = morph.show(morph: true)
        let stale = try XCTUnwrap(scheduled(shown, .frameDrawn))
        morph.reset()
        XCTAssertEqual(morph.show(morph: false), [.hideStatus])
        XCTAssertEqual(morph.step(.frameDrawn, generation: stale), [])
        XCTAssertEqual(morph.phase, .dictation)
    }

    /// Kill-Switch während des Zurückziehens: sofort zu, Status zurück.
    func testAbortWhileShrinkingClosesAndShowsTheStatus() {
        var morph = UnifiedPillMorph()
        _ = morph.show(morph: false)
        _ = morph.hide(morph: true)
        XCTAssertEqual(morph.abort(), [.closeWindow, .showStatus])
        XCTAssertEqual(morph.phase, .idle)
        XCTAssertEqual(morph.abort(), [], "nichts mehr offen")
    }

    func testAbortAfterTheStatusIsBackOnlyClosesTheWindow() throws {
        var morph = UnifiedPillMorph()
        _ = morph.show(morph: false)
        let hidden = morph.hide(morph: true)
        _ = morph.step(.animationDone, generation: try XCTUnwrap(scheduled(hidden, .animationDone)))
        XCTAssertEqual(morph.abort(), [.closeWindow])
    }

    // MARK: Ruhebild

    func testRestLookRowHeights() {
        XCTAssertEqual(UnifiedPillRestLook.pill(summary: NotchSummary(), alert: nil).rowHeight, PillMetrics.height)
        XCTAssertEqual(
            UnifiedPillRestLook.notch(summary: NotchSummary(working: 1), alert: nil, bodyWidth: 185).rowHeight,
            NotchGeometry.chinHeight)
        XCTAssertEqual(UnifiedPillRestLook.notchBand.rowHeight, 0, "nur das Band, die Zeile wächst darunter")
        XCTAssertFalse(UnifiedPillRestLook.pill(summary: NotchSummary(), alert: nil).isNotch)
        XCTAssertTrue(UnifiedPillRestLook.notchBand.isNotch)
    }

    /// Ohne Fenster (Testprozess) zieht sich nichts zurück: `hide` räumt das
    /// Ruhebild sofort ab, die nächste Pille beginnt ohne.
    @MainActor
    func testHideWithoutWindowClearsTheRestLook() {
        let overlay = OverlayController(presentsWindow: false)
        overlay.restLook = .notchBand
        overlay.showsRestLook = true
        overlay.hide()
        XCTAssertFalse(overlay.showsRestLook)
        XCTAssertNil(overlay.restLook)
        XCTAssertEqual(overlay.morph.phase, .idle)
    }
}
