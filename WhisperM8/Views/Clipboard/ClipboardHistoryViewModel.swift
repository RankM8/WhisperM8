import AppKit
import SwiftUI

// MARK: - Zustand des Verlaufs-Fensters

/// Alles, was die Ansicht braucht. Entscheidungen (Suche, Reihenfolge,
/// Nummern) kommen aus `ClipboardHistoryCore`; die Datei-Zugriffe stecken
/// hinter Closures, damit Snapshots und Tests nichts Echtes berühren.
///
/// `visible` wird nur neu berechnet, wenn sich Suche oder Einträge ändern,
/// nie im Body. Die Suche läuft über den vorbereiteten Index des Stores
/// (voller Text auch langer Einträge, ohne Datei-Zugriff beim Tippen).
@MainActor
final class ClipboardHistoryViewModel: ObservableObject {
    struct Loaders {
        var fullText: @Sendable (ClipboardEntry) -> String?
        /// Verkleinertes Bild; das `Int` ist die größte Kantenlänge in Pixeln.
        var image: @Sendable (ClipboardEntry, Int) -> NSImage?
        var appIcon: @MainActor (String?) -> NSImage?

        static let live = Loaders(
            fullText: { ClipboardHistoryStore.fullText(of: $0, directory: ClipboardHistoryStore.defaultDirectory()) },
            image: { entry, maxPixels in
                guard let file = entry.imageFile else { return nil }
                let url = ClipboardHistoryStore.blobURL(file, directory: ClipboardHistoryStore.defaultDirectory())
                return ClipboardImageConverter.thumbnail(at: url, maxPixelSize: maxPixels)
            },
            appIcon: { ClipboardAppIcons.icon(for: $0) }
        )
    }

    struct Actions {
        var paste: (ClipboardEntry, Bool) -> Void = { _, _ in }
        /// Roh-Transkript eines Diktats einfügen.
        var pasteOriginal: (ClipboardEntry) -> Void = { _ in }
        var togglePin: (ClipboardEntry) -> Void = { _ in }
        var delete: (ClipboardEntry) -> Void = { _ in }
        /// Alles außer den Angepinnten löschen.
        var clearUnpinned: () -> Void = {}
        var openSettings: () -> Void = {}
        var close: () -> Void = {}
    }

    /// Was die Liste zeigt: alles oder nur Diktate.
    enum Filter: Equatable {
        case all
        case dictations
    }

    nonisolated static let thumbnailPixels = 96
    nonisolated static let previewPixels = 1200
    /// Große Ansicht (⌘Y): scharf auch auf Retina bei voller Fenstergröße.
    nonisolated static let zoomPixels = 3000
    /// Vorschau-Text sehr langer Einträge: nur der Anfang, sonst stockt das Layout.
    nonisolated static let previewCharacterLimit = 20_000

    @Published private(set) var entries: [ClipboardEntry] = []
    @Published private(set) var visible: [ClipboardEntry] = []
    @Published var query = "" {
        didSet {
            guard query != oldValue else { return }
            recomputeVisible()
            selectFirstIfNeeded(force: true)
        }
    }
    @Published var selectedID: String?
    @Published var filter: Filter = .all {
        didSet {
            guard filter != oldValue else { return }
            recomputeVisible()
            selectFirstIfNeeded(force: true)
        }
    }
    /// Die Fußzeile fragt nach, bevor sie den Verlauf leert.
    @Published var isConfirmingClear = false
    /// Bild füllt das ganze Fenster (Klick aufs Vorschaubild oder ⌘Y).
    @Published private(set) var isZoomed = false
    @Published private(set) var zoomImage: NSImage?
    private var zoomTask: Task<Void, Never>?
    @Published private(set) var thumbnails: [String: NSImage] = [:]
    @Published private(set) var previewText = ""
    @Published private(set) var previewImage: NSImage?

    /// Nur bei offenem Fenster werden Bilder geladen.
    var isPresented = false {
        didSet {
            guard isPresented, !oldValue else { return }
            // App-Symbole vor dem ersten Zeichnen holen, nicht erst im Body.
            for bundleID in Set(entries.compactMap(\.sourceBundleID)) { _ = loaders.appIcon(bundleID) }
            loadThumbnails()
            loadPreview()
        }
    }

    var loaders: Loaders
    var actions = Actions()
    private var search = ClipboardSearchIndex()
    private let now: () -> Date
    private var previewTask: Task<Void, Never>?
    private var previewImages: [String: NSImage] = [:]

    init(loaders: Loaders = .live, now: @escaping () -> Date = Date.init) {
        self.loaders = loaders
        self.now = now
    }

    // MARK: Abgeleitet

    var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    var selectedEntry: ClipboardEntry? {
        guard let selectedID else { return nil }
        return visible.first { $0.id == selectedID }
    }

    /// Angepinnte stehen nur ohne Suche als eigene Gruppe oben; bei einer
    /// Suche gilt die Reihenfolge der Treffer. Die Nummern (⌘1 bis ⌘9) zählen
    /// in beiden Fällen genau so, wie die Liste es zeigt.
    var showsPinnedGroup: Bool { !isSearching && visible.contains(where: \.isPinned) }

    // MARK: Laden

    /// Einträge samt fertigem Suchindex aus dem Store.
    func setEntries(_ new: [ClipboardEntry], search index: ClipboardSearchIndex) {
        entries = new
        search = index
        let ids = Set(new.map(\.id))
        if thumbnails.keys.contains(where: { !ids.contains($0) }) {
            thumbnails = thumbnails.filter { ids.contains($0.key) }
        }
        previewImages = previewImages.filter { ids.contains($0.key) }
        recomputeVisible()
        selectFirstIfNeeded(force: false)
        if isPresented { loadThumbnails() }
        loadPreview()
    }

    /// Ohne Store (Snapshots, Tests): der Index entsteht aus den Texten im Eintrag.
    func setEntries(_ new: [ClipboardEntry]) {
        var index = ClipboardSearchIndex()
        for entry in new { index.set(entry, fullText: loaders.fullText(entry)) }
        setEntries(new, search: index)
    }

    /// Miniaturen von außen setzen (Snapshots, Tests), ohne Laden von Disk.
    func preload(thumbnails: [String: NSImage]) {
        self.thumbnails = thumbnails
        previewImages.merge(thumbnails) { current, _ in current }
        loadPreview()
    }

    func appIcon(for entry: ClipboardEntry) -> NSImage? { loaders.appIcon(entry.sourceBundleID) }

    func reset() {
        query = ""
        filter = .all
        isConfirmingClear = false
        closeZoom()
        recomputeVisible()
        selectedID = visible.first?.id
        loadPreview()
    }

    private func recomputeVisible() {
        let index = search
        let source = Self.filtered(entries, by: filter)
        visible = ClipboardHistoryCore.search(source, query: query) { entry in
            index.haystack(for: entry.id)
                ?? ClipboardSearchIndex.haystack(for: entry, fullText: entry.text)
        }
    }

    nonisolated static func filtered(_ entries: [ClipboardEntry], by filter: Filter) -> [ClipboardEntry] {
        switch filter {
        case .all: return entries
        case .dictations: return entries.filter { $0.dictationMode != nil }
        }
    }

    func toggleDictationFilter() {
        filter = filter == .all ? .dictations : .all
    }

    func confirmClear() {
        isConfirmingClear = false
        actions.clearUnpinned()
    }

    private func selectFirstIfNeeded(force: Bool) {
        if force || selectedID == nil || !visible.contains(where: { $0.id == selectedID }) {
            selectedID = visible.first?.id
            loadPreview()
        }
    }

    /// Miniaturen der neuesten Bild-Einträge, verkleinert und abseits des Main Threads.
    private func loadThumbnails() {
        let wanted = entries.filter { $0.kind == .image }.prefix(60).filter { thumbnails[$0.id] == nil }
        guard !wanted.isEmpty else { return }
        let loader = loaders.image
        let items = Array(wanted)
        Task { [weak self] in
            let loaded = await Task.detached(priority: .utility) { () -> [String: NSImage] in
                var loaded: [String: NSImage] = [:]
                for entry in items {
                    if let image = loader(entry, Self.thumbnailPixels) { loaded[entry.id] = image }
                }
                return loaded
            }.value
            guard let self else { return }
            self.thumbnails.merge(loaded) { $1 }
            self.loadPreview()
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
                    self?.previewText = String(full.prefix(Self.previewCharacterLimit))
                }
            }
        case .image:
            previewText = ""
            if let image = previewImages[entry.id] {
                previewImage = image
                return
            }
            previewImage = thumbnails[entry.id]
            guard isPresented else { return }
            let loader = loaders.image
            previewTask = Task { [weak self] in
                let image = await Task.detached(priority: .userInitiated) { loader(entry, Self.previewPixels) }.value
                guard !Task.isCancelled, let image, let self else { return }
                self.previewImages[entry.id] = image
                if self.selectedID == entry.id { self.previewImage = image }
            }
        case .files:
            previewImage = nil
            previewText = (entry.filePaths ?? []).joined(separator: "\n")
        }
    }

    // MARK: Bedienung

    func select(_ id: String) {
        selectedID = id
        loadPreview()
        if isZoomed { refreshZoom() }
    }

    // MARK: Große Bildansicht

    /// Nur Bilder lassen sich groß ansehen; bei anderen Einträgen passiert nichts.
    func toggleZoom() {
        if isZoomed { closeZoom() } else { openZoom() }
    }

    func openZoom() {
        guard selectedEntry?.kind == .image else { return }
        isZoomed = true
        refreshZoom()
    }

    func closeZoom() {
        zoomTask?.cancel()
        isZoomed = false
        zoomImage = nil
    }

    /// Lädt das gewählte Bild in großer Auflösung, bis dahin steht die Vorschau.
    private func refreshZoom() {
        zoomTask?.cancel()
        guard let entry = selectedEntry, entry.kind == .image else {
            closeZoom()
            return
        }
        zoomImage = previewImages[entry.id] ?? thumbnails[entry.id]
        let loader = loaders.image
        zoomTask = Task { [weak self] in
            let image = await Task.detached(priority: .userInitiated) { loader(entry, Self.zoomPixels) }.value
            guard !Task.isCancelled, let image, let self, self.selectedID == entry.id, self.isZoomed else { return }
            self.zoomImage = image
        }
    }

    func move(_ delta: Int) {
        let list = visible
        guard !list.isEmpty else { return }
        let current = list.firstIndex { $0.id == selectedID } ?? (delta > 0 ? -1 : list.count)
        let next = min(max(current + delta, 0), list.count - 1)
        select(list[next].id)
    }

    /// Eintrag zu ⌘1 bis ⌘9: Platz in der sichtbaren Liste.
    func entry(forQuickSelect number: Int) -> ClipboardEntry? {
        guard number >= 1, number <= visible.count else { return nil }
        return visible[number - 1]
    }

    func handle(_ command: ClipboardKeyCommand) {
        switch command {
        case .moveUp: move(-1)
        case .moveDown: move(1)
        case .paste: if let entry = selectedEntry { actions.paste(entry, false) }
        case .pastePlain: if let entry = selectedEntry { actions.paste(entry, true) }
        case .quickSelect(let number): if let entry = entry(forQuickSelect: number) { actions.paste(entry, false) }
        case .togglePin: if let entry = selectedEntry { actions.togglePin(entry) }
        case .delete: if let entry = selectedEntry { deleteEntry(entry) }
        case .toggleDictationFilter: toggleDictationFilter()
        case .toggleZoom: toggleZoom()
        case .close:
            // Esc schließt zuerst die große Ansicht bzw. eine offene Rückfrage, erst dann das Fenster.
            if isZoomed {
                closeZoom()
            } else if isConfirmingClear {
                isConfirmingClear = false
            } else {
                actions.close()
            }
        }
    }

    func deleteEntry(_ entry: ClipboardEntry) {
        let list = visible
        let index = list.firstIndex { $0.id == entry.id }
        actions.delete(entry)
        // Auswahl rückt auf den Nachbarn, nicht zurück an den Anfang.
        if let index, list.count > 1 {
            select(list[index + 1 < list.count ? index + 1 : index - 1].id)
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
