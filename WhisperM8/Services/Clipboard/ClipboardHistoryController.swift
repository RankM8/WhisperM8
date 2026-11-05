import AppKit
import KeyboardShortcuts
import SwiftUI

// MARK: - Steuerung des Zwischenablage-Verlaufs

/// Verbindet Monitor, Store, Hotkey und Fenster. Läuft nur, solange der
/// Schalter `clipboardHistoryEnabled` an ist; sonst hört der Monitor nicht
/// zu und der Hotkey ist freigegeben (er soll Maccy nicht im Weg stehen).
@MainActor
final class ClipboardHistoryController {
    static let shared = ClipboardHistoryController()

    /// Anbindung an die Schnellaktion „Korrigieren“ (gesetzt von der App;
    /// ohne sie zeigt das Fenster weder Kopfzeile noch Knöpfe).
    struct QuickActionHooks {
        var isAvailable: @MainActor () -> Bool
        var run: @MainActor (_ modeID: String, _ input: QuickActionInput) async -> Void
        var shortcutLabel: @MainActor () -> String?
    }

    var quickActions: QuickActionHooks?
    /// Zählt Öffnungen, damit eine späte Markierungs-Prüfung kein neues Fenster trifft.
    private var presentation = 0
    /// Zeit, bis die App davor nach dem Schließen wieder Tastatur annimmt.
    private let refocusDelay: Duration = .milliseconds(150)

    nonisolated let store: ClipboardHistoryStore
    private let monitor: ClipboardMonitor
    private let pasteService = PasteService()
    private let model = ClipboardHistoryViewModel()
    private var panel: ClipboardPanel?
    private var previousApp: NSRunningApplication?
    /// Letzter Stand des Stores auf dem Main Thread; Fenster, Einstellungen und
    /// Control-Socket lesen hier, ohne auf die Store-Queue zu warten.
    private(set) var entries: [ClipboardEntry] = []
    private var started = false
    private var observing = false
    private var appliedEnabled: Bool?
    private var defaultsObserver: NSObjectProtocol?

    init(store: ClipboardHistoryStore = ClipboardHistoryStore()) {
        self.store = store
        self.monitor = ClipboardMonitor(store: store)
        model.actions = ClipboardHistoryViewModel.Actions(
            paste: { [weak self] entry, plain in self?.paste(entry, plain: plain) },
            pasteOriginal: { [weak self] entry in self?.pasteOriginal(entry) },
            togglePin: { [weak self] entry in self?.togglePin(entry) },
            delete: { [weak self] entry in self?.delete(entry) },
            clearUnpinned: { [weak self] in self?.store.clear(keepPinned: true) },
            openSettings: { [weak self] in self?.openSettings() },
            close: { [weak self] in self?.hidePanel() },
            correctSelection: { [weak self] in self?.correctSelection() },
            correctAndPaste: { [weak self] entry in self?.correctAndPaste(entry) }
        )
    }

    // MARK: Lebenszyklus

    func start() {
        guard !started else { return }
        started = true
        KeyboardShortcuts.onKeyDown(for: .clipboardHistory) { [weak self] in
            Task { @MainActor in self?.togglePanel() }
        }
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applySettings() }
        }
        applySettings()
    }

    /// Lädt den Verlauf (auf der Store-Queue) und hält danach den Stand
    /// aktuell. Erst beim Einschalten oder wenn die Einstellungen die Anzahl
    /// brauchen: bei abgeschaltetem Verlauf liest die App beim Start nichts.
    func ensureLoaded() {
        guard !observing else { return }
        observing = true
        store.observe { [weak self] state in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.entries = state.entries
                    self?.model.setEntries(state.entries, search: state.search)
                }
            }
        }
    }

    /// Fertiges Diktat in den Verlauf. Der Monitor übergeht den Schreibvorgang
    /// des Diktats (er ist beansprucht, wie Anhänge und das Zurücklegen nach
    /// dem Einfügen); deshalb kommt das Ergebnis genau einmal über diesen Weg.
    func recordDictation(text: String, original: String?, modeName: String, targetApp: NSRunningApplication?) {
        let settings = ClipboardSettings.readLive()
        guard let capture = ClipboardHistoryCore.dictationCapture(
            text: text, original: original, modeName: modeName,
            targetBundleID: targetApp?.bundleIdentifier, targetName: targetApp?.localizedName,
            settings: settings
        ) else { return }
        ensureLoaded()
        store.add(capture, maxItems: settings.maxItems)
    }

    /// Beim Beenden: optional leeren (Angepinnte bleiben), Index festschreiben.
    func shutdown() {
        guard started, observing else { return }
        if ClipboardSettings.readLive().clearOnQuit { store.clear(keepPinned: true) }
        store.flush()
    }

    /// Schalter ausgewertet. Läuft bei jeder Defaults-Änderung der App, tut
    /// aber nur etwas, wenn sich der Hauptschalter wirklich geändert hat.
    func applySettings() {
        let enabled = ClipboardSettings.readLive().enabled
        guard enabled != appliedEnabled else { return }
        appliedEnabled = enabled
        if enabled { ensureLoaded() }
        Self.apply(enabled: enabled, monitor: monitor)
        if !enabled, panel != nil { hidePanel() }
    }

    /// Monitor und Hotkey folgen dem Schalter: aus heißt auch, dass ⇧⌘C
    /// wieder frei ist (für Maccy oder andere Apps).
    static func apply(enabled: Bool, monitor: ClipboardMonitor) {
        if enabled {
            monitor.start()
            KeyboardShortcuts.enable(.clipboardHistory)
        } else {
            monitor.stop()
            KeyboardShortcuts.disable(.clipboardHistory)
        }
    }

    // MARK: Fenster

    func togglePanel() {
        if panel?.isVisible == true { hidePanel() } else { showPanel() }
    }

    func showPanel() {
        let settings = ClipboardSettings.readLive()
        guard settings.enabled else { return }
        // Ziel des Einfügens ist die App davor, auch WhisperM8 selbst (Chat-Prompt).
        previousApp = NSWorkspace.shared.frontmostApplication

        model.reset()
        model.isPresented = true
        prepareQuickActions()
        let hosting = NSHostingView(rootView: ClipboardHistoryView(model: model))
        let panel = ClipboardPanel(contentView: hosting)
        panel.onCommand = { [weak self] command in
            self?.model.handle(command)
            return true
        }
        panel.isImageZoomed = { [weak self] in self?.model.isZoomed ?? false }
        panel.onResignKey = { [weak self] in
            // Klick daneben: schließen. Beim Einfügen schließt `paste` selbst.
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.hidePanelIfNotKey() } }
        }
        panel.setFrameOrigin(ClipboardPanelPlacement.origin(
            size: panel.frame.size,
            position: settings.windowPosition,
            mouse: NSEvent.mouseLocation,
            screens: NSScreen.screens.map(\.visibleFrame)
        ))
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
        panel.focusSearchField()
    }

    var isPanelVisible: Bool { panel?.isVisible == true }

    /// Knöpfe freischalten und die Markierung der App davor prüfen, abseits
    /// des Main Threads (nur Accessibility, nie Cmd+C).
    private func prepareQuickActions() {
        presentation += 1
        let available = quickActions?.isAvailable() ?? false
        model.quickActionsAvailable = available
        model.correctShortcutLabel = available ? quickActions?.shortcutLabel() : nil
        model.selectionAppName = previousApp?.localizedName
        guard available, let app = previousApp else { return }
        let canCopy = PermissionService.hasAccessibilityPermission
            && ClipboardCopyFallbackPolicy.allowsFallback(bundleIdentifier: app.bundleIdentifier)
        // WhisperM8 selbst (Chat-Prompt): jetzt lesen, solange das Fenster noch
        // nicht Key ist. Danach fände die Prüfung nur das eigene Suchfeld.
        if app.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            model.selectionProbe = Self.ownSelectionProbe()
            return
        }
        let pid = app.processIdentifier
        let current = presentation
        Task { @MainActor [weak self] in
            let probe = await Task.detached(priority: .userInitiated) {
                SelectedContextService.probeSelection(pid: pid)
            }.value
            guard let self, self.presentation == current, self.isPanelVisible else { return }
            self.model.selectionProbe = probe.respectingCopyFallback(canCopy)
        }
    }

    /// Markierung im eigenen Fenster: nur Textfelder, die AppKit kennt. Im
    /// Terminal eines Chats gibt es keine Kopfzeile.
    private static func ownSelectionProbe() -> SelectionProbe {
        guard let textView = NSApp.keyWindow?.firstResponder as? NSTextView else { return .none }
        let range = textView.selectedRange()
        guard range.length > 0, let text = textView.string as NSString? else { return .none }
        return .resolve(hasFocusedElement: true, selectedText: text.substring(with: range))
    }

    private func hidePanelIfNotKey() {
        if let panel, !panel.isKeyWindow { hidePanel() }
    }

    func hidePanel() {
        model.isPresented = false
        panel?.onResignKey = nil
        panel?.orderOut(nil)
        panel = nil
    }

    // MARK: Aktionen

    /// Kopfzeile: Fenster zu, dann die Markierung der App davor korrigieren
    /// (derselbe Ablauf wie ⇧⌘K).
    private func correctSelection() {
        guard let quickActions else { return }
        hidePanel()
        let delay = refocusDelay
        Task { @MainActor in
            try? await Task.sleep(for: delay)
            await quickActions.run(OutputMode.correctID, .selection)
        }
    }

    /// „Korrigieren & einfügen“: Fenster zu, vollen Text laden (lange Texte
    /// liegen in einer Datei), korrigieren und an der Schreibmarke einfügen.
    private func correctAndPaste(_ entry: ClipboardEntry) {
        guard let quickActions, entry.kind == .text else { return }
        hidePanel()
        let directory = store.directory
        let delay = refocusDelay
        Task { @MainActor in
            let text = await Task.detached(priority: .userInitiated) {
                ClipboardHistoryStore.fullText(of: entry, directory: directory)
            }.value
            try? await Task.sleep(for: delay)
            guard let text else {
                NSSound.beep()
                return
            }
            // Kein `bump`: die Zwischenablage hält danach wieder den alten
            // Inhalt, und das Ergebnis kommt ohnehin als eigener Eintrag.
            await quickActions.run(OutputMode.correctID, .text(text))
        }
    }

    private func togglePin(_ entry: ClipboardEntry) {
        store.setPinned(id: entry.id, pinned: !entry.isPinned)
    }

    private func delete(_ entry: ClipboardEntry) {
        store.delete(id: entry.id)
    }

    /// Legt den Eintrag in die Zwischenablage und fügt ihn, wenn gewünscht,
    /// in die vorherige App ein.
    private func paste(_ entry: ClipboardEntry, plain: Bool) {
        deliver { [weak self] in await self?.writeToPasteboard(entry, plain: plain) ?? false }
    }

    /// Roh-Transkript eines Diktats einfügen (immer als reiner Text).
    private func pasteOriginal(_ entry: ClipboardEntry) {
        guard let original = entry.dictationOriginal else { return }
        deliver { [weak self] in
            let item = [ClipboardRepresentation(type: ClipboardRestore.plainTextType, data: Data(original.utf8))]
            let written = ClipboardRestore.write(.items([item]), to: .general)
            if written { self?.store.bump(id: entry.id) }
            return written
        }
    }

    private func openSettings() {
        hidePanel()
        NSApp.activate(ignoringOtherApps: true)
        WindowRequestCenter.shared.requestSettings(routeID: SettingsPage.clipboard.rawValue)
    }

    /// Fenster zu, Inhalt in die Zwischenablage, dann (wenn gewünscht) in die
    /// App davor einfügen.
    private func deliver(_ write: @escaping @MainActor () async -> Bool) {
        let target = previousApp
        let autoPaste = ClipboardSettings.readLive().autoPaste
        hidePanel()
        Task { @MainActor in
            guard await write() else {
                NSSound.beep()
                return
            }
            guard autoPaste else { return }
            let ok = await pasteService.pasteClipboardContents(
                to: target,
                onMissingPermission: { Logger.paste.warning("Clipboard history: accessibility permission missing, entry stays on the clipboard") },
                onMissingTarget: { Logger.paste.warning("Clipboard history: no target app, entry stays on the clipboard") }
            )
            if !ok { NSSound.beep() }
        }
    }

    /// Für `whisperm8 clipboard copy`: zurück in die Zwischenablage, ohne Einfügen.
    func copyToPasteboard(_ entry: ClipboardEntry) async -> Bool {
        await writeToPasteboard(entry, plain: false)
    }

    /// Dateien lesen und Bilder umwandeln abseits des Main Threads, dann
    /// schreiben (markiert, der Monitor übergeht es) und nach oben schieben.
    private func writeToPasteboard(_ entry: ClipboardEntry, plain: Bool) async -> Bool {
        let directory = store.directory
        let payload = await Task.detached(priority: .userInitiated) {
            ClipboardRestore.payload(for: entry, plain: plain, directory: directory)
        }.value
        guard let payload else { return false }
        let written = ClipboardRestore.write(payload, to: .general)
        if written { store.bump(id: entry.id) }
        return written
    }
}

// MARK: - Fensterposition

enum ClipboardPanelPlacement {
    /// Linke untere Ecke des Panels. `cursor`: die obere linke Ecke nahe dem
    /// Mauszeiger, in den Bildschirm geschoben; `center`: mittig auf dem
    /// Bildschirm unter dem Zeiger. `screens` sind `visibleFrame`s.
    static func origin(size: CGSize, position: ClipboardWindowPosition, mouse: CGPoint, screens: [CGRect]) -> CGPoint {
        let screen = screens.first { $0.contains(mouse) } ?? screens.first ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        switch position {
        case .center:
            return CGPoint(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2 + screen.height * 0.08)
        case .cursor:
            var x = mouse.x - 24
            var y = mouse.y - size.height + 24
            x = min(max(x, screen.minX + 8), screen.maxX - size.width - 8)
            y = min(max(y, screen.minY + 8), screen.maxY - size.height - 8)
            return CGPoint(x: x, y: y)
        }
    }
}
