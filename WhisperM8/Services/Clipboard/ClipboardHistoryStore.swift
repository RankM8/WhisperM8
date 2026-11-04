import Foundation

// MARK: - Persistenz des Verlaufs

/// Index (`index.json`) plus Blob-Dateien unter
/// `~/Library/Application Support/WhisperM8/clipboard-history/`.
/// Ordner 0700, Dateien 0600. Die App ist einziger Schreiber; die CLI liest
/// über `loadIndex(directory:)` direkt von Disk.
///
/// Alle Änderungen laufen auf einer seriellen Queue, der Index wird gebündelt
/// (Debounce) und atomar geschrieben. Der Main Thread blockiert nie.
final class ClipboardHistoryStore: @unchecked Sendable {
    static let schema = "wm8.clipboard/1"
    static let indexFileName = "index.json"

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
    private var loaded = false
    private var flushPending = false
    /// Wird (auf beliebigem Thread) nach jeder Änderung gerufen.
    var onChange: (@Sendable ([ClipboardEntry]) -> Void)?

    init(directory: URL = ClipboardHistoryStore.defaultDirectory(), limits: Limits = Limits(), debounceSeconds: Double = 0.6) {
        self.directory = directory
        self.limits = limits
        self.debounceSeconds = debounceSeconds
    }

    // MARK: Lesen (CLI und App)

    /// Liest den Index von Disk; fehlende oder kaputte Datei = leerer Verlauf.
    static func loadIndex(directory: URL) -> [ClipboardEntry] {
        let url = directory.appendingPathComponent(indexFileName)
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        return (try? decoder.decode(IndexFile.self, from: data))?.entries ?? []
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

    func snapshot() -> [ClipboardEntry] {
        queue.sync {
            loadIfNeeded()
            return entries
        }
    }

    /// Nimmt einen erfassten Inhalt auf (aufbereiten, Duplikate, Kürzen).
    /// Läuft auf der Store-Queue; `completion` kommt von dort.
    func add(_ capture: ClipboardCapture, maxItems: Int, completion: (@Sendable (ClipboardHistoryCore.SkipReason?) -> Void)? = nil) {
        queue.async { [self] in
            loadIfNeeded()
            guard let entry = makeEntry(from: capture) else {
                completion?(.empty)
                return
            }
            let inserted = ClipboardHistoryCore.insert(entry, into: entries)
            entries = inserted.entries
            for file in inserted.discardedBlobs { removeBlob(file) }
            let trimmed = ClipboardHistoryCore.trim(entries, maxUnpinned: maxItems)
            entries = trimmed.kept
            for removed in trimmed.removed { removeBlobs(of: removed) }
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
            changed()
        }
    }

    /// Entfernt alles; `keepPinned` lässt Angepinnte stehen.
    func clear(keepPinned: Bool = false) {
        queue.async { [self] in
            loadIfNeeded()
            let (kept, removed) = keepPinned
                ? (entries.filter(\.isPinned), entries.filter { !$0.isPinned })
                : ([], entries)
            for entry in removed { removeBlobs(of: entry) }
            entries = kept
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
        entries = Self.loadIndex(directory: directory)
    }

    private func changed() {
        let current = entries
        onChange?(current)
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
    private func writeFile(_ data: Data, to url: URL) {
        let temp = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.close()
            if rename(temp.path, url.path) != 0 { try? FileManager.default.removeItem(at: temp) }
        } catch {
            try? FileManager.default.removeItem(at: temp)
        }
    }

    private func removeBlob(_ file: String) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(file))
    }

    private func removeBlobs(of entry: ClipboardEntry) {
        for file in entry.blobFiles { removeBlob(file) }
    }

    // MARK: Aufbereiten

    private func makeEntry(from capture: ClipboardCapture) -> ClipboardEntry? {
        let id = UUID().uuidString.lowercased()
        var entry = ClipboardEntry(
            id: id, kind: .text, createdAt: capture.date, lastCopiedAt: capture.date, copyCount: 1,
            isPinned: false, sourceBundleID: capture.sourceBundleID, sourceName: capture.sourceName,
            contentHash: "", preview: ""
        )

        // Dateien vor Bild vor Text: Finder liefert beim Kopieren einer Datei
        // auch ihren Namen als Text und ein Symbolbild.
        if !capture.filePaths.isEmpty {
            entry.kind = .files
            entry.filePaths = capture.filePaths
            entry.contentHash = ClipboardEntry.hash(paths: capture.filePaths)
            entry.preview = capture.filePaths.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
            return entry
        }

        if let image = capture.imageData, capture.text?.isEmpty ?? true {
            guard image.count <= limits.maxImageBytes else { return nil }
            let png = capture.imageIsPNG ? image : ClipboardImageConverter.pngData(fromTIFF: image)
            guard let png, png.count <= limits.maxImageBytes else { return nil }
            ensureDirectory()
            let file = "\(id).png"
            writeFile(png, to: directory.appendingPathComponent(file))
            let size = ClipboardImageConverter.pixelSize(of: png)
            entry.kind = .image
            entry.imageFile = file
            entry.imageWidth = size?.width
            entry.imageHeight = size?.height
            entry.imageBytes = png.count
            entry.contentHash = ClipboardEntry.hash(png)
            entry.preview = size.map { "Image \($0.width) × \($0.height)" } ?? "Image"
            return entry
        }

        guard let text = capture.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.count <= limits.maxTextChars else { return nil }
        entry.kind = .text
        entry.contentHash = ClipboardEntry.hash(text: text)
        entry.preview = ClipboardEntry.makePreview(from: text)
        if text.count <= limits.maxInlineTextChars {
            entry.text = text
        } else {
            ensureDirectory()
            let file = "\(id).txt"
            writeFile(Data(text.utf8), to: directory.appendingPathComponent(file))
            entry.textFile = file
        }
        if let rtf = capture.rtf, rtf.count <= limits.maxRichBytes {
            ensureDirectory()
            let file = "\(id).rtf"
            writeFile(rtf, to: directory.appendingPathComponent(file))
            entry.rtfFile = file
        }
        if let html = capture.html, html.count <= limits.maxRichBytes {
            ensureDirectory()
            let file = "\(id).html"
            writeFile(html, to: directory.appendingPathComponent(file))
            entry.htmlFile = file
        }
        return entry
    }
}
