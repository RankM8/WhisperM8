import Foundation

/// Künstliche Controller-Eingaben für den Debug-Kanal
/// (`whisperm8 debug controller …`). Ein Skript ist eine Folge von Schritten,
/// durch Kommas getrennt:
///
///     down:cross            Taste drücken
///     up:cross              Taste loslassen
///     trigger:r2:1          Trigger auf einen Wert zwischen 0 und 1 stellen
///     stick:left:0:1        Stick auslenken (x, y; y positiv = oben)
///     wait:300              Millisekunden warten
///     hid:4+cross           HID-Bericht des Xbox-Controllers: Paddle-Maske 4
///                           und A gedrückt im selben Bericht (Weiche der
///                           Paddles); `hid:0-cross` lässt los, `hid:+home`
///                           drückt den Xbox-Knopf, ohne Zahl bleibt die Maske
///
/// Die Schritte laufen durch dieselbe Kette wie echte Hardware.
enum ControllerDebugScript {
    enum Step: Equatable {
        case event(ControllerInputEvent)
        case wait(milliseconds: Int)
        /// Künstlicher HID-Bericht (Xbox Elite), durch die Weiche der Paddles.
        case hid(ControllerHIDReport)
    }

    enum ParseError: Error, Equatable {
        case invalid(String)
    }

    /// Der Control-Socket bricht jede Anfrage nach 10 s ab.
    static let maxTotalWaitMilliseconds = 8_000

    static func parse(_ script: String) throws -> [Step] {
        let parts = script.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !parts.isEmpty else { throw ParseError.invalid("Leeres Skript") }
        var steps: [Step] = []
        var totalWait = 0
        for part in parts {
            let fields = part.split(separator: ":").map(String.init)
            switch fields.first {
            case "down", "up":
                guard fields.count == 2, let button = ControllerButton(rawValue: fields[1]) else {
                    throw ParseError.invalid("Unbekannte Taste in „\(part)“ — erlaubt: \(buttonNames)")
                }
                guard button != .l2, button != .r2 else {
                    throw ParseError.invalid("\(button.rawValue) ist ein Trigger: trigger:\(button.rawValue):<0…1>")
                }
                steps.append(.event(.button(button, pressed: fields[0] == "down")))
            case "trigger":
                guard fields.count == 3, let button = ControllerButton(rawValue: fields[1]),
                      button == .l2 || button == .r2,
                      let value = Float(fields[2]), (0...1).contains(value) else {
                    throw ParseError.invalid("trigger:<l2|r2>:<0…1> erwartet, bekommen: „\(part)“")
                }
                steps.append(.event(.trigger(button, value: value)))
            case "stick":
                guard fields.count == 4, let side = ControllerStickSide(rawValue: fields[1]),
                      let x = Float(fields[2]), let y = Float(fields[3]),
                      (-1...1).contains(x), (-1...1).contains(y) else {
                    throw ParseError.invalid("stick:<left|right>:<x>:<y> mit Werten von -1 bis 1 erwartet, bekommen: „\(part)“")
                }
                steps.append(.event(.stick(side, x: x, y: y)))
            case "hid":
                guard fields.count == 2, let report = parseHID(fields[1]) else {
                    throw ParseError.invalid("hid:<maske>[+<taste>|-<taste>…] erwartet (Taste auch home), bekommen: „\(part)“")
                }
                steps.append(.hid(report))
            case "wait":
                guard fields.count == 2, let milliseconds = Int(fields[1]), milliseconds >= 0 else {
                    throw ParseError.invalid("wait:<millisekunden> erwartet, bekommen: „\(part)“")
                }
                totalWait += milliseconds
                steps.append(.wait(milliseconds: milliseconds))
            default:
                throw ParseError.invalid("Unbekannter Schritt: „\(part)“")
            }
        }
        guard totalWait <= maxTotalWaitMilliseconds else {
            throw ParseError.invalid("Zusammen höchstens \(maxTotalWaitMilliseconds) ms warten (Zeitlimit des Sockets)")
        }
        try requireNeutralEnd(steps)
        return steps
    }

    /// Ein Skript muss alles wieder loslassen: Sonst liefe nach dem Ende des
    /// Laufs ein Halten, eine Wiederholung oder ein Scrollen weiter — und
    /// träfe die App, nachdem der Trockenlauf schon vorbei ist.
    static func requireNeutralEnd(_ steps: [Step]) throws {
        var pressed = Set<ControllerButton>()
        var triggers: [ControllerButton: Float] = [:]
        var sticks: [ControllerStickSide: Bool] = [:]
        var mask: UInt32 = 0
        var home = false
        for case let .hid(report) in steps {
            if let paddleMask = report.paddleMask { mask = paddleMask }
            if let pressed = report.homeButton { home = pressed }
        }
        for case let .event(event) in steps {
            switch event {
            case let .button(button, isDown):
                if isDown { pressed.insert(button) } else { pressed.remove(button) }
            case let .trigger(button, value):
                triggers[button] = value
            case let .stick(side, x, y):
                sticks[side] = x != 0 || y != 0
            }
        }
        var open = pressed.map { "up:\($0.rawValue)" }.sorted()
        open += triggers.filter { $0.value != 0 }.map { "trigger:\($0.key.rawValue):0" }.sorted()
        open += sticks.filter(\.value).map { "stick:\($0.key.rawValue):0:0" }.sorted()
        if mask != 0 { open.append("hid:0") }
        if home { open.append("hid:-home") }
        guard open.isEmpty else {
            throw ParseError.invalid("Das Skript muss alles wieder loslassen — es fehlt am Ende: \(open.joined(separator: ", "))")
        }
    }

    /// Skript für einen einzelnen Tastendruck, wahlweise gehalten.
    static func pressScript(button: ControllerButton, holdMilliseconds: Int) -> String {
        if button == .l2 || button == .r2 {
            return "trigger:\(button.rawValue):1,wait:\(holdMilliseconds),trigger:\(button.rawValue):0"
        }
        return "down:\(button.rawValue),wait:\(holdMilliseconds),up:\(button.rawValue)"
    }

    /// `4+cross-circle`, `0-cross`, `+home`: erst die Maske (leer = keine),
    /// dann gedrückte (`+`) und losgelassene (`-`) Tasten der Tastenseite.
    static func parseHID(_ text: String) -> ControllerHIDReport? {
        var report = ControllerHIDReport()
        var tokens: [(sign: Character, name: String)] = []
        var maskText = ""
        var current: (sign: Character, name: String)?
        for character in text {
            if character == "+" || character == "-" {
                if let current { tokens.append(current) }
                current = (character, "")
            } else if current != nil {
                current?.name.append(character)
            } else {
                maskText.append(character)
            }
        }
        if let current { tokens.append(current) }
        if !maskText.isEmpty {
            let value = maskText.hasPrefix("0x") ? UInt32(maskText.dropFirst(2), radix: 16) : UInt32(maskText)
            guard let value, value <= 0xF else { return nil }
            report.paddleMask = value
        }
        for token in tokens {
            if token.name == "home" {
                report.homeButton = token.sign == "+"
                continue
            }
            guard let button = ControllerButton(rawValue: token.name), !button.isPaddle, !button.isTrigger else {
                return nil
            }
            report.buttons.append(.init(button: button, pressed: token.sign == "+"))
        }
        guard report.paddleMask != nil || report.homeButton != nil || !report.buttons.isEmpty else { return nil }
        return report
    }

    static var buttonNames: String {
        ControllerButton.allCases.map(\.rawValue).joined(separator: ", ")
    }
}
