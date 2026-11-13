import AppKit
import SwiftUI

/// Vereinte Pille, Übergang: Steht auf dem Bildschirm des Diktats eine
/// ruhende Pille (bzw. die Notch), beginnt das Diktat-Fenster genau mit
/// deren Bild und wächst daraus ins Diktat; am Ende zieht es sich wieder
/// hinein. Den Ablauf bestimmt `UnifiedPillMorph` (rein), hier werden nur
/// seine Schritte ausgeführt.
///
/// Die Diktat-Logik merkt davon nichts: `show`/`hide` kehren sofort zurück,
/// Aufnahme und Auslieferung warten nie auf eine Animation. Das Fenster bleibt
/// das bewährte `RecordingPanel` (nicht aktivierend, nie Key). Es erscheint
/// zuerst unsichtbar über der Status-Pille; steht es auf dem Bildschirm,
/// tauschen beide in einem Bild ihre Sichtbarkeit. Zurück genauso. So steht
/// auf dem Bildschirm in jedem Bild genau eine Pille.
extension OverlayController {
    /// Wartezeit, nachdem ein Fenster sein Bild abgegeben hat, bis es sicher
    /// auf dem Bildschirm steht. Gemessen (13.11.2026, 120 Hz, Rechner unter
    /// Last): ein neues Fenster erscheint 18 bis 33 ms nach dem Abgeben.
    static let morphHandoverDelay: TimeInterval = 0.05
    /// Länge der Breitenanimation (`Animation.pill`) plus ein Bild.
    static let morphAnimationDelay: TimeInterval = 0.37

    /// Ruhebild für diesen Bildschirm: von der Status-Pille, an der Notch
    /// ohne Anzeige das Band. `nil`: Hier steht keine ruhende Pille, das
    /// Diktat erscheint wie bisher direkt.
    func restSnapshot(onDisplay displayID: UInt32, isNotch: Bool) -> UnifiedPillRestSnapshot? {
        if let snapshot = UnifiedPillHub.shared.restSnapshot(displayID), snapshot.look.isNotch == isNotch {
            return snapshot
        }
        return isNotch ? UnifiedPillRestSnapshot(look: .notchBand, center: nil) : nil
    }

    /// `show` direkt nach `hide` im selben Lauf (Wiederholen, Schnellaktion
    /// nach dem Diktat): dieselbe Sitzung, dasselbe Fenster wächst sofort
    /// wieder, ohne Bildschirmsuche, sofern sein Bildschirm noch genauso steht.
    func adoptRetiringPanelInSameTurn() -> Bool {
        guard retiredInCurrentTurn, morph.isRetiring, let screen = unifiedScreen else { return false }
        let screens = NSScreen.screens.compactMap(NotchScreenInfo.init(screen:))
        guard screens.contains(screen) else { return false }
        adoptRetiringPanel()
        return true
    }

    /// Nach der Bildschirmsuche: Zieht sich noch eine Pille zurück, übernimmt
    /// das neue Diktat sie nur, wenn es auf genau ihren Bildschirm gehört
    /// (`UnifiedPillMorph.canAdopt`). Sonst geht sie sofort zu und das
    /// Diktat baut wie gewohnt an seiner Stelle auf.
    func buildOrAdoptUnifiedPanel(_ placement: DictationPillPlacement, build: (DictationPillPlacement) -> Void) {
        if morph.isRetiring {
            let screens = NSScreen.screens.compactMap(NotchScreenInfo.init(screen:))
            if UnifiedPillMorph.canAdopt(
                retiringScreen: unifiedScreen, retiringIsNotch: presentation.isNotch,
                placement: placement, screens: screens) {
                return adoptRetiringPanel()
            }
            finishRetiringPanelNow()
        }
        build(placement)
    }

    /// Dasselbe Fenster wächst wieder ins Diktat.
    private func adoptRetiringPanel() {
        guard panel != nil else { return }
        Logger.info("unified_pill_morph_adopted")
        lastPillActionAt = Date()
        observeUnifiedBadge()
        applyMorph(morph.show(morph: true))
        // Hat sich der Bildschirm inzwischen geändert, baut die Pille neu auf.
        relocateAfterScreenChange()
    }

    /// Bildschirme geändert, während sich die Pille zurückzieht: Steht ihr
    /// Bildschirm nicht mehr genauso, geht sie sofort zu (die Status-Pille
    /// kommt zurück), statt an falscher Stelle zu enden.
    func retiringPanelScreenChanged() {
        guard morph.isRetiring, let screen = unifiedScreen else { return }
        let screens = NSScreen.screens.compactMap(NotchScreenInfo.init(screen:))
        guard !screens.contains(screen) else { return }
        Logger.info("unified_pill_morph_screen_changed")
        finishRetiringPanelNow()
    }

    /// Klick beim Zurückziehen (Fensterkoordinaten): Die Knöpfe haben keine
    /// Wege mehr, also landet er hier statt in der App darunter. Auf dem
    /// Kern startet er ein Diktat wie an der ruhenden Pille, sonst nichts.
    func retiringPillClicked(at point: CGPoint) {
        guard morph.isRetiring, case .pill = restLook, let panel else { return }
        let core = UnifiedPillGeometry.restCoreFrame(pill: panel.pillFrameInPanel)
        guard UnifiedPillClickTarget.resolve(point: point, coreFrame: core) == .core else { return }
        UnifiedPillHub.shared.startDictation()
    }

    /// Aus `hide`: Zieht sich die Pille ins Ruhebild zurück, bleibt das
    /// Fenster noch stehen (`true`). Sonst schließt `hide` es wie bisher.
    func retireUnifiedPanel() -> Bool {
        if morph.isRetiring { return panel != nil }
        guard presentation.isUnified, panel != nil, let screen = unifiedScreen else {
            if morph.phase != .idle { _ = morph.abort() }
            return false
        }
        let snapshot = restSnapshot(onDisplay: screen.displayID, isNotch: presentation.isNotch)
        if let snapshot {
            restLook = snapshot.look
            restCenter = snapshot.center
        }
        let effects = morph.hide(morph: snapshot != nil)
        guard effects.contains(.shrink) else { return false }
        applyMorph(effects)
        // Ein `show` im selben Lauf gehört zur selben Sitzung (siehe
        // `adoptRetiringPanelInSameTurn`).
        retiredInCurrentTurn = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.retiredInCurrentTurn = false }
        }
        return true
    }

    /// Zieht sich gerade eine vereinte Pille zurück, aber das nächste Diktat
    /// kann sie nicht übernehmen (Kill-Switch umgelegt): sofort schließen.
    func finishRetiringPanelNow() {
        guard morph.isRetiring else { return }
        applyMorph(morph.abort())
    }

    // MARK: Schritte ausführen

    func applyMorph(_ effects: [UnifiedPillMorph.Effect]) {
        for effect in effects {
            debugEvent?("\(effect)")
            switch effect {
            case .showRestLook:
                // Schon vor dem Aufbau gesetzt (ohne Animation), hier nur zur Sicherheit.
                if !showsRestLook { showsRestLook = true }
            case .grow:
                beginMorphSignpost()
                setRetiringInput(false)
                showsRestLook = false
            case .shrink:
                beginMorphSignpost()
                isHoverExpanded = false
                showsRestLook = true
                setRetiringInput(true)
                returnToRestCenter()
            case .hideStatus:
                if let screen = unifiedScreen { UnifiedPillHub.shared.dictationDidShow(onDisplay: screen.displayID) }
            case .showStatus:
                UnifiedPillHub.shared.dictationDidHide()
            case .revealDictation:
                swapVisibility(dictationVisible: true)
            case .revealStatus:
                swapVisibility(dictationVisible: false)
            case .closeWindow:
                closeRetiredPanel()
            case .schedule(let step, let generation):
                let perform: @MainActor () -> Void = { [weak self] in
                    guard let self else { return }
                    // Nur die laufende Messung beenden, nicht eine überholte.
                    if step == .animationDone, generation == self.morph.generation { self.endMorphSignpost() }
                    self.applyMorph(self.morph.step(step, generation: generation))
                }
                switch step {
                case .frameDrawn, .revealDrawn:
                    Self.afterNextCommit(delay: Self.morphHandoverDelay, perform)
                case .animationDone:
                    DispatchQueue.main.asyncAfter(deadline: .now() + Self.morphAnimationDelay) {
                        MainActor.assumeIsolated(perform)
                    }
                }
            }
        }
    }

    /// Tausch in einem Bild: Beide Änderungen landen in derselben
    /// CATransaction (Ebenen-Deckkraft, keine Fensterbewegung), also im selben
    /// Bild auf dem Bildschirm. Fenster ein- und ausblenden ginge dagegen
    /// sofort an die Fensterverwaltung und überholte das Bild.
    private func swapVisibility(dictationVisible: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hostingView?.alphaValue = dictationVisible ? 1 : 0
        UnifiedPillHub.shared.setStatusContentHidden(onDisplay: dictationVisible ? unifiedScreen?.displayID : nil)
        CATransaction.commit()
    }

    /// Ersatz, falls der Beobachter nie läuft (anderer Run-Loop-Modus,
    /// Durchlauf, der nie zur Ruhe kommt): sonst hinge der Übergang, und das
    /// Diktat bliebe unsichtbar.
    static let morphCommitFallback: TimeInterval = 0.3

    /// `body` läuft genau einmal: wenn der Main Thread das nächste Bild
    /// abgegeben hat (Ende des laufenden Run-Loop-Durchlaufs, nach dem
    /// Zeichnen und der CATransaction), plus `delay` für die
    /// Fensterverwaltung; spätestens aber nach `fallback`. Ein beschäftigter
    /// Main Thread verschiebt so nur den Zeitpunkt, er kann den Tausch nicht
    /// vor das Bild ziehen (vorher: fester Zeitgeber ab Aufbau).
    /// `observesCommit: false` nur für Tests des Ersatzwegs.
    static func afterNextCommit(
        delay: TimeInterval, fallback: TimeInterval = morphCommitFallback, observesCommit: Bool = true,
        _ body: @escaping @MainActor () -> Void
    ) {
        var done = false
        var observer: CFRunLoopObserver?
        let runOnce: @MainActor () -> Void = {
            guard !done else { return }
            done = true
            if let observer { CFRunLoopObserverInvalidate(observer) }
            body()
        }
        if observesCommit {
            // Core Animation gibt bei `beforeWaiting` mit Rang 2_000_000 ab;
            // dieser Beobachter läuft direkt danach und nur einmal.
            observer = CFRunLoopObserverCreateWithHandler(
                nil, CFRunLoopActivity.beforeWaiting.rawValue, false, 2_000_001
            ) { _, _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated(runOnce) }
            }
            if let observer { CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + max(fallback, delay)) { MainActor.assumeIsolated(runOnce) }
    }

    /// Fenster zu, nachdem die Status-Pille wieder steht (oder sofort beim
    /// Abbruch). Hat ein neues Diktat das Fenster übernommen, kommt dieser
    /// Schritt nicht an (Generation).
    private func closeRetiredPanel() {
        cancelMorphSignpost()
        // Steht die Status-Pille noch unsichtbar, wird sie spätestens jetzt sichtbar.
        UnifiedPillHub.shared.setStatusContentHidden(onDisplay: nil)
        if let unifiedScreenObserver {
            NotificationCenter.default.removeObserver(unifiedScreenObserver)
            self.unifiedScreenObserver = nil
        }
        unifiedScreen = nil
        panel?.close()
        panel = nil
        hostingView = nil
        showsRestLook = false
        restLook = nil
        restCenter = nil
    }

    /// Beim Zurückziehen fängt das Fenster Klicks selbst ab, statt sie an
    /// SwiftUI (Knöpfe ohne Wege) oder durch zur App darunter zu geben (das
    /// könnte im Einfüge-Ziel den Fokus verschieben). Nicht ziehbar, keine
    /// gemerkte Lage. Das Fenster bleibt nicht aktivierend.
    private func setRetiringInput(_ retiring: Bool) {
        panel?.isMovableByWindowBackground = !retiring && !presentation.isNotch
        hostingView?.onInterceptedClick = retiring ? { [weak self] point in self?.retiringPillClicked(at: point) } : nil
    }

    /// Hat sich die Pille beim Diktat verschoben (am Bildschirmrand zur Mitte
    /// hin), gleitet sie im Zurückziehen an die Stelle der Status-Pille.
    /// Einen Lauf später: Übernimmt im selben Lauf ein neues Diktat, bleibt
    /// sie stehen.
    private func returnToRestCenter() {
        guard presentation == .pill, let center = restCenter else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.morph.phase == .shrinking, let panel = self.panel else { return }
                let origin = UnifiedPillGeometry.pillDictationPanelOrigin(center: center, panelSize: panel.frame.size)
                guard abs(origin.x - panel.frame.origin.x) > 0.5 || abs(origin.y - panel.frame.origin.y) > 0.5 else { return }
                self.isResettingPosition = true
                panel.animateOrigin(to: origin) { [weak self] in
                    self?.isResettingPosition = false
                }
            }
        }
    }

    // MARK: Messung

    private func beginMorphSignpost() {
        cancelMorphSignpost()
        morphSignpost = PerfBudgets.unifiedPillMorph.begin()
    }

    private func endMorphSignpost() {
        if let morphSignpost { PerfBudgets.unifiedPillMorph.end(morphSignpost) }
        morphSignpost = nil
    }

    func cancelMorphSignpost() {
        if let morphSignpost { PerfBudgets.unifiedPillMorph.cancel(morphSignpost) }
        morphSignpost = nil
    }
}
