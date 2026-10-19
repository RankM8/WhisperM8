import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Ermittelt den virtuellen Tastencode für ein Zeichen aus dem AKTIVEN
/// Tastaturlayout (LR-DIK-025). Synthetische Cmd+V-/Cmd+C-Events mit festem
/// US-Code (`kVK_ANSI_V` = 9) lösen unter Dvorak/Workman ein anderes Kürzel
/// aus (Dvorak: Cmd+K statt Cmd+V), weil Apps Menükürzel über das Zeichen des
/// Layouts auflösen. Die Übersetzung ist als Closure injizierbar (Tests);
/// der Produktionswert fragt `UCKeyTranslate` über das aktive ASCII-fähige
/// Layout.
enum KeyCodeResolver {
    /// Übersetzt einen virtuellen Tastencode in das Zeichen, das er im
    /// Layout (ohne Shift) erzeugt; `nil` = Layout nicht lesbar.
    typealias Translator = (UInt16) -> String?

    /// Haupt-Tastenblock (ANSI/ISO inkl. Zusatztaste); höhere Codes sind
    /// Ziffernblock, Funktions- und Navigationstasten.
    private static let mainBlockKeyCodes: Range<UInt16> = 0..<51

    /// Tastencode für `character`; ohne Treffer (Layout nicht lesbar oder
    /// Zeichen fehlt, z. B. nicht-lateinisches Layout) der US-Code `fallback`.
    static func keyCode(
        for character: Character,
        fallback: Int,
        translate: Translator = systemTranslator()
    ) -> CGKeyCode {
        let wanted = String(character).lowercased()
        for code in mainBlockKeyCodes {
            if translate(code)?.lowercased() == wanted {
                return CGKeyCode(code)
            }
        }
        return CGKeyCode(fallback)
    }

    /// Übersetzer über das aktive ASCII-fähige Layout. Mit `commandModifier`
    /// gilt die Cmd-Ebene: Layouts wie „Dvorak – QWERTY ⌘" bilden dort auf
    /// QWERTY ab, und genau diese Ebene löst Menükürzel aus.
    static func systemTranslator(commandModifier: Bool = true) -> Translator {
        return { keyCode in
            guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
                  let rawData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
                return nil
            }
            let layoutData = Unmanaged<CFData>.fromOpaque(rawData).takeUnretainedValue() as Data
            return layoutData.withUnsafeBytes { buffer -> String? in
                guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                    return nil
                }
                var deadKeyState: UInt32 = 0
                var length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let modifierState: UInt32 = commandModifier ? UInt32(cmdKey >> 8) & 0xFF : 0
                let status = UCKeyTranslate(
                    layout,
                    keyCode,
                    UInt16(kUCKeyActionDown),
                    modifierState,
                    UInt32(LMGetKbdType()),
                    OptionBits(kUCKeyTranslateNoDeadKeysBit),
                    &deadKeyState,
                    chars.count,
                    &length,
                    &chars
                )
                guard status == noErr, length > 0 else { return nil }
                return String(utf16CodeUnits: chars, count: length)
            }
        }
    }

    /// Cmd+Taste als synthetisches Tastendruck-Paar (down, 20 ms, up).
    /// Gibt `false` zurück, wenn die Events nicht erzeugt werden konnten.
    static func postCommandKey(character: Character, fallback: Int) -> Bool {
        let code = keyCode(for: character, fallback: fallback)
        let source = CGEventSource(stateID: .hidSystemState)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else {
            return false
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        usleep(20_000)
        keyUp.post(tap: .cghidEventTap)
        return true
    }
}
