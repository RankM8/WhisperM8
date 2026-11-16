import SwiftUI
@testable import WhisperM8

/// Pille „Meldung wartet“ oben rechts im Terminal (WM8-123) über
/// nachgestelltem Terminal: langer Chat, kurzer Chat mit dem Feld ganz oben
/// (darf frei bleiben), Board-Spalte bei Mindestbreite 280 pt englisch und mit
/// der längeren deutschen Fassung (Kurzfassung statt Abschneiden), Codex, und
/// im Raster mit offener Jarvis-Notizkarte: breite Kachel (Pille rechts neben
/// der Karte) und schmale Kachel (Pille an der Unterkante der Karte).
extension UISnapshotGallery {
    static let queueHoldLongChat = [
        "⏺ Die Pille liegt jetzt oben rechts im Terminal und verschiebt nichts.",
        "  ⎿  Read WhisperM8/Views/QueueHoldStrip.swift (160 lines)",
        "⏺ Snapshots für hell und dunkel sind gerendert.",
        "  ⎿  make snapshots ONLY=warteschlange-hinweis",
        "",
        "> Bitte noch die Doku zum Snapshot ergänz",
    ]
    static let queueHoldShortChat = ["> Bitte noch die Doku zum Snapshot ergänz", "  ? for shortcuts"]
    static let queueHoldCodex = [
        "• Ran swift test --filter QueueHoldTests",
        "  └ Executed 14 tests, with 0 failures",
        "",
        "▌ Bitte noch die Doku zum Snapshot ergänz",
    ]
    static let queueHoldGerman = QueueHoldStripContent.Texts(
        full: "3 Meldungen warten: Eine Ansicht von Claude ist offen", short: "3 warten · Ansicht offen")

    @MainActor
    static func queueHoldTerminal(_ lines: [String], height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(verbatim: line.isEmpty ? " " : line)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(AgentTheme.textPrimary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 6)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: height, alignment: .top)
        .background(AgentTheme.background)
    }

    /// Terminal ohne Kachel (Einzelansicht, Board-Spalte).
    @MainActor
    static func queueHoldPane(_ notice: QueueHoldNotices.Notice, lines: [String], width: CGFloat? = nil,
                              texts: QueueHoldStripContent.Texts? = nil) -> some View {
        queueHoldTerminal(lines, height: 96)
            .overlay { QueueHoldStripPlaced(notice: notice, fixedTexts: texts) }
            .frame(width: width)
            .clipped()
    }

    /// Kachel im Raster: Kopf, darunter eingerückt das Terminal, links unter
    /// dem Kopf die offene Notizkarte. Die Pille rechnet wie in der App.
    @MainActor
    static func queueHoldTile(width: CGFloat, card: CGSize) -> some View {
        let inset = JarvisNoteCardFootprint.terminalInset
        let header: CGFloat = 28
        let footprint = JarvisNoteCardFootprint(trailingEdge: 10 + card.width, bottomEdge: card.height)
        let terminalWidth = width - 2 * inset
        let insets = QueueHoldPlacement.insets(terminalWidth: terminalWidth, card: footprint)
        return VStack(spacing: 0) {
            HStack {
                Text(verbatim: "Ben · WM8-123").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AgentTheme.textSecondary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(height: header)
            .background(AgentTheme.header)
            queueHoldTerminal(queueHoldLongChat, height: 190)
                .overlay { QueueHoldStripPlaced(notice: .init(count: 1, reason: .textInField), insets: insets) }
                .padding(.top, inset)
                .padding(.horizontal, inset)
                .padding(.bottom, 8)
                .background(AgentTheme.background)
        }
        .overlay(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: "Arbeitspaket").font(.system(size: 11, weight: .semibold))
                Text(verbatim: "WM8-123 Pille weicht der Karte aus").font(.system(size: 11))
            }
            .foregroundStyle(AgentTheme.textPrimary)
            .padding(8)
            .frame(width: card.width, height: card.height, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 7).fill(AgentTheme.header))
            .padding(.leading, 10)
            .padding(.top, header)
        }
        .frame(width: width)
        .clipped()
    }

    @MainActor
    static func queueHoldFixture() -> Fixture {
        Fixture(name: "warteschlange-hinweis", size: CGSize(width: 820, height: 760)) {
            AnyView(VStack(alignment: .leading, spacing: 12) {
                queueHoldPane(.init(count: 3, reason: .textInField), lines: queueHoldLongChat)
                HStack(alignment: .top, spacing: 12) {
                    queueHoldPane(.init(count: 1, reason: .textInField), lines: queueHoldShortChat)
                    queueHoldPane(.init(count: 1, reason: .textInField, fieldReadable: false), lines: queueHoldCodex)
                }
                HStack(alignment: .top, spacing: 12) {
                    queueHoldPane(.init(count: 1, reason: .viewOpen), lines: queueHoldLongChat, width: 280)
                    queueHoldPane(.init(count: 3, reason: .viewOpen), lines: queueHoldLongChat, width: 280,
                                  texts: queueHoldGerman)
                }
                HStack(alignment: .top, spacing: 12) {
                    queueHoldTile(width: 500, card: CGSize(width: 240, height: 96))
                    queueHoldTile(width: 290, card: CGSize(width: 200, height: 96))
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(AgentTheme.sidebar))
        }
    }
}
