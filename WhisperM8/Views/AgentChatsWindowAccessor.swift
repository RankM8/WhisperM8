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
        if let onWillClose {
            coordinator.observeWillClose(of: window, handler: onWillClose)
        }
        onResolve?(window)
    }

    /// Hält den willClose-Observer über Re-Configures hinweg (`updateNSView`
    /// feuert mehrfach mit demselben Fenster — ohne Coordinator würde jeder
    /// Durchlauf einen weiteren Observer stapeln) und baut ihn bei
    /// Fensterwechsel oder View-Abbau ab.
    final class Coordinator {
        private var observedWindow: NSWindow?
        private var observer: NSObjectProtocol?

        func observeWillClose(of window: NSWindow, handler: @escaping () -> Void) {
            guard observedWindow !== window else { return }
            removeObserver()
            observedWindow = window
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { _ in handler() }
        }

        private func removeObserver() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            observedWindow = nil
        }

        deinit { removeObserver() }
    }
}
