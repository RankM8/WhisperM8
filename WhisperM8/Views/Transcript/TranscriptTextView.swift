import AppKit
import SwiftUI

/// Baut aus den gerenderten Zeilen den fertigen `NSAttributedString`.
///
/// Läuft bewusst OFF-MAIN (`Task.detached` im Container): Das Erzeugen der
/// Attribute ist linear zur Textmenge und damit die einzige Stelle, deren
/// Kosten noch mit der Verlaufslänge wachsen. Das anschließende Setzen im
/// `NSTextView` ist billig — TextKit layoutet erst, was sichtbar wird.
enum TranscriptTextDocument {
    /// Feste Schriftgröße und Zeilenhöhe. Die feste Höhe ist kein
    /// Schönheitsdetail: ein gleichmäßiges Raster macht TextKits
    /// Höhenschätzung für die Scrollbar präzise, auch bei sehr langen
    /// Verläufen.
    static let fontSize: CGFloat = 11.5
    static let lineHeight: CGFloat = 16

    nonisolated static func make(lines: [TranscriptTextLine]) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let boldFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .semibold)

        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        // Umbruch statt horizontalem Scrollen: in schmalen Grid-Panes ist
        // seitliches Scrollen unbrauchbar. Weiches Wrapping kostet TextKit
        // nur eine Schätzung der Restgeometrie — die Layout-Arbeit selbst
        // bleibt auf den sichtbaren Ausschnitt beschränkt.
        paragraph.lineBreakMode = .byWordWrapping
        // Fortsetzungszeilen eines umgebrochenen Absatzes rücken ein, damit
        // die Marker-Spalte (❯ / ⏺ / ⎿) optisch stehen bleibt.
        paragraph.headIndent = 14

        let result = NSMutableAttributedString()
        for line in lines {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: line.style == .prompt ? boldFont : font,
                .foregroundColor: color(for: line.style),
                .paragraphStyle: paragraph
            ]
            result.append(NSAttributedString(string: line.text + "\n", attributes: attributes))
        }
        return result
    }

    /// Dynamische Farben (wie `AppTheme.dynamic`): der Text passt sich beim
    /// Wechsel zwischen Hell und Dunkel von selbst an — der Verlauf muss
    /// dafür nicht neu gebaut werden.
    private nonisolated static func color(for style: TranscriptTextLine.Style) -> NSColor {
        switch style {
        case .prompt:
            return dynamic(light: NSColor.black.withAlphaComponent(0.90),
                           dark: NSColor.white.withAlphaComponent(0.94))
        case .answer:
            return dynamic(light: NSColor.black.withAlphaComponent(0.82),
                           dark: NSColor.white.withAlphaComponent(0.84))
        case .tool:
            return dynamic(light: NSColor(srgbRed: 0.28, green: 0.42, blue: 0.66, alpha: 1),
                           dark: NSColor(srgbRed: 0.55, green: 0.68, blue: 0.95, alpha: 1))
        case .toolOutput:
            return dynamic(light: NSColor.black.withAlphaComponent(0.52),
                           dark: NSColor.white.withAlphaComponent(0.50))
        case .toolError:
            return dynamic(light: NSColor(srgbRed: 0.84, green: 0.28, blue: 0.24, alpha: 1),
                           dark: NSColor(srgbRed: 0.90, green: 0.40, blue: 0.35, alpha: 1))
        case .thinking:
            return dynamic(light: NSColor.black.withAlphaComponent(0.40),
                           dark: NSColor.white.withAlphaComponent(0.38))
        case .meta, .blank:
            return dynamic(light: NSColor.black.withAlphaComponent(0.38),
                           dark: NSColor.white.withAlphaComponent(0.34))
        }
    }

    private nonisolated static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }
}

/// Der Verlauf als EIN `NSTextView` mit TextKit 2.
///
/// Das ist der Kern der Umstellung: Statt einer SwiftUI-View-Hierarchie pro
/// Nachricht (deren Layout-Kosten mit dem Inhalt wachsen und die App bei
/// großen Transcripts eingefroren haben) gibt es genau eine Textansicht.
/// TextKit 2 layoutet ausschließlich den sichtbaren Ausschnitt; Textauswahl
/// über den gesamten Verlauf, ⌘F und Kopieren kommen nativ dazu.
struct TranscriptTextView: NSViewRepresentable {
    /// Fertig gebauter Text — off-main erzeugt, hier nur noch gesetzt.
    let document: NSAttributedString
    /// Wechselt, sobald `document` ein anderer Stand ist. Ohne dieses Token
    /// müsste `updateNSView` den kompletten Text vergleichen.
    let revision: Int

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView(usingTextLayoutManager: true)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 12, height: 10)
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        // ⌘F über die native Find-Bar — ersetzt die 14 einzelnen
        // `.textSelection(.enabled)` der alten Views, von denen jedes eine
        // eigene NSView im Layout-Pfad erzeugt hat.
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true

        apply(document, to: textView, in: scrollView, forceScrollToEnd: true)
        context.coordinator.revision = revision
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard context.coordinator.revision != revision,
              let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.revision = revision
        // „Am Ende kleben" nur, wenn der User dort auch steht — sonst reißt
        // ein Live-Update ihn aus der Stelle, die er gerade liest.
        let wasAtBottom = isNearBottom(scrollView)
        apply(document, to: textView, in: scrollView, forceScrollToEnd: wasAtBottom)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var revision: Int = -1
    }

    private func apply(
        _ text: NSAttributedString,
        to textView: NSTextView,
        in scrollView: NSScrollView,
        forceScrollToEnd: Bool
    ) {
        textView.textStorage?.setAttributedString(text)
        guard forceScrollToEnd else { return }
        // Nach dem Setzen kennt TextKit die Gesamthöhe noch nicht — erst im
        // nächsten Runloop-Turn steht die Geometrie, dann ans Ende springen.
        DispatchQueue.main.async {
            textView.scrollToEndOfDocument(nil)
        }
    }

    private func isNearBottom(_ scrollView: NSScrollView) -> Bool {
        let clip = scrollView.contentView
        let visibleMax = clip.bounds.origin.y + clip.bounds.height
        let documentHeight = scrollView.documentView?.bounds.height ?? 0
        return documentHeight - visibleMax < 40
    }
}
