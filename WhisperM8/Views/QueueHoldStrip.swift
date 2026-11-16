import SwiftUI

/// Pille oben rechts im Terminal eines Chats: Meldungen aus der Warteschlange
/// warten (WM8-123). Liest nur den eigenen Eintrag in `QueueHoldNotices` und
/// in `JarvisNoteCardFootprints`; ändert er sich, wird nur diese Pille neu
/// ausgewertet, nicht die Chat-Ansicht.
///
/// Liegt als Überlagerung über dem Terminal und verschiebt nichts: Als
/// eigene Zeile darüber änderte sie beim Erscheinen und Verschwinden die
/// Höhe des Terminals, Claude zeichnete neu und das Bild sprang, oft mitten
/// beim Tippen. Oben rechts, weil Claudes Feld und Ausgabe links beginnen; ein
/// Streifen über die ganze Breite verdeckte in einem kurzen Chat genau das
/// Eingabefeld (Entscheidung Giuliano 16.11.2026).
///
/// Kein Hover-only: Der Grund steht immer in der Pille, an engen Stellen in
/// der Kurzfassung. Der Weg, wie die Meldung frei wird, steht in `.help` und
/// in der Bedienungshilfe. Ein Klick springt im Terminal ans Ende; dort ist
/// ein leeres Feld ablesbar, und die Warteschlange versucht es gleich neu.
/// Daneben geht jeder Klick ans Terminal.
struct QueueHoldStrip: View {
    let sessionID: UUID
    var onActivate: () -> Void = {}
    var notices: QueueHoldNotices = .shared
    var noteCards: JarvisNoteCardFootprints = .shared

    var body: some View {
        if let notice = notices.notices[sessionID] {
            let card = noteCards.footprints[sessionID]
            // Nur solange die Pille steht: die Breite des Terminals für das
            // Ausweichen vor der Notizkarte. Leere Flächen nehmen keine Maus an.
            GeometryReader { geometry in
                QueueHoldStripPlaced(
                    notice: notice,
                    insets: QueueHoldPlacement.insets(terminalWidth: geometry.size.width, card: card),
                    onActivate: onActivate)
            }
        }
    }
}

/// Pille mit Abständen, rechts oben in der gegebenen Fläche (auch Fixture).
struct QueueHoldStripPlaced: View {
    let notice: QueueHoldNotices.Notice
    var insets = QueueHoldPlacement.Insets(top: QueueHoldPlacement.topInset, leading: QueueHoldPlacement.leadingInset)
    var onActivate: () -> Void = {}
    var fixedTexts: QueueHoldStripContent.Texts?

    var body: some View {
        QueueHoldStripContent(notice: notice, onActivate: onActivate, fixedTexts: fixedTexts)
            .padding(.top, insets.top)
            .padding(.leading, insets.leading)
            .padding(.trailing, insets.trailing)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }
}

/// Der gezeichnete Teil, ohne Zustand (Snapshot-Fixture). Eine Zeile: Passt
/// der volle Text nicht, kommt die Kurzfassung („1 wartet · Text im Feld“),
/// passt auch die nicht, wird sie gekürzt statt umgebrochen.
struct QueueHoldStripContent: View {
    struct Texts: Equatable {
        var full: String
        var short: String
    }

    let notice: QueueHoldNotices.Notice
    var onActivate: () -> Void = {}
    /// Nur für Snapshots in einer festen Sprache; sonst aus dem Katalog.
    var fixedTexts: Texts?

    var body: some View {
        let text = fixedTexts?.full ?? QueueHoldNotices.text(for: notice)
        let short = fixedTexts?.short ?? QueueHoldNotices.shortText(for: notice)
        let hint = QueueHoldNotices.hint(for: notice) + " " + QueueHoldNotices.clickHint
        Button(action: onActivate) {
            ViewThatFits(in: .horizontal) {
                label(text)
                label(short)
            }
        }
        .buttonStyle(.plain)
        .help(hint)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: text))
        .accessibilityHint(Text(verbatim: hint))
        .accessibilityAddTraits(.isButton)
    }

    private func label(_ text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "tray.full")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.orange)
            Text(verbatim: text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AgentTheme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        // Deckend: Darunter läuft Terminal-Text, der sonst durchschiene.
        .background(Capsule().fill(Color.orange.opacity(0.14)))
        .background(Capsule().fill(AgentTheme.panel))
        .overlay(Capsule().strokeBorder(Color.orange.opacity(0.45), lineWidth: 1))
        .compositingGroup()
        .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
        .contentShape(Capsule())
    }
}

/// Wo die Pille steht. Pur und getestet. Im Raster hängt links unter dem
/// Kachelkopf die Jarvis-Notizkarte über dem Terminal; die Pille weicht ihr
/// aus: rechts daneben, solange dort die Kurzfassung Platz hat, sonst unter
/// die Karte.
enum QueueHoldPlacement {
    struct Insets: Equatable {
        var top: CGFloat
        var leading: CGFloat
        var trailing: CGFloat = QueueHoldPlacement.trailingInset
    }

    /// Höhe der Pille (11 pt Schrift, 4 pt Rand oben und unten, Linie).
    static let pillHeight: CGFloat = 22
    /// Abstand zur Kante der Karte, wenn die Pille in ihr sitzt.
    static let insideCardInset: CGFloat = 6

    /// Abstand zur Ecke des Terminals; rechts mehr, damit der Scroller frei bleibt.
    static let topInset: CGFloat = 6
    static let trailingInset: CGFloat = 16
    static let leadingInset: CGFloat = 8
    /// Abstand zur Notizkarte.
    static let cardGap: CGFloat = 8
    /// So breit braucht die Pille mindestens, damit die Kurzfassung ganz zu
    /// lesen ist (auch die längere deutsche, „3 warten · Ansicht offen“).
    static let minimumWidthBesideCard: CGFloat = 180

    static func insets(terminalWidth: CGFloat, card: JarvisNoteCardFootprint?) -> Insets {
        let plain = Insets(top: topInset, leading: leadingInset)
        guard let card else { return plain }
        // Karte in Koordinaten des Terminals: Sie hängt am Kachelkopf, das
        // Terminal beginnt darunter und eingerückt.
        let cardRight = card.trailingEdge - JarvisNoteCardFootprint.terminalInset
        let cardBottom = card.bottomEdge - JarvisNoteCardFootprint.terminalInset
        guard cardRight > 0, cardBottom > 0 else { return plain }
        let besideLeading = max(leadingInset, cardRight + cardGap)
        if terminalWidth - trailingInset - besideLeading >= minimumWidthBesideCard {
            return Insets(top: topInset, leading: besideLeading)
        }
        // Schmale Kachel: an die Unterkante der Karte heften, rechts und
        // innerhalb ihrer Fläche. Darunter läge sonst eine weitere Zeile
        // Terminal oder die Eingabezeile.
        return Insets(
            top: max(topInset, cardBottom - pillHeight - insideCardInset),
            leading: leadingInset,
            trailing: max(trailingInset, terminalWidth - cardRight + insideCardInset))
    }
}
