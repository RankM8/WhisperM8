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
        if let app, Self.isOwnProcess(app) {
            // WhisperM8 selbst: Eine AX-Anfrage an den eigenen Prozess müsste
            // der Main Thread beantworten, der gerade wartet. Das fror die
            // Oberfläche bis ins Zeitlimit ein. Darum direkt aus dem Textfeld.
            if let own = Self.ownTextSelection() { return own }
        } else {
            let element = Self.focusedElement(of: app)
            // Abgeleitete Elemente erben das Zeitlimit der App nicht (Standard ~6 s).
            if let element { AXUIElementSetMessagingTimeout(element, 0.5) }

            // Nur wenn das Element selbst die Markierung liefert, ist sein Urteil
            // über „beschreibbar“ verlässlich. Kommt der Text über Cmd+C (Electron
            // ohne volle Accessibility: Slack, Notion), meldet das Element oft
            // eine nicht setzbare Gruppe; dann wird eingefügt.
            if let element, let text = Self.selectedText(of: element), !Self.isBlank(text) {
                return CapturedSelection(text: text, writability: Self.writability(of: element))
            }
        }

        guard PermissionService.hasAccessibilityPermission, let app else { return nil }
        // Der Kurzbefehl (etwa ⇧⌘K) ist beim Auslösen noch gedrückt. Ein
        // gehaltenes ⇧ könnte aus dem Cmd+C ein ⇧⌘C machen (ab Werk der
        // Zwischenablage-Verlauf). Kurz warten, bis die Tasten los sind.
        await waitForModifierRelease()
        let text = await captureViaClipboard(bundleIdentifier: app.bundleIdentifier) { activator(app) }
        guard let text, !Self.isBlank(text) else { return nil }
        return CapturedSelection(text: text, writability: .unknown)
    }

    /// Wartet, bis keine Sondertaste mehr gedrückt ist, höchstens `timeout`.
    /// Gibt `true` zurück, wenn die Tasten rechtzeitig los waren.
    @MainActor
    @discardableResult
    func waitForModifierRelease(timeout: Duration = .milliseconds(500), step: Duration = .milliseconds(15)) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while modifierKeysHeld() {
            guard clock.now < deadline else {
                Logger.debug("quick_action_modifiers_still_held")
                return false
            }
            try? await Task.sleep(for: step)
        }
        return true
    }

    static func isOwnProcess(_ app: NSRunningApplication) -> Bool {
        app.processIdentifier == ProcessInfo.processInfo.processIdentifier
    }

    /// Markierung im eigenen Fenster, ohne Accessibility: nur Textfelder, die
    /// AppKit kennt (auch das Feld-Editor-`NSTextView` von SwiftUI-Feldern).
    @MainActor
    static func ownTextSelection() -> CapturedSelection? {
        guard let textView = NSApp.keyWindow?.firstResponder as? NSTextView else { return nil }
        let range = textView.selectedRange()
        guard range.length > 0 else { return nil }
        let text = (textView.string as NSString).substring(with: range)
        guard !isBlank(text) else { return nil }
        return CapturedSelection(text: text, writability: textView.isEditable ? .writable : .readOnly)
    }

    /// Aktuell markierter Text der App, `nil`, wenn er sich nicht lesen
    /// lässt. Fremde Apps werden abseits des Main Threads gefragt (kurzes
    /// Zeitlimit), WhisperM8 selbst direkt über sein Textfeld.
    @MainActor
    static func currentSelectedText(of app: NSRunningApplication) async -> String? {
        if isOwnProcess(app) {
            guard let textView = NSApp.keyWindow?.firstResponder as? NSTextView else { return nil }
            return (textView.string as NSString).substring(with: textView.selectedRange())
        }
        let pid = app.processIdentifier
        return await Task.detached(priority: .userInitiated) {
            selectedTextOffMain(pid: pid)
        }.value
    }

    /// Nur lesen, für einen Hintergrund-Thread gedacht (wie `probeSelection`).
    nonisolated static func selectedTextOffMain(pid: pid_t) -> String? {
        selectionReadoutOffMain(pid: pid, timeout: 0.25).text
    }

    /// Wie `selectedTextOffMain`, unterscheidet aber „die App antwortet
    /// nicht“ (Zeitlimit) von „kein Textfeld mit Markierung im Fokus“.
    nonisolated static func selectionReadoutOffMain(pid: pid_t, timeout: Float) -> SelectionReadout {
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, timeout)
        var focusedValue: CFTypeRef?
        let focusedStatus = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedValue)
        guard focusedStatus == .success else { return SelectionReadout(failure: focusedStatus) }
        guard let focusedValue, CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else { return .nothingSelectable }
        let element = unsafeBitCast(focusedValue, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, timeout)
        var textValue: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &textValue)
        guard status == .success else { return SelectionReadout(failure: status) }
        return .text((textValue as? String) ?? "")
    }

    /// Markierung der App für die Prüfung vor dem Einfügen. WhisperM8 selbst
    /// über sein Textfeld (ohne Accessibility), fremde Apps abseits des Main
    /// Threads mit `timeout`.
    @MainActor
    static func selectionReadout(of app: NSRunningApplication, timeout: Float) async -> SelectionReadout {
        if isOwnProcess(app) {
            guard let textView = NSApp.keyWindow?.firstResponder as? NSTextView else { return .nothingSelectable }
            return .text((textView.string as NSString).substring(with: textView.selectedRange()))
        }
        let pid = app.processIdentifier
        return await Task.detached(priority: .userInitiated) {
            selectionReadoutOffMain(pid: pid, timeout: timeout)
        }.value
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

/// Ergebnis einer Accessibility-Abfrage der Markierung.
enum SelectionReadout: Equatable {
    case text(String)
    /// Die App hat geantwortet: kein Fokus-Element oder eins ohne
    /// Markierung (etwa nach einem Klick auf eine Liste).
    case nothingSelectable
    /// Keine verwertbare Antwort (Zeitlimit, ausgelastete App, kein Recht).
    case noAnswer

    var text: String? {
        if case .text(let text) = self { return text }
        return nil
    }

    /// `cannotComplete` meldet AX beim Zeitlimit; `apiDisabled` und
    /// `failure` sagen ebenso nichts über das Feld.
    init(failure status: AXError) {
        switch status {
        case .cannotComplete, .apiDisabled, .failure, .notImplemented: self = .noAnswer
        default: self = .nothingSelectable
        }
    }
}

/// Vor dem Einfügen: Steht das Ziel noch so da wie beim Lesen? Pur, damit
/// die Regel ohne fremde App testbar ist.
enum QuickActionTargetCheck {
    /// Zeitlimit der Nachprüfung; bleibt die Antwort aus, einmal mit dem
    /// Zeitlimit der Erfassung (0,5 s) wiederholen.
    static let firstTimeout: Float = 0.25
    static let retryTimeout: Float = 0.5

    /// - `frontmostMatches`: Die App von damals ist noch vorn. Sonst nie einfügen.
    /// - Nur bei `writable` (Markierung kam per Accessibility) wird die
    ///   Markierung verglichen. Ein anderer Text oder kein markierbares Feld
    ///   heißt „geändert“. Antwortet die App auch beim zweiten Versuch
    ///   nicht, ist das unklar, nicht „geändert“: Die App ist noch vorn,
    ///   also zählt wie beim Cmd+C-Rückfall nur sie. Sonst kostete eine
    ///   ausgelastete App den Nutzer seine Zwischenablage (Ergebnis statt
    ///   Einfügen dort abgelegt), obwohl er nichts angefasst hat.
    static func isUnchanged(
        original: CapturedSelection?,
        frontmostMatches: Bool,
        read: (Float) async -> SelectionReadout
    ) async -> Bool {
        guard frontmostMatches else { return false }
        guard let original, original.writability == .writable else { return true }
        var readout = await read(firstTimeout)
        if readout == .noAnswer { readout = await read(retryTimeout) }
        switch readout {
        case .text(let current): return current == original.text
        case .nothingSelectable: return false
        case .noAnswer:
            Logger.paste.info("quick_action_target_check_unclear reason=no_answer")
            return true
        }
    }
}

/// Wann die alte Zwischenablage nach dem Einfügen zurückkommt. Zurücklegen
/// ist nur sicher, wenn die Ziel-App das Ergebnis schon gelesen hat; sonst
/// fügte eine spät lesende App den alten Inhalt ein.
enum QuickActionRestoreRule: Equatable {
    /// Das Feld gibt seine Markierung per Accessibility heraus: zurücklegen
    /// erst, wenn sie sich nach Cmd+V geändert hat (dann ist eingefügt).
    case afterConfirmation(original: String)
    /// Nicht prüfbar (Text kam über Cmd+C): zurücklegen nur, wenn das
    /// Ergebnis zusätzlich im Verlauf steht. Sonst bleibt es in der
    /// Zwischenablage, damit es nicht verloren geht.
    case ifResultSaved(Bool)
}

/// Was beim Einfügen passiert ist.
enum QuickActionPasteResult: Equatable {
    /// Eingefügt; die alte Zwischenablage ist zurück (oder gehört inzwischen
    /// jemand anderem).
    case pasted
    /// Cmd+V ist raus, aber das Einfügen ließ sich nicht bestätigen. Das
    /// Ergebnis bleibt in der Zwischenablage.
    case pastedResultKept
    /// Nicht eingefügt (kein Recht, Ziel-App nicht nach vorn).
    case notPasted
}

/// Ersetzt die Markierung per Cmd+V und legt danach die alte Zwischenablage
/// zurück, wenn das sicher ist (`QuickActionRestoreRule`). Cmd+V ist ein
/// normaler Bearbeitungsschritt der Ziel-App, deshalb macht ⌘Z ihn rückgängig.
@MainActor
struct QuickActionReplacer {
    var pasteService: PasteService
    var pasteboard: NSPasteboard = .general
    /// Zeit, die die Ziel-App bekommt, um die Zwischenablage nach Cmd+V zu
    /// lesen, bevor der alte Inhalt zurückkommt (Regel `ifResultSaved`).
    /// Electron-Apps lesen spät.
    var restoreDelay: Duration = .milliseconds(800)
    /// So lange wird bei `afterConfirmation` auf die geänderte Markierung gewartet.
    var confirmTimeout: Duration = .seconds(2)
    var confirmStep: Duration = .milliseconds(100)
    /// Aktuell markierter Text der App (`nil` = nicht lesbar).
    var currentSelection: @MainActor (NSRunningApplication?) async -> String? = { app in
        guard let app else { return nil }
        return await SelectedContextService.currentSelectedText(of: app)
    }

    func replaceSelection(
        with text: String,
        in app: NSRunningApplication?,
        restore rule: QuickActionRestoreRule
    ) async -> QuickActionPasteResult {
        // Snapshot wie beim Cmd+C-Rückfall: begrenzt, off-main, mit Zeitlimit.
        // Zu groß oder zu langsam: dann bleibt das Ergebnis in der Zwischenablage.
        let snapshot = await PasteboardSnapshot.capture(from: pasteboard, maxBytes: 8 * 1024 * 1024, timeout: 1.0)

        let result = await pasteService.pastePayloadToActiveApp(
            PastePayload(text: text, attachments: [], restoreTextToClipboardAfterPaste: false),
            previousApp: app,
            onMissingPermission: {},
            onMissingTarget: {}
        )
        guard result.textPasted else { return .notPasted }

        let ourChangeCount = pasteboard.changeCount
        let mayRestore: Bool
        switch rule {
        case .afterConfirmation(let original):
            mayRestore = await waitForChangedSelection(in: app, original: original)
        case .ifResultSaved(let saved):
            try? await Task.sleep(for: restoreDelay)
            mayRestore = saved
        }
        guard mayRestore else {
            Logger.paste.info("quick_action_restore_skipped reason=unconfirmed")
            return .pastedResultKept
        }
        // Hat inzwischen jemand anderes kopiert, gehört die Zwischenablage ihm.
        // Ein Passwort nie zurückschreiben (hielte das Auto-Leeren auf).
        guard let snapshot, !snapshot.isConfidential, pasteboard.changeCount == ourChangeCount else {
            return .pasted
        }
        // Geklammert wie beim Cmd+C-Rückfall: das Zurückschreiben läuft
        // off-main, der Verlauf darf den Stand vor dem `claim` nicht greifen.
        ClipboardInternalWrites.begin()
        defer { ClipboardInternalWrites.end() }
        await snapshot.restoreOffMain(to: pasteboard)
        ClipboardInternalWrites.claim(pasteboard)
        return .pasted
    }

    /// `true`, sobald die Markierung nicht mehr der ursprüngliche Text ist:
    /// Die App hat Cmd+V verarbeitet und die Zwischenablage gelesen.
    private func waitForChangedSelection(in app: NSRunningApplication?, original: String) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: confirmTimeout)
        repeat {
            try? await Task.sleep(for: confirmStep)
            if let current = await currentSelection(app), current != original { return true }
        } while clock.now < deadline
        return false
    }
}

/// Was das Zwischenablage-Fenster beim Öffnen über die Markierung der App
/// davor weiß. Danach richtet sich die Kopfzeile „Markierung korrigieren“.
enum SelectionProbe: Equatable {
    /// Markierung gelesen; die Kopfzeile zeigt ihren Anfang.
    case selected(preview: String)
    /// Die App meldet ausdrücklich: nichts markiert. Keine Kopfzeile.
    case none
    /// Die App sagt nichts Verlässliches (Electron ohne volle
    /// Accessibility, kein Fokus-Element). Die Kopfzeile erscheint ohne
    /// Vorschau; ein Klick liest dann per Cmd+C-Rückfall.
    case unknown

    static let previewLimit = 300

    /// `unknown` verspricht „ein Klick kopiert die Markierung“. Geht das
    /// nicht (keine Bedienungshilfen, Editor ohne Cmd+C-Rückfall), lieber
    /// keine Kopfzeile als eine, die danach „Erst Text markieren“ meldet.
    func respectingCopyFallback(_ canCopy: Bool) -> SelectionProbe {
        self == .unknown && !canCopy ? .none : self
    }

    /// Rollen, in denen Text stehen kann, auch wenn die App die Markierung
    /// nicht herausgibt (Electron, Web-Inhalte). Listen, Tabellen und
    /// Dateiansichten (Finder) gehören nicht dazu.
    static let textLikeRoles: Set<String> = [
        "AXTextArea", "AXTextField", "AXComboBox", "AXWebArea", "AXGroup", "AXScrollArea", "AXStaticText",
    ]

    /// Pur, damit die Regel ohne fremde App testbar ist. `role` ist die Rolle
    /// des Fokus-Elements, falls bekannt.
    static func resolve(hasFocusedElement: Bool, selectedText: String?, role: String? = nil) -> SelectionProbe {
        guard hasFocusedElement else { return .unknown }
        guard let selectedText else {
            if let role, !textLikeRoles.contains(role) { return .none }
            return .unknown
        }
        let trimmed = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .none }
        let oneLine = trimmed.split(whereSeparator: \.isNewline).joined(separator: " ")
        return .selected(preview: String(oneLine.prefix(previewLimit)))
    }
}

extension SelectedContextService {
    /// Nur lesen über Accessibility, nie Cmd+C: das Fenster ist offen, die
    /// Zwischenablage bleibt unberührt. Für einen Hintergrund-Thread gedacht
    /// (auch WhisperM8 selbst kann die App davor sein, deren AX-Anfragen
    /// beantwortet der Main Thread); das kurze Zeitlimit hält eine hängende
    /// App vom Fenster fern.
    nonisolated static func probeSelection(pid: pid_t) -> SelectionProbe {
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.25)
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedValue) == .success,
              let focusedValue, CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else {
            return .resolve(hasFocusedElement: false, selectedText: nil)
        }
        let element = unsafeBitCast(focusedValue, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, 0.25)
        var textValue: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &textValue)
        var roleValue: CFTypeRef?
        let role = status == .success ? nil
            : (AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue) == .success ? roleValue as? String : nil)
        return .resolve(hasFocusedElement: true, selectedText: status == .success ? (textValue as? String) ?? "" : nil, role: role)
    }
}
