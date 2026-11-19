import AppKit
import SwiftUI

/// Kamera-Insel: Hinweis „braucht dich“ und Liste als große Form
/// (`NotchIslandLargeGeometry`, `NotchIslandLargeStatusView`).
///
/// Das Fenster ist in Ruhe genau die Kapsel in der Menüleiste. Für die große
/// Form wird es in einem Schritt so groß wie die Form (ohne Animation) und
/// zeigt dabei noch die Kapsel; im nächsten Bild gleitet die Ansicht zur
/// offenen Form. Beim Schließen umgekehrt: Die Ansicht zieht sich auf die
/// Kapsel zurück, danach wird das Fenster wieder klein. So bewegt sich nur
/// eine Sache (die Form in SwiftUI), nie zugleich das Fenster.
///
/// Die offene Form darf Menüs und Statussymbole neben der Kamera verdecken
/// (Entscheidung 19.11.2026): Sie geht nur auf einen Klick auf bzw. beim
/// Hinweis für wenige Sekunden. Klicks nimmt das Fenster nur auf der Form an
/// (`NotchHostingView.islandHitFrame`), der Rand für das Überschwingen und
/// alles daneben bleibt bei der Menüleiste; beim Schließen sofort.
extension NotchStatusController {
    typealias IslandState = (presentation: NotchIslandPresentation, band: NotchIslandBand)

    /// Zeichnet Hinweis oder Liste als große Form bzw. schließt sie.
    /// `true`: Diese Stelle ist damit fertig; `false`: weiter mit der
    /// Darstellung in Ruhe.
    func renderIslandLarge(
        _ slot: NotchSlot, screen: NotchScreenInfo, island: IslandState,
        rows: [NotchRow], summary: NotchSummary, sections: [NotchSection]
    ) -> Bool {
        let expandedHere = expandedKind == slot.kind
        let shownAlert = expandedHere ? nil : alert
        guard expandedHere || shownAlert != nil else {
            return closeIslandLarge(slot, screen: screen, island: island, summary: summary)
        }
        let occupancy = islandOccupancy[screen.displayID]
        let kind: NotchIslandLargeKind = expandedHere
            ? .list(rowCount: sections.reduce(0) { $0 + $1.rows.count }, sectionCount: sections.count) : .alert
        let form = NotchIslandLargeGeometry.form(screen: screen, kind: kind, occupancy: occupancy)
        let display = NotchDisplay(
            style: .island(island.band), summary: summary, alert: shownAlert, isExpanded: expandedHere,
            sections: expandedHere ? sections : [], selectedRowID: expandedHere ? keyboardSelection : nil,
            islandLarge: .open(form),
            alertDetail: shownAlert.flatMap { alert in
                Self.alertDetail(kind: alert.kind, input: inputs.first { $0.id == alert.sessionID })
            })

        slot.showsIslandInBar = false
        slot.islandLargeClosing = false
        let panel = ensurePanel(slot)
        panel.hasShadow = false
        let wasVisible = panel.isVisible
        let previous = slot.islandLargeForm
        slot.islandLargeForm = form
        if display != slot.lastDisplay {
            slot.lastDisplay = display
            slot.shrinkTask?.cancel()
            slot.shrinkTask = nil
            // VoiceOver: Das Fenster nennt, was die Anzeige zeigt.
            panel.setAccessibilityLabel(display.accessibilitySummary)
            let margin = NotchIslandLargeGeometry.overshootMargin
            let settled = NotchIslandLargeGeometry.canvas(form.frame, margin: margin)
            let canvas = NotchIslandLargeGeometry.canvas(form.frame, previous?.frame, margin: margin)
            if previous == nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                // Erst die Kapsel im großen Fenster, dann wächst die Form.
                let seed = NotchIslandLargeGeometry.seedFrame(
                    screen: screen, band: island.band, presentation: island.presentation, occupancy: occupancy)
                var closed = display
                closed.islandLarge = .closed(form, outline: NotchIslandLargeGeometry.outline(of: seed, screen: screen))
                setDisplayWithoutAnimation(closed, on: slot)
                setIslandLargeFrame(canvas, form: form, slot: slot, panel: panel)
                DispatchQueue.main.async { [weak slot] in
                    guard let slot, slot.lastDisplay == display else { return }
                    slot.viewModel.display = display
                }
            } else {
                if previous == nil {
                    setDisplayWithoutAnimation(display, on: slot)
                } else {
                    // Von Form zu Form (Hinweis zur Liste, Liste wird länger).
                    slot.viewModel.display = display
                }
                setIslandLargeFrame(canvas, form: form, slot: slot, panel: panel)
            }
            if canvas != settled {
                // Die alte Form war größer: erst nach der Bewegung verkleinern.
                slot.shrinkTask = Task { [weak self, weak slot] in
                    try? await Task.sleep(for: NotchIslandLargeMotion.settleDelay)
                    guard !Task.isCancelled, let self, let slot, slot.lastDisplay == display,
                          let panel = slot.panel else { return }
                    slot.shrinkTask = nil
                    self.setIslandLargeFrame(settled, form: form, slot: slot, panel: panel)
                }
            }
        }
        if !wasVisible { panel.orderFrontRegardless() }
        slot.returnsFromDictation = false
        return true
    }

    /// Die große Form zieht sich auf die Kapsel zurück, die danach dasteht
    /// (bzw. in Apples Insel, wenn nichts mehr zu zeigen ist); dann wird das
    /// Fenster wieder klein. `false`: Es war keine Form offen oder sie geht
    /// ohne Bewegung zu; der Aufrufer zeichnet die Ruhe-Darstellung.
    private func closeIslandLarge(
        _ slot: NotchSlot, screen: NotchScreenInfo, island: IslandState, summary: NotchSummary
    ) -> Bool {
        if slot.islandLargeClosing { return true }
        guard let form = slot.islandLargeForm else { return false }
        slot.islandLargeForm = nil
        slot.shrinkTask?.cancel()
        slot.shrinkTask = nil
        guard let panel = slot.panel, panel.isVisible, var closing = slot.lastDisplay, closing.islandLarge != nil,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            endIslandLarge(slot)
            return false
        }
        let seed = NotchIslandLargeGeometry.seedFrame(
            screen: screen, band: island.band, presentation: island.presentation,
            occupancy: islandOccupancy[screen.displayID])
        let outline = NotchIslandLargeGeometry.outline(of: seed, screen: screen)
        closing.style = .island(island.band)
        closing.summary = summary
        closing.islandLarge = .closed(form, outline: outline)
        slot.lastDisplay = nil
        slot.islandLargeClosing = true
        slot.viewModel.display = closing
        // Die Menüleiste neben der Kapsel ist sofort wieder bedienbar.
        slot.host?.islandHitFrame = NotchIslandLargeGeometry.hitFrame(of: outline, inCanvasOfSize: panel.frame.size)
        slot.shrinkTask = Task { [weak self, weak slot] in
            try? await Task.sleep(for: NotchIslandLargeMotion.closeDelay)
            guard !Task.isCancelled, let self, let slot, slot.islandLargeClosing else { return }
            slot.shrinkTask = nil
            self.endIslandLarge(slot)
            self.render()
        }
        return true
    }

    /// Die Form ist zu: Das Fenster wird beim nächsten Zeichnen ohne
    /// Animation wieder die Kapsel (oder geht).
    private func endIslandLarge(_ slot: NotchSlot) {
        slot.islandLargeClosing = false
        slot.host?.islandHitFrame = nil
        slot.lastFrame = nil
        slot.lastDisplay = nil
        slot.snapsNextRender = true
    }

    /// Fenster ohne Animation setzen; Klicks nur auf der Form.
    private func setIslandLargeFrame(_ frame: CGRect, form: NotchIslandLargeForm, slot: NotchSlot, panel: NotchPanel) {
        slot.host?.islandHitFrame = NotchIslandLargeGeometry.hitFrame(
            of: NotchIslandLargeGeometry.openOutline(form), inCanvasOfSize: frame.size)
        guard frame != slot.lastFrame else { return }
        slot.lastFrame = frame
        panel.setFrame(frame, display: true)
    }

    /// Zweite Zeile des Hinweises. Wartet der Chat auf dich, steht dort nur
    /// die ART des Wartens (`AgentSessionActivity.awaitingKindLine`:
    /// „Approval: Bash“, „Question“, „Plan awaiting approval“); sonst sein
    /// Projekt. Der Hinweis geht von selbst auf, auch bei einer
    /// Bildschirmfreigabe: Befehle, Dateinamen, Fragetext und Antworttext
    /// eines Chats stehen deshalb nie darin, die zeigt erst die Liste auf
    /// einen Klick.
    nonisolated static func alertDetail(kind: NotchAlertKind, input: NotchChatInput?) -> String? {
        guard let input else { return nil }
        if kind == .awaitingInput, let line = input.activity?.awaitingKindLine { return line }
        return input.project
    }

    /// Der Hinweis bleibt über seine vier Sekunden hinaus stehen, solange
    /// der Mauszeiger über der großen Form ist: Wer gerade darauf klicken
    /// will, trifft sonst das Menü darunter. Gefragt wird der Ort des
    /// Zeigers selbst, kein gemerkter Hover-Zustand.
    nonisolated static func alertHeldByPointer(form: CGRect?, mouse: CGPoint) -> Bool {
        form?.contains(mouse) ?? false
    }

    /// Steht der Zeiger gerade auf einem Hinweis in der großen Form?
    func isPointerOnIslandAlert() -> Bool {
        guard !isExpanded, alert != nil else { return false }
        let mouse = NSEvent.mouseLocation
        return slots.values.contains { slot in
            slot.panel?.isVisible == true && !slot.islandLargeClosing
                && Self.alertHeldByPointer(form: slot.islandLargeForm?.frame, mouse: mouse)
        }
    }

    func setDisplayWithoutAnimation(_ display: NotchDisplay, on slot: NotchSlot) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { slot.viewModel.display = display }
    }
}
