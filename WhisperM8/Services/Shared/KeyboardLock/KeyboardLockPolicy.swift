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

    /// Takt des Lebenszeichens vom Main Thread (der sekündliche `tick()`).
    static let heartbeatInterval: TimeInterval = 1
    /// Ab diesem Alter des Lebenszeichens gilt der Main Thread als hängend,
    /// und die Sperre lässt alles durch. Begründung der 5 s: Im Normalbetrieb
    /// ist das Lebenszeichen höchstens gut 1 s alt (Takt plus 0,2 s
    /// Timer-Toleranz). Stocker von einigen Sekunden (großer Transcript-Scan,
    /// AX-Aufruf, Layout) sollen weiter sperren, sonst landen beim Wischen
    /// Return oder ⌘W in der App vorn. Ein Hänger über 5 s ist für den Nutzer
    /// schon am Beachball sichtbar; dann braucht er die Tastatur (⌥⌘⎋).
    static let heartbeatTimeout: TimeInterval = 5
    /// Feststelltaste: `CGEventSource.keyState` meldet je nach System den
    /// Schaltzustand statt der gedrückten Taste. Beim Erfassen gehaltener
    /// Tasten bleibt sie deshalb außen vor, sonst ginge ihr erstes Drücken
    /// während der Sperre durch.
    static let capsLockKeyCode: Int64 = 57

    /// Tasten, deren Loslassen noch genau einmal durch muss: beim Sperren
    /// schon gedrückt, oder gedrückt, während das Lebenszeichen ausblieb und
    /// die Sperre alles durchließ. Sonst glaubt das System nach dem
    /// Entsperren, sie hingen noch.
    private(set) var releasesToPass: Set<Int64>
    /// Uptime des letzten Lebenszeichens vom Main Thread.
    private(set) var lastHeartbeat: TimeInterval

    init(keysDownAtLock: Set<Int64> = [], startedAt: TimeInterval) {
        self.releasesToPass = keysDownAtLock.subtracting([Self.capsLockKeyCode])
        self.lastHeartbeat = startedAt
    }

    mutating func heartbeat(at now: TimeInterval) {
        lastHeartbeat = max(lastHeartbeat, now)
    }

    /// Ob der Main Thread sich zuletzt rechtzeitig gemeldet hat. Nur solange
    /// das gilt, wird gesperrt.
    func isHeartbeatFresh(at now: TimeInterval) -> Bool {
        now - lastHeartbeat <= Self.heartbeatTimeout
    }

    mutating func decide(_ event: Event, at now: TimeInterval) -> Decision {
        if case .tapDisabled = event { return .reenableTap }
        guard isHeartbeatFresh(at: now) else { return passWhileStale(event) }
        switch event {
        case .keyDown:
            return .swallow
        case let .keyUp(keyCode):
            return releasesToPass.remove(keyCode) == nil ? .swallow : .pass
        case let .flagsChanged(keyCode):
            // Modifier melden Drücken und Loslassen gleichermaßen als
            // flagsChanged. Ein vor der Sperre gehaltener Modifier darf genau
            // einmal (sein Loslassen) durch.
            return releasesToPass.remove(keyCode) == nil ? .swallow : .pass
        case let .systemDefined(subtype):
            return subtype == Self.auxControlButtonsSubtype ? .swallow : .pass
        case .tapDisabled, .other:
            return .pass
        }
    }

    /// Main Thread hängt: alles geht durch. Gedrückte Tasten werden gemerkt,
    /// damit ihr Loslassen auch dann durchkommt, wenn das Lebenszeichen
    /// inzwischen zurück ist.
    private mutating func passWhileStale(_ event: Event) -> Decision {
        switch event {
        case let .keyDown(keyCode):
            releasesToPass.insert(keyCode)
        case let .keyUp(keyCode):
            releasesToPass.remove(keyCode)
        case let .flagsChanged(keyCode):
            // Drücken oder Loslassen ist hier nicht unterscheidbar: abwechselnd.
            if releasesToPass.remove(keyCode) == nil { releasesToPass.insert(keyCode) }
        case .systemDefined, .tapDisabled, .other:
            break
        }
        return .pass
    }

    /// Erlaubte Sperrdauer nach „+1 Minute“, gemessen ab Sperrbeginn in
    /// Uptime-Sekunden (nicht an der Wanduhr, die springen kann). Gedeckelt auf
    /// `maximumDuration`.
    static func extendedDuration(allowed: TimeInterval, elapsed: TimeInterval) -> TimeInterval {
        min(max(allowed, elapsed) + extensionStep, maximumDuration)
    }

    /// Ob „+1 Minute“ noch etwas bewirkt.
    static func canExtend(allowed: TimeInterval) -> Bool {
        allowed < maximumDuration
    }
}

/// Warum die Sperre endet — für Log und Tests.
enum KeyboardUnlockReason: String, Equatable {
    case user
    case timeout
    case screenLocked
    case systemSleep
    case screensSlept
    case sessionResigned
    case appTerminating
    case tapFailed
}
