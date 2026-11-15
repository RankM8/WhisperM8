import Carbon.HIToolbox
import Foundation

/// Buchstabe einer Taste im aktuellen Tastaturlayout (WM8-104): Die Insel
/// erkennt die Schnellbefehle über den keyCode, zeigt aber den Buchstaben,
/// der auf dieser Taste steht (AZERTY: Q statt A). Auf QWERTZ und QWERTY
/// stimmen sie überein; dann bleibt die Tabelle leer.
///
/// Nur im Ereignis-Pfad auf dem Main Thread aufrufen: Die Text-Input-Sources
/// gehören dem Main Thread (Absturz 20.10.2026 im Diktat, TIS abseits davon).
@MainActor
enum KeyboardLayoutLetters {
    static func current() -> [KeyboardIslandCommand: String] {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return [:] }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        var result: [KeyboardIslandCommand: String] = [:]
        data.withUnsafeBytes { raw in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return }
            for command in KeyboardIslandCommand.allCases {
                guard let letter = translate(command.keyCode, layout: layout), letter != command.letter else { continue }
                result[command] = letter
            }
        }
        return result
    }

    private static func translate(_ keyCode: UInt16, layout: UnsafePointer<UCKeyboardLayout>) -> String? {
        var deadKeyState: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = UCKeyTranslate(
            layout, keyCode, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
            OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, chars.count, &length, &chars)
        guard status == noErr, length > 0 else { return nil }
        let text = String(utf16CodeUnits: chars, count: length).uppercased()
        // Nur ein sichtbares Zeichen; sonst bleibt der gewohnte Buchstabe.
        guard text.count == 1, text.rangeOfCharacter(from: .letters) != nil else { return nil }
        return text
    }
}
