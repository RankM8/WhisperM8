import SwiftUI
import AppKit

/// Tastatur-/Maus-Event-Monitore und Tab-Navigation der AgentChatsView.
/// Aus AgentChatsView.swift ausgelagert (reiner Move) — die genutzten
/// View-Member sind dort auf `internal` gehoben. install*/remove* werden
/// vom Body (onAppear/onDisappear) aufgerufen und sind daher internal;
/// die handle*/selectAdjacentTab-Helfer bleiben private (nur hier genutzt).
extension AgentChatsView {
    /// Wechselt zum benachbarten Tab (vor/zurück) mit Wrap-around. Quelle ist
    /// `headerTabs` (sichtbare, nicht-archivierte Tabs in Anzeige-Reihenfolge) —
    /// konsistent mit den ⌘1–⌘9-Sprüngen. Das Setzen von `selectedSessionID`
    /// triggert die bestehende UIState-Persistenz via `onChange`.
    private func selectAdjacentTab(_ direction: Int) {
        let order = headerTabs.map(\.id)
        if let next = adjacentTabID(in: order, current: selectedSessionID, direction: direction) {
            selectedSessionID = next
        }
    }

    // MARK: - Cmd-W (Tab schließen)

    /// Installiert den lokalen `keyDown`-Monitor für Cmd-W. Idempotent —
    /// bei wiederholtem `onAppear` passiert nichts. Wir nutzen bewusst einen
    /// NSEvent-Monitor statt eines SwiftUI-Menü-Commands: Der Monitor fängt
    /// das Event ab, BEVOR es das Terminal (SwiftTerm-`keyDown`) oder das
    /// AppKit-Menü („Fenster schließen") erreicht — Cmd-W schließt damit
    /// auch dann den Tab, wenn der Fokus im Terminal liegt. Belegt durch den
    /// bestehenden `TerminalKeyboardShortcutHandler`, der so Cmd-Z/Cmd-⌫
    /// abfängt.
    func installCloseTabShortcutIfNeeded() {
        guard closeTabKeyMonitor == nil else { return }
        closeTabKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Erst Tab-Wechsel (⌘⌥←/→) prüfen — bei Treffer ist `event` konsumiert
            // (nil). Sonst durchreichen an die Cmd-W-Prüfung.
            guard let event = handleTabNavShortcut(event) else { return nil }
            return handleCloseTabShortcut(event)
        }
    }

    func removeCloseTabShortcut() {
        if let closeTabKeyMonitor {
            NSEvent.removeMonitor(closeTabKeyMonitor)
            self.closeTabKeyMonitor = nil
        }
    }

    /// Verarbeitet Cmd-W. Gibt `nil` zurück, wenn das Event konsumiert wurde
    /// (Tab geschlossen), sonst das Original-Event für die normale Pipeline.
    /// Bewusst nur für das Agent-Chats-Fenster (`event.window === hostWindow`):
    /// In Settings/Onboarding und über Sheets bleibt Cmd-W das System-„Schließen".
    /// Ohne offenen Tab fällt Cmd-W ebenfalls durch → das Fenster schließt
    /// sich wie gewohnt (Browser-Verhalten: letzter Tab zu → Fenster zu).
    private func handleCloseTabShortcut(_ event: NSEvent) -> NSEvent? {
        guard let hostWindow, event.window === hostWindow else { return event }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers == .command,
              event.charactersIgnoringModifiers == "w" else { return event }
        guard let session = selectedSession else { return event }
        closeTab(session)
        return nil
    }

    /// Verarbeitet ⌘⌥← / ⌘⌥→ (vorheriger/nächster Tab, mit Wrap-around). Gibt
    /// `nil` zurück, wenn das Event konsumiert wurde, sonst das Original-Event.
    /// Gleiche Window-Gating-Semantik wie Cmd-W: nur Events des Agent-Chats-
    /// Fensters. Der Terminal-Handler reicht ⌘⌥-Pfeile durch (siehe
    /// `TerminalShortcut.bytes`), deshalb fängt dieser Monitor sie zuverlässig
    /// ab — auch wenn der Fokus im Terminal liegt.
    private func handleTabNavShortcut(_ event: NSEvent) -> NSEvent? {
        guard let hostWindow, event.window === hostWindow else { return event }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers == [.command, .option] else { return event }
        switch event.keyCode {
        case TerminalShortcut.KeyCode.leftArrow:
            selectAdjacentTab(-1)
            return nil
        case TerminalShortcut.KeyCode.rightArrow:
            selectAdjacentTab(+1)
            return nil
        default:
            return event
        }
    }

    // MARK: - Titelleisten-Maus: Doppelklick-Zoom

    func installTitleBarZoomHandlerIfNeeded() {
        guard titleBarZoomMonitor == nil else { return }
        titleBarZoomMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            handleTitleBarMouse(event)
        }
    }

    func removeTitleBarZoomHandler() {
        if let titleBarZoomMonitor {
            NSEvent.removeMonitor(titleBarZoomMonitor)
            self.titleBarZoomMonitor = nil
        }
    }

    /// Doppelklick im freien Titelleisten-Band → System-Zoom. Lokaler Monitor,
    /// weil `hiddenTitleBar` + `fullSizeContentView` die native Titelleiste durch
    /// den Tab-Strip ersetzen und macOS den Doppelklick dort nicht mehr selbst
    /// auswertet.
    ///
    /// Das Fenster-Dragging läuft NICHT hier, sondern über ein hover-gesteuertes
    /// `isMovable`-Toggle (siehe `.onChange(of: isHoveringTabStrip)` am Body):
    /// über dem Tab-Strip AUS (Tab-Drag/Reorder), auf freien Flächen AN (natives
    /// Fenster-Verschieben). Schon beim Hover gesetzt — nicht erst beim mouseDown,
    /// was vorher zu „Tab-Drag zieht doch das Fenster" führte.
    private func handleTitleBarMouse(_ event: NSEvent) -> NSEvent? {
        guard event.clickCount == 2,
              let window = hostWindow,
              event.window === window,
              let contentView = window.contentView else { return event }

        let topZone: CGFloat = 28
        let trafficLightWidth: CGFloat = 80
        let location = event.locationInWindow
        let inTopBand = location.y >= contentView.bounds.height - topZone

        // Nur im freien Band: nicht über den Tabs, nicht über den Ampel-Buttons.
        if inTopBand, location.x >= trafficLightWidth, !isHoveringTabStrip {
            TitleBarZoom.performSystemDoubleClickAction(on: window)
            return nil
        }
        return event
    }

    // MARK: - Mausrad-Scroll für den Tab-Strip

    /// Installiert den lokalen `scrollWheel`-Monitor. Idempotent. Wir nutzen —
    /// wie beim Cmd-W- und Zoom-Monitor — bewusst einen NSEvent-Monitor, weil
    /// SwiftUI einen `ScrollView(.horizontal)` nicht per vertikalem Mausrad
    /// scrollt.
    func installTabStripScrollMonitorIfNeeded() {
        guard tabStripScrollMonitor == nil else { return }
        tabStripScrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            handleTabStripScroll(event)
        }
    }

    func removeTabStripScrollMonitor() {
        if let tabStripScrollMonitor {
            NSEvent.removeMonitor(tabStripScrollMonitor)
            self.tabStripScrollMonitor = nil
        }
    }

    /// Übersetzt vertikales Mausrad über dem Tab-Strip in tab-weises
    /// horizontales Scrollen. Gibt `nil` zurück, wenn das Event konsumiert wurde.
    ///
    /// Gating (sonst Event durchreichen):
    /// - nur dieses Fenster, nur das oberste 28px-Band, nur innerhalb der
    ///   gemessenen X-Spanne des Strips → Sidebar/Terminal werden nie gekapert;
    /// - nur „echtes" Mausrad (`hasPreciseScrollingDeltas == false`); Trackpad
    ///   reichen wir durch, damit dessen native horizontale Geste glatt bleibt.
    ///
    /// Eine Rasterung = ein Tab. `delta > 0` (Rad hoch, gleiche Konvention wie
    /// `TerminalScrollGuard`) → ein Tab nach links, sonst nach rechts. Das
    /// System-„natürliches Scrollen" steckt bereits im Vorzeichen von `delta`.
    private func handleTabStripScroll(_ event: NSEvent) -> NSEvent? {
        let tabs = headerTabs
        // Gating per Hover-Flag statt Koordinaten-Hit-Test: nur Events
        // konsumieren, während die Maus über dem Strip schwebt. Echtes Mausrad
        // (`hasPreciseScrollingDeltas == false`) übersetzen wir in Tab-Schritte;
        // Trackpad reichen wir durch, damit dessen native horizontale Geste
        // glatt bleibt. Sidebar/Terminal werden nie gekapert.
        guard isHoveringTabStrip,
              let window = hostWindow,
              event.window === window,
              !tabs.isEmpty,
              !event.hasPreciseScrollingDeltas else { return event }

        let delta = event.deltaY != 0 ? event.deltaY : event.deltaX
        guard delta != 0 else { return nil }

        // Anker als UUID auflösen (stabil über Reorder/Close); Fallback auf die
        // Selektion, sonst den ersten Tab. Index immer frisch gegen `tabs`
        // berechnen → kein Out-of-Range.
        let baseID = stripWheelAnchorID ?? selectedSessionID
        let currentIndex = baseID.flatMap { id in tabs.firstIndex(where: { $0.id == id }) } ?? 0
        let step = delta > 0 ? -1 : 1
        let newIndex = min(max(currentIndex + step, 0), tabs.count - 1)
        let newID = tabs[newIndex].id
        if newID != stripWheelAnchorID {
            stripWheelAnchorID = newID
            stripWheelTick &+= 1
        }
        return nil
    }
}
