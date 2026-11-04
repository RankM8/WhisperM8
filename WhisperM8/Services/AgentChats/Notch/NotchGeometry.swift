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
    /// `chipCount`: wie viele Zähler sichtbar sind (bestimmt die Breite der Pille).
    case compact(chipCount: Int)
    case alert
    case expanded(rowCount: Int, sectionCount: Int)
}

enum NotchGeometry {
    // MARK: Maße

    /// Seitenflügel neben der Notch im Ruhezustand (Platz für Zähler).
    static let compactWing: CGFloat = 92
    /// Seitenflügel bei „braucht dich" (rechts steht der Chat-Name).
    static let alertWing: CGFloat = 200
    static let expandedMinWidth: CGFloat = 380
    static let expandedMaxListHeight: CGFloat = 400
    static let rowHeight: CGFloat = 50
    static let sectionHeaderHeight: CGFloat = 24
    static let footerHeight: CGFloat = 28
    static let listPadding: CGFloat = 12

    static let pillHeight: CGFloat = 28
    static let pillAlertWidth: CGFloat = 380
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

    /// Breite des Ruhezustands der Pille aus den sichtbaren Zählern.
    static func pillCompactWidth(chipCount: Int) -> CGFloat {
        // Ohne Zähler steht der Hinweis "No active chats" in der Pille.
        guard chipCount > 0 else { return 150 }
        return max(64, 28 + CGFloat(chipCount) * 46)
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
    /// Mit Notch hängt die Anzeige bündig an der Oberkante und wächst um die
    /// Aussparung herum; ohne Notch sitzt eine Pille mittig unter der Menüleiste.
    static func panelFrame(screen: NotchScreenInfo, mode: NotchPanelMode) -> CGRect {
        if screen.hasNotch {
            let height = screen.safeAreaTop
            let width: CGFloat
            var totalHeight = height
            switch mode {
            case .compact:
                width = screen.notchWidth + 2 * compactWing
            case .alert:
                width = screen.notchWidth + 2 * alertWing
            case .expanded(let rows, let sections):
                width = max(expandedMinWidth, screen.notchWidth + 2 * compactWing)
                totalHeight += listHeight(rowCount: rows, sectionCount: sections)
            }
            return CGRect(
                x: screen.notchCenterX - width / 2,
                y: screen.frame.maxY - totalHeight,
                width: width,
                height: totalHeight)
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
        return CGRect(x: screen.frame.midX - width / 2, y: top - height, width: width, height: height)
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
    /// Deckt ein fremdes Fenster der normalen Ebene den Bildschirm samt
    /// Menüleistenbereich exakt ab? Das ist ein Vollbild-Space (Video, Spiel,
    /// Vollbild-App). Ein bloß maximiertes Fenster lässt die Menüleiste frei
    /// und zählt nicht.
    static func isFullscreen(
        screenFrameQuartz: CGRect,
        windows: [NotchWindowSample],
        ownPID: Int32,
        tolerance: CGFloat = 1
    ) -> Bool {
        windows.contains { window in
            window.layer == 0
                && window.ownerPID != ownPID
                && abs(window.bounds.minX - screenFrameQuartz.minX) <= tolerance
                && abs(window.bounds.minY - screenFrameQuartz.minY) <= tolerance
                && abs(window.bounds.width - screenFrameQuartz.width) <= tolerance
                && abs(window.bounds.height - screenFrameQuartz.height) <= tolerance
        }
    }

    /// Cocoa-Rahmen (unten links) in Quartz-Koordinaten (oben links) umrechnen;
    /// `primaryHeight` ist die Höhe des Hauptbildschirms.
    static func quartzFrame(fromCocoa frame: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height)
    }
}
