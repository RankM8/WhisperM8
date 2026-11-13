import Foundation

// Rohes HID des Xbox-Controllers (Plan `controller-xbox-paddles.md`, „HID-Quelle
// und Berechtigung“, Nachtrag „Xbox-Knopf“). Nur Zahlen und pure Logik; die
// IOKit-Anbindung liegt in `XboxPaddleHIDSource` (der Kern bleibt
// Foundation-only).

enum XboxHID {
    static let vendorMicrosoft = 0x045E
    /// Generic Desktop; Geräte-Usages, die geöffnet werden dürfen. Nie
    /// Tastatur oder Maus: Das löste die Rückfrage nach Eingabeüberwachung aus.
    static let pageGenericDesktop: UInt32 = 0x01
    static let usageJoystick: UInt32 = 0x04
    static let usageGamePad: UInt32 = 0x05
    static let usageMultiAxis: UInt32 = 0x08
    static let gamepadUsages: [UInt32] = [usageJoystick, usageGamePad, usageMultiAxis]
    /// Tastatur und Ziffernblock: Tritt ein Gerät auch so auf (der Elite tut
    /// es über Bluetooth LE), braucht sein Öffnen „Eingabeüberwachung“.
    static let usageKeyboard: UInt32 = 0x06
    static let usageKeypad: UInt32 = 0x07

    /// Darf ein Gerät mit diesen `DeviceUsagePairs` geöffnet werden? Mit
    /// Tastatur- oder Ziffernblock-Paar nur bei erteilter Eingabeüberwachung:
    /// Das Öffnen löste sonst die Rückfrage des Systems aus.
    static func mayOpen(usagePairs: [(page: UInt32, usage: UInt32)], listenAccessGranted: Bool) -> Bool {
        listenAccessGranted || !usagePairs.contains {
            $0.page == pageGenericDesktop && ($0.usage == usageKeyboard || $0.usage == usageKeypad)
        }
    }

    /// Tastenseite (A, B, X, Y …).
    static let pageButton: UInt32 = 0x09
    /// Consumer-Seite: Paddle-Maske unter Usage 0x81 (Elite Series 2).
    static let pageConsumer: UInt32 = 0x0C
    static let usagePaddles: UInt32 = 0x81
}

/// Tastenseite 0x09 ↔ logische Taste. Gemessen (12.11.2026, Elite Series 2
/// über Bluetooth LE, Firmware 5.21): A = 1, B = 2, X = 4, Y = 5, Xbox-Knopf
/// = 0x0D; gemessen 13.11.2026: LB = 7, RB = 8, View = 0x0B, Menu = 0x0C,
/// LS = 0x0E, RS = 0x0F. Unbekannte Usages werden ignoriert (kein Urteil).
enum XboxHIDButtons {
    static let homeUsage: UInt32 = 0x0D

    static let table: [UInt32: ControllerButton] = [
        0x01: .cross,     // A (gemessen)
        0x02: .circle,    // B (gemessen)
        0x04: .square,    // X (gemessen)
        0x05: .triangle,  // Y (gemessen)
        0x07: .l1,        // LB (gemessen 13.11.2026)
        0x08: .r1,        // RB (gemessen 13.11.2026)
        0x0B: .create,    // View (gemessen 13.11.2026)
        0x0C: .options,   // Menu (gemessen 13.11.2026)
        0x0E: .l3,        // LS (gemessen 13.11.2026)
        0x0F: .r3,        // RS (gemessen 13.11.2026)
    ]

    /// Tasten, für die HID ein Urteil fällen kann. Nur sie hält die Weiche
    /// zurück; die Gesichtstasten der Paddles (A, B, X, Y) gehören dazu.
    static let judgeable: Set<ControllerButton> = Set(table.values)
}

/// Bündelt die einzelnen Werte eines HID-Berichts (gleicher Zeitstempel)
/// zu einem `ControllerHIDReport`. Merkt sich den letzten Wert je Element,
/// damit nur Wechsel ankommen. Pur, ohne IOKit.
struct XboxHIDReportBuilder: Sendable {
    private var lastValues: [UInt64: Int] = [:]
    private var pending: ControllerHIDReport?
    private(set) var pendingTimestamp: UInt64?

    init() {}

    /// Ein Wert kam an. Gehört er zu einem neuen Bericht, kommt der fertige
    /// alte zurück.
    mutating func add(page: UInt32, usage: UInt32, value: Int, timestamp: UInt64) -> ControllerHIDReport? {
        var finished: ControllerHIDReport?
        if let pendingTimestamp, pendingTimestamp != timestamp { finished = flush() }
        let key = UInt64(page) << 32 | UInt64(usage)
        guard lastValues[key] != value else { return finished }
        let previous = lastValues[key]
        lastValues[key] = value
        var report = pending ?? ControllerHIDReport()
        switch (page, usage) {
        case (XboxHID.pageConsumer, XboxHID.usagePaddles):
            report.paddleMask = UInt32(truncatingIfNeeded: max(0, value))
        case (XboxHID.pageButton, XboxHIDButtons.homeUsage):
            report.homeButton = value != 0
        case (XboxHID.pageButton, _):
            guard let button = XboxHIDButtons.table[usage] else { return finished }
            // Erster Wert nach dem Verbinden ohne Druck: kein Wechsel.
            if previous == nil, value == 0 { return finished }
            report.buttons.append(.init(button: button, pressed: value != 0))
        default:
            return finished
        }
        pending = report
        pendingTimestamp = timestamp
        return finished
    }

    /// Den angefangenen Bericht abschließen.
    mutating func flush() -> ControllerHIDReport? {
        defer { pending = nil; pendingTimestamp = nil }
        return pending
    }

    /// Gerät getrennt: alles vergessen.
    mutating func reset() {
        lastValues = [:]
        pending = nil
        pendingTimestamp = nil
    }
}

/// Zustand der Paddles (und des Xbox-Knopfs) über HID, für Einstellungen,
/// Legende und Debug-Kanal.
enum ControllerPaddleSupport: Equatable, Sendable {
    /// Kein Xbox-Controller über HID gefunden (oder die Steuerung ist aus).
    case none
    /// Notbremse `controllerPaddleHIDEnabled` aus: kein HID, Rückfall.
    case disabled
    /// Xbox-Controller über HID lesbar, aber ohne Paddles (Xbox-Knopf geht).
    case noPaddles
    /// Paddles lesbar: eigene Tasten, die Weiche verschluckt die Doppel.
    case readable
    /// Nicht lesbar (fehlende Freigabe, Öffnen gescheitert): Paddles wirken
    /// als die Gesichtstasten ihres Controller-Profils.
    case notReadable(reason: String)

    /// Der Xbox-Knopf kommt an (er läuft über denselben HID-Leser).
    var homeButtonReadable: Bool { self == .noPaddles || self == .readable }

    /// Kurzform für den Debug-Kanal.
    var debugName: String {
        switch self {
        case .none: return "none"
        case .disabled: return "disabled"
        case .noPaddles: return "noPaddles"
        case .readable: return "readable"
        case let .notReadable(reason): return "notReadable: \(reason)"
        }
    }
}
