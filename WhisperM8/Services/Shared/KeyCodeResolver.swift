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
    /// QWERTY ab, und genau diese Ebene löst Menükürzel aus. Das Layout kommt
    /// aus `KeyboardLayoutCache` (einmal je Übersetzer, nicht je Tastencode);
    /// ohne lesbares Layout liefert der Übersetzer `nil` → US-Fallback.
    static func systemTranslator(
        commandModifier: Bool = true,
        cache: KeyboardLayoutCache = .shared
    ) -> Translator {
        let snapshot = cache.current()
        return { keyCode in
            guard let snapshot else { return nil }
            return snapshot.layout.withUnsafeBytes { buffer -> String? in
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
                    snapshot.keyboardType,
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

/// Layout-Daten des aktiven Tastaturlayouts. HIToolbox (TIS) verlangt den Main
/// Thread: unter macOS 26 bricht `TISGetInputSourceProperty` abseits davon per
/// `dispatch_assert_queue` ab — die App stürzte beim Diktatstart ab, weil der
/// Kontext-Capture Cmd+C aus einem Task postet. Deshalb liest nur der Main
/// Thread das Layout (beim Start und bei jedem Layoutwechsel); andere Threads
/// bekommen den zuletzt gelesenen Stand. `UCKeyTranslate` auf den kopierten
/// Daten ist threadsicher.
final class KeyboardLayoutCache: @unchecked Sendable {
    struct Snapshot: Equatable {
        let layout: Data
        let keyboardType: UInt32
    }

    static let shared = KeyboardLayoutCache()

    private let reader: () -> Snapshot?
    private let lock = NSLock()
    private var snapshot: Snapshot?
    private var observer: NSObjectProtocol?

    init(reader: @escaping () -> Snapshot? = KeyboardLayoutCache.readSystemLayout) {
        self.reader = reader
    }

    /// Auf dem Main Thread frisch gelesen (und gemerkt), sonst der gemerkte Stand.
    func current() -> Snapshot? {
        guard Thread.isMainThread else { return lock.withLock { snapshot } }
        return refresh()
    }

    /// Nur auf dem Main Thread aufrufen.
    @discardableResult
    func refresh() -> Snapshot? {
        precondition(Thread.isMainThread, "TIS nur auf dem Main Thread lesen")
        let fresh = reader()
        lock.withLock { snapshot = fresh }
        return fresh
    }

    /// Liest das Layout sofort und bei jedem Wechsel der Eingabequelle neu.
    /// Beim App-Start auf dem Main Thread aufrufen.
    func startObserving() {
        refresh()
        guard observer == nil else { return }
        observer = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refresh()
        }
    }

    static func readSystemLayout() -> Snapshot? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let rawData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let layout = Unmanaged<CFData>.fromOpaque(rawData).takeUnretainedValue() as Data
        return Snapshot(layout: layout, keyboardType: UInt32(LMGetKbdType()))
    }
}
