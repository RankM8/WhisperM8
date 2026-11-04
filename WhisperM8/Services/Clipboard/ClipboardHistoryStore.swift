import Foundation

// MARK: - Persistenz des Verlaufs

/// Was der Store nach jeder Änderung meldet: Einträge plus fertiger Suchindex.
struct ClipboardHistoryState: Sendable {
    var entries: [ClipboardEntry]
    var search: ClipboardSearchIndex
}

/// Index (`index.json`) plus Blob-Dateien unter
/// `~/Library/Application Support/WhisperM8/clipboard-history/`.
/// Ordner 0700, Dateien 0600. Die App ist einziger Schreiber; die CLI liest
/// über `loadIndex(directory:)` direkt von Disk (der Index wird atomar ersetzt).
///
/// Alle Änderungen laufen auf einer seriellen Queue, der Index wird gebündelt
/// (Debounce) und atomar geschrieben. Der Main Thread wartet nie auf die Queue,
/// außer beim Beenden (`flush`).
final class ClipboardHistoryStore: @unchecked Sendable {
    static let schema = "wm8.clipboard/1"
    static let indexFileName = "index.json"
    static let brokenIndexPrefix = "index.broken-"

    struct IndexFile: Codable {
        var schema: String
        var entries: [ClipboardEntry]
    }

    /// Größenlimits der Erfassung.
    struct Limits: Sendable {
        var maxInlineTextChars = 16_000
        var maxTextChars = 2_000_000
        var maxImageBytes = 12 * 1024 * 1024
        var maxRichBytes = 4 * 1024 * 1024
        var search = ClipboardSearchIndex.Limits()
    }

    static func defaultDirectory() -> URL {
        AppInstance.applicationSupport
            .appendingPathComponent("WhisperM8", isDirectory: true)
            .appendingPathComponent("clipboard-history", isDirectory: true)
    }

    let directory: URL
    let limits: Limits
    private let queue = DispatchQueue(label: "com.whisperm8.clipboard-store", qos: .utility)
    private let debounceSeconds: Double
    private var entries: [ClipboardEntry] = []
    private var search: ClipboardSearchIndex
    private var loaded = false
    private var flushPending = false
    private var onChange: (@Sendable (ClipboardHistoryState) -> Void)?

    init(directory: URL = ClipboardHistoryStore.defaultDirectory(), limits: Limits = Limits(), debounceSeconds: Double = 0.6) {
        self.directory = directory
        self.limits = limits
        self.debounceSeconds = debounceSeconds
        self.search = ClipboardSearchIndex(limits: limits.search)
    }

    // MARK: Lesen (CLI und App)

    enum IndexStatus: Equatable {
        case missing
        case ok
        /// Datei da, aber nicht lesbar: nicht überschreiben, sondern beiseitelegen.
        case unreadable
    }

    /// Liest den Index von Disk; fehlende oder kaputte Datei = leerer Verlauf.
    static func loadIndex(directory: URL) -> [ClipboardEntry] {
        readIndex(directory: directory).entries
    }

    /// Wie `loadIndex`, aber nachsichtig: ein einzelner kaputter Eintrag kostet
    /// nur sich selbst, nicht den ganzen Verlauf.
    static func readIndex(directory: URL) -> (entries: [ClipboardEntry], status: IndexStatus) {
        let url = directory.appendingPathComponent(indexFileName)
        guard let data = try? Data(contentsOf: url) else { return ([], .missing) }
        guard let file = try? JSONDecoder().decode(LossyIndexFile.self, from: data) else { return ([], .unreadable) }
        return (file.entries, .ok)
    }

    /// Voller Text eines Eintrags (Index oder Blob-Datei).
    static func fullText(of entry: ClipboardEntry, directory: URL) -> String? {
        if let text = entry.text { return text }
        guard let file = entry.textFile else { return nil }
        return (try? Data(contentsOf: directory.appendingPathComponent(file))).map { String(decoding: $0, as: UTF8.self) }
    }

    static func blobURL(_ file: String, directory: URL) -> URL {
        directory.appendingPathComponent(file)
    }

    // MARK: App-Seite

    /// Meldet den Stand sofort (nach dem Laden, abseits des Main Threads) und
    /// danach nach jeder Änderung.
    func observe(_ handler: @escaping @Sendable (ClipboardHistoryState) -> Void) {
        queue.async { [self] in
            onChange = handler
            loadIfNeeded()
            handler(ClipboardHistoryState(entries: entries, search: search))
        }
    }

    /// Wartet auf die Queue: nur für Tests und Werkzeuge, nie auf dem Main Thread der App.
    func snapshot() -> [ClipboardEntry] {
        queue.sync {
            loadIfNeeded()
            return entries
        }
    }

    func searchSnapshot() -> ClipboardSearchIndex {
        queue.sync {
            loadIfNeeded()
            return search
        }
    }

    /// Nimmt einen erfassten Inhalt auf (aufbereiten, Duplikate, Kürzen).
    /// Läuft auf der Store-Queue; `completion` kommt von dort.
    func add(_ capture: ClipboardCapture, maxItems: Int, completion: (@Sendable (ClipboardHistoryCore.SkipReason?) -> Void)? = nil) {
        queue.async { [self] in
            loadIfNeeded()
            guard let made = makeEntry(from: capture) else {
                completion?(.empty)
                return
            }
            let inserted = ClipboardHistoryCore.insert(made.entry, into: entries)
            entries = inserted.entries
            for file in inserted.discardedBlobs { removeBlob(file) }
            if inserted.merged {
                // Herkunfts-App kann sich geändert haben; der Inhalt nicht.
                if let existing = entries.first { search.set(existing, fullText: fullText(of: existing)) }
            } else {
                search.set(made.entry, fullText: made.fullText)
            }
            let trimmed = ClipboardHistoryCore.trim(entries, maxUnpinned: maxItems)
            entries = trimmed.kept
            for removed in trimmed.removed {
                removeBlobs(of: removed)
                search.remove(id: removed.id)
            }
            search.enforceBudget(entries)
            changed()
            completion?(nil)
        }
    }

    func setPinned(id: String, pinned: Bool) {
        queue.async { [self] in
            loadIfNeeded()
            guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
            entries[index].isPinned = pinned
            changed()
        }
    }

    /// Eintrag wurde erneut benutzt (eingefügt oder zurückkopiert): nach oben.
    func bump(id: String, at date: Date = Date()) {
        queue.async { [self] in
            loadIfNeeded()
            guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
            entries[index].lastCopiedAt = date
            entries[index].copyCount += 1
            changed()
        }
    }

    func delete(id: String) {
        queue.async { [self] in
            loadIfNeeded()
            guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
            removeBlobs(of: entries.remove(at: index))
            search.remove(id: id)
            changed()
        }
    }

    /// Entfernt alles; `keepPinned` lässt Angepinnte stehen. Ohne Pins wird
    /// der Ordner komplett geleert, auch Reste nach einem Absturz.
    func clear(keepPinned: Bool = false) {
        queue.async { [self] in
            loadIfNeeded()
            if keepPinned {
                for entry in entries where !entry.isPinned { removeBlobs(of: entry) }
                entries = entries.filter(\.isPinned)
                search.retain(entries)
            } else {
                entries = []
                search = ClipboardSearchIndex(limits: limits.search)
                removeAllFiles()
            }
            changed()
        }
    }

    /// Schreibt sofort, ohne Debounce (Beenden, Tests).
    func flush() {
        queue.sync {
            loadIfNeeded()
            writeIndex()
        }
    }

    /// Wartet, bis alle bisherigen Aufträge durch sind (Tests).
    func waitUntilIdle() { queue.sync {} }

    func fullText(of entry: ClipboardEntry) -> String? {
        Self.fullText(of: entry, directory: directory)
    }

    func blobURL(_ file: String) -> URL { Self.blobURL(file, directory: directory) }

    // MARK: Intern (immer auf `queue`)

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        let (loadedEntries, status) = Self.readIndex(directory: directory)
        entries = loadedEntries
        switch status {
        case .unreadable:
            // Nicht überschreiben und keine Dateien wegräumen: beiseitelegen,
            // damit nichts unwiederbringlich verloren geht.
            setAsideBrokenIndex()
        case .ok, .missing:
            removeOrphans()
        }
        for entry in entries {
            search.set(entry, fullText: entry.kind == .text ? fullText(of: entry) : nil)
        }
        search.enforceBudget(entries)
    }

    private func changed() {
        onChange?(ClipboardHistoryState(entries: entries, search: search))
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard !flushPending else { return }
        flushPending = true
        queue.asyncAfter(deadline: .now() + debounceSeconds) { [self] in
            flushPending = false
            writeIndex()
        }
    }

    private func ensureDirectory() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory.path) {
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        // Auch ein vorhandener Ordner wird auf 0700 gezogen.
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    private func writeIndex() {
        ensureDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(IndexFile(schema: Self.schema, entries: entries)) else { return }
        let url = directory.appendingPathComponent(Self.indexFileName)
        writeFile(data, to: url)
    }

    /// Atomar (Temp-Datei + rename) und mit 0600 von Anfang an.
    @discardableResult
    private func writeFile(_ data: Data, to url: URL) -> Bool {
        let temp = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return false }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.close()
            if rename(temp.path, url.path) != 0 {
                try? FileManager.default.removeItem(at: temp)
                return false
            }
            return true
        } catch {
            try? FileManager.default.removeItem(at: temp)
            return false
        }
    }

    private func removeBlob(_ file: String) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(file))
    }

    private func removeBlobs(of entry: ClipboardEntry) {
        for file in entry.blobFiles { removeBlob(file) }
    }

    private func directoryContents() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    }

    /// „Verlauf leeren“: alles weg, auch ein beiseitegelegter kaputter Index.
    private func removeAllFiles() {
        for name in directoryContents() { removeBlob(name) }
    }

    /// Blob- und Temp-Dateien ohne Eintrag (Absturz zwischen Blob und Index)
    /// weg. Liegt ein beiseitegelegter kaputter Index da, bleibt alles, bis der
    /// User den Verlauf leert: die Dateien gehören womöglich zu ihm.
    private func removeOrphans() {
        let names = directoryContents()
        guard !names.contains(where: { $0.hasPrefix(Self.brokenIndexPrefix) }) else { return }
        let referenced = Set(entries.flatMap(\.blobFiles))
        for name in names where name != Self.indexFileName && !referenced.contains(name) {
            removeBlob(name)
        }
    }

    private func setAsideBrokenIndex() {
        let source = directory.appendingPathComponent(Self.indexFileName)
        let stamp = Int(Date().timeIntervalSince1970)
        let target = directory.appendingPathComponent("\(Self.brokenIndexPrefix)\(stamp).json")
        try? FileManager.default.moveItem(at: source, to: target)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        Logger.info("clipboard_history_index_unreadable set_aside=\(target.lastPathComponent)")
    }

    // MARK: Aufbereiten

    /// Typen, die der Verlauf ohnehin selbst zurückschreibt; alles darüber
    /// hinaus (App-eigene Formate, mehrere Einträge) braucht das Archiv.
    static let basicTypes: Set<String> = [
        "public.utf8-plain-text", "public.utf16-external-plain-text", "public.utf16-plain-text",
        "public.rtf", "public.html", "public.png", "public.tiff",
        "NSStringPboardType", ClipboardInternalMarker.typeName,
    ]

    static func needsArchive(_ archive: ClipboardArchive?) -> Bool {
        guard let archive else { return false }
        if archive.items.count > 1 { return true }
        return archive.items.first?.contains { !basicTypes.contains($0.type) } ?? false
    }

    private func storeArchive(_ capture: ClipboardCapture, id: String, into entry: inout ClipboardEntry) {
        guard Self.needsArchive(capture.archive), let data = capture.archive?.encoded() else { return }
        ensureDirectory()
        let file = "\(id).pasteboard"
        if writeFile(data, to: directory.appendingPathComponent(file)) { entry.archiveFile = file }
    }

    private func makeEntry(from capture: ClipboardCapture) -> (entry: ClipboardEntry, fullText: String?)? {
        let id = UUID().uuidString.lowercased()
        var entry = ClipboardEntry(
            id: id, kind: .text, createdAt: capture.date, lastCopiedAt: capture.date, copyCount: 1,
            isPinned: false, sourceBundleID: capture.sourceBundleID, sourceName: capture.sourceName,
            contentHash: "", preview: ""
        )
        entry.dictationMode = capture.dictationMode
        entry.dictationOriginal = capture.dictationOriginal

        // Dateien vor Bild vor Text: Finder liefert beim Kopieren einer Datei
        // auch ihren Namen als Text und ein Symbolbild.
        if !capture.filePaths.isEmpty {
            entry.kind = .files
            entry.filePaths = capture.filePaths
            entry.contentHash = ClipboardEntry.hash(paths: capture.filePaths)
            entry.preview = capture.filePaths.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
            return (entry, nil)
        }

        let text = capture.text.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }

        if let image = capture.imageData, text == nil {
            // TIFF ist unkomprimiert und darf größer sein; es zählt das PNG.
            guard image.count <= (capture.imageIsPNG ? limits.maxImageBytes : limits.maxImageBytes * 10) else { return nil }
            let png = capture.imageIsPNG ? image : ClipboardImageConverter.pngData(fromTIFF: image)
            guard let png, png.count <= limits.maxImageBytes else { return nil }
            ensureDirectory()
            let file = "\(id).png"
            guard writeFile(png, to: directory.appendingPathComponent(file)) else { return nil }
            let size = ClipboardImageConverter.pixelSize(of: png)
            entry.kind = .image
            entry.imageFile = file
            entry.imageWidth = size?.width
            entry.imageHeight = size?.height
            entry.imageBytes = png.count
            entry.contentHash = ClipboardEntry.hash(png)
            entry.preview = size.map { "Image \($0.width) × \($0.height)" } ?? "Image"
            storeArchive(capture, id: id, into: &entry)
            return (entry, nil)
        }

        guard let text, text.count <= limits.maxTextChars else { return nil }
        entry.kind = .text
        entry.contentHash = ClipboardEntry.hash(text: text)
        entry.preview = ClipboardEntry.makePreview(from: text)
        entry.charCount = text.count
        if text.count <= limits.maxInlineTextChars {
            entry.text = text
        } else {
            ensureDirectory()
            let file = "\(id).txt"
            guard writeFile(Data(text.utf8), to: directory.appendingPathComponent(file)) else { return nil }
            entry.textFile = file
        }
        // Mit Archiv (Tabelle mit Bild, App-Formate) liegt RTF und HTML schon darin.
        storeArchive(capture, id: id, into: &entry)
        if entry.archiveFile == nil {
            if let rtf = capture.rtf, rtf.count <= limits.maxRichBytes {
                ensureDirectory()
                let file = "\(id).rtf"
                if writeFile(rtf, to: directory.appendingPathComponent(file)) { entry.rtfFile = file }
            }
            if let html = capture.html, html.count <= limits.maxRichBytes {
                ensureDirectory()
                let file = "\(id).html"
                if writeFile(html, to: directory.appendingPathComponent(file)) { entry.htmlFile = file }
            }
        }
        return (entry, text)
    }
}

// MARK: - Nachsichtiges Lesen des Index

/// Liest `entries` Eintrag für Eintrag; was sich nicht lesen lässt, wird
/// übersprungen statt den ganzen Verlauf zu verwerfen.
private struct LossyIndexFile: Decodable {
    var entries: [ClipboardEntry] = []

    private enum CodingKeys: String, CodingKey { case entries }
    /// Nimmt jeden JSON-Wert an, ohne ihn zu lesen.
    private struct Skip: Decodable {
        init(from decoder: Decoder) throws {}
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var list = try container.nestedUnkeyedContainer(forKey: .entries)
        while !list.isAtEnd {
            if let entry = try? list.decode(ClipboardEntry.self) {
                entries.append(entry)
            } else if (try? list.decode(Skip.self)) == nil {
                break
            }
        }
    }
}
