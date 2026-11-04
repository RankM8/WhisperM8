import AppKit

// MARK: - Eigene Schreibvorgänge der App

/// Die App schreibt selbst auf die Zwischenablage (Diktat-Paste, Kontext-
/// Erfassung per Cmd+C mit Zurückschreiben, Einfügen aus dem Verlauf). Solche
/// Änderungen gehören nicht in den Verlauf. Wer schreibt, klammert mit
/// `begin()` und `end()`; der Monitor übergeht den Zähler währenddessen und
/// übernimmt danach den Stand als neue Grundlinie.
enum ClipboardInternalWrites {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var depth = 0
        var settled: (pasteboard: String, count: Int)?
    }

    private static let state = State()

    static var isActive: Bool {
        state.lock.lock(); defer { state.lock.unlock() }
        return state.depth > 0
    }

    static func begin() {
        state.lock.lock(); defer { state.lock.unlock() }
        state.depth += 1
    }

    static func end(pasteboard: NSPasteboard = .general) {
        state.lock.lock(); defer { state.lock.unlock() }
        state.depth = max(0, state.depth - 1)
        if state.depth == 0 { state.settled = (pasteboard.name.rawValue, pasteboard.changeCount) }
    }

    /// Einmal abholen: Zähler, den der Monitor als gesehen betrachten soll.
    static func takeSettledChangeCount(for pasteboard: NSPasteboard) -> Int? {
        state.lock.lock(); defer { state.lock.unlock() }
        guard let settled = state.settled, settled.pasteboard == pasteboard.name.rawValue else { return nil }
        state.settled = nil
        return settled.count
    }

    /// Markiert Inhalt, den die App gerade selbst in einen Pasteboard-Eintrag schreibt.
    static func mark(_ item: NSPasteboardItem) {
        item.setData(Data([1]), forType: NSPasteboard.PasteboardType(ClipboardInternalMarker.typeName))
    }

    static func markPasteboard(_ pasteboard: NSPasteboard) {
        pasteboard.setData(Data([1]), forType: NSPasteboard.PasteboardType(ClipboardInternalMarker.typeName))
    }
}

// MARK: - Bildumwandlung

enum ClipboardImageConverter {
    static func pngData(fromTIFF tiff: Data) -> Data? {
        guard let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    static func pixelSize(of png: Data) -> (width: Int, height: Int)? {
        guard let rep = NSBitmapImageRep(data: png) else { return nil }
        return (rep.pixelsWide, rep.pixelsHigh)
    }
}

// MARK: - Monitor

/// Beobachtet `changeCount` der allgemeinen Zwischenablage. Kosten im
/// Ruhezustand: ein Zähler-Vergleich zweimal pro Sekunde. Inhalt wird nur bei
/// einer Änderung gelesen; Umwandlung und Speichern laufen abseits des Main Threads.
@MainActor
final class ClipboardMonitor {
    private let pasteboard: NSPasteboard
    private let interval: TimeInterval
    private let settings: () -> ClipboardSettings
    private let frontmostApp: () -> (bundleID: String?, name: String?)
    private let store: ClipboardHistoryStore
    private var timer: Timer?
    private var lastChangeCount: Int

    /// Zuletzt aufgenommener Eintrag (für Tests und Statusanzeige).
    private(set) var skippedCount = 0

    init(
        store: ClipboardHistoryStore,
        pasteboard: NSPasteboard = .general,
        interval: TimeInterval = 0.5,
        settings: @escaping () -> ClipboardSettings = { ClipboardSettings.readLive() },
        frontmostApp: @escaping () -> (bundleID: String?, name: String?) = {
            let app = NSWorkspace.shared.frontmostApplication
            return (app?.bundleIdentifier, app?.localizedName)
        }
    ) {
        self.store = store
        self.pasteboard = pasteboard
        self.interval = interval
        self.settings = settings
        self.frontmostApp = frontmostApp
        self.lastChangeCount = pasteboard.changeCount
    }

    var isRunning: Bool { timer != nil }

    func start() {
        guard timer == nil else { return }
        // Was beim Einschalten schon in der Ablage liegt, wird nicht nachträglich erfasst.
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
        if let settled = ClipboardInternalWrites.takeSettledChangeCount(for: pasteboard) {
            lastChangeCount = settled
        }
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return }
        // Mitten in einem eigenen Schreibvorgang: abwarten, der Zähler wird danach übernommen.
        if ClipboardInternalWrites.isActive { return }
        lastChangeCount = count

        let current = settings()
        let types = pasteboard.types?.map(\.rawValue) ?? []
        let source = frontmostApp()
        let decision = ClipboardHistoryCore.decide(
            enabled: current.enabled, paused: current.paused, isInternalWrite: false,
            types: types, sourceBundleID: source.bundleID,
            excludedApps: Set(current.excludedApps)
        )
        guard decision == .store else {
            skippedCount += 1
            return
        }
        let capture = readCapture(types: types, source: source)
        store.add(capture, maxItems: current.maxItems)
    }

    private func readCapture(types: [String], source: (bundleID: String?, name: String?)) -> ClipboardCapture {
        var capture = ClipboardCapture(types: types, sourceBundleID: source.bundleID, sourceName: source.name)
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        capture.filePaths = urls.map(\.path)
        capture.text = pasteboard.string(forType: .string)
        if capture.filePaths.isEmpty {
            capture.rtf = pasteboard.data(forType: .rtf)
            capture.html = pasteboard.data(forType: .html)
            if let png = pasteboard.data(forType: .png) {
                capture.imageData = png
                capture.imageIsPNG = true
            } else if let tiff = pasteboard.data(forType: .tiff) {
                capture.imageData = tiff
            }
        }
        return capture
    }
}
