import AppKit
import Combine
import SwiftUI

/// Vereinte Pille, Status-Seite: Die Pille ohne Notch sieht aus wie die
/// Diktat-Pille (eigener Schattenrand, kein Fensterschatten), macht dem Diktat
/// auf ihrem Bildschirm Platz und reicht die Raute für wartende Chats an die
/// Diktat-Pille. Ein Klick auf den ruhenden Kern startet ein Diktat.
extension NotchStatusController {
    // MARK: Diktat

    /// Steht das Diktat auf diesem Bildschirm, zeigt sich dort nur das Diktat.
    func isDictationShown(on screen: NotchScreenInfo) -> Bool {
        config.unified && hub.dictationDisplayID == screen.displayID
    }

    /// Diktat erscheint oder geht: neu zeichnen. Danach einen Hinweis, der
    /// während des Diktats kam, einmal nachholen, wenn der Chat noch wartet.
    func observeDictation() {
        hub.$dictationDisplayID
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] displayID in
                guard let self else { return }
                if displayID != nil, self.expandedKind != nil { self.collapse(rebuildAfter: false) }
                if displayID == nil { self.replayAlertAfterDictation() }
                self.render()
            }
            .store(in: &activeCancellables)
    }

    func replayAlertAfterDictation() {
        guard let pending = alertDuringDictation else { return }
        alertDuringDictation = nil
        var statuses: [UUID: AgentSessionRuntimeStatus] = [:]
        for input in inputs { if let status = input.status { statuses[input.id] = status } }
        guard NotchStatusModel.isStillValid(pending, statuses: statuses) else { return }
        show(alert: pending)
    }

    /// Raute für die Diktat-Pille: nur wartende Chats und Fehler.
    func publishBadge(_ summary: NotchSummary) {
        hub.updateBadge(config.unified ? DictationStatusBadge(summary: summary) : nil)
    }

    /// Klick auf den ruhenden Kern: Diktat wie per Hotkey.
    func startDictationFromPill(_ kind: NotchPlacement.Kind) {
        slots[kind]?.lastCoreClickAt = Date()
        collapse(rebuildAfter: false)
        startDictation()
    }

    // MARK: Fenster

    /// Kill-Switch umgelegt: Fenster weg, beim nächsten Zeichnen neu.
    func dismantlePanels() {
        collapse(rebuildAfter: false)
        for slot in slots.values {
            slot.shrinkTask?.cancel()
            slot.panel?.orderOut(nil)
            slot.panel = nil
            slot.host = nil
            slot.lastDisplay = nil
            slot.lastFrame = nil
            slot.coreFrame = nil
        }
    }

    /// SwiftUI meldet Pille und Kern: Treffer-Fläche und Klickziel.
    func pillLayoutChanged(_ kind: NotchPlacement.Kind, pill: CGRect, core: CGRect) {
        guard let slot = slots[kind] else { return }
        if slot.host?.interactiveSwiftUIFrame != pill { slot.host?.interactiveSwiftUIFrame = pill }
        slot.coreFrame = core.width > 0 ? core : nil
    }

    /// Pille ohne Notch, vereint: festes Fenster mit Schattenrand, die Pille
    /// darin so breit wie ihr Inhalt. Zustandswechsel animiert SwiftUI (eine
    /// Kurve, um die Mitte), das Fenster springt nur zwischen zu und offen.
    func renderUnifiedPill(
        _ slot: NotchSlot, screen: NotchScreenInfo,
        rows: [NotchRow], summary: NotchSummary, sections: [NotchSection]
    ) {
        let token = PerfBudgets.unifiedPillRender.begin()
        defer { PerfBudgets.unifiedPillRender.end(token) }
        let expandedHere = expandedKind == slot.kind
        guard !slot.isFullscreenHidden, !isDictationShown(on: screen) else { return hide(slot) }
        let mode = NotchStatusModel.panelMode(
            isExpanded: expandedHere, alert: alert, rows: rows, sections: expandedHere ? sections : [])
        let center = pillCenter(on: screen)
        let display = NotchDisplay(
            style: .pill, summary: summary, alert: alert, isExpanded: expandedHere,
            sections: expandedHere ? sections : [],
            opensUpward: NotchPillPlacement.opensUpward(center: center, on: screen),
            selectedRowID: expandedHere ? keyboardSelection : nil)
        let frame = UnifiedPillGeometry.statusPanelFrame(mode: mode, center: center, screen: screen)

        let panel = ensurePanel(slot)
        panel.hasShadow = false
        let wasVisible = panel.isVisible
        if display != slot.lastDisplay {
            slot.lastDisplay = display
            slot.viewModel.display = display
        }
        updatePillMouse(slot, display: display)
        if frame != slot.lastFrame, slot.dragOrigin == nil {
            let shrinking = wasVisible && (slot.lastFrame.map { frame.height < $0.height } ?? false)
            slot.lastFrame = frame
            slot.shrinkTask?.cancel()
            slot.shrinkTask = nil
            if shrinking {
                // Erst die Liste ausblenden lassen, dann das Fenster verkleinern.
                slot.shrinkTask = Task { [weak slot] in
                    try? await Task.sleep(for: .milliseconds(260))
                    guard !Task.isCancelled, let slot, slot.lastFrame == frame else { return }
                    slot.panel?.setFrame(frame, display: true)
                }
            } else {
                panel.setFrame(frame, display: true)
            }
        }
        if !wasVisible { panel.orderFrontRegardless() }
    }

    /// Ziehen der vereinten Pille: ihren Mittelpunkt führen, die Pille selbst
    /// bleibt im sichtbaren Bereich (nicht das Fenster mit seinem Rand).
    func unifiedPillDragged(_ slot: NotchSlot, panel: NotchPanel, origin: CGPoint, offset: CGVector, screen: NotchScreenInfo) {
        let size = panel.frame.size
        let start = CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
        let width = slot.host?.interactiveSwiftUIFrame?.width ?? NotchGeometry.pillIdleWidth
        let center = UnifiedPillGeometry.draggedCenter(from: start, by: offset, compactWidth: width, screen: screen)
        panel.setFrameOrigin(CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2))
    }

    // MARK: Tastatur

    /// Hotkey „Statusliste öffnen“: Liste mit Tastaturfokus, Pfeile wählen,
    /// Return springt in den Chat, Esc schließt. Ein zweiter Druck schließt.
    func openListFromKeyboard() {
        guard config.isActive else { return }
        let kinds = placements().map(\.kind)
        guard let kind = kinds.contains(.pill) ? NotchPlacement.Kind.pill : kinds.first else { return }
        if expandedKind == kind { return collapse() }
        collapse(rebuildAfter: false)
        toggleExpanded(kind)
        keyboardSelection = listRowIDs.first
        render()
    }

    func handleListKey(_ event: NSEvent) -> Bool {
        guard isExpanded, !listRowIDs.isEmpty else { return false }
        switch event.keyCode {
        case 125, 126: // runter, hoch
            let step = event.keyCode == 125 ? 1 : -1
            let current = keyboardSelection.flatMap { listRowIDs.firstIndex(of: $0) }
            let next = current.map { min(max($0 + step, 0), listRowIDs.count - 1) } ?? 0
            keyboardSelection = listRowIDs[next]
            render()
            return true
        case 36, 76: // Return, Enter
            guard let id = keyboardSelection else { return false }
            select(sessionID: id)
            return true
        default:
            return false
        }
    }
}
