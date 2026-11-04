import AppKit

// MARK: - Einträge zurück in die Zwischenablage

/// Baut aus einem Eintrag, was in die Zwischenablage kommt. Der Aufbau ist
/// rein (Dateien lesen, kein AppKit-Fenster) und läuft abseits des Main
/// Threads; geschrieben wird danach auf dem Main Thread mit Markierung, damit
/// der Monitor den eigenen Stand übergeht.
enum ClipboardRestore {
    enum Payload: Equatable {
        /// Pasteboard-Einträge mit allen Typen (Reihenfolge = Vorrang).
        case items([[ClipboardRepresentation]])
        case files([String])
    }

    static let plainTextType = NSPasteboard.PasteboardType.string.rawValue

    /// `plain`: nur reiner Text (⌥↩). Sonst so vollständig wie gespeichert:
    /// das Archiv aller Originaltypen, wenn es eins gibt.
    static func payload(
        for entry: ClipboardEntry,
        plain: Bool,
        directory: URL,
        makeTIFF: (Data) -> Data? = ClipboardImageConverter.tiffData(fromPNG:)
    ) -> Payload? {
        func blob(_ file: String?) -> Data? {
            file.flatMap { try? Data(contentsOf: ClipboardHistoryStore.blobURL($0, directory: directory)) }
        }
        switch entry.kind {
        case .files:
            let paths = entry.filePaths ?? []
            return paths.isEmpty ? nil : .files(paths)
        case .text:
            guard let text = ClipboardHistoryStore.fullText(of: entry, directory: directory) else { return nil }
            let plainItem = [ClipboardRepresentation(type: plainTextType, data: Data(text.utf8))]
            if plain { return .items([plainItem]) }
            if let archive = blob(entry.archiveFile).flatMap(ClipboardArchive.decode), !archive.items.isEmpty {
                return .items(archive.items)
            }
            var item = plainItem
            if let rtf = blob(entry.rtfFile) { item.append(ClipboardRepresentation(type: NSPasteboard.PasteboardType.rtf.rawValue, data: rtf)) }
            if let html = blob(entry.htmlFile) { item.append(ClipboardRepresentation(type: NSPasteboard.PasteboardType.html.rawValue, data: html)) }
            return .items([item])
        case .image:
            if !plain, let archive = blob(entry.archiveFile).flatMap(ClipboardArchive.decode), !archive.items.isEmpty {
                return .items(archive.items)
            }
            guard let png = blob(entry.imageFile) else { return nil }
            var item = [ClipboardRepresentation(type: NSPasteboard.PasteboardType.png.rawValue, data: png)]
            // Ältere Apps nehmen nur TIFF; die Umwandlung läuft hier, abseits des Main Threads.
            if let tiff = makeTIFF(png) {
                item.append(ClipboardRepresentation(type: NSPasteboard.PasteboardType.tiff.rawValue, data: tiff))
            }
            return .items([item])
        }
    }

    /// Schreibt und beansprucht den neuen Stand (der Monitor übergeht ihn).
    @MainActor
    @discardableResult
    static func write(_ payload: Payload, to pasteboard: NSPasteboard) -> Bool {
        pasteboard.clearContents()
        let written: Bool
        switch payload {
        case .files(let paths):
            written = pasteboard.writeObjects(paths.map { URL(fileURLWithPath: $0) as NSURL })
        case .items(let items):
            let objects = items.enumerated().map { index, representations -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for representation in representations {
                    item.setData(representation.data, forType: NSPasteboard.PasteboardType(representation.type))
                }
                if index == 0 { ClipboardInternalWrites.mark(item) }
                return item
            }
            written = pasteboard.writeObjects(objects)
        }
        ClipboardInternalWrites.claim(pasteboard)
        return written
    }
}
