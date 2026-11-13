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
    /// der richtigen Reihenfolge: Erst wenn das Diktat-Fenster steht,
    /// tauschen beide in einem Bild die Sichtbarkeit; die Status-Pille geht
    /// erst danach aus dem Weg. Zurück genauso, das Fenster schließt zuletzt.
    func testFullCycleHandsOverWithoutAGap() throws {
        var morph = UnifiedPillMorph()
        let shown = morph.show(morph: true)
        XCTAssertEqual(morph.phase, .handoverIn)
        XCTAssertTrue(shown.contains(.showRestLook))
        XCTAssertFalse(shown.contains(.hideStatus), "Status-Pille steht noch, bis das Bild da ist")

        let drawn = morph.step(.frameDrawn, generation: try XCTUnwrap(scheduled(shown, .frameDrawn)))
        XCTAssertEqual(morph.phase, .growing)
        XCTAssertEqual(Array(drawn.prefix(2)), [.revealDictation, .grow])
        XCTAssertFalse(drawn.contains(.hideStatus), "Fenster geht erst, wenn der Tausch auf dem Bildschirm ist")

        XCTAssertEqual(morph.step(.revealDrawn, generation: try XCTUnwrap(scheduled(drawn, .revealDrawn))), [.hideStatus])
        XCTAssertEqual(morph.phase, .growing)
        XCTAssertEqual(morph.step(.animationDone, generation: try XCTUnwrap(scheduled(drawn, .animationDone))), [.hideStatus])
        XCTAssertEqual(morph.phase, .dictation)

        let hidden = morph.hide(morph: true)
        XCTAssertEqual(morph.phase, .shrinking)
        XCTAssertTrue(hidden.contains(.shrink))
        XCTAssertFalse(hidden.contains(.showStatus), "erst zurückziehen, dann die Status-Pille")
        XCTAssertFalse(hidden.contains(.closeWindow))

        let shrunk = morph.step(.animationDone, generation: try XCTUnwrap(scheduled(hidden, .animationDone)))
        XCTAssertEqual(morph.phase, .handoverOut)
        XCTAssertTrue(shrunk.contains(.showStatus))
        XCTAssertFalse(shrunk.contains(.revealStatus), "erst wenn die Status-Pille wieder steht")
        XCTAssertFalse(shrunk.contains(.closeWindow), "Fenster bleibt, bis die Status-Pille gezeichnet ist")

        let revealed = morph.step(.frameDrawn, generation: try XCTUnwrap(scheduled(shrunk, .frameDrawn)))
        XCTAssertEqual(morph.phase, .closing)
        XCTAssertEqual(revealed.first, .revealStatus)
        XCTAssertFalse(revealed.contains(.closeWindow), "Fenster geht erst, wenn der Tausch auf dem Bildschirm ist")

        let closed = morph.step(.revealDrawn, generation: try XCTUnwrap(scheduled(revealed, .revealDrawn)))
        XCTAssertEqual(closed, [.closeWindow])
        XCTAssertEqual(morph.phase, .idle)
    }

    /// Main Thread lange blockiert: Das Wachsen ist durch, bevor der Tausch
    /// auf dem Bildschirm ist. Die Status-Pille bleibt stehen, bis er da ist,
    /// sonst gäbe es ein Bild ohne Pille.
    func testGrowEndingBeforeTheSwapWaitsForIt() throws {
        var morph = UnifiedPillMorph()
        let shown = morph.show(morph: true)
        let drawn = morph.step(.frameDrawn, generation: try XCTUnwrap(scheduled(shown, .frameDrawn)))
        XCTAssertEqual(morph.step(.animationDone, generation: try XCTUnwrap(scheduled(drawn, .animationDone))), [])
        XCTAssertEqual(morph.phase, .growing, "wartet auf den Tausch")
        XCTAssertEqual(morph.step(.revealDrawn, generation: try XCTUnwrap(scheduled(drawn, .revealDrawn))), [.hideStatus])
        XCTAssertEqual(morph.phase, .dictation)
    }

    /// Ohne Tausch (aus dem Zurückziehen wieder wachsen) wartet nichts.
    func testRegrowWithoutSwapEndsDirectly() throws {
        var morph = UnifiedPillMorph()
        _ = morph.show(morph: false)
        _ = morph.hide(morph: true)
        let again = morph.show(morph: true)
        XCTAssertNil(scheduled(again, .revealDrawn))
        XCTAssertEqual(morph.step(.animationDone, generation: try XCTUnwrap(scheduled(again, .animationDone))), [.hideStatus])
        XCTAssertEqual(morph.phase, .dictation)
    }

    /// Ohne ruhende Pille an der Stelle (anderer Bildschirm, Status aus,
    /// Kill-Switch): wie bisher direkt da und direkt weg.
    func testWithoutRestPillTheDictationAppearsDirectly() {
        var morph = UnifiedPillMorph()
        XCTAssertEqual(morph.show(morph: false), [.hideStatus])
        XCTAssertEqual(morph.phase, .dictation)
        XCTAssertEqual(morph.hide(morph: false), [.closeWindow, .showStatus, .revealStatus])
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

    /// Neues Diktat, nachdem schon zurückgetauscht ist (Status sichtbar,
    /// Diktat-Fenster unsichtbar, schließt gleich): in einem Bild zurück
    /// tauschen und wachsen, das Fenster schließt nicht.
    func testStartWhileClosingSwapsBackAndGrows() throws {
        var morph = UnifiedPillMorph()
        _ = morph.show(morph: false)
        let hidden = morph.hide(morph: true)
        let shrunk = morph.step(.animationDone, generation: try XCTUnwrap(scheduled(hidden, .animationDone)))
        let revealed = morph.step(.frameDrawn, generation: try XCTUnwrap(scheduled(shrunk, .frameDrawn)))
        let closeStep = try XCTUnwrap(scheduled(revealed, .revealDrawn))
        XCTAssertTrue(morph.isRetiring)
        let again = morph.show(morph: true)
        XCTAssertEqual(Array(again.prefix(2)), [.revealDictation, .grow])
        XCTAssertEqual(morph.step(.revealDrawn, generation: closeStep), [], "Fenster bleibt")
        XCTAssertEqual(morph.step(.revealDrawn, generation: try XCTUnwrap(scheduled(again, .revealDrawn))), [.hideStatus])
        XCTAssertEqual(morph.phase, .growing)
    }

    /// `show` ruft vorher `hide` (Wiederholen, Schnellaktion): im selben Lauf
    /// zurück und wieder vor, am Ende wieder das Diktat.
    func testHideAndShowInTheSameTurnEndsInDictation() throws {
        var morph = UnifiedPillMorph()
        _ = morph.show(morph: false)
        _ = morph.hide(morph: true)
        let again = morph.show(morph: true)
        // Status-Pille bleibt weg (doppelt gemeldet schadet nicht, der Hub entprellt).
        XCTAssertEqual(morph.step(.animationDone, generation: try XCTUnwrap(scheduled(again, .animationDone))), [.hideStatus])
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
        XCTAssertEqual(morph.abort(), [.closeWindow, .showStatus, .revealStatus])
        XCTAssertEqual(morph.phase, .idle)
        XCTAssertEqual(morph.abort(), [], "nichts mehr offen")
    }

    /// Status-Pille steht schon wieder, ist aber noch unsichtbar: Fenster zu,
    /// Status sichtbar machen.
    func testAbortDuringHandoverOutRevealsTheStatus() throws {
        var morph = UnifiedPillMorph()
        _ = morph.show(morph: false)
        let hidden = morph.hide(morph: true)
        _ = morph.step(.animationDone, generation: try XCTUnwrap(scheduled(hidden, .animationDone)))
        XCTAssertEqual(morph.phase, .handoverOut)
        XCTAssertEqual(morph.abort(), [.closeWindow, .revealStatus])
    }

    func testAbortWhileClosingOnlyClosesTheWindow() throws {
        var morph = UnifiedPillMorph()
        _ = morph.show(morph: false)
        let hidden = morph.hide(morph: true)
        let shrunk = morph.step(.animationDone, generation: try XCTUnwrap(scheduled(hidden, .animationDone)))
        _ = morph.step(.frameDrawn, generation: try XCTUnwrap(scheduled(shrunk, .frameDrawn)))
        XCTAssertEqual(morph.phase, .closing)
        XCTAssertEqual(morph.abort(), [.closeWindow], "Status ist schon sichtbar")
    }

    /// Stopp, bevor getauscht wurde: Das Diktat-Fenster war nie sichtbar.
    func testAbortDuringHandoverInOnlyClosesTheWindow() {
        var morph = UnifiedPillMorph()
        _ = morph.show(morph: true)
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

    // MARK: Übernahme beim Zurückziehen

    private let screenA = NotchScreenInfo(
        displayID: 2, frame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
        visibleFrame: CGRect(x: 0, y: 0, width: 1600, height: 975), safeAreaTop: 0,
        auxiliaryLeftWidth: nil, auxiliaryRightWidth: nil, isBuiltIn: false, uuid: "A")
    private let notchB = NotchScreenInfo(
        displayID: 1, frame: CGRect(x: -1512, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: -1512, y: 0, width: 1512, height: 944), safeAreaTop: 38,
        auxiliaryLeftWidth: 663.5, auxiliaryRightWidth: 663.5, isBuiltIn: true)

    /// Review-Befund: Ein Diktat kurz nach dem Ende auf einem anderen
    /// Bildschirm darf die alte Pille nicht übernehmen; ebenso nicht, wenn
    /// ihr Bildschirm weg ist oder andere Maße hat.
    func testRetiringPillIsAdoptedOnlyOnItsOwnUnchangedScreen() {
        let screens = [screenA, notchB]
        let onA = DictationPillPlacement.pill(screenA, center: CGPoint(x: 800, y: 950))
        XCTAssertTrue(UnifiedPillMorph.canAdopt(
            retiringScreen: screenA, retiringIsNotch: false, placement: onA, screens: screens))
        XCTAssertFalse(UnifiedPillMorph.canAdopt(
            retiringScreen: screenA, retiringIsNotch: false, placement: .notch(notchB), screens: screens),
            "anderer Bildschirm")
        XCTAssertFalse(UnifiedPillMorph.canAdopt(
            retiringScreen: screenA, retiringIsNotch: false, placement: onA, screens: [notchB]),
            "Bildschirm abgesteckt")
        var resized = screenA
        resized.frame.size.width = 1920
        XCTAssertFalse(UnifiedPillMorph.canAdopt(
            retiringScreen: screenA, retiringIsNotch: false, placement: .pill(resized, center: .zero),
            screens: [resized, notchB]), "andere Maße")
        XCTAssertFalse(UnifiedPillMorph.canAdopt(
            retiringScreen: screenA, retiringIsNotch: true, placement: onA, screens: screens),
            "andere Darstellung (Notch-Band auf Bildschirm ohne Notch)")
        XCTAssertFalse(UnifiedPillMorph.canAdopt(
            retiringScreen: nil, retiringIsNotch: false, placement: onA, screens: screens))
        XCTAssertTrue(UnifiedPillMorph.canAdopt(
            retiringScreen: notchB, retiringIsNotch: true, placement: .notch(notchB), screens: screens))
    }

    /// Klick beim Zurückziehen: nur der Kern startet ein Diktat.
    func testRestCoreFrameSitsAtTheLeadingEdgeOfThePill() {
        let pill = CGRect(x: 100, y: 20, width: 170, height: 40)
        let core = UnifiedPillGeometry.restCoreFrame(pill: pill)
        XCTAssertEqual(core, CGRect(x: 108, y: 26, width: PillMetrics.coreMinWidth, height: PillMetrics.coreHeight))
        XCTAssertEqual(UnifiedPillClickTarget.resolve(point: CGPoint(x: 120, y: 40), coreFrame: core), .core)
        XCTAssertEqual(UnifiedPillClickTarget.resolve(point: CGPoint(x: 220, y: 40), coreFrame: core), .status)
    }
}
