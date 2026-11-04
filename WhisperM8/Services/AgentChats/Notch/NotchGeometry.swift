import CoreGraphics
import Foundation

/// Bildschirmwerte, die die Notch-Geometrie braucht, als reiner Wert. Der
/// AppKit-Teil (`NSScreen`) füllt ihn; alles Rechnen geschieht hier und ist
/// ohne Bildschirm testbar.
struct NotchScreenInfo: Equatable {
    var displayID: UInt32
    var frame: CGRect
    var visibleFrame: CGRect
    /// `NSScreen.safeAreaInsets.top`: > 0 nur bei Bildschirmen mit Notch.
    var safeAreaTop: CGFloat
    var auxiliaryLeftWidth: CGFloat?
    var auxiliaryRightWidth: CGFloat?
    var isBuiltIn: Bool

    /// Notch vorhanden: Sicherheitsrand oben und beide freien Bereiche daneben.
    var hasNotch: Bool {
        safeAreaTop > 0 && auxiliaryLeftWidth != nil && auxiliaryRightWidth != nil
    }

    /// Breite der Hardware-Aussparung (0 ohne Notch).
    var notchWidth: CGFloat {
        guard hasNotch, let left = auxiliaryLeftWidth, let right = auxiliaryRightWidth else { return 0 }
        return max(0, frame.width - left - right)
    }

    /// Mitte der Aussparung in globalen Koordinaten; ohne Notch die Bildschirmmitte.
    var notchCenterX: CGFloat {
        guard hasNotch, let left = auxiliaryLeftWidth else { return frame.midX }
        return frame.minX + left + notchWidth / 2
    }
}

enum NotchScreenChoice: String, CaseIterable {
    /// Eingebauter Bildschirm mit Notch, sonst der Hauptbildschirm.
    case auto
    case builtIn
    case main
}

/// Darstellungsart der Anzeige im Fenster.
enum NotchPanelMode: Equatable {
    /// `chipCount`: wie viele Zähler sichtbar sind (bestimmt die Breite).
    case compact(chipCount: Int)
    case alert
    case expanded(rowCount: Int, sectionCount: Int)
}

/// Sichtbare Teile der Anzeige an der Notch, in globalen Cocoa-Koordinaten.
/// `band` liegt in der Menüleiste und ist nie breiter als die Aussparung
/// selbst; alles andere (`body`) hängt unter der Menüleiste. So verdeckt die
/// Anzeige kein Menü und kein Statussymbol neben der Notch.
struct NotchLayout: Equatable {
    var frame: CGRect
    var band: CGRect
    var body: CGRect
}

enum NotchGeometry {
    // MARK: Maße

    /// Höhe der Zeile unter der Notch (Zähler bzw. Chat-Name).
    static let chinHeight: CGFloat = 24
    /// Breite des Körpers bei „braucht dich" (Platz für den Chat-Namen).
    static let alertWidth: CGFloat = 340
    static let expandedMinWidth: CGFloat = 380
    static let expandedMaxListHeight: CGFloat = 400
    static let rowHeight: CGFloat = 50
    static let sectionHeaderHeight: CGFloat = 24
    static let footerHeight: CGFloat = 28
    static let listPadding: CGFloat = 12

    static let pillHeight: CGFloat = 28
    static let pillAlertWidth: CGFloat = 340
    static let pillExpandedWidth: CGFloat = 380
    /// Abstand der Pille zur Menüleiste.
    static let pillTopGap: CGFloat = 6
    /// Höhe der Menüleiste, falls ein Bildschirm ohne Notch keine Angabe liefert.
    static let fallbackMenuBarHeight: CGFloat = 24

    /// Höhe der Liste unter der Kopfzeile, begrenzt; darüber scrollt sie.
    static func listHeight(rowCount: Int, sectionCount: Int) -> CGFloat {
        let content = CGFloat(rowCount) * rowHeight + CGFloat(sectionCount) * sectionHeaderHeight
        return min(expandedMaxListHeight, content) + footerHeight + listPadding
    }

    /// Platz, den die Zähler im Ruhezustand brauchen (Punkt, Zahl, Abstand).
    static func chipsWidth(chipCount: Int) -> CGFloat {
        28 + CGFloat(max(0, chipCount)) * 46
    }

    /// Breite des Ruhezustands der Pille aus den sichtbaren Zählern.
    static func pillCompactWidth(chipCount: Int) -> CGFloat {
        // Ohne Zähler steht der Hinweis "No active chats" in der Pille.
        guard chipCount > 0 else { return 150 }
        return max(64, chipsWidth(chipCount: chipCount))
    }

    // MARK: Bildschirmwahl

    /// Wählt den Bildschirm der Anzeige. `auto` bevorzugt den eingebauten
    /// Bildschirm mit Notch und fällt auf den Hauptbildschirm zurück; ist die
    /// Wahl nicht erfüllbar (kein eingebauter Bildschirm), gilt ebenfalls der
    /// Hauptbildschirm. Ohne Bildschirme `nil`.
    static func selectScreen(
        choice: NotchScreenChoice,
        screens: [NotchScreenInfo],
        mainDisplayID: UInt32?
    ) -> NotchScreenInfo? {
        guard !screens.isEmpty else { return nil }
        let main = screens.first { $0.displayID == mainDisplayID } ?? screens[0]
        switch choice {
        case .main:
            return main
        case .builtIn:
            return screens.first { $0.isBuiltIn } ?? main
        case .auto:
            return screens.first { $0.isBuiltIn && $0.hasNotch }
                ?? screens.first { $0.hasNotch }
                ?? main
        }
    }

    // MARK: Fenster-Rahmen

    /// Rahmen des Fensters in globalen Cocoa-Koordinaten (Ursprung unten links).
    static func panelFrame(screen: NotchScreenInfo, mode: NotchPanelMode) -> CGRect {
        layout(screen: screen, mode: mode).frame
    }

    /// Mit Notch: Oben deckt ein schwarzes Band genau die Aussparung (sie ist
    /// ohnehin schwarz), darunter hängt der Körper mit Zählern, Chat-Name oder
    /// Liste. Das Band ist nie breiter als die Notch, die Menüleiste daneben
    /// bleibt frei. Ohne Notch sitzt eine Pille mittig unter der Menüleiste.
    static func layout(screen: NotchScreenInfo, mode: NotchPanelMode) -> NotchLayout {
        if screen.hasNotch {
            let bandHeight = screen.safeAreaTop
            let notchWidth = screen.notchWidth
            let bodyWidth: CGFloat
            var bodyHeight = chinHeight
            switch mode {
            case .compact:
                // Genau Notch-Breite: Das Fenster berührt die Menüleiste daneben
                // im Dauerzustand gar nicht, auch kein transparenter Rand.
                // Vier zweistellige Zähler passen in jede Notch.
                bodyWidth = notchWidth
            case .alert:
                bodyWidth = max(notchWidth, alertWidth)
            case .expanded(let rows, let sections):
                bodyWidth = max(notchWidth, expandedMinWidth)
                bodyHeight += listHeight(rowCount: rows, sectionCount: sections)
            }
            let top = screen.frame.maxY
            let band = CGRect(
                x: screen.notchCenterX - notchWidth / 2, y: top - bandHeight,
                width: notchWidth, height: bandHeight)
            let body = CGRect(
                x: screen.notchCenterX - bodyWidth / 2, y: band.minY - bodyHeight,
                width: bodyWidth, height: bodyHeight)
            return NotchLayout(frame: band.union(body), band: band, body: body)
        }

        let menuBar = max(0, screen.frame.maxY - screen.visibleFrame.maxY)
        let top = screen.frame.maxY - (menuBar > 0 ? menuBar : fallbackMenuBarHeight) - pillTopGap
        let width: CGFloat
        var height = pillHeight
        switch mode {
        case .compact(let chipCount):
            width = pillCompactWidth(chipCount: chipCount)
        case .alert:
            width = pillAlertWidth
        case .expanded(let rows, let sections):
            width = pillExpandedWidth
            height += listHeight(rowCount: rows, sectionCount: sections)
        }
        let frame = CGRect(x: screen.frame.midX - width / 2, y: top - height, width: width, height: height)
        return NotchLayout(frame: frame, band: .zero, body: frame)
    }

    /// Bereich der Menüleiste neben der Notch, den die Anzeige nicht berühren
    /// darf (links und rechts der Aussparung). Ohne Notch die ganze Leiste.
    static func menuBarItemAreas(screen: NotchScreenInfo) -> [CGRect] {
        let menuBarHeight = screen.hasNotch
            ? screen.safeAreaTop
            : max(0, screen.frame.maxY - screen.visibleFrame.maxY)
        let bar = CGRect(
            x: screen.frame.minX, y: screen.frame.maxY - menuBarHeight,
            width: screen.frame.width, height: menuBarHeight)
        guard screen.hasNotch else { return [bar] }
        let notchMinX = screen.notchCenterX - screen.notchWidth / 2
        let notchMaxX = screen.notchCenterX + screen.notchWidth / 2
        return [
            CGRect(x: bar.minX, y: bar.minY, width: notchMinX - bar.minX, height: bar.height),
            CGRect(x: notchMaxX, y: bar.minY, width: bar.maxX - notchMaxX, height: bar.height),
        ]
    }
}

// MARK: - Vollbild-Erkennung

/// Ein Fenster aus `CGWindowListCopyWindowInfo`, auf das Nötige reduziert.
struct NotchWindowSample: Equatable {
    var layer: Int
    /// Koordinaten wie bei Quartz: Ursprung oben links am Hauptbildschirm.
    var bounds: CGRect
    var ownerPID: Int32
}

enum NotchFullscreenDetector {
    /// Läuft auf diesem Bildschirm eine fremde App im Vollbild?
    ///
    /// - Ein fremdes Fenster der normalen Ebene deckt den Bildschirm samt
    ///   Menüleistenbereich exakt ab (Vollbild ohne Notch, Video, Spiel).
    /// - Auf Bildschirmen mit Notch legt macOS Vollbild-Apps meist unter die
    ///   Kamera: das Fenster beginnt an der Unterkante der Notch. Dieselben
    ///   Maße hat ein maximiertes Fenster bei ausgeblendetem Dock, deshalb
    ///   zählt das nur, wenn das System gerade Vollbild meldet
    ///   (`NSApp.currentSystemPresentationOptions` enthält `.fullScreen`).
    ///
    /// Ein bloß maximiertes Fenster lässt die Menüleiste frei und zählt nicht.
    static func isFullscreen(
        screenFrameQuartz: CGRect,
        safeAreaTop: CGFloat = 0,
        windows: [NotchWindowSample],
        ownPID: Int32,
        systemReportsFullScreen: Bool = false,
        tolerance: CGFloat = 1
    ) -> Bool {
        func close(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) <= tolerance }
        return windows.contains { window in
            guard window.layer == 0, window.ownerPID != ownPID,
                  close(window.bounds.minX, screenFrameQuartz.minX),
                  close(window.bounds.width, screenFrameQuartz.width),
                  close(window.bounds.maxY, screenFrameQuartz.maxY) else { return false }
            if close(window.bounds.minY, screenFrameQuartz.minY) { return true }
            return systemReportsFullScreen && safeAreaTop > 0
                && close(window.bounds.minY, screenFrameQuartz.minY + safeAreaTop)
        }
    }

    /// Cocoa-Rahmen (unten links) in Quartz-Koordinaten (oben links) umrechnen;
    /// `primaryHeight` ist die Höhe des Hauptbildschirms.
    static func quartzFrame(fromCocoa frame: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height)
    }
}
