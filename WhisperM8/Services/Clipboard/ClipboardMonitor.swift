import AppKit

// MARK: - Eigene Schreibvorgänge der App

/// Die App schreibt selbst auf die Zwischenablage (Diktat-Paste, Kontext-
/// Erfassung per Cmd+C mit Zurückschreiben, Einfügen aus dem Verlauf). Solche
/// Änderungen gehören nicht in den Verlauf, eine echte Kopie des Users direkt
/// daneben aber schon. Deshalb merkt sich die App genau die `changeCount`-
/// Stände, die sie selbst erzeugt hat (`claim`), statt ein Zeitfenster zu
/// sperren. Der Monitor übergeht nur diese Stände.
///
/// `begin()`/`end()` braucht nur, wer eine fremde App schreiben lässt (das
/// Cmd+C der Kontext-Erfassung): solange die Klammer offen ist, wartet der
/// Monitor, bis die entstandenen Stände beansprucht sind.
enum ClipboardInternalWrites {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var depth = 0
        var claimed: [(pasteboard: String, count: Int)] = []
    }

    private static let state = State()
    /// So viele Stände reichen für jeden eigenen Ablauf; ältere fallen heraus.
    static let claimLimit = 64

    static var isActive: Bool {
        state.lock.lock(); defer { state.lock.unlock() }
        return state.depth > 0
    }

    static func begin() {
        state.lock.lock(); defer { state.lock.unlock() }
        state.depth += 1
    }

    static func end() {
        state.lock.lock(); defer { state.lock.unlock() }
        state.depth = max(0, state.depth - 1)
    }

    /// Der aktuelle Stand von `pasteboard` stammt von der App.
    static func claim(_ pasteboard: NSPasteboard) {
        claim(count: pasteboard.changeCount, on: pasteboard)
    }

    /// Ein bestimmter Stand (oder mehrere hintereinander) stammt von der App.
    static func claim(count: Int, through last: Int? = nil, on pasteboard: NSPasteboard) {
        state.lock.lock(); defer { state.lock.unlock() }
        let name = pasteboard.name.rawValue
        let upper = max(count, last ?? count)
        // Mehr als `claimLimit` Stände am Stück kommen nicht vor; Schutz vor Unsinn.
        for value in max(count, upper - claimLimit + 1)...upper {
            state.claimed.append((name, value))
        }
        if state.claimed.count > claimLimit {
            state.claimed.removeFirst(state.claimed.count - claimLimit)
        }
    }

    static func isClaimed(_ count: Int, on pasteboard: NSPasteboard) -> Bool {
        state.lock.lock(); defer { state.lock.unlock() }
        let name = pasteboard.name.rawValue
        return state.claimed.contains { $0.pasteboard == name && $0.count == count }
    }

    /// Markiert Inhalt, den die App gerade selbst in einen Pasteboard-Eintrag schreibt.
    static func mark(_ item: NSPasteboardItem) {
        item.setData(Data([1]), forType: NSPasteboard.PasteboardType(ClipboardInternalMarker.typeName))
    }

    static func markPasteboard(_ pasteboard: NSPasteboard) {
        pasteboard.setData(Data([1]), forType: NSPasteboard.PasteboardType(ClipboardInternalMarker.typeName))
    }
}

// MARK: - Bilder

enum ClipboardImageConverter {
    static func pngData(fromTIFF tiff: Data) -> Data? {
        guard let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    static func tiffData(fromPNG png: Data) -> Data? {
        NSBitmapImageRep(data: png)?.tiffRepresentation
    }

    static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (width, height)
    }

    /// Verkleinerte Fassung für Liste und Vorschau, ohne das ganze Bild zu
    /// dekodieren (ein 5K-Screenshot wären sonst 60 MB je Miniatur).
    static func thumbnail(at url: URL, maxPixelSize: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}

// MARK: - Lesen der Zwischenablage (beliebiger Thread)

/// Liest alles, was der Verlauf von einer Kopie braucht. Läuft abseits des
/// Main Threads: große Bilder und lazy gelieferte Formate (Excel, Numbers)
/// zwingen die Quell-App sonst, auf unserem Main Thread zu liefern.
enum ClipboardPasteboardReader {
    struct Limits: Sendable {
        /// Obergrenze für alle Originaltypen zusammen; darüber nur Text, RTF, HTML und Bild.
        var maxArchiveBytes = 16 * 1024 * 1024
    }

    static func read(from pasteboard: NSPasteboard, limits: Limits = Limits()) -> ClipboardCapture {
        var capture = ClipboardCapture(types: pasteboard.types?.map(\.rawValue) ?? [])
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        capture.filePaths = urls.map(\.path)
        capture.text = pasteboard.string(forType: .string)
        // Dateien: die Pfade genügen, Finder liefert sonst Symbole in allen Größen mit.
        guard capture.filePaths.isEmpty else { return capture }

        let archived = archive(of: pasteboard, maxBytes: limits.maxArchiveBytes)
        capture.archive = archived
        // Mit Archiv liegt schon alles im Speicher; ohne (zu groß) einzeln lesen.
        func value(_ type: NSPasteboard.PasteboardType) -> Data? {
            if let archived {
                return archived.items.first?.first { $0.type == type.rawValue }?.data
            }
            return pasteboard.data(forType: type)
        }
        capture.rtf = value(.rtf)
        capture.html = value(.html)
        if let png = value(.png) {
            capture.imageData = png
            capture.imageIsPNG = true
        } else if let tiff = value(.tiff) {
            capture.imageData = tiff
        }
        return capture
    }

    /// Alle Einträge mit allen Typen; `nil`, sobald es mehr als `maxBytes` werden.
    static func archive(of pasteboard: NSPasteboard, maxBytes: Int) -> ClipboardArchive? {
        var total = 0
        var items: [[ClipboardRepresentation]] = []
        for item in pasteboard.pasteboardItems ?? [] {
            var representations: [ClipboardRepresentation] = []
            for type in item.types where type.rawValue != ClipboardInternalMarker.typeName {
                guard let data = item.data(forType: type) else { continue }
                total += data.count
                if total > maxBytes { return nil }
                representations.append(ClipboardRepresentation(type: type.rawValue, data: data))
            }
            if !representations.isEmpty { items.append(representations) }
        }
        return items.isEmpty ? nil : ClipboardArchive(items: items)
    }
}

// MARK: - Monitor

/// Beobachtet `changeCount` der allgemeinen Zwischenablage. Kosten im
/// Ruhezustand: ein Zähler-Vergleich zweimal pro Sekunde. Bei einer Änderung
/// prüft der Main Thread nur Typen und Herkunft; Lesen, Umwandeln und
/// Speichern laufen abseits davon.
@MainActor
final class ClipboardMonitor {
    private let pasteboard: NSPasteboard
    private let interval: TimeInterval
    private let settings: () -> ClipboardSettings
    private let frontmostApp: () -> (bundleID: String?, name: String?)
    private let store: ClipboardHistoryStore
    private let readTimeout: TimeInterval
    private var timer: Timer?
    private var lastChangeCount: Int
    private var reads: [Task<Void, Never>] = []

    /// Wie oft eine Änderung übergangen wurde (Tests, Diagnose).
    private(set) var skippedCount = 0

    /// Herkunft für einen Stand (`changeCount`), den ein eigenes Fenster selbst
    /// geschrieben hat, das die App davor vorn lässt (Verlaufsfenster, nicht
    /// aktivierend). Sonst gälte ⌘C in der Vorschau als Kopie aus der App davor,
    /// und wäre die ausgeschlossen, fiele die Kopie ganz weg. Nur für genau diesen
    /// Stand: was andere Apps schreiben, während das Fenster offen ist, behält
    /// die vordere App als Herkunft (Ausschlussliste greift). `nil`: die vordere App.
    var ownWindowSource: (@MainActor (_ changeCount: Int) -> (bundleID: String?, name: String?)?)?

    init(
        store: ClipboardHistoryStore,
        pasteboard: NSPasteboard = .general,
        interval: TimeInterval = 0.5,
        readTimeout: TimeInterval = 3,
        settings: @escaping () -> ClipboardSettings = { ClipboardSettings.readLive() },
        frontmostApp: @escaping () -> (bundleID: String?, name: String?) = {
            let app = NSWorkspace.shared.frontmostApplication
            return (app?.bundleIdentifier, app?.localizedName)
        }
    ) {
        self.store = store
        self.pasteboard = pasteboard
        self.interval = interval
        self.readTimeout = readTimeout
        self.settings = settings
        self.frontmostApp = frontmostApp
        self.lastChangeCount = pasteboard.changeCount
    }

    var isRunning: Bool { timer != nil }

    func start() {
        guard timer == nil else { return }
        // Was beim Einschalten schon in der Ablage liegt, wird nicht nachträglich
        // erfasst: seine Herkunft ist unbekannt, die Ausschlussliste griffe nicht.
        lastChangeCount = pasteboard.changeCount
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = interval * 0.4
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Ein Takt; auch von Tests direkt aufrufbar.
    func tick() {
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return }
        // Mitten in einer Kontext-Erfassung: abwarten, bis ihre Stände beansprucht sind.
        if ClipboardInternalWrites.isActive { return }
        lastChangeCount = count

        if ClipboardInternalWrites.isClaimed(count, on: pasteboard) {
            skippedCount += 1
            return
        }
        let current = settings()
        let types = pasteboard.types?.map(\.rawValue) ?? []
        let source = ownWindowSource?(count) ?? frontmostApp()
        let decision = ClipboardHistoryCore.decide(
            enabled: current.enabled, paused: current.paused, isInternalWrite: false,
            types: types, sourceBundleID: source.bundleID,
            excludedApps: Set(current.excludedApps)
        )
        guard decision == .store else {
            skippedCount += 1
            return
        }
        startRead(count: count, source: source, maxItems: current.maxItems)
    }

    /// Wartet auf laufende Lesevorgänge (Tests).
    func waitForReads() async {
        let pending = reads
        reads.removeAll()
        for task in pending { await task.value }
    }

    private func startRead(count: Int, source: (bundleID: String?, name: String?), maxItems: Int) {
        let pasteboard = pasteboard
        let store = store
        let timeout = readTimeout
        reads.removeAll { $0.isCancelled }
        let task = Task.detached(priority: .utility) {
            guard var capture = await Self.readWithTimeout(pasteboard, timeout: timeout) else {
                Logger.debug("clipboard_history_read_skipped reason=timeout")
                return
            }
            // Inzwischen kopiert der User schon das Nächste: das liest der nächste Takt.
            guard pasteboard.changeCount == count else { return }
            capture.sourceBundleID = source.bundleID
            capture.sourceName = source.name
            capture.date = Date()
            store.add(capture, maxItems: maxItems)
        }
        reads.append(task)
        if reads.count > 8 { reads.removeFirst(reads.count - 8) }
    }

    /// Liest im Hintergrund; hängt die Quell-App, wird der Lauf nicht abgewartet.
    nonisolated private static func readWithTimeout(_ pasteboard: NSPasteboard, timeout: TimeInterval) async -> ClipboardCapture? {
        final class Once: @unchecked Sendable {
            private let lock = NSLock()
            private var continuation: CheckedContinuation<ClipboardCapture?, Never>?
            init(_ continuation: CheckedContinuation<ClipboardCapture?, Never>) { self.continuation = continuation }
            func resume(_ value: ClipboardCapture?) {
                lock.lock()
                let pending = continuation
                continuation = nil
                lock.unlock()
                pending?.resume(returning: value)
            }
        }
        return await withCheckedContinuation { continuation in
            let once = Once(continuation)
            DispatchQueue.global(qos: .utility).async {
                once.resume(ClipboardPasteboardReader.read(from: pasteboard))
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                once.resume(nil)
            }
        }
    }
}
