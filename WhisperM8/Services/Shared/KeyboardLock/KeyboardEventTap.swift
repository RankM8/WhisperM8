import AppKit
import CoreGraphics

/// Dünne Hülle um den echten `CGEventTap`, damit der Controller ohne
/// Systemeingriff testbar bleibt.
@MainActor
protocol KeyboardEventTapping: AnyObject {
    /// Installiert den Tap. `false`, wenn macOS ihn verweigert (fehlende
    /// Bedienungshilfen-Freigabe).
    func install(handler: @escaping @MainActor (KeyboardLockPolicy.Event, CGEventFlags) -> KeyboardLockPolicy.Decision) -> Bool
    func reenable()
    func uninstall()
}

/// Aktiver Tap auf HID-Ebene: sitzt vor Apps, Systemkürzeln (⌘-Tab) und den
/// Carbon-Hotkeys. Er läuft auf dem Main-Runloop — hängt der Main Thread,
/// schaltet macOS den Tap per Zeitüberschreitung ab und die Tastatur geht
/// wieder. Stirbt die App, verschwindet der Tap mit dem Prozess.
@MainActor
final class LiveKeyboardEventTap: KeyboardEventTapping {
    /// `NX_SYSDEFINED` — in `CGEventType` nicht als Fall vorhanden.
    private static let systemDefinedType: UInt32 = 14

    private var machPort: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    fileprivate var handler: (@MainActor (KeyboardLockPolicy.Event, CGEventFlags) -> KeyboardLockPolicy.Decision)?

    func install(handler: @escaping @MainActor (KeyboardLockPolicy.Event, CGEventFlags) -> KeyboardLockPolicy.Decision) -> Bool {
        uninstall()
        self.handler = handler

        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
            | (1 << Self.systemDefinedType)

        guard let port = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: keyboardLockTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            self.handler = nil
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        machPort = port
        runLoopSource = source
        return true
    }

    func reenable() {
        guard let machPort else { return }
        CGEvent.tapEnable(tap: machPort, enable: true)
    }

    func uninstall() {
        if let machPort {
            CGEvent.tapEnable(tap: machPort, enable: false)
            CFMachPortInvalidate(machPort)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        machPort = nil
        runLoopSource = nil
        handler = nil
    }

    /// Übersetzt ein `CGEvent` in das Ereignis der reinen Logik.
    fileprivate static func event(type: CGEventType, cgEvent: CGEvent) -> KeyboardLockPolicy.Event {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            return .tapDisabled
        case .keyDown:
            return .keyDown(keyCode: cgEvent.getIntegerValueField(.keyboardEventKeycode))
        case .keyUp:
            return .keyUp(keyCode: cgEvent.getIntegerValueField(.keyboardEventKeycode))
        case .flagsChanged:
            return .flagsChanged(keyCode: cgEvent.getIntegerValueField(.keyboardEventKeycode))
        default:
            if type.rawValue == systemDefinedType, let nsEvent = NSEvent(cgEvent: cgEvent) {
                return .systemDefined(subtype: nsEvent.subtype.rawValue)
            }
            return .other
        }
    }
}

/// C-Callback des Taps. Läuft auf dem Main-Runloop (siehe `install`).
private func keyboardLockTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<LiveKeyboardEventTap>.fromOpaque(refcon).takeUnretainedValue()
    let decision: KeyboardLockPolicy.Decision = MainActor.assumeIsolated {
        guard let handler = tap.handler else { return .pass }
        let mapped = LiveKeyboardEventTap.event(type: type, cgEvent: event)
        let result = handler(mapped, event.flags)
        if result == .reenableTap { tap.reenable() }
        return result
    }
    return decision == .swallow ? nil : Unmanaged.passUnretained(event)
}
