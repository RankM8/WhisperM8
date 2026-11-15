import AppKit
import SwiftUI

// MARK: - Ticket und Verlauf als ein Text

/// Stand der Kommentare des gezeigten Tickets.
enum TicketCommentsLoad: Equatable {
    case loading
    case loaded(TicketComments)
    /// Fertig übersetzter Grund.
    case failed(String)
}

/// Baut aus Titel, Beschreibung und Kommentaren EINEN `NSAttributedString`.
///
/// Warum kein SwiftUI-Baum: Ein Ticket mit langen Kommentaren hat schnell
/// tausend Zeilen. Als `Text` je Absatz wüchsen die Layout-Kosten mit dem
/// Inhalt, und jedes J/K baute alles neu auf. Derselbe Weg wie der
/// Chat-Verlauf (`TranscriptTextDocument`): Text abseits des Main Threads
/// bauen, im `NSTextView` nur setzen; TextKit 2 layoutet nur, was sichtbar ist.
///
/// Inhalte stammen von Kollegen und Chats: kein HTML, Links nur `http(s)`,
/// Bilder nur als Verweis „Bild in Linear“.
enum TicketTextDocument {
    struct Input: Equatable {
        var title: String
        var description: String
        var comments: TicketCommentsLoad
    }

    static let bodySize: CGFloat = 13
    /// Höchstens so viele Blöcke je Kommentar; der Rest steht in Linear.
    static let maxCommentBlocks = 200
    /// Höchstens so viele Kommentare (die neuesten). Das Setzen des Textes auf
    /// dem Main Thread wächst mit seiner Länge; so bleibt J/K auch bei einem
    /// Ticket mit langem Verlauf flüssig. Der Rest steht in Linear.
    static let maxComments = 40

    nonisolated static func make(_ input: Input) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let styles = Styles()
        result.append(NSAttributedString(string: input.title + "\n", attributes: styles.title))
        let blocks = TicketDescriptionBlocks.make(input.description)
        if blocks.isEmpty {
            result.append(NSAttributedString(string: String(localized: "No description.") + "\n", attributes: styles.muted))
        } else {
            append(blocks, to: result, styles: styles, base: styles.body)
        }
        result.append(NSAttributedString(string: "\n", attributes: styles.body))
        appendComments(input.comments, to: result, styles: styles)
        return result
    }

    // MARK: Kommentare

    private nonisolated static func appendComments(_ load: TicketCommentsLoad, to result: NSMutableAttributedString, styles: Styles) {
        switch load {
        case .loading:
            result.append(NSAttributedString(string: String(localized: "Activity") + "\n", attributes: styles.section))
            result.append(NSAttributedString(string: String(localized: "Loading comments…") + "\n", attributes: styles.muted))
        case .failed(let reason):
            result.append(NSAttributedString(string: String(localized: "Activity") + "\n", attributes: styles.section))
            result.append(NSAttributedString(string: String(localized: "Comments could not be loaded: \(reason)") + "\n",
                                             attributes: styles.muted))
        case .loaded(let comments):
            result.append(NSAttributedString(string: String(localized: "Activity · \(comments.items.count)") + "\n",
                                             attributes: styles.section))
            if comments.items.isEmpty {
                result.append(NSAttributedString(string: String(localized: "No comments yet.") + "\n", attributes: styles.muted))
            }
            for comment in comments.items.prefix(maxComments) {
                appendComment(comment, to: result, styles: styles)
            }
            if comments.hasMore || comments.items.count > maxComments {
                result.append(NSAttributedString(string: String(localized: "Older comments are in Linear.") + "\n",
                                                 attributes: styles.muted))
            }
        }
    }

    private nonisolated static func appendComment(_ comment: TicketComment, to result: NSMutableAttributedString, styles: Styles) {
        let highlighted = comment.kind != .plain
        var parts: [String] = []
        switch comment.kind {
        case .decision: parts.append(String(localized: "Decision"))
        case .completion: parts.append(String(localized: "Completion"))
        case .plain: break
        }
        if let date = comment.createdAt { parts.append(date.formatted(.dateTime.day().month().hour().minute())) }
        if !comment.author.isEmpty { parts.append(comment.author) }
        if comment.isReply { parts.append(String(localized: "reply")) }
        let marker = highlighted ? "◆ " : ""
        result.append(NSAttributedString(string: marker + parts.joined(separator: " · ") + "\n",
                                         attributes: highlighted ? styles.highlightHead : styles.commentHead))
        var blocks = TicketDescriptionBlocks.make(comment.body)
        if blocks.count > maxCommentBlocks {
            blocks = Array(blocks.prefix(maxCommentBlocks)) + [.truncated]
        }
        append(blocks, to: result, styles: styles, base: highlighted ? styles.highlightBody : styles.commentBody)
        result.append(NSAttributedString(string: "\n", attributes: styles.commentBody))
    }

    // MARK: Blöcke

    private nonisolated static func append(_ blocks: [TicketDescriptionBlock], to result: NSMutableAttributedString,
                                           styles: Styles, base: [NSAttributedString.Key: Any]) {
        for block in blocks {
            switch block {
            case .heading(let title):
                result.append(NSAttributedString(string: title + "\n", attributes: styles.merged(base, styles.heading)))
            case .check(let done, let text):
                var attributes = styles.merged(base, styles.listItem)
                if done { attributes[.foregroundColor] = styles.secondary }
                result.append(NSAttributedString(string: checkMark(done), attributes: attributes))
                appendInline(text, to: result, base: attributes, styles: styles)
            case .bullet(let text):
                let attributes = styles.merged(base, styles.listItem)
                result.append(NSAttributedString(string: "•\t", attributes: attributes))
                appendInline(text, to: result, base: attributes, styles: styles)
            case .numbered(let number, let text):
                let attributes = styles.merged(base, styles.listItem)
                result.append(NSAttributedString(string: number + "\t", attributes: attributes))
                appendInline(text, to: result, base: attributes, styles: styles)
            case .text(let text):
                appendInline(text, to: result, base: base, styles: styles)
            case .code(let line):
                result.append(NSAttributedString(string: line + "\n", attributes: styles.merged(base, styles.code)))
            case .gap:
                result.append(NSAttributedString(string: "\n", attributes: styles.merged(base, styles.gap)))
            case .truncated:
                result.append(NSAttributedString(string: String(localized: "The text continues in Linear.") + "\n",
                                                 attributes: styles.merged(base, styles.mutedOverlay)))
            }
        }
    }

    /// Kästchen als Zeichen; kein Text für die Übersetzung.
    private nonisolated static func checkMark(_ done: Bool) -> String {
        if done { return "☑\t" }
        return "☐\t"
    }

    /// Fettschrift, Kursiv, Code und Links aus dem schon geprüften
    /// `AttributedString` (`TicketDescriptionBlocks.inline` lässt nur Links ins
    /// Web stehen). Hier wird nur noch Schrift zugeordnet.
    private nonisolated static func appendInline(_ text: AttributedString, to result: NSMutableAttributedString,
                                                 base: [NSAttributedString.Key: Any], styles: Styles) {
        let font = base[.font] as? NSFont ?? styles.bodyFont
        for run in text.runs {
            var attributes = base
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.code) {
                    attributes[.font] = NSFont.monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular)
                } else {
                    var traits: NSFontDescriptor.SymbolicTraits = []
                    if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
                    if intent.contains(.emphasized) { traits.insert(.italic) }
                    if !traits.isEmpty {
                        let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(traits))
                        attributes[.font] = NSFont(descriptor: descriptor, size: font.pointSize) ?? font
                    }
                }
            }
            if let link = run.link, TicketDescriptionBlocks.isSafe(link) {
                attributes[.link] = link
            }
            result.append(NSAttributedString(string: String(text[run.range].characters), attributes: attributes))
        }
        result.append(NSAttributedString(string: "\n", attributes: base))
    }

    // MARK: Schriften und Farben

    /// Dynamische Farben: Hell und Dunkel wechseln ohne Neubau.
    struct Styles {
        let bodyFont = NSFont.systemFont(ofSize: TicketTextDocument.bodySize)
        let secondary = Styles.dynamic(light: NSColor.black.withAlphaComponent(0.55), dark: NSColor.white.withAlphaComponent(0.58))
        let primary = Styles.dynamic(light: NSColor.black.withAlphaComponent(0.88), dark: NSColor.white.withAlphaComponent(0.90))
        let accent = Styles.dynamic(light: NSColor(srgbRed: 0.37, green: 0.42, blue: 0.82, alpha: 1),
                                    dark: NSColor(srgbRed: 0.49, green: 0.52, blue: 0.91, alpha: 1))

        var body: [NSAttributedString.Key: Any] {
            [.font: bodyFont, .foregroundColor: primary, .paragraphStyle: paragraph(spacing: 2, after: 2)]
        }
        var title: [NSAttributedString.Key: Any] {
            [.font: NSFont.systemFont(ofSize: 19, weight: .bold), .foregroundColor: primary, .paragraphStyle: paragraph(spacing: 1, after: 10)]
        }
        var section: [NSAttributedString.Key: Any] {
            [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: secondary,
             .paragraphStyle: paragraph(spacing: 0, before: 14, after: 8), .kern: 0.4]
        }
        var heading: [NSAttributedString.Key: Any] {
            [.font: NSFont.systemFont(ofSize: 13.5, weight: .semibold), .paragraphStyle: paragraph(spacing: 1, before: 8, after: 3)]
        }
        var listItem: [NSAttributedString.Key: Any] {
            let style = paragraph(spacing: 2, after: 2)
            style.tabStops = [NSTextTab(textAlignment: .left, location: 18)]
            style.defaultTabInterval = 18
            style.headIndent = 18
            return [.paragraphStyle: style]
        }
        var code: [NSAttributedString.Key: Any] {
            [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: secondary]
        }
        var gap: [NSAttributedString.Key: Any] {
            [.font: NSFont.systemFont(ofSize: 6)]
        }
        var muted: [NSAttributedString.Key: Any] {
            [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: secondary, .paragraphStyle: paragraph(spacing: 2, after: 4)]
        }
        var mutedOverlay: [NSAttributedString.Key: Any] { [.foregroundColor: secondary] }
        var commentHead: [NSAttributedString.Key: Any] {
            [.font: NSFont.systemFont(ofSize: 11.5, weight: .semibold), .foregroundColor: secondary,
             .paragraphStyle: paragraph(spacing: 0, before: 10, after: 3)]
        }
        var highlightHead: [NSAttributedString.Key: Any] {
            var head = commentHead
            head[.foregroundColor] = accent
            return head
        }
        var commentBody: [NSAttributedString.Key: Any] {
            [.font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: primary, .paragraphStyle: paragraph(spacing: 2, after: 2)]
        }
        /// Entscheidung und Abschluss: Die Kopfzeile in Akzent mit ◆ hebt sie
        /// hervor. Ein Hintergrund je Textlauf wäre zerfranst (TextKit färbt
        /// nur die Zeichen, nicht die Zeile).
        var highlightBody: [NSAttributedString.Key: Any] { commentBody }

        func merged(_ base: [NSAttributedString.Key: Any], _ extra: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
            base.merging(extra) { _, new in new }
        }

        private func paragraph(spacing: CGFloat, before: CGFloat = 0, after: CGFloat = 0) -> NSMutableParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.lineSpacing = spacing
            style.paragraphSpacingBefore = before
            style.paragraphSpacing = after
            style.lineBreakMode = .byWordWrapping
            return style
        }

        static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
            NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            }
        }
    }
}

/// Der Text eines Tickets in EINEM `NSTextView` (TextKit 2), auswählbar und
/// durchsuchbar (⌘F). Ein neues Ticket beginnt oben.
struct TicketTextView: NSViewRepresentable {
    let document: NSAttributedString
    /// Wechselt mit jedem neuen Text; spart den Vergleich des ganzen Textes.
    let revision: Int
    /// Anderes Ticket: nach oben. Nachgeladene Kommentare: Stelle halten.
    let ticketKey: String

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView(usingTextLayoutManager: true)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 18, height: 14)
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.linkTextAttributes = [.underlineStyle: NSUnderlineStyle.single.rawValue, .cursor: NSCursor.pointingHand]
        textView.delegate = context.coordinator

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        textView.textStorage?.setAttributedString(document)
        context.coordinator.revision = revision
        context.coordinator.ticketKey = ticketKey
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard context.coordinator.revision != revision, let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.revision = revision
        textView.textStorage?.setAttributedString(document)
        if context.coordinator.ticketKey != ticketKey {
            context.coordinator.ticketKey = ticketKey
            textView.scroll(.zero)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var revision = -1
        var ticketKey = ""

        /// Zweite Sicherung: Nur Links ins Web öffnen.
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
            guard let url, TicketDescriptionBlocks.isSafe(url) else { return true }
            return false
        }
    }
}
