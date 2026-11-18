import AppKit
import ApplicationServices
import Combine

/// Misst über die Bedienungshilfen, was in der Menüleiste neben einer
/// Kamera-Insel steht: die Menüs der vorderen App, die Statussymbole und was
/// Apples eigene Insel gerade zeigt (Mikrofon- oder Kamera-Hinweis, Live
/// Activity; sie reicht dann über die Aussparung hinaus). Nur öffentliche
/// Accessibility-Aufrufe, kein Prozessname und kein festes Maß; ohne
/// Berechtigung oder wenn etwas davon nicht zu ermitteln ist, gibt es kein
/// Ergebnis und die Anzeige bleibt aus der Menüleiste heraus.
///
/// So ist die Menüleiste unter macOS 27 aufgebaut (gemessen 18.11.2026): Ein
/// Prozess führt zwei Fenster. Das bildschirmgroße gehört der Insel; zeigt
/// sie etwas, hat es ein Kind mit dem Rahmen ihrer Kapsel. Das Fenster in
/// Höhe der Menüleiste enthält die Statussymbole aller Apps. Welcher Prozess
/// das ist, verrät ein Treffer-Test an der Kamera.
///
/// Kosten: rund 10 bis 30 ms, etwa 60 kurze Anfragen an die vordere App und
/// an den Prozess der System-Insel. Läuft nie auf dem Main Thread und nur zu
/// Ereignissen (`NotchIslandMonitor`).
enum NotchIslandProbe {
    static let timeout: Float = 0.25
    /// Nur was so nah an der Kamera liegt, zählt zur Insel.
    static let reach: CGFloat = 400

    struct Result: Equatable {
        var occupancy: NotchMenuBarOccupancy
        /// Prozess, dem das Fenster der System-Insel gehört.
        var islandPID: pid_t
    }

    /// `knownIslandPID`: Prozess der System-Insel aus der letzten Messung,
    /// falls an der Kamera gerade ein eigenes Fenster getroffen wird.
    nonisolated static func measure(
        screen: NotchScreenInfo, primaryHeight: CGFloat, menuOwnerPID: pid_t?, ownPID: pid_t, knownIslandPID: pid_t?
    ) -> Result? {
        guard screen.hasIsland, AXIsProcessTrusted(), let menuOwnerPID else { return nil }
        let quartz = NotchFullscreenDetector.quartzFrame(fromCocoa: screen.frame, primaryHeight: primaryHeight)
        let band = NotchIslandGeometry.band(screen: screen)
        let probeY = quartz.minY + NotchIslandGeometry.topInset(screen) + band.capsuleHeight / 2

        // Wem gehört die Insel? Ihr Fenster liegt über allen anderen.
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, timeout)
        var element: AXUIElement?
        var hit: pid_t = 0
        if AXUIElementCopyElementAtPosition(system, Float(screen.notchCenterX), Float(probeY), &element) == .success,
           let element {
            AXUIElementGetPid(element, &hit)
        }
        guard let islandPID = hit != 0 && hit != ownPID ? hit : knownIslandPID,
              let bar = systemBar(
                pid: islandPID, screenQuartz: quartz, barHeight: NotchIslandGeometry.bodyTop(screen),
                cameraX: screen.notchCenterX),
              let menus = menuFrames(pid: menuOwnerPID, screenQuartz: quartz) else { return nil }
        let frames = (menus + bar.statusItems)
            .filter { $0.width > 0 && $0.width < quartz.width / 2 }
            .map { CGRect(x: $0.minX, y: primaryHeight - $0.maxY, width: $0.width, height: $0.height) }
        let island = bar.island
        return Result(
            occupancy: NotchMenuBarOccupancy(
                frames: frames, systemIsland: island.map { $0.minX...$0.maxX },
                systemIslandInsets: island.map { ($0.minY - quartz.minY)...($0.maxY - quartz.minY) }),
            islandPID: islandPID)
    }

    /// Fenster des Insel-Prozesses auf diesem Bildschirm: aus dem in Höhe der
    /// Menüleiste die Statussymbole, aus dem bildschirmgroßen der Rahmen
    /// dessen, was die Insel gerade zeigt (`nil` in Ruhe). Ohne Fenster der
    /// Menüleiste gilt die Messung als gescheitert.
    nonisolated private static func systemBar(
        pid: pid_t, screenQuartz: CGRect, barHeight: CGFloat, cameraX: CGFloat
    ) -> (statusItems: [CGRect], island: CGRect?)? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        var foundBar = false
        var statusItems: [CGRect] = []
        var island: CGRect?
        for window in windows {
            AXUIElementSetMessagingTimeout(window, timeout)
            guard let bounds = frame(window), abs(bounds.minY - screenQuartz.minY) <= 2,
                  bounds.maxX > screenQuartz.minX, bounds.minX < screenQuartz.maxX,
                  let items = children(window) else { continue }
            let frames = items.compactMap { frame($0) }
            if bounds.height <= barHeight * 2 {
                foundBar = true
                statusItems += frames
            } else {
                // Was die Insel zeigt: in der Menüleiste, an der Kamera.
                for item in frames where item.minY < screenQuartz.minY + barHeight
                    && item.minX < cameraX && item.maxX > cameraX && item.width < reach {
                    island = island?.union(item) ?? item
                }
            }
        }
        return foundBar ? (statusItems, island) : nil
    }

    /// Menüs der App, der die Menüleiste gerade gehört (Quartz-Koordinaten).
    /// Zeigt die App ihre Leiste auf einem anderen Bildschirm, stehen
    /// dieselben Menüs hier gleich weit vom linken Rand.
    nonisolated private static func menuFrames(pid: pid_t, screenQuartz: CGRect) -> [CGRect]? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let bar = value as! AXUIElement
        AXUIElementSetMessagingTimeout(bar, timeout)
        guard let items = children(bar) else { return nil }
        let shift = frame(bar).map { screenQuartz.minX - $0.minX } ?? 0
        return items.compactMap { frame($0) }.map { $0.offsetBy(dx: shift, dy: 0) }
    }

    nonisolated private static func children(_ element: AXUIElement) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let items = value as? [AXUIElement] else { return nil }
        // Abgeleitete Elemente erben das Zeitlimit nicht.
        for item in items { AXUIElementSetMessagingTimeout(item, timeout) }
        return items
    }

    nonisolated private static func frame(_ element: AXUIElement) -> CGRect? {
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
}

/// Hält die letzte Messung je Bildschirm mit Kamera-Insel. Beobachtet selbst
/// nichts: Gemessen wird, wenn Anzeige oder Diktat darum bitten (App- und
/// Space-Wechsel, neuer Stand der Anzeige, Diktat erscheint oder geht).
/// Solange nichts gemessen ist, fehlt der Bildschirm; die Anzeige bleibt dann
/// aus der Menüleiste heraus.
@MainActor
final class NotchIslandMonitor: ObservableObject {
    static let shared = NotchIslandMonitor()

    @Published private(set) var occupancy: [UInt32: NotchMenuBarOccupancy] = [:]
    private var generation = 0
    private var islandPID: pid_t?
    private var followUp: Task<Void, Never>?

    /// Jetzt messen und, weil Apples Insel ihre Breite erst nach und nach
    /// ändert (Mikrofon an oder aus), zu den genannten Zeiten noch einmal.
    /// Ohne neue Zeiten laufen schon geplante Nachmessungen weiter.
    func measure(_ screens: [NotchScreenInfo], followUps: [Duration] = []) {
        let islands = screens.filter(\.hasIsland)
        guard !islands.isEmpty else {
            followUp?.cancel()
            followUp = nil
            if !occupancy.isEmpty { occupancy = [:] }
            return
        }
        measureNow(islands)
        guard !followUps.isEmpty else { return }
        followUp?.cancel()
        followUp = Task { [weak self] in
            var elapsed = Duration.zero
            for moment in followUps.sorted() {
                try? await Task.sleep(for: moment - elapsed)
                guard !Task.isCancelled else { return }
                elapsed = moment
                self?.measureNow(islands)
            }
        }
    }

    private func measureNow(_ screens: [NotchScreenInfo]) {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screens[0].frame.height
        let menuOwner = NSWorkspace.shared.menuBarOwningApplication?.processIdentifier
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let known = islandPID
        generation += 1
        let current = generation
        Task.detached(priority: .utility) { [weak self] in
            var results: [UInt32: NotchIslandProbe.Result] = [:]
            for screen in screens {
                results[screen.displayID] = NotchIslandProbe.measure(
                    screen: screen, primaryHeight: primaryHeight, menuOwnerPID: menuOwner,
                    ownPID: ownPID, knownIslandPID: known)
            }
            let measured = results
            await MainActor.run { [weak self] in
                guard let self, self.generation == current else { return }
                if let pid = measured.values.first?.islandPID { self.islandPID = pid }
                let new = measured.mapValues(\.occupancy)
                if new != self.occupancy { self.occupancy = new }
            }
        }
    }
}
