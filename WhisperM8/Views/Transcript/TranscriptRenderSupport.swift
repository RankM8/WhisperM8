import Foundation

/// Harte Render-Deckel für Transcript-Inhalte (Absturz-Schutz, 2026-07-16):
/// SwiftUI/CoreText layoutet einen `Text` mit Megabyte-Inhalt sekundenlang
/// auf dem Main-Thread und explodiert dabei im Speicher — injizierte
/// System-Prompts oder gepastete Blobs haben so beim Hochscrollen die ganze
/// App eingefroren und gekillt. Deshalb wird JEDER frei skalierende String
/// vor dem `Text(...)` geclippt; der volle Inhalt bleibt in der Roh-Ansicht
/// bzw. der Quell-JSONL erhalten (wir werfen nichts weg, wir rendern nur
/// bounded).
enum TranscriptRenderLimits {
    /// Prompt-Bubble der Timeline (User-Text).
    static let promptChars = 12_000
    /// Gesamter Markdown-Input einer Antwort (vor dem Block-Parse).
    static let markdownChars = 40_000
    /// Einzelner Roh-Block (Text/Thinking/Teammate-Payload).
    static let rawBlockChars = 20_000
    /// Steps, die eine aufgeklappte Aktivitätszeile maximal rendert.
    static let expandedSteps = 400

    struct Clipped {
        let text: String
        /// Abgeschnittene Zeichen (0 = nichts geclippt).
        let truncatedCount: Int
        var isTruncated: Bool { truncatedCount > 0 }
    }

    /// Deckelt `text` auf `max` Zeichen. Nutzt `count` erst nach dem billigen
    /// UTF8-Vor-Check — `String.count` ist O(n) und soll den Normalfall
    /// (kurzer Text) nicht bestrafen.
    static func clip(_ text: String, max: Int) -> Clipped {
        // utf8.count ist O(1)-nah (kontiguierlicher Speicher) und eine obere
        // Schranke der Zeichenzahl — liegt sie unter dem Limit, ist nichts zu tun.
        guard text.utf8.count > max else { return Clipped(text: text, truncatedCount: 0) }
        let characterCount = text.count
        guard characterCount > max else { return Clipped(text: text, truncatedCount: 0) }
        return Clipped(
            text: String(text.prefix(max)),
            truncatedCount: characterCount - max
        )
    }

    /// Einheitlicher Hinweistext unter geclipptem Inhalt.
    static func truncationHint(_ truncatedCount: Int) -> String {
        "… \(truncatedCount) weitere Zeichen — vollständig in der Roh-Ansicht"
    }
}

/// Prozessweiter Cache der teuren Render-Vorstufen: Markdown-Block-Parse und
/// `AttributedString(markdown:)` liefen bisher bei JEDEM Body-Aufruf jeder
/// materialisierten Zeile auf dem Main-Thread — beim Hochscrollen (LazyVStack
/// materialisiert Zeile für Zeile neu) war das der Haupt-Hänger. Der Cache
/// macht Scroll-Zurück und Re-Renders zu Dictionary-Lookups.
///
/// NSCache ist thread-safe und wirft unter Memory-Pressure selbst aus;
/// die Limits halten die Keys (die Texte selbst) bounded.
final class MarkdownRenderCache {
    static let shared = MarkdownRenderCache()

    private final class BlocksBox {
        let blocks: [MarkdownBlock]
        init(_ blocks: [MarkdownBlock]) { self.blocks = blocks }
    }
    private final class InlineBox {
        let attributed: AttributedString?
        init(_ attributed: AttributedString?) { self.attributed = attributed }
    }

    private let blocksCache = NSCache<NSString, BlocksBox>()
    private let inlineCache = NSCache<NSString, InlineBox>()

    init() {
        blocksCache.countLimit = 512
        inlineCache.countLimit = 4096
    }

    /// Geparste Blöcke für einen (bereits geclippten) Markdown-Text.
    func blocks(for text: String) -> [MarkdownBlock] {
        let key = text as NSString
        if let hit = blocksCache.object(forKey: key) { return hit.blocks }
        let parsed = MarkdownBlockParser.parse(text)
        blocksCache.setObject(BlocksBox(parsed), forKey: key)
        return parsed
    }

    /// Inline-Markdown (fett, `code`, Links) tolerant aufgelöst; `nil` wenn
    /// der Text kein parsebares Markdown ist (Aufrufer fällt auf Plaintext
    /// zurück).
    func inlineAttributed(for raw: String) -> AttributedString? {
        let key = raw as NSString
        if let hit = inlineCache.object(forKey: key) { return hit.attributed }
        let attributed = try? AttributedString(
            markdown: raw,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )
        inlineCache.setObject(InlineBox(attributed), forKey: key)
        return attributed
    }
}
