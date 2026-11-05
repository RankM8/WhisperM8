import AppKit
import ApplicationServices

/// Lässt sich die Markierung an Ort und Stelle ersetzen?
enum SelectionWritability: Equatable {
    /// Das Feld nimmt Text an (Eingabefeld, Editor).
    case writable
    /// Das Feld meldet sich als nicht beschreibbar (Webseite, PDF, Label).
    case readOnly
    /// Die App sagt nichts Verlässliches dazu (kein Element, oder der Text kam
    /// über den Cmd+C-Rückfall). Dann wird
    /// eingefügt, und das Ergebnis steht zusätzlich im Zwischenablage-Verlauf.
    case unknown

    /// Pur, damit die Regel ohne fremde App testbar ist.
    static func resolve(hasFocusedElement: Bool, selectedTextSettable: Bool, valueSettable: Bool) -> SelectionWritability {
        guard hasFocusedElement else { return .unknown }
        return selectedTextSettable || valueSettable ? .writable : .readOnly
    }
}

/// Markierter Text einer fremden App für die Schnellaktion.
struct CapturedSelection: Equatable {
    var text: String
    var writability: SelectionWritability
}

extension SelectedContextService {
    /// Liest die Markierung für die Schnellaktion. Anders als `capture(from:)`
    /// unabhängig vom Schalter „markierten Text als Kontext“: Hier hat der
    /// Nutzer die Markierung ausdrücklich per Kurzbefehl übergeben. Der Text
    /// bleibt unverändert (keine Normalisierung), damit Absätze und
    /// Leerzeichen am Rand beim Ersetzen erhalten bleiben.
    @MainActor
    func captureForQuickAction(from app: NSRunningApplication?) async -> CapturedSelection? {
        let element = Self.focusedElement(of: app)
        // Abgeleitete Elemente erben das Zeitlimit der App nicht (Standard ~6 s).
        if let element { AXUIElementSetMessagingTimeout(element, 0.5) }

        // Nur wenn das Element selbst die Markierung liefert, ist sein Urteil
        // über „beschreibbar“ verlässlich. Kommt der Text über Cmd+C (Electron
        // ohne volle Accessibility: Slack, VS Code, Notion), meldet das
        // Element oft eine nicht setzbare Gruppe; dann wird eingefügt.
        if let element, let text = Self.selectedText(of: element), !Self.isBlank(text) {
            return CapturedSelection(text: text, writability: Self.writability(of: element))
        }

        guard PermissionService.hasAccessibilityPermission, let app else { return nil }
        let text = await captureViaClipboard(bundleIdentifier: app.bundleIdentifier) { activator(app) }
        guard let text, !Self.isBlank(text) else { return nil }
        return CapturedSelection(text: text, writability: .unknown)
    }

    static func writability(of element: AXUIElement) -> SelectionWritability {
        SelectionWritability.resolve(
            hasFocusedElement: true,
            selectedTextSettable: isSettable(kAXSelectedTextAttribute, of: element),
            valueSettable: isSettable(kAXValueAttribute, of: element)
        )
    }

    private static func isSettable(_ attribute: String, of element: AXUIElement) -> Bool {
        var settable: DarwinBoolean = false
        let status = AXUIElementIsAttributeSettable(element, attribute as CFString, &settable)
        return status == .success && settable.boolValue
    }

    static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Ersetzt die Markierung per Cmd+V und legt danach die alte Zwischenablage
/// zurück. Cmd+V ist ein normaler Bearbeitungsschritt der Ziel-App, deshalb
/// macht ⌘Z ihn rückgängig.
@MainActor
struct QuickActionReplacer {
    var pasteService: PasteService
    var pasteboard: NSPasteboard = .general
    /// Zeit, die die Ziel-App bekommt, um die Zwischenablage nach Cmd+V zu
    /// lesen, bevor der alte Inhalt zurückkommt. Electron-Apps lesen spät.
    var restoreDelay: Duration = .milliseconds(800)

    /// `true`, wenn Cmd+V abgesetzt wurde. Bei `false` liegt nichts oder das
    /// Ergebnis in der Zwischenablage; der Aufrufer legt es sicher dort ab.
    func replaceSelection(with text: String, in app: NSRunningApplication?) async -> Bool {
        // Snapshot wie beim Cmd+C-Rückfall: begrenzt, off-main, mit Zeitlimit.
        // Zu groß oder zu langsam: dann bleibt das Ergebnis in der Zwischenablage.
        let snapshot = await PasteboardSnapshot.capture(from: pasteboard, maxBytes: 8 * 1024 * 1024, timeout: 1.0)

        let result = await pasteService.pastePayloadToActiveApp(
            PastePayload(text: text, attachments: [], restoreTextToClipboardAfterPaste: false),
            previousApp: app,
            onMissingPermission: {},
            onMissingTarget: {}
        )
        guard result.textPasted else { return false }

        let ourChangeCount = pasteboard.changeCount
        try? await Task.sleep(for: restoreDelay)
        // Hat inzwischen jemand anderes kopiert, gehört die Zwischenablage ihm.
        // Ein Passwort nie zurückschreiben (hielte das Auto-Leeren auf).
        guard let snapshot, !snapshot.isConfidential, pasteboard.changeCount == ourChangeCount else {
            return true
        }
        // Geklammert wie beim Cmd+C-Rückfall: das Zurückschreiben läuft
        // off-main, der Verlauf darf den Stand vor dem `claim` nicht greifen.
        ClipboardInternalWrites.begin()
        defer { ClipboardInternalWrites.end() }
        await snapshot.restoreOffMain(to: pasteboard)
        ClipboardInternalWrites.claim(pasteboard)
        return true
    }
}
