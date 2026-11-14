import AppKit
import Foundation

/// Aufwecken aus einer anderen App (WM8-92): Agent Chats nach vorn holen und
/// dafür sorgen, dass danach das richtige Agent-Chats-Fenster die Tastatur hat.
///
/// Vorher öffnete der Weg nur das Primärfenster (`openWindow`) und aktivierte
/// die App. macOS stellt beim Aktivieren aber das zuletzt aktive Fenster der
/// App wieder her — lag dort das Einstellungsfenster, war es Schlüsselfenster.
/// Der Controller sah dann „anderes Fenster“, schickte Brücken-Tasten dorthin,
/// und macOS antwortete mit dem Fehlerton, bis ein Mausklick das
/// Agent-Chats-Fenster nach vorn holte.
///
/// Ziel ist das zuletzt aktive Agent-Chats-Fenster (`dictationWindowID`; es
/// bleibt gesetzt, während die App im Hintergrund ist), sonst das
/// Primärfenster wie bisher. Zum Schlüsselfenster wird es erst nach der
/// Aktivierung gemacht, weil macOS beim Aktivieren sonst wieder ein anderes
/// Fenster nach vorn holt.
@MainActor
struct ControllerWakeFocus {
    /// Zuletzt aktives Agent-Chats-Fenster, sofern bekannt.
    var targetWindowID: () -> UUID?
    /// Macht dieses Fenster zum Schlüsselfenster; `false`, wenn es das nicht
    /// mehr gibt.
    var makeKey: (UUID) -> Bool
    /// Der bisherige Weg: Primärfenster öffnen und die App aktivieren.
    var openPrimary: () -> Void
    var activate: () -> Void
    /// Ruft den Block auf, sobald die App aktiv ist (sofort, wenn sie es schon ist).
    var whenActive: (@escaping @MainActor () -> Void) -> Void

    func bringToFront() {
        guard let target = targetWindowID() else {
            openPrimary()
            return
        }
        whenActive {
            if !makeKey(target) { openPrimary() }
        }
        activate()
    }

    static var live: ControllerWakeFocus {
        ControllerWakeFocus(
            targetWindowID: { AgentWindowStore.shared.dictationWindowID },
            makeKey: { AgentChatsCommandCenter.shared.perform(.makeKeyWindow, in: $0) },
            openPrimary: { WindowRequestCenter.shared.request(.agentChats) },
            activate: { AppActivation.activate() },
            whenActive: ControllerWakeFocus.runWhenAppActive
        )
    }

    /// Einmal nach `didBecomeActive`, einen Lauf der Ereignisschleife später:
    /// AppKit setzt beim Aktivieren selbst ein Schlüsselfenster, unseres soll
    /// danach kommen. Wird die App binnen 2 s nicht aktiv, verfällt der Wunsch.
    static func runWhenAppActive(_ block: @escaping @MainActor () -> Void) {
        if NSApp.isActive {
            block()
            return
        }
        let once = WakeOnce(block)
        once.token = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { once.fire() } }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { MainActor.assumeIsolated { once.cancel() } }
    }
}

/// Einmaliger Aufruf nach der Aktivierung, danach Beobachter weg.
@MainActor
private final class WakeOnce: @unchecked Sendable {
    private var block: (@MainActor () -> Void)?
    var token: NSObjectProtocol?

    init(_ block: @escaping @MainActor () -> Void) { self.block = block }

    func fire() {
        let pending = block
        cancel()
        pending?()
    }

    func cancel() {
        block = nil
        if let token { NotificationCenter.default.removeObserver(token) }
        token = nil
    }
}
