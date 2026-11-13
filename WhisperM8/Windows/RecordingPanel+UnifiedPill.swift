import AppKit
import Combine
import SwiftUI

/// Wie die Diktat-Pille gezeichnet und platziert wird.
enum OverlayPresentation: Equatable {
    /// Getrennte Diktat-Pille wie vor der vereinten Pille (Kill-Switch
    /// `unifiedPillEnabled` aus): eine Lage für alle Bildschirme, unten mittig.
    case classic
    /// Vereinte Pille ohne Notch: an der gemerkten Lage des Bildschirms (oben
    /// mittig), Zustandswechsel wachsen um die Mitte.
    case pill
    /// Vereinte Pille an der Notch: schwarz, die Zeile hängt unter der
    /// Aussparung, nicht verschiebbar.
    case notch(width: CGFloat, height: CGFloat)

    var isNotch: Bool {
        if case .notch = self { return true }
        return false
    }

    var isUnified: Bool { self != .classic }
}

/// Vereinte Pille: Nur Lage und Aussehen des Diktats ändern sich, die
/// Diktat-Logik (Coordinator, Aufnahme, Auslieferung) bleibt unberührt. Der
/// Coordinator ruft weiter `show`/`update`/`hide`; hier wird nur entschieden,
/// WO die Pille erscheint.
extension OverlayController {
    /// Baut die Pille an der Stelle der vereinten Pille auf. Der Bildschirm
    /// des vorderen Fensters wird abseits des Main Threads bestimmt
    /// (Fensterliste); bis dahin (höchstens `frontWindowTimeout`) steht noch
    /// nichts, das Diktat selbst läuft davon unabhängig.
    func presentUnifiedPanel() {
        let screens = NSScreen.screens.compactMap(NotchScreenInfo.init(screen:))
        let mouse = NSEvent.mouseLocation
        let mouseDisplayID = screens.first { $0.frame.contains(mouse) }?.displayID

        // Unsere Fenster aktivieren nicht: vorne ist die App, in der man tippt.
        let frontApp = NSWorkspace.shared.frontmostApplication
        let lookup: (@escaping @MainActor (UInt32?) -> Void) -> Void
        if frontApp?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            // WhisperM8 selbst vorne: das Key-Fenster kennen wir ohne Fensterliste.
            let window = NSApp.keyWindow ?? NSApp.mainWindow
            let displayID = window.flatMap { DictationPillPlacement.displayID(containing: $0.frame, screens: screens) }
            lookup = { answer in answer(displayID) }
        } else if let pid = frontApp?.processIdentifier {
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            lookup = { answer in
                Task.detached(priority: .userInitiated) {
                    let rect = FrontWindowLocator.frontWindowFrame(pid: pid, primaryHeight: primaryHeight)
                    await MainActor.run {
                        answer(rect.flatMap { DictationPillPlacement.displayID(containing: $0, screens: screens) })
                    }
                }
            }
        } else {
            lookup = { answer in answer(nil) }
        }
        beginUnifiedPresentation(
            screens: screens, mouseDisplayID: mouseDisplayID, mainDisplayID: CGMainDisplayID(),
            frontWindowLookup: lookup, timeout: Self.frontWindowTimeout,
            build: { [weak self] placement in
                self?.buildOrAdoptUnifiedPanel(placement) { self?.buildUnifiedPanel($0) }
            })
    }

    /// Kern des asynchronen Aufbaus, ohne Fenster testbar: Die erste Antwort
    /// gewinnt (Fensterliste oder Zeitlimit, dann die Maus). Gebaut wird nur,
    /// solange die Pille noch gezeigt werden soll, kein neuerer Aufbau läuft
    /// (Generation) und noch kein Fenster steht.
    func beginUnifiedPresentation(
        screens: [NotchScreenInfo],
        mouseDisplayID: UInt32?,
        mainDisplayID: UInt32?,
        frontWindowLookup: (@escaping @MainActor (UInt32?) -> Void) -> Void,
        timeout: TimeInterval,
        build: @escaping @MainActor (DictationPillPlacement) -> Void
    ) {
        unifiedGeneration += 1
        let generation = unifiedGeneration
        var settled = false
        let settle: @MainActor (UInt32?) -> Void = { [weak self] frontDisplayID in
            guard !settled else { return }
            settled = true
            // Ein Fenster, das sich noch zurückzieht, hindert nicht: Es wird
            // übernommen oder geschlossen (`buildOrAdoptUnifiedPanel`).
            guard let self, self.isPresented, self.unifiedGeneration == generation,
                  self.panel == nil || self.morph.isRetiring else { return }
            guard let placement = DictationPillPlacement.resolve(
                frontWindowDisplayID: frontDisplayID,
                mouseDisplayID: mouseDisplayID,
                mainDisplayID: mainDisplayID,
                screens: screens,
                positions: AppPreferences.shared.notchPillPositions) else { return }
            build(placement)
        }
        frontWindowLookup(settle)
        guard !settled else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            MainActor.assumeIsolated { settle(nil) }
        }
    }

    /// Ab hier wird es eng: lieber die Maus nehmen als die Pille warten lassen.
    static let frontWindowTimeout: TimeInterval = 0.08

    /// `allowMorph`: Steht dort eine ruhende Pille, wächst das Diktat aus ihr
    /// (`RecordingPanel+PillMorph.swift`); nach einem Bildschirmwechsel nicht.
    private func buildUnifiedPanel(_ placement: DictationPillPlacement, allowMorph: Bool = true) {
        let token = PerfBudgets.unifiedPillShow.begin()
        defer { PerfBudgets.unifiedPillShow.end(token) }
        let screen = placement.screen
        // Ruhebild vor dem Aufbau setzen: Die Ansicht beginnt ohne Animation
        // genau mit dem Bild der ruhenden Pille.
        let snapshot = allowMorph ? restSnapshot(onDisplay: screen.displayID, isNotch: placement.isNotch) : nil
        restLook = snapshot?.look
        restCenter = snapshot?.center
        showsRestLook = snapshot != nil
        let panel: RecordingPanel
        switch placement {
        case .notch(let screen):
            presentation = .notch(width: screen.notchWidth, height: screen.safeAreaTop)
            let frame = UnifiedPillGeometry.notchDictationPanelFrame(
                screen: screen, panelWidth: OverlayFrameResolver.panelSize.width)
            panel = RecordingPanel(initialOrigin: frame.origin, size: frame.size)
            // Über der Menüleiste, damit das Band die Aussparung deckt; an der
            // Notch nichts zum Ziehen.
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
            panel.allowsAboveMenuBar = true
            panel.isMovableByWindowBackground = false
            hasCustomPosition = true
        case .pill(let screen, let center):
            presentation = .pill
            // Genau über der ruhenden Pille, auch wenn die am Rand verschoben steht.
            panel = Self.makeUnifiedPillPanel(center: snapshot?.center ?? center)
            hasCustomPosition = AppPreferences.shared.notchPillPositions[screen.pillStorageKey] != nil
        }
        pillAlignment = .center
        unifiedScreen = screen
        collapsedPillWidth = nil
        // Ein Doppelklick direkt nach dem Erscheinen (Klick auf den Kern hat
        // das Diktat gestartet) setzt die Lage nicht zurück.
        lastPillActionAt = Date()
        panel.sharingType = AppPreferences.shared.isNotchStatusHiddenFromCapture ? .none : .readOnly
        panel.onMoveAnchor = { [weak self] anchor in
            guard let self, !self.isResettingPosition else { return }
            self.rememberUnifiedPosition(anchor)
        }
        installPanel(panel, safeAreaFree: placement.isNotch)
        observeScreenChanges()
        observeUnifiedBadge()
        // Ohne Übergang meldet sich das Diktat sofort beim Hub (die
        // Status-Pille dort tritt zurück), mit Übergang erst nach dem ersten Bild.
        applyMorph(morph.show(morph: snapshot != nil))
    }

    /// Fenster der vereinten Pille ohne Notch, mittig um den Mittelpunkt der
    /// Pille. Steht die Pille oben unter der Menüleiste, ragt der Schattenrand
    /// des Fensters in die Leiste; AppKit schöbe das ganze Fenster sonst beim
    /// Einblenden darunter (bis zu 24 pt), und die Pille spränge beim Start des
    /// Diktats nach unten, statt aus der ruhenden Pille zu wachsen. Die
    /// sichtbare Pille halten wir selbst im Bildschirm
    /// (`OverlayFrameResolver.clampedPanelOrigin`), wie die Status-Pille.
    static func makeUnifiedPillPanel(center: CGPoint) -> RecordingPanel {
        let size = OverlayFrameResolver.panelSize
        let panel = RecordingPanel(
            initialOrigin: UnifiedPillGeometry.pillDictationPanelOrigin(center: center, panelSize: size),
            size: size)
        panel.allowsAboveMenuBar = true
        return panel
    }

    /// Raute für wartende Chats und Fehler, solange das Diktat steht.
    func observeUnifiedBadge() {
        statusBadge = UnifiedPillHub.shared.badge
        badgeCancellable = UnifiedPillHub.shared.$badge
            .removeDuplicates()
            .sink { [weak self] badge in
                guard let self, self.statusBadge != badge else { return }
                self.statusBadge = badge
            }
    }

    /// Gezogen: Lage je Bildschirm merken (wie die Status-Pille), als Anteil
    /// am Bildschirm über die Display-UUID.
    private func rememberUnifiedPosition(_ anchor: PillAnchor) {
        // Nur echtes Ziehen (linke Maustaste gedrückt) merken; Verschiebungen
        // durch AppKit (Bildschirm abgesteckt) überschrieben sonst die Lage
        // auf einem anderen Bildschirm.
        guard presentation == .pill, NSEvent.pressedMouseButtons & 1 != 0 else { return }
        let center = UnifiedPillGeometry.center(of: anchor)
        let screens = NSScreen.screens.compactMap(NotchScreenInfo.init(screen:))
        guard let screen = screens.first(where: { $0.frame.contains(center) }) ?? unifiedScreen else { return }
        hasCustomPosition = true
        var positions = AppPreferences.shared.notchPillPositions
        positions[screen.pillStorageKey] = NotchPillPlacement.position(forCenter: center, on: screen)
        AppPreferences.shared.notchPillPositions = positions
        if screen.displayID != unifiedScreen?.displayID {
            unifiedScreen = screen
            UnifiedPillHub.shared.dictationDidShow(onDisplay: screen.displayID)
        }
    }

    /// Doppelklick: zurück nach oben mittig, gemerkte Lage dieses Bildschirms
    /// vergessen. An der Notch gibt es nichts zurückzusetzen.
    func resetUnifiedPosition() {
        guard presentation == .pill, let panel, let screen = unifiedScreen else { return }
        var positions = AppPreferences.shared.notchPillPositions
        positions.removeValue(forKey: screen.pillStorageKey)
        AppPreferences.shared.notchPillPositions = positions
        hasCustomPosition = false
        let origin = UnifiedPillGeometry.pillDictationPanelOrigin(
            center: NotchPillPlacement.defaultCenter(screen), panelSize: panel.frame.size)
        isResettingPosition = true
        panel.animateOrigin(to: origin) { [weak self] in
            self?.isResettingPosition = false
        }
    }

    /// Bildschirme geändert (abgesteckt, Auflösung): Steht der Bildschirm des
    /// Diktats nicht mehr oder hat er andere Maße, wird die Pille neu
    /// platziert (Maus-Bildschirm, gemerkte Lage), damit ✓ und ✕ sichtbar
    /// bleiben. Das Diktat selbst läuft weiter.
    private func observeScreenChanges() {
        if let unifiedScreenObserver { NotificationCenter.default.removeObserver(unifiedScreenObserver) }
        unifiedScreenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.retiringPanelScreenChanged()
                self?.relocateAfterScreenChange()
            }
        }
    }

    func relocateAfterScreenChange() {
        guard isPresented, presentation.isUnified, let current = unifiedScreen else { return }
        let screens = NSScreen.screens.compactMap(NotchScreenInfo.init(screen:))
        if let same = screens.first(where: { $0.displayID == current.displayID }), same == current { return }
        let mouse = NSEvent.mouseLocation
        guard let placement = DictationPillPlacement.resolve(
            frontWindowDisplayID: screens.first(where: { $0.displayID == current.displayID })?.displayID,
            mouseDisplayID: screens.first { $0.frame.contains(mouse) }?.displayID,
            mainDisplayID: CGMainDisplayID(),
            screens: screens,
            positions: AppPreferences.shared.notchPillPositions) else { return }
        Logger.info("unified_pill_relocated")
        closePanelForRebuild()
        cancelMorphSignpost()
        morph.reset()
        buildUnifiedPanel(placement, allowMorph: false)
    }

    /// Aufräumen beim Ausblenden (aus `hide`). `keepingWindow`: Die Pille
    /// zieht sich noch zurück; Fenster, Bildschirm und Meldung beim Hub
    /// räumt dann der Übergang selbst ab.
    func tearDownUnified(keepingWindow: Bool = false) {
        unifiedGeneration += 1
        badgeCancellable = nil
        if statusBadge != nil { statusBadge = nil }
        guard !keepingWindow else { return }
        if let unifiedScreenObserver {
            NotificationCenter.default.removeObserver(unifiedScreenObserver)
            self.unifiedScreenObserver = nil
        }
        unifiedScreen = nil
        // Kein Ruhebild mehr übrig (etwa Stopp vor dem ersten Bild): Das
        // nächste Diktat, auch die getrennte Pille, beginnt sauber.
        if showsRestLook { showsRestLook = false }
        restLook = nil
        restCenter = nil
        UnifiedPillHub.shared.dictationDidHide()
    }

    /// Klappen Listen an der Pille nach unten auf (obere Bildschirmhälfte)?
    var unifiedMenusOpenDownward: Bool {
        guard presentation.isUnified, let screen = unifiedScreen else { return false }
        if presentation.isNotch { return true }
        guard let panel, panel.pillFrameInPanel.width > 0 else { return true }
        let pill = panel.pillFrameInPanel.offsetBy(dx: panel.frame.origin.x, dy: panel.frame.origin.y)
        return UnifiedPillMenuDirection.opensDownward(pillFrame: pill, screenFrame: screen.frame)
    }
}

/// Bildschirm des vorderen Fensters einer App über die Fensterliste. Läuft
/// abseits des Main Threads; braucht keine Aufnahmerechte (nur Rahmen und
/// Besitzer, keine Titel).
enum FrontWindowLocator {
    /// Rahmen (Cocoa-Koordinaten) des vordersten normalen Fensters von `pid`.
    nonisolated static func frontWindowFrame(pid: pid_t, primaryHeight: CGFloat) -> CGRect? {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return frontWindowFrame(in: list, pid: pid, primaryHeight: primaryHeight)
    }

    /// Rein: erstes Fenster der Liste (vorne nach hinten) von `pid` auf der
    /// normalen Ebene, sichtbar und nicht winzig.
    nonisolated static func frontWindowFrame(in list: [[String: Any]], pid: pid_t, primaryHeight: CGFloat) -> CGRect? {
        for info in list {
            guard (info[kCGWindowOwnerPID as String] as? Int32) == pid,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  ((info[kCGWindowAlpha as String] as? Double) ?? 1) > 0,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.width > 40, bounds.height > 40 else { continue }
            return NotchFullscreenDetector.quartzFrame(fromCocoa: bounds, primaryHeight: primaryHeight)
        }
        return nil
    }
}
