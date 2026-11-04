import CoreGraphics
import Foundation

/// Reine Entscheidungslogik der Tastatursperre („Tastatur reinigen“): welches
/// Tastatur-Ereignis verworfen wird und wann die Sperre von selbst endet.
/// Kein AppKit, kein Event-Tap — der `KeyboardLockController` übersetzt die
/// echten `CGEvent`s in `Event` und setzt die Entscheidung um.
struct KeyboardLockPolicy: Equatable {
    /// Standarddauer bis zum automatischen Entsperren.
    static let defaultDuration: TimeInterval = 120
    /// Schritt für „+1 Minute“.
    static let extensionStep: TimeInterval = 60
    /// Obergrenze, damit „+1 Minute“ die Sperre nicht beliebig verlängert.
    static let maximumDuration: TimeInterval = 10 * 60

    /// `NX_SUBTYPE_AUX_CONTROL_BUTTONS`: Medien-, Helligkeits-, Lautstärke- und
    /// Tastaturlicht-Tasten. Andere Untertypen der Systemereignisse (etwa 7 =
    /// Maustasten) müssen durch, sonst hakt die Maus.
    static let auxControlButtonsSubtype: Int16 = 8

    enum Event: Equatable {
        case keyDown(keyCode: Int64)
        case keyUp(keyCode: Int64)
        case flagsChanged(keyCode: Int64)
        case systemDefined(subtype: Int16)
        /// macOS hat den Tap abgeschaltet (Zeitüberschreitung oder Nutzereingabe).
        case tapDisabled
        case other
    }

    enum Decision: Equatable {
        case pass
        case swallow
        /// Tap wieder einschalten, Ereignis selbst durchlassen.
        case reenableTap
    }

    /// Tasten, die beim Sperren schon gedrückt waren. Ihr Loslassen geht durch,
    /// sonst glaubt das System nach dem Entsperren, sie hingen noch.
    private(set) var keysDownAtLock: Set<Int64>

    init(keysDownAtLock: Set<Int64> = []) {
        self.keysDownAtLock = keysDownAtLock
    }

    mutating func decide(_ event: Event) -> Decision {
        switch event {
        case .keyDown:
            return .swallow
        case let .keyUp(keyCode):
            return keysDownAtLock.remove(keyCode) == nil ? .swallow : .pass
        case let .flagsChanged(keyCode):
            // Modifier melden Drücken und Loslassen gleichermaßen als
            // flagsChanged. Ein vor der Sperre gehaltener Modifier darf genau
            // einmal (sein Loslassen) durch.
            return keysDownAtLock.remove(keyCode) == nil ? .swallow : .pass
        case let .systemDefined(subtype):
            return subtype == Self.auxControlButtonsSubtype ? .swallow : .pass
        case .tapDisabled:
            return .reenableTap
        case .other:
            return .pass
        }
    }

    /// Neue Frist nach „+1 Minute“, gedeckelt auf `maximumDuration` ab Sperrbeginn.
    static func extendedDeadline(current: Date, lockedAt: Date, now: Date) -> Date {
        let base = max(current, now)
        let extended = base.addingTimeInterval(extensionStep)
        return min(extended, lockedAt.addingTimeInterval(maximumDuration))
    }

    /// Ob „+1 Minute“ noch etwas bewirkt.
    static func canExtend(current: Date, lockedAt: Date) -> Bool {
        current < lockedAt.addingTimeInterval(maximumDuration)
    }
}

/// Warum die Sperre endet — für Log und Tests.
enum KeyboardUnlockReason: String, Equatable {
    case user
    case timeout
    case screenLocked
    case systemSleep
    case sessionResigned
    case appTerminating
    case tapFailed
}
