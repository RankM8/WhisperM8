import AppKit
import ApplicationServices
import Combine

/// Die Accessibility-Aufrufe der Messung als austauschbare Schicht (Tests
/// reichen eine Attrappe herein). Es gibt bewusst nur Einstiege je Prozess:
/// Das systemweite Element kommt nicht vor, denn ein Zeitlimit daran gälte
/// für alle Accessibility-Aufrufe der App (auch den Diktat-Kontext).
struct NotchIslandAX {
    var isTrusted: () -> Bool
    /// Fenster eines Prozesses.
    var windows: (pid_t) -> [AnyObject]?
    /// Menüleiste eines Prozesses.
    var menuBar: (pid_t) -> AnyObject?
    var children: (AnyObject) -> [AnyObject]?
    /// Rahmen in Quartz-Koordinaten (Ursprung oben links am Hauptbildschirm).
    var frame: (AnyObject) -> CGRect?

    /// Echte Aufrufe. Jedes Element bekommt sein eigenes Zeitlimit (0,25 s);
    /// nach `deadline` antwortet die Schicht nicht mehr, die Messung endet
    /// dann ohne Ergebnis.
    static func live(deadline: Date) -> NotchIslandAX {
        let timeout: Float = 0.25
        func element(_ object: AnyObject) -> AXUIElement? {
            guard Date() < deadline, CFGetTypeID(object) == AXUIElementGetTypeID() else { return nil }
            return (object as! AXUIElement)
        }
        func application(_ pid: pid_t) -> AXUIElement? {
            guard Date() < deadline else { return nil }
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, timeout)
            return app
        }
        func elements(_ owner: AXUIElement, _ attribute: String) -> [AnyObject]? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(owner, attribute as CFString, &value) == .success,
                  let items = value as? [AXUIElement] else { return nil }
            // Abgeleitete Elemente erben das Zeitlimit nicht.
            for item in items { AXUIElementSetMessagingTimeout(item, timeout) }
            return items
        }
        return NotchIslandAX(
            isTrusted: { AXIsProcessTrusted() },
            windows: { pid in application(pid).flatMap { elements($0, kAXWindowsAttribute) } },
            menuBar: { pid in
                guard let app = application(pid) else { return nil }
                var value: CFTypeRef?
                guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &value) == .success,
                      let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
                AXUIElementSetMessagingTimeout(value as! AXUIElement, timeout)
                return value
            },
            children: { object in element(object).flatMap { elements($0, kAXChildrenAttribute) } },
            frame: { object in
                guard let element = element(object) else { return nil }
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
            })
    }
}

/// Misst über die Bedienungshilfen, was in der Menüleiste neben einer
/// Kamera-Insel steht: die Menüs der vorderen App, die Statussymbole und was
/// Apples eigene Insel gerade zeigt (Mikrofon- oder Kamera-Hinweis, Live
/// Activity; sie reicht dann über die Aussparung hinaus). Nur öffentliche
/// Aufrufe, kein Prozessname und kein festes Maß; ohne Berechtigung oder wenn
/// etwas davon nicht zu ermitteln ist, gibt es kein Ergebnis und die Anzeige
/// bleibt aus der Menüleiste heraus.
///
/// So ist die Menüleiste unter macOS 27 aufgebaut (gemessen 18.11.2026): Ein
/// Prozess führt zwei Fenster. Das bildschirmgroße gehört der Insel und
/// liegt über allen anderen; zeigt sie etwas, hat es ein Kind mit dem Rahmen
/// ihrer Kapsel. Das Fenster in Höhe der Menüleiste enthält die
/// Statussymbole aller Apps. Welcher Prozess das ist, sagt die Fensterliste:
/// der Besitzer des obersten bildschirmbreiten Fensters an der Kamera.
///
/// Kosten: rund 10 bis 30 ms, etwa 60 kurze Anfragen an die vordere App und
/// an den Prozess der System-Insel, dazu einmal die Fensterliste. Läuft nie
/// auf dem Main Thread und nur zu Ereignissen (`NotchIslandMonitor`).
enum NotchIslandProbe {
    /// Gesamtfrist einer Messung.
    static let budget: TimeInterval = 0.5
    /// Nur was so nah an der Kamera liegt, zählt zur Insel.
    static let reach: CGFloat = 400
    /// So viele Besitzer von Fenstern an der Kamera werden höchstens gefragt.
    static let maxCandidates = 3

    /// `windows`: Fensterliste von vorn nach hinten (Quartz-Koordinaten).
    nonisolated static func measure(
        screen: NotchScreenInfo, primaryHeight: CGFloat, menuOwnerPID: pid_t?, ownPID: pid_t,
        windows: [NotchWindowSample], ax: NotchIslandAX
    ) -> NotchMenuBarOccupancy? {
        guard screen.hasIsland, ax.isTrusted(), let menuOwnerPID else { return nil }
        let quartz = NotchFullscreenDetector.quartzFrame(fromCocoa: screen.frame, primaryHeight: primaryHeight)
        let band = NotchIslandGeometry.band(screen: screen)
        let camera = CGPoint(
            x: screen.notchCenterX, y: quartz.minY + NotchIslandGeometry.topInset(screen) + band.capsuleHeight / 2)
        let barHeight = NotchIslandGeometry.bodyTop(screen)

        var bar: (statusItems: [CGRect], island: CGRect?)?
        for pid in islandOwnerCandidates(windows: windows, camera: camera, screenQuartz: quartz, ownPID: ownPID) {
            bar = systemBar(pid: pid, screenQuartz: quartz, barHeight: barHeight, cameraX: camera.x, ax: ax)
            if bar != nil { break }
        }
        guard let bar, let menus = menuFrames(pid: menuOwnerPID, screenQuartz: quartz, ax: ax) else { return nil }
        let frames = (menus + bar.statusItems)
            .filter { $0.width > 0 && $0.width < quartz.width / 2 }
            .map { CGRect(x: $0.minX, y: primaryHeight - $0.maxY, width: $0.width, height: $0.height) }
        return NotchMenuBarOccupancy(
            frames: frames, systemIsland: bar.island.map { $0.minX...$0.maxX },
            systemIslandInsets: bar.island.map { ($0.minY - quartz.minY)...($0.maxY - quartz.minY) })
    }

    /// Wem die Insel gehören kann: Besitzer der bildschirmbreiten Fenster an
    /// der Kamera, von vorn nach hinten, ohne uns selbst. Das Fenster der
    /// Insel liegt zuvorderst; der Mauszeiger (ein kleines Fenster) zählt nicht.
    nonisolated static func islandOwnerCandidates(
        windows: [NotchWindowSample], camera: CGPoint, screenQuartz: CGRect, ownPID: pid_t
    ) -> [pid_t] {
        var result: [pid_t] = []
        for window in windows where window.ownerPID != ownPID && window.bounds.contains(camera)
            && window.bounds.width >= screenQuartz.width - 1 && !result.contains(window.ownerPID) {
            result.append(window.ownerPID)
            if result.count == maxCandidates { break }
        }
        return result
    }

    /// Fenster des Insel-Prozesses auf diesem Bildschirm: aus dem in Höhe der
    /// Menüleiste die Statussymbole, aus dem bildschirmgroßen der Rahmen
    /// dessen, was die Insel gerade zeigt (`nil` in Ruhe). Ohne Fenster der
    /// Menüleiste gilt die Messung als gescheitert.
    nonisolated private static func systemBar(
        pid: pid_t, screenQuartz: CGRect, barHeight: CGFloat, cameraX: CGFloat, ax: NotchIslandAX
    ) -> (statusItems: [CGRect], island: CGRect?)? {
        guard let windows = ax.windows(pid) else { return nil }
        var foundBar = false
        var statusItems: [CGRect] = []
        var island: CGRect?
        for window in windows {
            guard let bounds = ax.frame(window), abs(bounds.minY - screenQuartz.minY) <= 2,
                  bounds.maxX > screenQuartz.minX, bounds.minX < screenQuartz.maxX,
                  let items = ax.children(window) else { continue }
            let frames = items.compactMap { ax.frame($0) }
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
    nonisolated private static func menuFrames(pid: pid_t, screenQuartz: CGRect, ax: NotchIslandAX) -> [CGRect]? {
        guard let bar = ax.menuBar(pid), let items = ax.children(bar) else { return nil }
        let shift = ax.frame(bar).map { screenQuartz.minX - $0.minX } ?? 0
        return items.compactMap { ax.frame($0) }.map { $0.offsetBy(dx: shift, dy: 0) }
    }
}

/// Hält die letzte Messung je Bildschirm mit Kamera-Insel. Beobachtet selbst
/// nichts: Gemessen wird, wenn Anzeige oder Diktat darum bitten (App- und
/// Space-Wechsel, neuer Stand der Anzeige, alle 30 s, solange etwas in der
/// Menüleiste steht, Klick auf die Kapsel, Diktat erscheint oder geht).
/// Solange nichts gemessen ist, fehlt der Bildschirm; die Anzeige bleibt dann
/// aus der Menüleiste heraus.
@MainActor
final class NotchIslandMonitor: ObservableObject {
    static let shared = NotchIslandMonitor()

    @Published private(set) var occupancy: [UInt32: NotchMenuBarOccupancy] = [:]
    /// Es läuft immer höchstens eine Messung; eine Bitte währenddessen wird
    /// gemerkt und danach einmal erfüllt.
    private var isMeasuring = false
    private var pending: [NotchScreenInfo]?
    private var followUp: Task<Void, Never>?

    /// Jetzt messen und, weil Apples Insel ihre Breite erst nach und nach
    /// ändert (Mikrofon an oder aus), zu den genannten Zeiten noch einmal.
    /// Ohne neue Zeiten laufen schon geplante Nachmessungen weiter.
    func measure(_ screens: [NotchScreenInfo], followUps: [Duration] = []) {
        let islands = screens.filter(\.hasIsland)
        guard !islands.isEmpty else {
            followUp?.cancel()
            followUp = nil
            pending = nil
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
        guard !isMeasuring else {
            pending = screens
            return
        }
        isMeasuring = true
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screens[0].frame.height
        let menuOwner = NSWorkspace.shared.menuBarOwningApplication?.processIdentifier
        let ownPID = ProcessInfo.processInfo.processIdentifier
        Task.detached(priority: .utility) { [weak self] in
            let windows = NotchStatusController.onScreenWindows()
            var measured: [UInt32: NotchMenuBarOccupancy] = [:]
            for screen in screens {
                measured[screen.displayID] = NotchIslandProbe.measure(
                    screen: screen, primaryHeight: primaryHeight, menuOwnerPID: menuOwner, ownPID: ownPID,
                    windows: windows, ax: .live(deadline: Date().addingTimeInterval(NotchIslandProbe.budget)))
            }
            let result = measured
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isMeasuring = false
                if result != self.occupancy { self.occupancy = result }
                if let next = self.pending {
                    self.pending = nil
                    self.measureNow(next)
                }
            }
        }
    }
}
