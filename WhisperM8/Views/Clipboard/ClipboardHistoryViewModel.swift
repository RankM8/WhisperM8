import AppKit
import SwiftUI

// MARK: - Zustand des Verlaufs-Fensters

/// Alles, was die Ansicht braucht. Entscheidungen (Suche, Reihenfolge,
/// Nummern) kommen aus `ClipboardHistoryCore`; die Datei-Zugriffe stecken
/// hinter Closures, damit Snapshots und Tests nichts Echtes berühren.
@MainActor
final class ClipboardHistoryViewModel: ObservableObject {
    struct Loaders {
        var fullText: @Sendable (ClipboardEntry) -> String?
        var image: @Sendable (ClipboardEntry) -> NSImage?
        var appIcon: @MainActor (String?) -> NSImage?

        static let live = Loaders(
            fullText: { ClipboardHistoryStore.fullText(of: $0, directory: ClipboardHistoryStore.defaultDirectory()) },
            image: { entry in
                guard let file = entry.imageFile else { return nil }
                return NSImage(contentsOf: ClipboardHistoryStore.blobURL(file, directory: ClipboardHistoryStore.defaultDirectory()))
            },
            appIcon: { ClipboardAppIcons.icon(for: $0) }
        )
    }

    struct Actions {
        var paste: (ClipboardEntry, Bool) -> Void = { _, _ in }
        var togglePin: (ClipboardEntry) -> Void = { _ in }
        var delete: (ClipboardEntry) -> Void = { _ in }
        var close: () -> Void = {}
    }

    @Published private(set) var entries: [ClipboardEntry] = []
    @Published var query = "" {
        didSet { if query != oldValue { selectFirstIfNeeded(force: true) } }
    }
    @Published var selectedID: String?
    @Published private(set) var thumbnails: [String: NSImage] = [:]
    @Published private(set) var previewText = ""
    @Published private(set) var previewImage: NSImage?

    var loaders: Loaders
    var actions = Actions()
    private let now: () -> Date
    private var previewTask: Task<Void, Never>?

    init(loaders: Loaders = .live, now: @escaping () -> Date = Date.init) {
        self.loaders = loaders
        self.now = now
    }

    // MARK: Abgeleitet

    var visible: [ClipboardEntry] {
        // Gesucht wird im Index (Text bis 16.000 Zeichen, sonst die Vorschau):
        // kein Dateizugriff beim Tippen.
        ClipboardHistoryCore.search(entries, query: query)
    }

    var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    var selectedEntry: ClipboardEntry? {
        visible.first { $0.id == selectedID }
    }

    // MARK: Laden

    func setEntries(_ new: [ClipboardEntry]) {
        entries = new
        selectFirstIfNeeded(force: false)
        loadThumbnails()
        loadPreview()
    }

    /// Miniaturen von außen setzen (Snapshots, Tests), ohne Laden von Disk.
    func preload(thumbnails: [String: NSImage]) {
        self.thumbnails = thumbnails
        loadPreview()
    }

    func appIcon(for entry: ClipboardEntry) -> NSImage? { loaders.appIcon(entry.sourceBundleID) }

    func reset() {
        query = ""
        selectedID = visible.first?.id
        loadPreview()
    }

    private func selectFirstIfNeeded(force: Bool) {
        let list = visible
        if force || selectedID == nil || !list.contains(where: { $0.id == selectedID }) {
            selectedID = list.first?.id
            loadPreview()
        }
    }

    /// Miniaturen der neuesten Bild-Einträge, abseits des Main Threads.
    private func loadThumbnails() {
        let wanted = entries.filter { $0.kind == .image }.prefix(40).filter { thumbnails[$0.id] == nil }
        guard !wanted.isEmpty else { return }
        let loader = loaders.image
        let items = Array(wanted)
        Task.detached(priority: .utility) { [weak self] in
            var loaded: [String: NSImage] = [:]
            for entry in items {
                if let image = loader(entry) { loaded[entry.id] = image }
            }
            await MainActor.run { [loaded] in
                self?.thumbnails.merge(loaded) { $1 }
                self?.loadPreview()
            }
        }
    }

    private func loadPreview() {
        previewTask?.cancel()
        guard let entry = selectedEntry else {
            previewText = ""
            previewImage = nil
            return
        }
        switch entry.kind {
        case .text:
            previewImage = nil
            if let text = entry.text {
                previewText = text
            } else {
                previewText = entry.preview
                let loader = loaders.fullText
                previewTask = Task { [weak self] in
                    let full = await Task.detached(priority: .userInitiated) { loader(entry) }.value
                    guard !Task.isCancelled, let full else { return }
                    // Sehr lange Texte: nur den Anfang zeigen.
                    self?.previewText = String(full.prefix(20_000))
                }
            }
        case .image:
            previewText = ""
            previewImage = thumbnails[entry.id]
        case .files:
            previewImage = nil
            previewText = (entry.filePaths ?? []).joined(separator: "\n")
        }
    }

    // MARK: Bedienung

    func select(_ id: String) {
        selectedID = id
        loadPreview()
    }

    func move(_ delta: Int) {
        let list = visible
        guard !list.isEmpty else { return }
        let current = list.firstIndex { $0.id == selectedID } ?? (delta > 0 ? -1 : list.count)
        let next = min(max(current + delta, 0), list.count - 1)
        select(list[next].id)
    }

    func handle(_ command: ClipboardKeyCommand) {
        switch command {
        case .moveUp: move(-1)
        case .moveDown: move(1)
        case .paste: if let entry = selectedEntry { actions.paste(entry, false) }
        case .pastePlain: if let entry = selectedEntry { actions.paste(entry, true) }
        case .quickSelect(let number):
            let list = visible
            if number >= 1, number <= list.count { actions.paste(list[number - 1], false) }
        case .togglePin: if let entry = selectedEntry { actions.togglePin(entry) }
        case .delete: if let entry = selectedEntry { deleteEntry(entry) }
        case .close: actions.close()
        }
    }

    func deleteEntry(_ entry: ClipboardEntry) {
        let list = visible
        let index = list.firstIndex { $0.id == entry.id }
        actions.delete(entry)
        // Auswahl rückt auf den Nachbarn, nicht zurück an den Anfang.
        if let index, list.count > 1 {
            selectedID = list[index + 1 < list.count ? index + 1 : index - 1].id
        }
    }
}

// MARK: - App-Symbole

/// Symbole der Herkunfts-Apps, einmal je Bundle-ID geholt und dann gemerkt.
@MainActor
enum ClipboardAppIcons {
    private static var cache: [String: NSImage] = [:]
    private static var misses = Set<String>()

    static func icon(for bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        if let image = cache[bundleID] { return image }
        if misses.contains(bundleID) { return nil }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            misses.insert(bundleID)
            return nil
        }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        image.size = NSSize(width: 32, height: 32)
        cache[bundleID] = image
        return image
    }
}
