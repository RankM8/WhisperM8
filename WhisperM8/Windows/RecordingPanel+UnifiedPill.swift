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
        unifiedGeneration += 1
        let generation = unifiedGeneration
        let screens = NSScreen.screens.compactMap(NotchScreenInfo.init(screen:))
        let mouse = NSEvent.mouseLocation
        let mouseDisplayID = screens.first { $0.frame.contains(mouse) }?.displayID
        let finish: (UInt32?) -> Void = { [weak self] frontDisplayID in
            guard let self, self.isPresented, self.unifiedGeneration == generation, self.panel == nil else { return }
            let placement = DictationPillPlacement.resolve(
                frontWindowDisplayID: frontDisplayID,
                mouseDisplayID: mouseDisplayID,
                mainDisplayID: CGMainDisplayID(),
                screens: screens,
                positions: AppPreferences.shared.notchPillPositions)
            guard let placement else { return }
            self.buildUnifiedPanel(placement)
        }

        // WhisperM8 selbst vorne: das Key-Fenster kennen wir ohne Fensterliste.
        // Unsere Fenster aktivieren nicht: vorne ist die App, in der man tippt.
        let frontApp = NSWorkspace.shared.frontmostApplication
        if frontApp?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            let window = NSApp.keyWindow ?? NSApp.mainWindow
            return finish(window.flatMap { DictationPillPlacement.displayID(containing: $0.frame, screens: screens) })
        }
        guard let pid = frontApp?.processIdentifier else { return finish(nil) }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        var settled = false
        let settle: (UInt32?) -> Void = { displayID in
            guard !settled else { return }
            settled = true
            finish(displayID)
        }
        Task.detached(priority: .userInitiated) {
            let rect = FrontWindowLocator.frontWindowFrame(pid: pid, primaryHeight: primaryHeight)
            await MainActor.run {
                settle(rect.flatMap { DictationPillPlacement.displayID(containing: $0, screens: screens) })
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.frontWindowTimeout) {
            MainActor.assumeIsolated { settle(nil) }
        }
    }

    /// Ab hier wird es eng: lieber die Maus nehmen als die Pille warten lassen.
    static let frontWindowTimeout: TimeInterval = 0.08

    private func buildUnifiedPanel(_ placement: DictationPillPlacement) {
        let token = PerfBudgets.unifiedPillShow.begin()
        defer { PerfBudgets.unifiedPillShow.end(token) }
        let screen = placement.screen
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
            let size = OverlayFrameResolver.panelSize
            panel = RecordingPanel(
                initialOrigin: UnifiedPillGeometry.pillDictationPanelOrigin(center: center, panelSize: size),
                size: size)
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

        UnifiedPillHub.shared.dictationDidShow(onDisplay: screen.displayID)
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
        guard presentation == .pill else { return }
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

    /// Aufräumen beim Ausblenden (aus `hide`).
    func tearDownUnified() {
        unifiedGeneration += 1
        badgeCancellable = nil
        if statusBadge != nil { statusBadge = nil }
        unifiedScreen = nil
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
