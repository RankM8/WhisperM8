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

    nonisolated let store: ClipboardHistoryStore
    private let monitor: ClipboardMonitor
    private let pasteService = PasteService()
    private let model = ClipboardHistoryViewModel()
    private var panel: ClipboardPanel?
    private var previousApp: NSRunningApplication?
    private var cachedEntries: [ClipboardEntry] = []
    private var started = false
    private var defaultsObserver: NSObjectProtocol?

    init(store: ClipboardHistoryStore = ClipboardHistoryStore()) {
        self.store = store
        self.monitor = ClipboardMonitor(store: store)
        model.actions = ClipboardHistoryViewModel.Actions(
            paste: { [weak self] entry, plain in self?.paste(entry, plain: plain) },
            togglePin: { [weak self] entry in self?.togglePin(entry) },
            delete: { [weak self] entry in self?.delete(entry) },
            close: { [weak self] in self?.hidePanel() }
        )
    }

    // MARK: Lebenszyklus

    func start() {
        guard !started else { return }
        started = true
        store.onChange = { [weak self] entries in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.cachedEntries = entries
                    self?.model.setEntries(entries)
                }
            }
        }
        KeyboardShortcuts.onKeyDown(for: .clipboardHistory) { [weak self] in
            Task { @MainActor in self?.togglePanel() }
        }
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applySettings() }
        }
        applySettings()
        // Index off-main laden; bis dahin ist das Fenster nur leer.
        let store = store
        Task.detached(priority: .utility) { [weak self] in
            let entries = store.snapshot()
            await MainActor.run {
                self?.cachedEntries = entries
                self?.model.setEntries(entries)
            }
        }
    }

    /// Beim Beenden: optional leeren (Angepinnte bleiben), Index festschreiben.
    func shutdown() {
        guard started else { return }
        if ClipboardSettings.readLive().clearOnQuit { store.clear(keepPinned: true) }
        store.flush()
    }

    /// Schalter ausgewertet; billig, darf bei jeder Defaults-Änderung laufen.
    func applySettings() {
        let settings = ClipboardSettings.readLive()
        if settings.enabled {
            if !monitor.isRunning { monitor.start() }
            KeyboardShortcuts.enable(.clipboardHistory)
        } else {
            if monitor.isRunning { monitor.stop() }
            KeyboardShortcuts.disable(.clipboardHistory)
            if panel != nil { hidePanel() }
        }
    }

    // MARK: Fenster

    func togglePanel() {
        if panel?.isVisible == true { hidePanel() } else { showPanel() }
    }

    func showPanel() {
        let settings = ClipboardSettings.readLive()
        guard settings.enabled else { return }
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front?.bundleIdentifier == Bundle.main.bundleIdentifier ? previousApp : front

        model.setEntries(cachedEntries)
        model.reset()
        let hosting = NSHostingView(rootView: ClipboardHistoryView(model: model))
        let panel = ClipboardPanel(contentView: hosting)
        panel.onCommand = { [weak self] command in
            self?.model.handle(command)
            return true
        }
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
    }

    private func hidePanelIfNotKey() {
        if let panel, !panel.isKeyWindow { hidePanel() }
    }

    func hidePanel() {
        panel?.onResignKey = nil
        panel?.orderOut(nil)
        panel = nil
    }

    // MARK: Aktionen

    private func togglePin(_ entry: ClipboardEntry) {
        store.setPinned(id: entry.id, pinned: !entry.isPinned)
    }

    private func delete(_ entry: ClipboardEntry) {
        store.delete(id: entry.id)
    }

    /// Legt den Eintrag in die Zwischenablage und fügt ihn, wenn gewünscht,
    /// in die vorherige App ein.
    private func paste(_ entry: ClipboardEntry, plain: Bool) {
        let target = previousApp
        let autoPaste = ClipboardSettings.readLive().autoPaste
        hidePanel()
        guard writeToPasteboard(entry, plain: plain) else { return }
        guard autoPaste else { return }
        Task { @MainActor in
            let ok = await pasteService.pasteClipboardContents(
                to: target,
                onMissingPermission: { Logger.paste.warning("Clipboard history: accessibility permission missing, entry stays on the clipboard") },
                onMissingTarget: { Logger.paste.warning("Clipboard history: no target app, entry stays on the clipboard") }
            )
            if !ok { NSSound.beep() }
        }
    }

    /// Für `whisperm8 clipboard copy`: zurück in die Zwischenablage, ohne Einfügen.
    @discardableResult
    func copyToPasteboard(_ entry: ClipboardEntry) -> Bool {
        writeToPasteboard(entry, plain: false)
    }

    /// Schreibt den Eintrag mit Marker (der Monitor übergeht ihn) und
    /// schiebt ihn im Verlauf nach oben.
    private func writeToPasteboard(_ entry: ClipboardEntry, plain: Bool) -> Bool {
        let pasteboard = NSPasteboard.general
        ClipboardInternalWrites.begin()
        defer { ClipboardInternalWrites.end(pasteboard: pasteboard) }
        let dir = store.directory

        let written: Bool
        switch entry.kind {
        case .text:
            guard let text = ClipboardHistoryStore.fullText(of: entry, directory: dir) else { return false }
            pasteboard.clearContents()
            let item = NSPasteboardItem()
            item.setString(text, forType: .string)
            if !plain {
                if let file = entry.rtfFile, let data = try? Data(contentsOf: ClipboardHistoryStore.blobURL(file, directory: dir)) {
                    item.setData(data, forType: .rtf)
                }
                if let file = entry.htmlFile, let data = try? Data(contentsOf: ClipboardHistoryStore.blobURL(file, directory: dir)) {
                    item.setData(data, forType: .html)
                }
            }
            ClipboardInternalWrites.mark(item)
            written = pasteboard.writeObjects([item])
        case .image:
            guard let file = entry.imageFile,
                  let data = try? Data(contentsOf: ClipboardHistoryStore.blobURL(file, directory: dir)) else { return false }
            pasteboard.clearContents()
            let item = NSPasteboardItem()
            item.setData(data, forType: .png)
            if let tiff = NSImage(data: data)?.tiffRepresentation { item.setData(tiff, forType: .tiff) }
            ClipboardInternalWrites.mark(item)
            written = pasteboard.writeObjects([item])
        case .files:
            let urls = (entry.filePaths ?? []).map { URL(fileURLWithPath: $0) as NSURL }
            guard !urls.isEmpty else { return false }
            pasteboard.clearContents()
            written = pasteboard.writeObjects(urls)
            ClipboardInternalWrites.markPasteboard(pasteboard)
        }
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
