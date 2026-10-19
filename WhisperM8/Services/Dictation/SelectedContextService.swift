import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Editoren, in denen Cmd+C OHNE Auswahl die ganze aktuelle Zeile kopiert (VS Code,
/// JetBrains, Sublime, Zed …). Dort würde der Clipboard-Fallback ungefragt eine Zeile in
/// den Kontext ziehen (LR-DIK-027) — er wird für diese Apps übersprungen.
enum ClipboardCopyFallbackPolicy {
    private static let blockedBundleIDs: Set<String> = [
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.vscodium",
        "com.todesktop.230313mzl4w4u92", // Cursor
        "com.exafunction.windsurf",
        "com.sublimetext.4", "com.sublimetext.3", "dev.zed.Zed", "dev.zed.Zed-Preview",
    ]
    private static let blockedPrefixes = ["com.jetbrains.", "com.google.android.studio"]

    static func allowsFallback(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return true }
        if blockedBundleIDs.contains(bundleIdentifier) { return false }
        return !blockedPrefixes.contains { bundleIdentifier.hasPrefix($0) }
    }
}

/// Meldet dem Coordinator, auf welchen `changeCount` er den Zwischenablage-Monitor setzen
/// darf, ohne eine echte Nutzerkopie zu verschlucken (LR-DIK-016). `nil` = nicht anfassen.
final class ClipboardCaptureOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var _resyncChangeCount: Int?
    var resyncChangeCount: Int? {
        get { lock.lock(); defer { lock.unlock() }; return _resyncChangeCount }
        set { lock.lock(); _resyncChangeCount = newValue; lock.unlock() }
    }
}

struct SelectedContextService {
    private let copyDelayNanoseconds: UInt64 = 160_000_000

    /// Test-Seams (Closure-DI): Zwischenablage, Cmd+C-Auslöser und Ziel-App-Aktivierung.
    let pasteboard: NSPasteboard
    let copyPoster: () -> Void
    let activator: (NSRunningApplication) -> Void
    /// Obergrenze für den Zwischenablage-Snapshot; größere Inhalte (Bilder, Tabellen)
    /// werden nie angefasst – der Fallback entfällt dann.
    let maxSnapshotBytes: Int
    let snapshotTimeout: TimeInterval
    let outcome: ClipboardCaptureOutcome

    init(
        pasteboard: NSPasteboard = .general,
        copyPoster: @escaping () -> Void = {
            // Tastencode aus dem aktiven Layout (LR-DIK-025), nicht fest US-„C".
            if !KeyCodeResolver.postCommandKey(character: "c", fallback: kVK_ANSI_C) {
                Logger.paste.error("Failed to create selected-context copy events")
            }
        },
        activator: @escaping (NSRunningApplication) -> Void = { $0.activate() },
        maxSnapshotBytes: Int = 8 * 1024 * 1024,
        snapshotTimeout: TimeInterval = 1.0,
        outcome: ClipboardCaptureOutcome = ClipboardCaptureOutcome()
    ) {
        self.pasteboard = pasteboard
        self.copyPoster = copyPoster
        self.activator = activator
        self.maxSnapshotBytes = maxSnapshotBytes
        self.snapshotTimeout = snapshotTimeout
        self.outcome = outcome
    }

    @MainActor
    func capture(from app: NSRunningApplication?) async -> SelectedContext {
        guard AppPreferences.shared.isSelectedContextCaptureEnabled else {
            return .empty
        }

        let sourceApp = app ?? NSWorkspace.shared.frontmostApplication
        outcome.resyncChangeCount = nil

        if let accessibilityText = captureViaAccessibility(from: sourceApp),
           !accessibilityText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return SelectedContext(
                text: TextNormalizer.normalizeTranscriptionText(accessibilityText),
                sourceAppName: sourceApp?.localizedName,
                sourceBundleIdentifier: sourceApp?.bundleIdentifier
            )
        }

        guard PermissionService.hasAccessibilityPermission else {
            Logger.permission.warning("Selected context capture needs Accessibility permission")
            return .empty
        }

        let activateSource: () -> Void = { if let sourceApp { activator(sourceApp) } }
        if sourceApp != nil,
           let clipboardText = await captureViaClipboard(bundleIdentifier: sourceApp?.bundleIdentifier, activate: activateSource),
           !clipboardText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return SelectedContext(
                text: TextNormalizer.normalizeTranscriptionText(clipboardText),
                sourceAppName: sourceApp?.localizedName,
                sourceBundleIdentifier: sourceApp?.bundleIdentifier
            )
        }

        return .empty
    }

    private func captureViaAccessibility(from app: NSRunningApplication?) -> String? {
        guard let pid = app?.processIdentifier else { return nil }

        let appElement = AXUIElementCreateApplication(pid)
        // Haengt die Ziel-App, blockiert das synchrone AX-IPC sonst bis zum
        // Default-Timeout (mehrere Sekunden). Seit P5 laeuft das Capture
        // parallel zum sichtbaren Overlay — ein eingefrorener MainActor waere
        // sofort sichtbar. 0,5 s sind grosszuegig fuer gesunde Apps.
        AXUIElementSetMessagingTimeout(appElement, 0.5)
        var focusedValue: CFTypeRef?
        let focusedStatus = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        )

        guard focusedStatus == .success,
              let focusedElement = focusedValue,
              CFGetTypeID(focusedElement) == AXUIElementGetTypeID() else {
            return nil
        }

        let focusedAXElement = unsafeBitCast(focusedElement, to: AXUIElement.self)
        var selectedTextValue: CFTypeRef?
        let selectedTextStatus = AXUIElementCopyAttributeValue(
            focusedAXElement,
            kAXSelectedTextAttribute as CFString,
            &selectedTextValue
        )

        guard selectedTextStatus == .success else { return nil }
        return selectedTextValue as? String
    }

    /// Clipboard-Fallback (Cmd+C). Eigentümerschaft statt Blindflug (LR-DIK-016/027):
    /// - Snapshot nur bis `maxSnapshotBytes`, off-main und mit Zeitlimit; sonst Abbruch ohne Eingriff.
    /// - Ändert sich die Zwischenablage zwischen Snapshot und Cmd+C oder öfter als durch die
    ///   Ziel-App erwartet (fremde Nutzerkopie), wird nichts übernommen und nichts zurückgeschrieben.
    /// - Editoren mit „Zeile kopieren ohne Auswahl" sind ausgenommen.
    /// `@MainActor`: Aktivieren der Ziel-App und das Cmd+C (Tastaturlayout über
    /// HIToolbox) sind Main-Thread-pflichtig — ohne die Isolation lief der Rest
    /// nach dem ersten `await` auf dem globalen Executor, und HIToolbox brach die
    /// App beim Diktatstart ab. Der Snapshot selbst läuft weiter off-main.
    @MainActor
    func captureViaClipboard(bundleIdentifier: String?, activate: () -> Void) async -> String? {
        guard ClipboardCopyFallbackPolicy.allowsFallback(bundleIdentifier: bundleIdentifier) else {
            Logger.debug("clipboard_fallback_skipped reason=copy_line_editor")
            return nil
        }

        // Liegt schon ein Passwort in der Zwischenablage, ersetzte die Cmd+C-Kopie
        // es — und zurückgeschrieben wird ein vertraulicher Inhalt bewusst nicht.
        // Dann lieber ganz ohne Fallback (Review W2b zu LR-DIK-023).
        if PasteboardPrivacy.isConfidential(pasteboard.types?.map(\.rawValue) ?? []) {
            Logger.info("clipboard_fallback_skipped reason=confidential")
            return nil
        }

        let baseline = pasteboard.changeCount
        guard let snapshot = await PasteboardSnapshot.capture(
            from: pasteboard, maxBytes: maxSnapshotBytes, timeout: snapshotTimeout
        ) else {
            Logger.info("clipboard_fallback_skipped reason=snapshot_too_large_or_slow")
            return nil
        }
        guard pasteboard.changeCount == baseline else {
            Logger.info("clipboard_fallback_skipped reason=pasteboard_changed_before_copy")
            return nil
        }

        activate()
        try? await Task.sleep(for: .milliseconds(60))
        copyPoster()
        try? await Task.sleep(nanoseconds: copyDelayNanoseconds)

        // Hat sich nichts geändert, gab es keine Auswahl. Manche Apps (Office,
        // Electron) erhöhen den Zähler beim Kopieren um mehr als 1 — auch das
        // ist ihre Kopie, die Nutzerkopie im Snapshot muss zurück (Review W2b:
        // vorher ging sie dabei verloren). Eine eigene Nutzerkopie in den
        // ~200 ms ist praktisch ausgeschlossen; direkt vor dem Zurückschreiben
        // wird trotzdem noch einmal geprüft.
        let afterCopy = pasteboard.changeCount
        guard afterCopy != baseline else { return nil }
        if afterCopy > baseline + 1 {
            Logger.info("clipboard_fallback_multi_write changes=\(afterCopy - baseline)")
        }

        let selectedText: String?
        if !PasteboardPrivacy.isConfidential(pasteboard.types?.map(\.rawValue) ?? []) {
            selectedText = pasteboard.string(forType: .string)
        } else {
            selectedText = nil
        }

        // Ein Passwort im Snapshot nicht zurückschreiben: der neue changeCount
        // hielte das Auto-Leeren des Passwort-Managers auf (LR-DIK-023).
        // Nur zurückschreiben, wenn seit der Kopie niemand mehr kopiert hat.
        if !snapshot.isConfidential, pasteboard.changeCount == afterCopy {
            await snapshot.restoreOffMain(to: pasteboard)
        }
        outcome.resyncChangeCount = pasteboard.changeCount
        return selectedText
    }
}

struct PasteboardSnapshot: @unchecked Sendable {
    private struct Item {
        let values: [(NSPasteboard.PasteboardType, Data)]
    }

    private let items: [Item]

    /// Trägt der gesicherte Inhalt eine Passwort-Manager-Markierung?
    var isConfidential: Bool {
        PasteboardPrivacy.isConfidential(items.flatMap { $0.values.map(\.0.rawValue) })
    }

    static func capture(from pasteboard: NSPasteboard) -> PasteboardSnapshot {
        captureLimited(from: pasteboard, maxBytes: .max) ?? PasteboardSnapshot(items: [])
    }

    /// Snapshot mit Größenlimit: `nil`, sobald die Summe der Daten `maxBytes` überschreitet –
    /// dann wird nichts gesichert und nichts überschrieben.
    static func captureLimited(from pasteboard: NSPasteboard, maxBytes: Int) -> PasteboardSnapshot? {
        var total = 0
        var items: [Item] = []
        for pasteboardItem in pasteboard.pasteboardItems ?? [] {
            var values: [(NSPasteboard.PasteboardType, Data)] = []
            for type in pasteboardItem.types {
                guard let data = pasteboardItem.data(forType: type) else { continue }
                total += data.count
                if total > maxBytes { return nil }
                values.append((type, data))
            }
            items.append(Item(values: values))
        }
        return PasteboardSnapshot(items: items)
    }

    /// Snapshot off-main mit Größen- und Zeitlimit: lazy gelieferte Daten (große Bilder, Excel-
    /// Auswahlen) zwingen die Quell-App sonst, auf dem Main Thread alle Varianten zu liefern.
    /// Bei Überschreitung `nil`; ein hängender Hintergrund-Lauf wird nicht abgewartet.
    static func capture(from pasteboard: NSPasteboard, maxBytes: Int, timeout: TimeInterval) async -> PasteboardSnapshot? {
        final class Once: @unchecked Sendable {
            private let lock = NSLock()
            private var continuation: CheckedContinuation<PasteboardSnapshot?, Never>?
            init(_ continuation: CheckedContinuation<PasteboardSnapshot?, Never>) { self.continuation = continuation }
            func resume(_ value: PasteboardSnapshot?) {
                lock.lock()
                let pending = continuation
                continuation = nil
                lock.unlock()
                pending?.resume(returning: value)
            }
        }
        return await withCheckedContinuation { continuation in
            let once = Once(continuation)
            DispatchQueue.global(qos: .userInitiated).async {
                once.resume(captureLimited(from: pasteboard, maxBytes: maxBytes))
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) {
                once.resume(nil)
            }
        }
    }

    func restoreOffMain(to pasteboard: NSPasteboard) async {
        let snapshot = self
        await Task.detached(priority: .userInitiated) { snapshot.restore(to: pasteboard) }.value
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let restoredItems = items.map { item -> NSPasteboardItem in
            let pasteboardItem = NSPasteboardItem()
            for (type, data) in item.values {
                pasteboardItem.setData(data, forType: type)
            }
            return pasteboardItem
        }
        pasteboard.writeObjects(restoredItems)
    }
}

/// Markierungen, mit denen Passwort-Manager (1Password, Bitwarden, Schlüsselbund)
/// und andere Apps vertrauliche bzw. flüchtige Inhalte kennzeichnen
/// (nspasteboard.org). Solche Inhalte gehören nie in Diktat-Kontext, Prompt
/// oder Report-Archiv (LR-DIK-023).
enum PasteboardPrivacy {
    static let confidentialTypes: Set<String> = [
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.TransientType",
        "org.nspasteboard.AutoGeneratedType",
    ]

    static func isConfidential(_ types: [String]) -> Bool {
        types.contains { confidentialTypes.contains($0) }
    }
}
