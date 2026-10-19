import AppKit

/// App nach vorn holen — außer in der Test-Instanz: Die läuft neben der
/// Produktiv-App des Nutzers und darf ihm nie den Fokus nehmen.
@MainActor
enum AppActivation {
    static func activate() {
        guard !AppInstance.isTestInstance else { return }
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Test-Instanz: Fenster liegen hinter dem Schreibtisch (Fensterebene unter
/// `desktopWindow`, klickdurchlässig) und so weit links wie AppKit zulässt, und wird die App doch aktiv (SwiftUI
/// aktiviert z. B. beim Öffnen eines Fensters selbst), bekommt die zuvor
/// vorderste App den Fokus sofort zurück. So legt eine zweite App-Instanz
/// nichts über die Arbeitsfenster des Nutzers und nimmt ihm keine Tastatur.
/// Gerendert wird trotzdem — ScreenCaptureKit (`whisperm8 debug snapshot`)
/// erfasst das Fenster auch verdeckt. Alpha 0 ginge nicht: dann ist das Foto leer.
/// `WHISPERM8_TEST_VISIBLE=1` schaltet das ab.
@MainActor
enum TestInstanceWindowParking {
    static let parkedOriginX: CGFloat = -30_000
    static let parkedLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
    private static var observers: [NSObjectProtocol] = []
    private static var lastForeignFrontmost: NSRunningApplication?

    static func installIfNeeded(environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard AppInstance.isTestInstance, environment["WHISPERM8_TEST_VISIBLE"] != "1", observers.isEmpty else { return }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != ownPID {
            lastForeignFrontmost = front
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didUpdateNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { parkWindows() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                if let app, app.processIdentifier != ownPID { lastForeignFrontmost = app }
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { _ = lastForeignFrontmost?.activate() }
        })
    }

    static func parkWindows() {
        // Auch unsichtbare Fenster: `scripts/test-instance.sh` startet die App
        // versteckt (`open -j`), eingeblendet wird erst danach, ohne Aktivierung.
        for window in NSApp.windows where window.level != parkedLevel {
            // Statusleisten-Fenster (MenuBarExtra) bleiben, wie sie sind.
            guard window.level != .statusBar, !window.className.contains("StatusBar") else { continue }
            window.level = parkedLevel
            window.ignoresMouseEvents = true
            // Titelfenster hält AppKit mit einem Rest auf dem Bildschirm — der liegt hinter dem Schreibtisch.
            window.setFrameOrigin(NSPoint(x: parkedOriginX, y: window.frame.minY))
        }
        if NSApp.isHidden {
            NSApp.unhideWithoutActivation()
        }
    }
}
