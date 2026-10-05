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
        let order = visualTabOrderIDs
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
            // z. B. ⌘N mitten im Durchtabben den Picker öffnen) → ⌃⌥Tab
            // (nächster wartender Chat) → ⌘N (Picker öffnen) → ⌘⌥←/→
            // (Tab-Wechsel) → ⌘W (Tab schließen). Jeder Schritt gibt bei
            // Treffer `nil` zurück (Event konsumiert), sonst das Event weiter
            // an den nächsten.
            guard let event = handleTabSwitcherKeyDown(event) else { return nil }
            guard let event = handleNextWaitingChatShortcut(event) else { return nil }
            guard let event = handleNewChatShortcut(event) else { return nil }
            guard let event = handleTabNavShortcut(event) else { return nil }
            guard let event = handleGridFocusShortcut(event) else { return nil }
            observeTerminalInterruptKey(event)
            return handleCloseTabShortcut(event)
        }
    }

    /// Reiner BEOBACHTER (konsumiert nie): Ein ESC ohne Modifier, das im
    /// Terminal einer working-Session landet, ist in der Claude-TUI der
    /// Turn-Abbruch — der Stop-Hook feuert dabei nicht, und ein Abbruch vor
    /// dem ersten Output hinterlässt auch keinen Transcript-Marker; die
    /// Session bliebe im working-Stau (QA-Befund 2026-08-17). Der Coordinator
    /// verifiziert den Verdacht (5 s Hook- UND Transcript-Stille), bevor er
    /// den Status dreht — ein ESC mit anderer TUI-Bedeutung bleibt folgenlos.
    private func observeTerminalInterruptKey(_ event: NSEvent) {
        guard let hostWindow, event.window === hostWindow,
              event.keyCode == 53, // ESC
              event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
              let sessionID = selectedSession?.id,
              AgentSessionStatusCoordinator.shared.statusStore
                  .status(for: sessionID) == .working,
              let responder = hostWindow.firstResponder,
              String(describing: type(of: responder)).contains("TerminalView")
        else { return }
        AgentSessionStatusCoordinator.shared.suspectTurnAborted(sessionID)
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

    // MARK: - ⌃⌥Tab: nächster wartender Chat

    /// Verarbeitet ⌃⌥Tab: springt zum Chat, der am längsten auf Eingabe
    /// wartet; wiederholt gedrückt zum nächsten (Reihenfolge und Rotation im
    /// puren `NextWaitingChatResolver`). Umfang sind alle nicht archivierten
    /// Chats des Workspace, nicht nur offene Tabs.
    ///
    /// Navigation über den `selectedSessionID`-Setter — derselbe Pfad wie ein
    /// Sidebar-Klick: öffnet einen noch nicht offenen Chat als Tab, setzt im
    /// sichtbaren Grid den Pane-Fokus und routet in das Fenster, das den Tab
    /// hält.
    ///
    /// Kein wartender Chat → nichts passiert (kein Beep, kein Dialog); das
    /// Event wird trotzdem konsumiert, damit kein Tab-Byte im Terminal
    /// landet. Greift auch bei Fokus im Terminal: der Monitor läuft vor
    /// SwiftTerms `keyDown`, und `TerminalShortcut.bytes` reicht
    /// Control-Combos ohnehin durch.
    ///
    /// Status und `statusSince` werden NUR hier, im Key-Event-Pfad, gelesen —
    /// kein Beobachter, kein Scan im View-Body (Performance-Regeln in
    /// docs/plans/tab-switcher-workspace.md).
    private func handleNextWaitingChatShortcut(_ event: NSEvent) -> NSEvent? {
        guard let hostWindow, event.window === hostWindow,
              TabSwitcherShortcut.isNextWaitingChat(
                  keyCode: event.keyCode, modifiers: event.modifierFlags
              ) else { return event }
        let activityStore = tabSwitcherActivityStore
        // Über die (wenigen) wartenden Einträge des Status-Stores statt über
        // alle Sessions — siehe `NextWaitingChatResolver.candidates`.
        let candidates = NextWaitingChatResolver.candidates(
            statuses: runtimeStatusStore.statuses,
            sessions: workspace.sessions,
            statusSince: { activityStore.statusSince(for: $0) }
        )
        guard let target = NextWaitingChatResolver.next(
            candidates: candidates, current: selectedSessionID
        ) else { return nil }
        selectedSessionID = target
        multiSelection = []
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
    /// Bei AKTIVEM Switcher (Entscheidung pur in
    /// `TabSwitcherShortcut.activeKeyAction`): Tab/Shift+Tab und die
    /// Pfeiltasten navigieren (Grid und Mini-Map räumlich, Projekt-Liste
    /// linear), Esc bricht ab (darf die TUI nie erreichen — würde dort die
    /// laufende Generation abbrechen), Return committet sofort. Jede andere
    /// Taste MIT Ctrl bricht ab und wird geschluckt — wer mit gehaltenem Ctrl
    /// z. B. `C` drückt, will fast nie ein Ctrl+C an die laufende TUI
    /// schicken. Eine Taste OHNE Ctrl heißt dagegen: das Loslassen ist uns
    /// entgangen (Menü-Tracking) — Abbruch, und die Taste läuft normal weiter.
    private func handleTabSwitcherKeyDown(_ event: NSEvent) -> NSEvent? {
        guard let hostWindow, event.window === hostWindow else { return event }

        guard tabSwitcher != nil else {
            guard let direction = TabSwitcherShortcut.direction(
                keyCode: event.keyCode, modifiers: event.modifierFlags
            ) else { return event }
            // Aktivierung braucht ≥ 2 Tabs — `begin` liefert sonst nil. Das
            // Event wird trotzdem konsumiert (No-op), damit kein Tab-Byte im
            // Terminal landet.
            // Umfang (Grid / Workspace / Projekt) statt aller offenen Tabs —
            // siehe `TabSwitcherScope`.
            tabSwitcherRun.lastModifiers = event.modifierFlags
            tabSwitcher = TabSwitcherModel.begin(
                order: refreshTabSwitcherScope(),
                current: selectedSession?.id,
                direction: direction
            )
            if tabSwitcher == nil { tabSwitcherSessions = [] }
            syncTabSwitcherGridMarking()
            return nil
        }

        tabSwitcherRun.lastModifiers = event.modifierFlags
        switch TabSwitcherShortcut.activeKeyAction(keyCode: event.keyCode, modifiers: event.modifierFlags) {
        case .step(let step):
            // Umfang bei jedem Schritt frisch auflösen — Tabs/Slots können
            // sich während des Durchlaufs extern ändern (Archivierung,
            // anderes Fenster).
            tabSwitcher?.advance(step, order: refreshTabSwitcherScope())
        case .arrow(let arrow):
            if isGridActive {
                // Grid sichtbar (Situation A): geometrisch wie ⌃⌘-Pfeile.
                moveTabSwitcherHighlightInGrid(arrow)
                return nil
            } else if tabSwitcherMiniMapWorkspace != nil {
                // Mini-Map (Situation B): räumlich wie ⌃⌘-Pfeile im Grid.
                moveTabSwitcherInMiniMap(arrow)
                return nil
            }
            // Projekt-Liste (Situation C): jede Pfeiltaste = ein Schritt in
            // der Liste, Wrap-around inklusive.
            let step = (arrow == .left || arrow == .up) ? -1 : +1
            tabSwitcher?.advance(step, order: refreshTabSwitcherScope())
        case .commit:
            commitTabSwitcher()
        case .cancel:
            cancelTabSwitcher()
        case .cancelAndPassThrough:
            // Ctrl-Loslassen verpasst (Menü-Tracking): Switcher weg, die
            // Taste gehört wieder dem Terminal bzw. der normalen Pipeline.
            cancelTabSwitcher()
            return event
        }
        syncTabSwitcherGridMarking()
        return nil
    }

    /// Pfeiltaste bei gehaltenem Ctrl im sichtbaren Grid: Highlight springt
    /// geometrisch (`TabSwitcherGridMarking.arrowTarget` → `GridFocusNavigator`,
    /// dieselbe Logik wie ⌃⌘-Pfeile). Am Rand bleibt es stehen.
    private func moveTabSwitcherHighlightInGrid(_ direction: GridFocusDirection) {
        guard let entity = activeGridWorkspaceEntity else { return }
        let order = refreshTabSwitcherScope()
        if let target = TabSwitcherGridMarking.arrowTarget(
            from: tabSwitcher?.highlightedID,
            direction: direction,
            entity: entity,
            order: order
        ) {
            tabSwitcher?.highlight(target, order: order)
        }
        syncTabSwitcherGridMarking()
    }

    /// Spiegelt den Durchlauf in den kleinen Beobachtungswert der
    /// Grid-Markierung (Situation A). Nur im Event-Pfad aufgerufen — nie aus
    /// einem Body. Ohne Durchlauf oder ohne sichtbares Grid: Markierung aus.
    /// Liest den Umfang aus dem Snapshot von `refreshTabSwitcherScope`
    /// (kein zweites Auflösen).
    func syncTabSwitcherGridMarking() {
        guard let tabSwitcher, isGridActive else {
            tabSwitcherGridMarking.reset()
            return
        }
        tabSwitcherGridMarking.update(
            highlightedID: tabSwitcher.highlightedID,
            targets: tabSwitcherSessions.map(\.id)
        )
    }

    /// Installiert den `.flagsChanged`-Monitor: Loslassen von Control bei
    /// aktivem Switcher = Commit. Dauerhaft installiert (idempotent, wie die
    /// anderen Monitore); der Guard auf `tabSwitcher` macht ihn im
    /// Normalbetrieb zu einem Bool-Check pro Modifier-Druck. Beobachtend —
    /// Modifier-Änderungen laufen unverändert weiter.
    ///
    /// Zusätzlich ein Observer auf `NSMenu.didBeginTrackingNotification`:
    /// Lokale Monitore laufen während Menü-Tracking nicht (Ctrl+Klick =
    /// Kontextmenü in Sidebar/Tab-Leiste mitten im Durchlauf). Ein dort
    /// losgelassenes Ctrl sähe dieser Monitor nie — der Switcher bliebe
    /// offen und ein späteres Shift committete ins alte Highlight. Deshalb
    /// bricht jedes beginnende Menü-Tracking den Durchlauf ab.
    func installTabSwitcherFlagsMonitorIfNeeded() {
        if tabSwitcherFlagsMonitor == nil {
            tabSwitcherFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                guard tabSwitcher != nil else { return event }
                let action = TabSwitcherShortcut.flagsChangeAction(
                    previous: tabSwitcherRun.lastModifiers,
                    current: event.modifierFlags
                )
                tabSwitcherRun.lastModifiers = event.modifierFlags
                switch action {
                case .none: break
                // Echtes Loslassen von Control (egal ob Shift o. ä. noch
                // gehalten wird) → Commit.
                case .commit: commitTabSwitcher()
                // Control fehlt, ohne dass wir das Loslassen gesehen haben →
                // nicht ins (veraltete) Highlight springen.
                case .cancel: cancelTabSwitcher()
                }
                return event
            }
        }
        if tabSwitcherMenuObserver == nil {
            tabSwitcherMenuObserver = NotificationCenter.default.addObserver(
                forName: NSMenu.didBeginTrackingNotification,
                object: nil,
                queue: .main
            ) { _ in
                MainActor.assumeIsolated {
                    guard tabSwitcher != nil else { return }
                    cancelTabSwitcher()
                }
            }
        }
    }

    func removeTabSwitcherFlagsMonitor() {
        if let tabSwitcherFlagsMonitor {
            NSEvent.removeMonitor(tabSwitcherFlagsMonitor)
            self.tabSwitcherFlagsMonitor = nil
        }
        if let tabSwitcherMenuObserver {
            NotificationCenter.default.removeObserver(tabSwitcherMenuObserver)
            self.tabSwitcherMenuObserver = nil
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
        let order = refreshTabSwitcherScope()
        tabSwitcher = nil
        tabSwitcherSessions = []
        tabSwitcherGridMarking.reset()
        guard let target = switcher.commitTarget(order: order) else { return }
        selectTabSwitcherTarget(target)
    }

    /// Maus-Commit aus dem Overlay: Klick auf eine Zelle wählt diesen Chat
    /// sofort — auch wenn Control noch gehalten wird. Ohne laufenden
    /// Durchlauf ein No-op: Mini-Map und Liste bleiben während der
    /// Ausblend-Animation noch klickbar, ein Klick dort darf nach Commit/
    /// Abbruch nicht erneut navigieren.
    func commitTabSwitcher(to sessionID: UUID) {
        guard tabSwitcher != nil else { return }
        let order = refreshTabSwitcherScope()
        tabSwitcher = nil
        tabSwitcherSessions = []
        tabSwitcherGridMarking.reset()
        guard order.contains(sessionID) else { return }
        selectTabSwitcherTarget(sessionID)
    }

    /// Gemeinsamer Commit-Schritt. In der Mini-Map (Situation B) bleibt die
    /// Einzelansicht: das Ziel wird groß, Grid bleibt verborgen, die
    /// Workspace-Referenz bleibt und der gemerkte Pane-Fokus zieht mit
    /// (`showSingleSessionFollowingGridFocus`) — „Zurück zum Workspace" landet
    /// so beim zuletzt angesehenen Chat. Sonst der zentrale Selektionspfad.
    /// `tabSwitcherMiniMapWorkspace` stammt aus dem unmittelbar vorher
    /// gelaufenen `refreshTabSwitcherScope()`.
    private func selectTabSwitcherTarget(_ target: UUID) {
        if tabSwitcherMiniMapWorkspace != nil {
            windowStore.showSingleSessionFollowingGridFocus(target, in: windowID)
        } else {
            selectedSessionID = target
        }
        multiSelection = []
    }

    /// Ein räumlicher Schritt in der Mini-Map (pure Logik in
    /// `TabSwitcherMiniMapGeometry.spatialTarget`). Kein Ziel in der Richtung
    /// → Highlight bleibt (kein Wrap-around, wie ⌃⌘-Pfeile). Das Highlight
    /// wandert über `advance` um den Index-Abstand in der Umfangs-Reihenfolge
    /// — `TabSwitcherModel` bleibt unverändert.
    private func moveTabSwitcherInMiniMap(_ direction: GridFocusDirection) {
        let order = refreshTabSwitcherScope()
        guard let entity = tabSwitcherMiniMapWorkspace,
              let current = tabSwitcher?.highlightedID,
              let from = order.firstIndex(of: current),
              let target = TabSwitcherMiniMapGeometry.spatialTarget(
                  from: current, direction: direction, in: entity, order: order
              ),
              let to = order.firstIndex(of: target) else { return }
        tabSwitcher?.advance(to - from, order: order)
    }

    func cancelTabSwitcher() {
        tabSwitcher = nil
        tabSwitcherSessions = []
        tabSwitcherGridMarking.reset()
    }

    /// Löst den Switcher-Umfang frisch auf (`TabSwitcherScope`) und legt die
    /// Ziel-Sessions als Snapshot für das Overlay ab. Läuft NUR im
    /// Key-/Maus-Event-Pfad, nie im View-Body — das Overlay liest den
    /// Snapshot statt bei jedem Rebuild über alle Sessions zu gehen
    /// (Performance-Regel aus docs/plans/tab-switcher-workspace.md).
    /// Gibt die Reihenfolge zurück; leer, wenn es keinen Umfang gibt.
    @discardableResult
    func refreshTabSwitcherScope() -> [UUID] {
        // `headerTabs` (Dictionary über ALLE Sessions) nur einmal pro Taste
        // bauen und für Reihenfolge und Selektion wiederverwenden.
        let openTabs = headerTabs
        let tabs = visualHeaderTabs(from: openTabs)
        let scope = TabSwitcherScope.resolve(
            showsGrid: showsGrid,
            activeWorkspace: activeGridWorkspaceEntity,
            selectedSessionID: tabSwitcherCurrentID(amongHeaderTabs: openTabs),
            openTabs: tabs.map {
                TabSwitcherScope.Tab(
                    id: $0.id,
                    projectID: $0.projectID,
                    isArchived: $0.status == .archived
                )
            }
        )
        let order = scope?.order ?? []
        // Darstellung folgt dem Umfang: A (`.grid`) markiert die Panes und hat
        // kein Overlay, B (`.workspaceMap`) zeigt die Mini-Map, C (`.project`)
        // die Projekt-Liste (`AgentTabSwitcherOverlay`).
        let miniMapWorkspace: AgentGridWorkspace?
        if case .workspaceMap = scope { miniMapWorkspace = activeGridWorkspaceEntity } else { miniMapWorkspace = nil }
        if tabSwitcherMiniMapWorkspace != miniMapWorkspace { tabSwitcherMiniMapWorkspace = miniMapWorkspace }
        let byID = Dictionary(tabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let sessions = order.compactMap { byID[$0] }
        if tabSwitcherSessions != sessions { tabSwitcherSessions = sessions }
        return order
    }

    /// `selectedSession?.id` ohne Linearsuche über alle Sessions, wenn die
    /// Selektion ein offener Tab ist (der Normalfall). Ergebnis identisch:
    /// Ein Treffer in `headerTabs` existiert und ist nicht archiviert — genau
    /// das, was `selectedSession` sucht. Sonst der unveränderte Rückfall.
    private func tabSwitcherCurrentID(amongHeaderTabs openTabs: [AgentChatSession]) -> UUID? {
        guard let selectedSessionID else { return openTabs.first?.id }
        if openTabs.contains(where: { $0.id == selectedSessionID }) { return selectedSessionID }
        return selectedSession?.id
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
    /// - nicht über dem Tab-Strip (`isPointerInTabStripBand`, zustandslos) —
    ///   dort scrollt die Leiste nativ horizontal.
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
              !isPointerInTabStripBand(event) else { return event }

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

        // Bandhöhe zentral in `TabStripBand.height` (34pt, Chrome-Redesign).
        let trafficLightWidth: CGFloat = 80
        let location = event.locationInWindow
        let inTopBand = location.y >= contentView.bounds.height - TabStripBand.height

        // Nur im freien Band: nicht über den Tabs (zustandsloser Hit-Test,
        // Vorfall 2026-08-23), nicht über den Ampel-Buttons.
        if inTopBand, location.x >= trafficLightWidth, !isPointerInTabStripBand(event) {
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

    /// Zustandsloser Hit-Test: liegt der Zeiger JETZT über dem Tab-Strip-Band?
    /// Gating für die Scroll-Monitore und den Doppelklick-Zoom — bewusst KEIN
    /// `isHoveringTabStrip` mehr (Vorfall 2026-08-23: das Hover-Flag blieb
    /// hängen, der Monitor schluckte jedes Mausrad-Event im Fenster, Scrollen
    /// war app-weit tot; Details in `TabStripBand`). Das Flag bleibt nur noch
    /// fürs `isMovable`-Toggle im Einsatz, wo ein Hänger kein Event kapert.
    func isPointerInTabStripBand(_ event: NSEvent) -> Bool {
        guard let window = hostWindow,
              let contentView = window.contentView else { return false }
        return TabStripBand.contains(
            event.locationInWindow,
            contentViewHeight: contentView.bounds.height,
            stripFrame: stripFrameInWindow
        )
    }

    /// Übersetzt vertikales Mausrad über dem Tab-Strip in tab-weises
    /// horizontales Scrollen. Gibt `nil` zurück, wenn das Event konsumiert wurde.
    ///
    /// Gating (sonst Event durchreichen):
    /// - nur dieses Fenster, nur das oberste Band in der gemessenen X-Spanne
    ///   des Strips (`isPointerInTabStripBand`, zustandslos pro Event) →
    ///   Sidebar/Terminal werden nie gekapert, nichts kann hängen bleiben;
    /// - nur „echtes" Mausrad (`hasPreciseScrollingDeltas == false`); Trackpad
    ///   reichen wir durch, damit dessen native horizontale Geste glatt bleibt.
    ///
    /// Eine Rasterung = ein Tab. `delta > 0` (Rad hoch, gleiche Konvention wie
    /// `TerminalScrollGuard`) → ein Tab nach links, sonst nach rechts. Das
    /// System-„natürliches Scrollen" steckt bereits im Vorzeichen von `delta`.
    private func handleTabStripScroll(_ event: NSEvent) -> NSEvent? {
        let tabs = visibleHeaderTabs
        guard let window = hostWindow,
              event.window === window,
              isPointerInTabStripBand(event),
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
            if tabDropSession != nil { tabDropSession = nil }
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
