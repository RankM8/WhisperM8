import AppKit
import Combine
import SwiftUI

/// Fenster, Bildschirme, Vollbild und Ziehen der Notch-Anzeige. Die Anzeige
/// steht an höchstens zwei Stellen (`NotchPillPlacement.placements`): an der
/// Notch wie bisher und als dauerhafte Pille auf dem Bildschirm des
/// Agent-Chats-Fensters, wenn der keine Notch hat.
extension NotchStatusController {
    // MARK: Darstellung

    func render() {
        guard config.isActive else { return }
        let current = now()
        let rows = NotchStatusModel.rows(from: inputs, now: current, showFreshDone: config.showFreshDone)
        let summary = NotchStatusModel.summary(of: rows)
        let sections = isExpanded ? NotchStatusModel.sections(of: rows) : []
        listRowIDs = sections.flatMap { $0.rows.map(\.id) }
        let placements = placements()
        // Vereinte Pille: Raute für die Diktat-Pille (nur bei Änderung).
        publishBadge(summary)

        // Die Stelle mit der offenen Liste ist weg (Fenster auf anderen
        // Bildschirm gezogen, Bildschirm getrennt): Liste zu.
        if let expandedKind, !placements.contains(where: { $0.kind == expandedKind }) {
            collapse(rebuildAfter: false)
        }

        for kind in NotchPlacement.Kind.allCases {
            guard let slot = slots[kind] else { continue }
            guard let placement = placements.first(where: { $0.kind == kind }) else {
                hide(slot)
                continue
            }
            if slot.screen != placement.screen {
                slot.screen = placement.screen
                slot.lastFrame = nil
            }
            render(slot, screen: placement.screen, rows: rows, summary: summary, sections: sections)
        }
        updateIslandRefresh()
    }

    /// Solange an einer Kamera-Insel etwas in der Menüleiste steht, alle 30 s
    /// nachmessen: Ein neues Menü oder Statussymbol wäre sonst bis zum
    /// nächsten App-Wechsel verdeckt. Kein Takt, wenn dort nichts steht.
    private func updateIslandRefresh() {
        let screens = slots.values.filter(\.showsIslandInBar).compactMap(\.screen)
        guard !screens.isEmpty else {
            islandRefreshTask?.cancel()
            islandRefreshTask = nil
            return
        }
        guard islandRefreshTask == nil else { return }
        islandRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.islandRefreshInterval)
                guard !Task.isCancelled, let self else { return }
                NotchIslandMonitor.shared.measure(self.slots.values.filter(\.showsIslandInBar).compactMap(\.screen))
            }
        }
    }

    private func render(
        _ slot: NotchSlot, screen: NotchScreenInfo,
        rows: [NotchRow], summary: NotchSummary, sections: [NotchSection]
    ) {
        if slot.isUnified {
            return renderUnifiedPill(slot, screen: screen, rows: rows, summary: summary, sections: sections)
        }
        let expandedHere = expandedKind == slot.kind
        let isPill = slot.kind == .pill
        slot.showsIslandInBar = false
        // Kamera-Insel: In der Menüleiste steht nur, wofür die Messung Platz
        // belegt (kompakt, minimal oder nichts).
        let island = screen.hasIsland ? islandState(slot, screen: screen, summary: summary) : nil
        // Die Pille steht immer da, wie die Notch selbst; an der Notch
        // erscheint die Anzeige nur, wenn etwas los ist. Vereint macht die
        // Notch dem Diktat Platz, das dann selbst dort hängt.
        guard !slot.isFullscreenHidden, !isDictationShown(on: screen) else { return hide(slot) }
        if let island, !expandedHere, alert == nil, island.presentation == .hidden {
            return retractIsland(slot, screen: screen)
        }
        guard isPill || NotchStatusModel.isVisible(summary: summary, isExpanded: expandedHere, alert: alert) else {
            return hide(slot)
        }

        let mode = NotchStatusModel.panelMode(
            isExpanded: expandedHere, alert: alert, rows: rows, sections: expandedHere ? sections : [])
        let pillCenter = isPill ? pillCenter(on: screen) : nil
        let frame = NotchGeometry.panelFrame(screen: screen, mode: mode, pillCenter: pillCenter, islandBand: island?.band)
        let display = NotchDisplay(
            style: Self.displayStyle(screen: screen, islandBand: island?.band),
            summary: summary, alert: alert, isExpanded: expandedHere,
            sections: expandedHere ? sections : [],
            opensUpward: pillCenter.map { NotchPillPlacement.opensUpward(center: $0, on: screen) } ?? false,
            selectedRowID: expandedHere ? keyboardSelection : nil,
            cameraOffset: island == nil || frame == island?.band.detachedFrame ? 0 : screen.notchCenterX - frame.midX)

        slot.showsIslandInBar = island.map { $0.presentation != .hidden } ?? false
        let panel = ensurePanel(slot)
        // Ohne Notch ein Fensterschatten: Ein im Fenster gezeichneter Schatten
        // bräuchte einen Rand, der bei einer dauerhaft sichtbaren Pille Klicks
        // in die Fenster darunter abfinge.
        panel.hasShadow = !screen.hasNotch
        let wasVisible = panel.isVisible
        slot.shrinkTask?.cancel()
        slot.shrinkTask = nil
        if display != slot.lastDisplay {
            slot.lastDisplay = display
            // VoiceOver: Das Fenster nennt, was die Anzeige zeigt.
            panel.setAccessibilityLabel(display.accessibilitySummary)
            if let island, island.band.detachedFrame == nil, !wasVisible, !display.hasIslandBody,
               !slot.returnsFromDictation,
               !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                growIsland(slot, screen: screen, to: display)
            } else {
                setDisplay(display, on: slot, wasVisible: wasVisible)
            }
        }
        updatePillMouse(slot, display: display)
        // Während des Ziehens bestimmt die Maus die Lage.
        if frame != slot.lastFrame, slot.dragOrigin == nil {
            slot.lastFrame = frame
            if wasVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                // Über den Animator: `setFrame(_:display:animate:)` hielte den
                // Main Thread für die ganze Animation fest.
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.2
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    panel.animator().setFrame(frame, display: true)
                }
            } else {
                panel.setFrame(frame, display: true)
            }
        }
        if !wasVisible { panel.orderFrontRegardless() }
        slot.returnsFromDictation = false
    }

    /// Notch: Band in der Aussparung. Kamera-Insel: die Kapsel um die Kamera
    /// (`islandBand`, ohne Angabe der schmale Hals). Sonst die Pille.
    nonisolated static func displayStyle(screen: NotchScreenInfo, islandBand: NotchIslandBand? = nil) -> NotchDisplay.Style {
        switch screen.cutout {
        case .none: return .pill
        case .notch: return .notch(width: screen.notchWidth, height: screen.safeAreaTop)
        case .island: return .island(islandBand ?? NotchIslandGeometry.band(screen: screen))
        }
    }

    // MARK: Kamera-Insel

    /// Stufe und Band der Anzeige an der Insel aus Zählern und letzter
    /// Messung. Ändert sich, was gezeigt werden soll, wird neu gemessen
    /// (kein eigener Beobachter; die Antwort zeichnet bei Bedarf neu).
    func islandState(
        _ slot: NotchSlot, screen: NotchScreenInfo, summary: NotchSummary
    ) -> (presentation: NotchIslandPresentation, band: NotchIslandBand) {
        let signal = NotchIslandSignal(summary: summary)
        if slot.lastIslandSignal != signal {
            slot.lastIslandSignal = signal
            if signal != nil { NotchIslandMonitor.shared.measure([screen]) }
        }
        let occupancy = islandOccupancy[screen.displayID]
        let presentation = NotchIslandGeometry.presentation(signal: signal, screen: screen, occupancy: occupancy)
        let band = NotchIslandGeometry.band(
            screen: screen, occupancy: occupancy, presentation: presentation, digits: signal?.digits ?? 1)
        return (presentation, band)
    }

    /// Erscheinen an der Insel: erst nur die Kapsel um die Kamera (deckt sich
    /// mit Apples Insel), dann wächst sie im nächsten Bild seitlich auf.
    private func growIsland(_ slot: NotchSlot, screen: NotchScreenInfo, to display: NotchDisplay) {
        var start = display
        start.style = .island(NotchIslandGeometry.band(screen: screen, occupancy: islandOccupancy[screen.displayID]))
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { slot.viewModel.display = start }
        DispatchQueue.main.async { [weak slot] in
            guard let slot, slot.lastDisplay == display else { return }
            slot.viewModel.display = display
        }
    }

    /// Nichts mehr zu zeigen: Die Flügel ziehen sich in die Insel zurück,
    /// dann geht das Fenster.
    private func retractIsland(_ slot: NotchSlot, screen: NotchScreenInfo) {
        guard let panel = slot.panel, panel.isVisible, var display = slot.lastDisplay, !display.hasIslandBody,
              case .island(let shown) = display.style, shown.detachedFrame == nil,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            // Schon im Rückzug: laufen lassen.
            if slot.shrinkTask != nil, slot.lastDisplay == nil { return }
            return hide(slot)
        }
        display.style = .island(NotchIslandGeometry.band(screen: screen, occupancy: islandOccupancy[screen.displayID]))
        slot.lastDisplay = nil
        slot.viewModel.display = display
        slot.shrinkTask?.cancel()
        slot.shrinkTask = Task { [weak self, weak slot] in
            try? await Task.sleep(for: .milliseconds(240))
            guard !Task.isCancelled, let self, let slot, slot.lastDisplay == nil else { return }
            self.hide(slot)
        }
    }

    func hide(_ slot: NotchSlot) {
        slot.showsIslandInBar = false
        slot.lastDisplay = nil
        slot.dragOrigin = nil
        slot.shrinkTask?.cancel()
        slot.shrinkTask = nil
        slot.panel?.orderOut(nil)
    }

    func ensurePanel(_ slot: NotchSlot) -> NotchPanel {
        if let panel = slot.panel { return panel }
        let panel = NotchPanel()
        // Vereinte Pille ohne Notch: Ansicht und Rand wie die Diktat-Pille.
        slot.isUnified = config.unified && slot.kind == .pill
        let host = NotchHostingView(rootView: NotchHostView(
            model: slot.viewModel, controller: self, kind: slot.kind, unified: slot.isUnified))
        host.unifiedPill = slot.isUnified
        host.safeAreaRegions = []
        host.sizingOptions = []
        // Immer dunkel: an der Notch schwarz, ohne Notch das Glas der Diktat-Pille.
        host.appearance = NSAppearance(named: .darkAqua)
        panel.contentView = host
        if let hidden = hub.statusContentHiddenDisplayID, slot.screen?.displayID == hidden { host.alphaValue = 0 }
        panel.sharingType = config.hideFromCapture ? .none : .readOnly
        panel.onCancel = { [weak self] in self?.collapse() }
        panel.onKeyDown = { [weak self] event in self?.handleListKey(event) ?? false }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isReleasingKey else { return }
                self.collapse()
            }
        }
        slot.panel = panel
        slot.host = host
        return panel
    }

    // MARK: Bildschirm

    func placements() -> [NotchPlacement] {
        if let cachedPlacements { return cachedPlacements }
        let screens = NSScreen.screens.compactMap(NotchScreenInfo.init(screen:))
        // Hauptbildschirm = der mit der Menüleiste (`CGMainDisplayID`), nicht
        // `NSScreen.main`: das folgt dem Fokus und ließe die Anzeige springen.
        let result = NotchPillPlacement.placements(
            choice: config.screenChoice, screens: screens, mainDisplayID: CGMainDisplayID(),
            agentWindowDisplayID: agentWindowDisplayID())
        cachedPlacements = result
        return result
    }

    /// Wechselt das Agent-Chats-Fenster den Bildschirm (oder ein anderes wird
    /// Key, eins geht zu), wandert die Pille mit. Billig: nur bei diesen
    /// Fenster-Ereignissen, entprellt, und neu gezeichnet nur bei einer Änderung.
    func observeAgentWindowScreen() {
        let center = NotificationCenter.default
        center.publisher(for: NSWindow.didChangeScreenNotification)
            .merge(with: center.publisher(for: NSWindow.didBecomeKeyNotification),
                   center.publisher(for: NSWindow.willCloseNotification))
            .debounce(for: .milliseconds(250), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.agentWindowMayHaveMoved() }
            .store(in: &activeCancellables)
    }

    private func agentWindowMayHaveMoved() {
        guard config.isActive else { return }
        let old = cachedPlacements
        cachedPlacements = nil
        guard placements() != old else { return }
        scheduleFullscreenCheck()
        render()
    }

    // MARK: Vollbild

    /// Vollbild-Spaces verstecken die Anzeige. Geprüft bei Space- und App-Wechsel
    /// und kurz danach noch einmal, weil der Übergang erst nach der Meldung endet.
    func scheduleFullscreenCheck() {
        updateFullscreenState()
        fullscreenRecheckTask?.cancel()
        fullscreenRecheckTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            self?.updateFullscreenState()
        }
    }

    /// Die Fensterliste kostet je nach Anzahl der Fenster einige Millisekunden
    /// und wird deshalb abseits des Main Threads gelesen — einmal für alle
    /// Stellen.
    private func updateFullscreenState() {
        guard config.isActive else { return }
        let placements = placements()
        guard !placements.isEmpty else { return }
        // Zu denselben Ereignissen: was neben einer Kamera-Insel in der
        // Menüleiste steht (Menüs der neuen vorderen App, Apples Insel).
        NotchIslandMonitor.shared.measure(placements.map(\.screen))
        let primaryHeight = NSScreen.screens.first?.frame.height ?? placements[0].screen.frame.height
        let targets = placements.map { placement in
            (kind: placement.kind,
             quartz: NotchFullscreenDetector.quartzFrame(fromCocoa: placement.screen.frame, primaryHeight: primaryHeight),
             topInsets: placement.screen.fullscreenTopInsets)
        }
        let systemFullScreen = NSApp.currentSystemPresentationOptions.contains(.fullScreen)
        let ownPID = ProcessInfo.processInfo.processIdentifier
        fullscreenGeneration += 1
        let generation = fullscreenGeneration
        Task.detached(priority: .utility) { [weak self] in
            let windows = Self.onScreenWindows()
            var hidden: [NotchPlacement.Kind: Bool] = [:]
            for target in targets {
                hidden[target.kind] = NotchFullscreenDetector.isFullscreen(
                    screenFrameQuartz: target.quartz,
                    safeAreaTop: target.topInsets.lowerBound,
                    maxTopInset: target.topInsets.upperBound,
                    windows: windows,
                    ownPID: ownPID,
                    systemReportsFullScreen: systemFullScreen,
                    windowIsFullScreen: Self.accessibilityReportsFullScreen)
            }
            let result = hidden
            await MainActor.run { [weak self] in
                guard let self, self.fullscreenGeneration == generation else { return }
                var changed = false
                for (kind, value) in result {
                    guard let slot = self.slots[kind], slot.isFullscreenHidden != value else { continue }
                    slot.isFullscreenHidden = value
                    changed = true
                }
                if changed { self.render() }
            }
        }
    }

    /// Fragt die Besitzer-App per Accessibility, ob ein Fenster mit genau
    /// diesen Maßen im Vollbild ist. Läuft abseits des Main Threads, nur für
    /// Fenster mit den Maßen „Vollbild unter der Kamera“. Ohne Recht: nein.
    nonisolated private static func accessibilityReportsFullScreen(_ window: NotchWindowSample) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let app = AXUIElementCreateApplication(window.ownerPID)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var list: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &list) == .success,
              let windows = list as? [AXUIElement] else { return false }
        for element in windows {
            // Abgeleitete Elemente erben das Zeitlimit der App nicht (Standard ~6 s).
            AXUIElementSetMessagingTimeout(element, 0.25)
            var flag: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, "AXFullScreen" as CFString, &flag) == .success,
                  (flag as? Bool) == true else { continue }
            // Dieselben Koordinaten wie die Fensterliste (oben links am Hauptbildschirm).
            guard let frame = axFrame(of: element) else { return true }
            if abs(frame.minX - window.bounds.minX) <= 2, abs(frame.minY - window.bounds.minY) <= 2,
               abs(frame.width - window.bounds.width) <= 2, abs(frame.height - window.bounds.height) <= 2 {
                return true
            }
        }
        return false
    }

    nonisolated private static func axFrame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }

    /// Sichtbare Fenster von vorn nach hinten (Quartz-Koordinaten).
    nonisolated static func onScreenWindows() -> [NotchWindowSample] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return list.compactMap { info in
            guard let layer = info[kCGWindowLayer as String] as? Int,
                  let pid = info[kCGWindowOwnerPID as String] as? Int32,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict) else { return nil }
            return NotchWindowSample(layer: layer, bounds: bounds, ownerPID: pid)
        }
    }

    // MARK: Pille ziehen

    /// Mittelpunkt der Pille auf diesem Bildschirm (gemerkt oder oben mittig).
    func pillCenter(on screen: NotchScreenInfo) -> CGPoint {
        NotchPillPlacement.center(screen, stored: config.pillPositions[screen.pillStorageKey])
    }

    /// Ziehen und Doppelklick wie bei der Diktat-Pille: die ganze Pille
    /// zieht, unter 4 pt Bewegung ist es ein Klick (Liste auf und zu), ein
    /// Doppelklick setzt sie oben mittig zurück. Bei offener Liste gilt das
    /// nur für den Kopf; die Zeilen bleiben normale Knöpfe.
    func updatePillMouse(_ slot: NotchSlot, display: NotchDisplay) {
        guard let host = slot.host else { return }
        guard slot.kind == .pill, !display.isNotch else {
            host.pillMouse = nil
            return
        }
        host.pillHeaderOnly = display.isExpanded
        host.pillHeaderAtBottom = display.opensUpward
        guard host.pillMouse == nil else { return }
        let kind = slot.kind
        host.pillMouse = NotchPillMouse(
            began: { [weak self] in self?.pillDragBegan(kind) },
            dragged: { [weak self] in self?.pillDragged(kind, by: $0) },
            ended: { [weak self] in self?.pillDragEnded(kind, moved: $0, at: $1) },
            doubleClick: { [weak self] in self?.pillDoubleClicked(kind, at: $0) })
        host.unifiedPill = slot.isUnified
    }

    private func pillDragBegan(_ kind: NotchPlacement.Kind) {
        guard let slot = slots[kind], let panel = slot.panel else { return }
        let expandedHere = expandedKind == kind
        slot.pressStartedExpanded = expandedHere
        // Offene Liste hier: nicht ziehen. Eine offene Liste an der Notch
        // des anderen Bildschirms hindert nicht.
        slot.dragOrigin = expandedHere ? nil : panel.frame.origin
    }

    /// Doppelklick: zurücksetzen nur, wenn die Pille vor dem ersten Klick zu
    /// war (der erste Klick hat dann die Liste geöffnet). War sie offen, ist
    /// es schnelles Zu und wieder Auf, die gemerkte Lage bleibt.
    private func pillDoubleClicked(_ kind: NotchPlacement.Kind, at point: CGPoint) {
        guard let slot = slots[kind] else { return }
        // Der erste Klick lag auf dem Kern und hat ein Diktat gestartet: dann
        // tut der zweite nichts mehr. Zurückgesetzt wird nur außerhalb des Kerns.
        if Date().timeIntervalSince(slot.lastCoreClickAt) < 0.6 { return }
        if slot.isUnified, UnifiedPillClickTarget.resolve(point: point, coreFrame: slot.coreFrame) == .core { return }
        if slot.pressStartedExpanded {
            toggleExpanded(kind)
        } else {
            resetPillPosition(kind)
        }
    }

    /// Fenster mit der Maus mitführen, die Pille bleibt im sichtbaren Bereich
    /// des Bildschirms (wie die Diktat-Pille).
    private func pillDragged(_ kind: NotchPlacement.Kind, by offset: CGVector) {
        guard let slot = slots[kind], let panel = slot.panel, let origin = slot.dragOrigin,
              let screen = slot.screen else { return }
        if slot.isUnified {
            return unifiedPillDragged(slot, panel: panel, origin: origin, offset: offset, screen: screen)
        }
        let moved = CGRect(origin: CGPoint(x: origin.x + offset.dx, y: origin.y + offset.dy), size: panel.frame.size)
        let clamped = NotchPillPlacement.clamp(moved, to: NotchPillPlacement.usableArea(screen))
        panel.setFrameOrigin(clamped.origin)
    }

    private func pillDragEnded(_ kind: NotchPlacement.Kind, moved: Bool, at point: CGPoint) {
        guard let slot = slots[kind] else { return }
        let wasDragging = slot.dragOrigin != nil
        slot.dragOrigin = nil
        if !moved, slot.isUnified,
           UnifiedPillClickTarget.resolve(point: point, coreFrame: slot.coreFrame) == .core {
            return startDictationFromPill(kind)
        }
        guard moved else { return toggleExpanded(kind) }
        guard wasDragging, let panel = slot.panel, let screen = slot.screen else { return }
        let center = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
        var positions = prefs.notchPillPositions
        positions[screen.pillStorageKey] = NotchPillPlacement.position(forCenter: center, on: screen)
        prefs.notchPillPositions = positions
        slot.lastFrame = panel.frame
        applyConfigIfChanged()
    }

    /// Doppelklick: zurück nach oben mittig, gemerkte Lage dieses
    /// Bildschirms vergessen. Eine offene Liste klappt zu (der erste Klick
    /// des Doppelklicks hat sie geöffnet).
    func resetPillPosition(_ kind: NotchPlacement.Kind) {
        guard let screen = slots[kind]?.screen else { return }
        collapse(rebuildAfter: false)
        var positions = prefs.notchPillPositions
        positions.removeValue(forKey: screen.pillStorageKey)
        prefs.notchPillPositions = positions
        applyConfigIfChanged()
        rebuild()
    }
}

/// Mausbehandlung der Pille ohne Notch (siehe `NotchHostingView.pillMouse`).
struct NotchPillMouse {
    var began: () -> Void
    var dragged: (CGVector) -> Void
    /// `true`: gezogen, `false`: Klick; dazu der Ort des Drückens
    /// (SwiftUI-Koordinaten der Hosting-View, oben links).
    var ended: (Bool, CGPoint) -> Void
    /// Ort des zweiten Klicks (SwiftUI-Koordinaten, oben links).
    var doubleClick: (CGPoint) -> Void
}
