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
/// das bewährte `RecordingPanel` (nicht aktivierend, nie Key); die
/// Status-Pille tritt erst zurück, wenn es sein erstes Bild gezeichnet hat,
/// und kommt zurück, bevor es schließt. So steht auf dem Bildschirm immer
/// genau eine Pille.
extension OverlayController {
    /// Ein Bild bei 60 Hz plus Luft: so lange überlappen Status- und
    /// Diktat-Fenster mit gleichem Bild beim Wechsel.
    static let morphHandoverDelay: TimeInterval = 0.03
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

    /// Ein laufender Rückzug wird vom nächsten Diktat übernommen: dasselbe
    /// Fenster wächst wieder, ohne neue Bildschirmsuche.
    func adoptRetiringPanel() -> Bool {
        guard morph.isRetiring, let panel, presentation.isUnified else { return false }
        Logger.info("unified_pill_morph_adopted")
        lastPillActionAt = Date()
        panel.ignoresMouseEvents = false
        observeUnifiedBadge()
        applyMorph(morph.show(morph: true))
        return true
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
            switch effect {
            case .showRestLook:
                // Schon vor dem Aufbau gesetzt (ohne Animation), hier nur zur Sicherheit.
                if !showsRestLook { showsRestLook = true }
            case .grow:
                beginMorphSignpost()
                panel?.ignoresMouseEvents = false
                showsRestLook = false
            case .shrink:
                beginMorphSignpost()
                isHoverExpanded = false
                showsRestLook = true
                // Zurückziehen nimmt keine Klicks mehr an: Die Knöpfe haben
                // keine Wege mehr, ein Ziehen soll keine Lage merken.
                panel?.ignoresMouseEvents = true
                returnToRestCenter()
            case .hideStatus:
                if let screen = unifiedScreen { UnifiedPillHub.shared.dictationDidShow(onDisplay: screen.displayID) }
            case .showStatus:
                UnifiedPillHub.shared.dictationDidHide()
            case .closeWindow:
                closeRetiredPanel()
            case .schedule(let step, let generation):
                let delay = step == .frameDrawn ? Self.morphHandoverDelay : Self.morphAnimationDelay
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        if step == .animationDone { self.endMorphSignpost() }
                        self.applyMorph(self.morph.step(step, generation: generation))
                    }
                }
            }
        }
    }

    /// Fenster zu, nachdem die Status-Pille wieder steht (oder sofort beim
    /// Abbruch). Hat ein neues Diktat das Fenster übernommen, kommt dieser
    /// Schritt nicht an (Generation).
    private func closeRetiredPanel() {
        cancelMorphSignpost()
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

    private func cancelMorphSignpost() {
        if let morphSignpost { PerfBudgets.unifiedPillMorph.cancel(morphSignpost) }
        morphSignpost = nil
    }
}
