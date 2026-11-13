import Foundation

/// Zwischenablage-Verlauf für L1 + Kreuz (Runde 5): neuester Eintrag aus dem
/// Stand im Speicher, voller Text und Bild abseits des Main Thread.
@MainActor
enum LiveControllerClipboard {
    static func newest() -> ControllerClipPreview? {
        guard let entry = ClipboardHistoryController.shared.entries.max(by: { $0.lastCopiedAt < $1.lastCopiedAt }) else {
            return nil
        }
        switch entry.kind {
        case .text:
            let firstLine = entry.preview.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
            return ControllerClipPreview(id: entry.id, kind: .text, preview: String(firstLine.prefix(80)))
        case .image:
            return ControllerClipPreview(
                id: entry.id, kind: .image, preview: "", imageWidth: entry.imageWidth, imageHeight: entry.imageHeight)
        case .files:
            return nil
        }
    }

    static func loadText(id: String, completion: @escaping @MainActor (String?) -> Void) {
        let controller = ClipboardHistoryController.shared
        guard let entry = controller.entries.first(where: { $0.id == id }) else { return completion(nil) }
        let directory = controller.store.directory
        Task { @MainActor in
            let text = await Task.detached(priority: .userInitiated) {
                ClipboardHistoryStore.fullText(of: entry, directory: directory)
            }.value
            if text != nil { controller.store.bump(id: id) }
            completion(text)
        }
    }

    /// Schreibt das Bild in die allgemeine Zwischenablage. `ClipboardRestore`
    /// beansprucht den Schreibvorgang (`ClipboardInternalWrites.claim`), er
    /// landet also nicht noch einmal im Verlauf.
    static func copyImage(id: String, completion: @escaping @MainActor (Bool) -> Void) {
        let controller = ClipboardHistoryController.shared
        guard let entry = controller.entries.first(where: { $0.id == id }) else { return completion(false) }
        Task { @MainActor in
            completion(await controller.copyToPasteboard(entry))
        }
    }
}
