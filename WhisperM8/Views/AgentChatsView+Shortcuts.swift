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
            multiSelection = []
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
            // Reihenfolge: Ctrl+Tab-Switcher (MUSS zuerst — bei aktivem
            // Switcher konsumiert er ALLE Tasten dieses Fensters, sonst würde
            // z. B. ⌘N mitten im Durchtabben den Picker öffnen) → ⌘N (Picker
            // öffnen) → ⌘⌥←/→ (Tab-Wechsel) → ⌘W (Tab schließen). Jeder
            // Schritt gibt bei Treffer `nil` zurück (Event konsumiert), sonst
            // das Event weiter an den nächsten.
            guard let event = handleTabSwitcherKeyDown(event) else { return nil }
            guard let event = handleNewChatShortcut(event) else { return nil }
            guard let event = handleTabNavShortcut(event) else { return nil }
            guard let event = handleGridFocusShortcut(event) else { return nil }
            return handleCloseTabShortcut(event)
        }
    }

    /// Verarbeitet ⌃⌘←/→/↑/↓ als Pane-Fokuswechsel im sichtbaren Grid
    /// (Plan F9: vollständige Bedienung ohne Maus). Nur bei aktivem Grid —
    /// sonst fällt das Event unverändert durch. Pfeiltasten tragen
    /// `.function`/`.numericPad`-Flags, daher Contains-Prüfung statt
    /// Gleichheit (Muster `TabNavShortcut`).
    private func handleGridFocusShortcut(_ event: NSEvent) -> NSEvent? {
        guard let hostWindow, event.window === hostWindow, isGridActive else { return event }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.contains(.control), modifiers.contains(.command),
              !modifiers.contains(.option), !modifiers.contains(.shift) else { return event }
        let direction: GridFocusDirection?
        switch event.keyCode {
        case 123: direction = .left
        case 124: direction = .right
        case 125: direction = .down
        case 126: direction = .up
        default: direction = nil
        }
        guard let direction else { return event }
        moveGridFocus(direction)
        return nil
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

    /// Verarbeitet ⌘N: öffnet das durchsuchbare „Neuer Chat"-Projekt-Popover
    /// mit Autofokus im Suchfeld (der Picker aktiviert per `onAppear` das erste
    /// Ergebnis → tippen → `Enter`). Bewusst nur öffnen (nicht togglen) —
    /// Schließen macht `Esc` im Picker. Gleiche Window-Gating-Semantik wie
    /// Cmd-W: nur Events des Agent-Chats-Fensters, damit ⌘N in Settings/
    /// Onboarding nichts auslöst. Greift auch bei fokussiertem Terminal-Tab.
    private func handleNewChatShortcut(_ event: NSEvent) -> NSEvent? {
        guard let hostWindow, event.window === hostWindow else { return event }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers == .command,
              event.charactersIgnoringModifiers == "n" else { return event }
        showNewChatProjectPicker = true
        return nil
    }

    /// Verarbeitet ⌘⌥←/→ (Chrome) und ⌘⇧←/→ (Safari) als vorheriger/nächster
    /// Tab (mit Wrap-around). Gibt `nil` zurück, wenn das Event konsumiert wurde,
    /// sonst das Original-Event. Gleiche Window-Gating-Semantik wie Cmd-W: nur
    /// Events des Agent-Chats-Fensters. Die Modifier-/KeyCode-Logik liegt im
    /// reinen, unit-getesteten `TabNavShortcut` (robust gegen die
    /// `.function`/`.numericPad`-Flags auf Pfeiltasten). Der Terminal-Handler
    /// reicht beide Chords durch (siehe `TerminalShortcut.bytes`), deshalb greift
    /// dieser Monitor auch bei Fokus im Terminal.
    private func handleTabNavShortcut(_ event: NSEvent) -> NSEvent? {
        guard let hostWindow, event.window === hostWindow else { return event }
        guard let direction = TabNavShortcut.direction(keyCode: event.keyCode, modifiers: event.modifierFlags) else {
            return event
        }
        selectAdjacentTab(direction)
        return nil
    }

    // MARK: - Ctrl+Tab-Switcher (Alt-Tab-artige Tab-Auswahl)

    /// Verarbeitet den Ctrl+Tab-Switcher im `keyDown`-Pfad. Gibt `nil` zurück,
    /// wenn das Event konsumiert wurde, sonst das Original-Event.
    ///
    /// Warum das auch bei fokussiertem Terminal greift: `TerminalShortcut.bytes`
    /// reicht Control-Combos explizit durch (`guard !hasControl`), und dieser
    /// Monitor konsumiert das Event, BEVOR SwiftTerms `keyDown` ein Tab-Byte
    /// an die PTY schicken würde.
    ///
    /// Bei AKTIVEM Switcher werden alle `keyDown` dieses Fensters konsumiert:
    /// Tab/Shift+Tab und ←/→ navigieren, Esc bricht ab (darf die TUI nie
    /// erreichen — würde dort die laufende Generation abbrechen), Return
    /// committet sofort. Jede andere Taste bricht ab und wird geschluckt —
    /// wer mit gehaltenem Ctrl z. B. `C` drückt, will fast nie ein Ctrl+C an
    /// die laufende TUI schicken.
    private func handleTabSwitcherKeyDown(_ event: NSEvent) -> NSEvent? {
        guard let hostWindow, event.window === hostWindow else { return event }
        let direction = TabSwitcherShortcut.direction(
            keyCode: event.keyCode, modifiers: event.modifierFlags
        )

        guard tabSwitcher != nil else {
            guard let direction else { return event }
            // Aktivierung braucht ≥ 2 Tabs — `begin` liefert sonst nil. Das
            // Event wird trotzdem konsumiert (No-op), damit kein Tab-Byte im
            // Terminal landet.
            tabSwitcher = TabSwitcherModel.begin(
                order: headerTabs.map(\.id),
                current: selectedSession?.id,
                direction: direction
            )
            return nil
        }

        if let direction {
            tabSwitcher?.advance(direction, order: headerTabs.map(\.id))
            return nil
        }
        switch event.keyCode {
        case TerminalShortcut.KeyCode.leftArrow:
            tabSwitcher?.advance(-1, order: headerTabs.map(\.id))
        case TerminalShortcut.KeyCode.rightArrow:
            tabSwitcher?.advance(+1, order: headerTabs.map(\.id))
        case TabSwitcherShortcut.KeyCode.upArrow:
            // Eine Grid-Reihe hoch/runter: Schrittweite = Spaltenzahl des
            // Karten-Grids (vom Overlay gemeldet), Wrap-around inklusive.
            tabSwitcher?.advance(-max(1, tabSwitcherColumns), order: headerTabs.map(\.id))
        case TabSwitcherShortcut.KeyCode.downArrow:
            tabSwitcher?.advance(+max(1, tabSwitcherColumns), order: headerTabs.map(\.id))
        case TabSwitcherShortcut.KeyCode.escape:
            cancelTabSwitcher()
        case TerminalShortcut.KeyCode.returnKey:
            commitTabSwitcher()
        default:
            cancelTabSwitcher()
        }
        return nil
    }

    /// Installiert den `.flagsChanged`-Monitor: Loslassen von Control bei
    /// aktivem Switcher = Commit. Dauerhaft installiert (idempotent, wie die
    /// anderen Monitore); der Guard auf `tabSwitcher` macht ihn im
    /// Normalbetrieb zu einem Bool-Check pro Modifier-Druck. Beobachtend —
    /// Modifier-Änderungen laufen unverändert weiter.
    func installTabSwitcherFlagsMonitorIfNeeded() {
        guard tabSwitcherFlagsMonitor == nil else { return }
        tabSwitcherFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            guard tabSwitcher != nil else { return event }
            // Control weg (egal ob Shift o. ä. noch gehalten wird) → Commit.
            if !event.modifierFlags.contains(.control) {
                commitTabSwitcher()
            }
            return event
        }
    }

    func removeTabSwitcherFlagsMonitor() {
        if let tabSwitcherFlagsMonitor {
            NSEvent.removeMonitor(tabSwitcherFlagsMonitor)
            self.tabSwitcherFlagsMonitor = nil
        }
    }

    /// Committet den per Tastatur hervorgehobenen Tab (Control losgelassen
    /// oder Return). Existiert der Tab nicht mehr, bleibt die Selektion
    /// unverändert.
    func commitTabSwitcher() {
        guard let switcher = tabSwitcher else { return }
        // Erst den Switcher-State räumen, DANN selektieren — der
        // `onChange(of: selectedSessionID)`-Cancel (Klick in Sidebar/Strip
        // bricht den Switcher ab) darf den eigenen Commit nicht anfassen.
        tabSwitcher = nil
        guard let target = switcher.commitTarget(order: headerTabs.map(\.id)) else { return }
        selectedSessionID = target
        multiSelection = []
    }

    /// Maus-Commit aus dem Overlay: Klick auf eine Zelle wählt diesen Chat
    /// sofort — auch wenn Control noch gehalten wird.
    func commitTabSwitcher(to sessionID: UUID) {
        tabSwitcher = nil
        guard headerTabs.contains(where: { $0.id == sessionID }) else { return }
        selectedSessionID = sessionID
        multiSelection = []
    }

    func cancelTabSwitcher() {
        tabSwitcher = nil
    }

    // MARK: - Zwei-Finger-Swipe (Tab links/rechts)

    /// Übersetzt eine horizontale Zwei-Finger-Trackpad-Geste (Safari-Stil) in
    /// den benachbarten Tab — gleiche Semantik wie ⌘⌥←/→ (Wrap-around,
    /// Multi-Select-Reset via `selectAdjacentTab`). Läuft im selben
    /// `scrollWheel`-Monitor wie der Tab-Strip-Scroll (siehe
    /// `installTabStripScrollMonitorIfNeeded`). Gibt `nil` zurück, wenn das
    /// Event konsumiert wurde.
    ///
    /// Gating (sonst Event durchreichen):
    /// - nur dieses Fenster, nur Trackpad (`hasPreciseScrollingDeltas`) —
    ///   Mausräder gehören dem Tab-Strip-Monitor bzw. dem Terminal;
    /// - nicht über dem Tab-Strip (`isHoveringTabStrip`) — dort scrollt die
    ///   Leiste nativ horizontal.
    ///
    /// Die Gesten-Logik (Achsen-Entscheid, Schwellwert, Einmal-Trigger,
    /// Momentum-Schlucken) lebt pur und getestet im
    /// `TabScrollSwipeRecognizer`; vertikale Gesten laufen unangetastet
    /// durch → Terminal-Scrollback bleibt unberührt. Bei aktivem
    /// Ctrl+Tab-Switcher wird der Trigger ignoriert (Geste trotzdem
    /// geschluckt) — zwei Navigationsmodi würden ums Highlight kämpfen.
    ///
    /// Vorzeichen: `scrollingDeltaX` wird über `isDirectionInvertedFromDevice`
    /// in den FINGER-Raum normalisiert (positiv = Finger nach rechts); Finger
    /// nach rechts → Tab rechts. Sollte die QA auf realer Hardware eine
    /// invertierte Richtung zeigen, dreht sich NUR diese Normalisierung.
    private func handleTabSwipeScroll(_ event: NSEvent) -> NSEvent? {
        guard let hostWindow, event.window === hostWindow,
              event.hasPreciseScrollingDeltas,
              !isHoveringTabStrip else { return event }

        let sign: CGFloat = event.isDirectionInvertedFromDevice ? 1 : -1
        var recognizer = tabScrollSwipeRecognizer
        let verdict = recognizer.handle(
            phase: event.phase,
            momentumPhase: event.momentumPhase,
            deltaX: event.scrollingDeltaX * sign,
            deltaY: event.scrollingDeltaY * sign
        )
        tabScrollSwipeRecognizer = recognizer

        switch verdict {
        case .passThrough:
            return event
        case .consume:
            return nil
        case .trigger(let direction):
            if tabSwitcher == nil {
                selectAdjacentTab(direction)
            }
            return nil
        }
    }

    // MARK: - Titelleisten-Maus: Doppelklick-Zoom

    func installTitleBarZoomHandlerIfNeeded() {
        guard titleBarZoomMonitor == nil else { return }
        titleBarZoomMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            // Grid-Ansicht: Klick in eine nicht-fokussierte Pane verschiebt
            // die Selektion dorthin (Dictation-Routing folgt). Beobachtend —
            // das Event läuft danach unverändert weiter (Terminal-Klick,
            // Titelzonen-Doppelklick).
            handleGridPaneMouseDown(event)
            return handleTitleBarMouse(event)
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
    /// scrollt. Pipeline wie beim keyDown-Monitor: erst Tab-Strip-Scroll
    /// (Mausrad über dem Strip), dann Zwei-Finger-Swipe (Trackpad-Blättern) —
    /// jeder Schritt gibt bei Konsum `nil` zurück.
    func installTabStripScrollMonitorIfNeeded() {
        guard tabStripScrollMonitor == nil else { return }
        tabStripScrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard let event = handleTabStripScroll(event) else { return nil }
            return handleTabSwipeScroll(event)
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

    // MARK: - Drag-Ende: Einfügelinie zurücksetzen

    /// Lokaler `leftMouseUp`-Monitor. Setzt `tabInsertionIndex` beim Loslassen
    /// der Maustaste zurück — der einzige verlässliche „Drag vorbei"-Geber, weil
    /// `.draggable` die parallele `DragGesture` cancelt (kein `onEnded`) und
    /// `DropDelegate.dropExited`/`performDrop` bei Cancel/Außerhalb-Drop nicht
    /// zuverlässig feuern. Reines Beobachten — das Event läuft unverändert weiter.
    func installTabDragEndMonitorIfNeeded() {
        guard tabDragEndMonitor == nil else { return }
        tabDragEndMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { event in
            if tabInsertionIndex != nil { tabInsertionIndex = nil }
            return event
        }
    }

    func removeTabDragEndMonitor() {
        if let tabDragEndMonitor {
            NSEvent.removeMonitor(tabDragEndMonitor)
            self.tabDragEndMonitor = nil
        }
    }
}
