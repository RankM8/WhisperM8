import Carbon.HIToolbox
import Foundation

/// Fängt ESC systemweit ab, solange ein Diktat nachgearbeitet wird.
///
/// Das Overlay wird nie Key-Window, und beim Diktat steht meist eine fremde
/// App vorne (Slack, Mail). Der lokale ESC-Wächter des Coordinators sieht die
/// Taste dort nicht. Ein Carbon-Hotkey braucht keine Berechtigung, verschluckt
/// die Taste aber für alle Apps. Deshalb ist er nur während der Nacharbeit
/// angemeldet, also für wenige Sekunden.
protocol CleanUpCancelKeyGrabbing: AnyObject {
    /// Meldet ESC an; `handler` läuft auf dem Main Thread.
    func activate(handler: @escaping @MainActor () -> Void)
    func deactivate()
}

/// Für Tests und Prozesse ohne App-Bundle: meldet nichts an.
final class InactiveCleanUpCancelKey: CleanUpCancelKeyGrabbing {
    func activate(handler: @escaping @MainActor () -> Void) {}
    func deactivate() {}
}

final class GlobalEscapeHotKey: CleanUpCancelKeyGrabbing {
    static let shared = GlobalEscapeHotKey()

    /// „WMEs“: Kennung unseres Hotkeys, fremde Hotkeys (KeyboardShortcuts)
    /// reichen wir unverändert weiter.
    private static let signature: OSType = 0x574D_4573
    private static let hotKeyID: UInt32 = 1

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var handler: (@MainActor () -> Void)?

    func activate(handler: @escaping @MainActor () -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        self.handler = handler
        guard hotKeyRef == nil else { return }
        installEventHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(kVK_Escape),
            0,
            EventHotKeyID(signature: Self.signature, id: Self.hotKeyID),
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status == noErr {
            hotKeyRef = ref
        } else {
            Logger.transcription.info("cleanup_cancel_key_register_failed status=\(status, privacy: .public)")
        }
    }

    func deactivate() {
        dispatchPrecondition(condition: .onQueue(.main))
        handler = nil
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var id = EventHotKeyID()
                let read = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &id
                )
                guard read == noErr, id.signature == GlobalEscapeHotKey.signature else {
                    return OSStatus(eventNotHandledErr)
                }
                let grabber = Unmanaged<GlobalEscapeHotKey>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async {
                    guard let handler = grabber.handler else { return }
                    MainActor.assumeIsolated { handler() }
                }
                return noErr
            },
            1,
            &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
        if status != noErr {
            Logger.transcription.info("cleanup_cancel_key_handler_failed status=\(status, privacy: .public)")
        }
    }
}
