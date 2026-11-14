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
    /// Ruft `onActive` auf, sobald die App aktiv ist (sofort, wenn sie es schon
    /// ist), sonst nach Ablauf der Frist `onTimeout`.
    var whenActive: (_ onActive: @escaping @MainActor () -> Void, _ onTimeout: @escaping @MainActor () -> Void) -> Void

    func bringToFront() {
        guard let target = targetWindowID() else {
            openPrimary()
            return
        }
        whenActive({
            if !makeKey(target) { openPrimary() }
        }, {
            // Aktivierung verweigert oder ausgeblieben: wenigstens der alte Weg.
            openPrimary()
        })
        activate()
    }

    static var live: ControllerWakeFocus {
        ControllerWakeFocus(
            targetWindowID: { AgentWindowStore.shared.dictationWindowID },
            makeKey: { target in
                // Für den Feldtest: welches Fenster vorher Key war und ob unseres es danach ist.
                let before = describe(NSApp.keyWindow)
                let done = AgentChatsCommandCenter.shared.perform(.makeKeyWindow, in: target)
                DispatchQueue.main.async {
                    Logger.controller.info(
                        "controller_wake_focus made=\(done, privacy: .public) before=\(before, privacy: .public) after=\(describe(NSApp.keyWindow), privacy: .public)")
                }
                return done
            },
            openPrimary: { WindowRequestCenter.shared.request(.agentChats) },
            activate: { AppActivation.activate() },
            whenActive: ControllerWakeFocus.runWhenAppActive
        )
    }

    /// Einmal nach `didBecomeActive`, einen Lauf der Ereignisschleife später:
    /// AppKit setzt beim Aktivieren selbst ein Schlüsselfenster, unseres soll
    /// danach kommen. Wird die App binnen 2 s nicht aktiv, verfällt der Wunsch.
    static func runWhenAppActive(
        _ block: @escaping @MainActor () -> Void,
        onTimeout: @escaping @MainActor () -> Void
    ) {
        // Die Test-Instanz aktiviert sich nie (`AppActivation`): sofort.
        if NSApp.isActive || AppInstance.isTestInstance {
            block()
            return
        }
        let once = WakeOnce(block)
        once.token = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { once.fire() } }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            MainActor.assumeIsolated { if once.cancel() { onTimeout() } }
        }
    }
}

/// Klasse und Kennung eines Fensters für das Log, ohne Titel (der kann Inhalte nennen).
@MainActor
private func describe(_ window: NSWindow?) -> String {
    guard let window else { return "none" }
    return "\(type(of: window)):\(window.identifier?.rawValue ?? "-")"
}

/// Einmaliger Aufruf nach der Aktivierung, danach Beobachter weg.
@MainActor
private final class WakeOnce {
    private var block: (@MainActor () -> Void)?
    var token: NSObjectProtocol?

    init(_ block: @escaping @MainActor () -> Void) { self.block = block }

    func fire() {
        let pending = block
        cancel()
        pending?()
    }

    /// `true`, wenn der Block da noch ausstand (Frist abgelaufen).
    @discardableResult
    func cancel() -> Bool {
        let wasPending = block != nil
        block = nil
        if let token { NotificationCenter.default.removeObserver(token) }
        token = nil
        return wasPending
    }
}
