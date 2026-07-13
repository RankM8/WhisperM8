import AppKit
import SwiftUI

struct AgentChatsWindowAccessor: NSViewRepresentable {
    /// Wird mit dem aufgelösten NSWindow gerufen, sobald die View im Fenster
    /// hängt — z. B. damit die View einen fensterscoped Cmd-W-Monitor
    /// installieren kann.
    var onResolve: ((NSWindow) -> Void)? = nil
    /// Feuert bei `NSWindow.willCloseNotification` des aufgelösten Fensters
    /// (Main-Thread, einmal pro Close). Ob das Close user-initiiert war
    /// (rotes X, Fenstermenü) oder programmatisch (App-Quit, Profilwechsel),
    /// entscheidet der Empfänger — `AgentWindowStore.handleWindowWillClose`
    /// via Suspend-Flag.
    var onWillClose: (() -> Void)? = nil
    /// Key-Window-Tracking fürs Dictation-Routing: `didBecomeKey`/
    /// `didResignKey` des aufgelösten Fensters →
    /// `AgentWindowStore.windowDidBecomeKey/ResignKey` (das globale
    /// Dictation-Ziel folgt ausschließlich dem Key-Fenster).
    var onBecomeKey: (() -> Void)? = nil
    var onResignKey: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let coordinator = context.coordinator
        DispatchQueue.main.async {
            configure(view.window, coordinator: coordinator)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let coordinator = context.coordinator
        DispatchQueue.main.async {
            configure(nsView.window, coordinator: coordinator)
        }
    }

    private func configure(_ window: NSWindow?, coordinator: Coordinator) {
        guard let window else { return }
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = false
        // macOS/SwiftUI-Fenster-Restoration AUS: Die WindowGroup wuerde sonst
        // Sekundaerfenster frueherer Sessions eigenmaechtig wiederherstellen —
        // zusaetzlich zu unserem Store-basierten Restore. Das fuehrte zu sich
        // aufstapelnden Duplikaten bei jedem Launch. AgentWindowStore ist die
        // EINZIGE Restore-Autoritaet. (Auf macOS 15+ waere das
        // `restorationBehavior(.disabled)`; isRestorable ist der macOS-14-Weg.)
        window.isRestorable = false
        window.backgroundColor = NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return isDark
                ? NSColor(srgbRed: 0.058, green: 0.060, blue: 0.064, alpha: 1)
                : NSColor.white
        }
        if onWillClose != nil || onBecomeKey != nil || onResignKey != nil {
            coordinator.observe(
                window: window,
                onWillClose: onWillClose,
                onBecomeKey: onBecomeKey,
                onResignKey: onResignKey
            )
        }
        // Fenster ist beim Aufbau oft schon key, BEVOR der Observer hängt —
        // den Anfangszustand explizit melden, sonst routet Dictation bis zum
        // ersten Fokuswechsel ins Leere.
        if window.isKeyWindow { onBecomeKey?() }
        onResolve?(window)
    }

    /// Hält die Fenster-Observer über Re-Configures hinweg (`updateNSView`
    /// feuert mehrfach mit demselben Fenster — ohne Coordinator würde jeder
    /// Durchlauf weitere Observer stapeln) und baut sie bei
    /// Fensterwechsel oder View-Abbau ab.
    final class Coordinator {
        private var observedWindow: NSWindow?
        private var observers: [NSObjectProtocol] = []

        func observe(
            window: NSWindow,
            onWillClose: (() -> Void)?,
            onBecomeKey: (() -> Void)?,
            onResignKey: (() -> Void)?
        ) {
            guard observedWindow !== window else { return }
            removeObservers()
            observedWindow = window
            let center = NotificationCenter.default
            if let onWillClose {
                observers.append(center.addObserver(
                    forName: NSWindow.willCloseNotification, object: window, queue: .main
                ) { _ in onWillClose() })
            }
            if let onBecomeKey {
                observers.append(center.addObserver(
                    forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
                ) { _ in onBecomeKey() })
            }
            if let onResignKey {
                observers.append(center.addObserver(
                    forName: NSWindow.didResignKeyNotification, object: window, queue: .main
                ) { _ in onResignKey() })
            }
        }

        private func removeObservers() {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers = []
            observedWindow = nil
        }

        deinit { removeObservers() }
    }
}
