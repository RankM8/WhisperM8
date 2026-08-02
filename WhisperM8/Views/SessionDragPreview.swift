import SwiftUI

/// Das Bild, das am Zeiger haengt, waehrend ein Chat gezogen wird.
///
/// **Warum ueberhaupt eins:** Ohne eigenes Vorschaubild nimmt SwiftUI einen
/// Abzug der gezogenen Ansicht. Bei einer Grid-Pane ist das die halbe
/// Fensterflaeche samt Terminal — in der Praxis sieht man davon nichts
/// Brauchbares, und der Zug wirkt, als haette die Maus gar nichts gepackt
/// (Nutzerbefund 02.08.2026). Ein kleiner beschrifteter Chip beantwortet
/// beide Fragen auf einen Blick: dass gezogen wird, und was.
struct SessionDragPreview: View {
    let title: String
    /// Wird bei mehreren gezogenen Chats angezeigt.
    var count: Int = 1

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: count > 1 ? "square.stack.3d.up.fill" : "bubble.left.and.text.bubble.right")
                .font(.system(size: 11, weight: .semibold))
            Text(count > 1 ? "\(count) Chats" : title)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: 260, alignment: .leading)
        .foregroundStyle(.white)
        .background(AgentTheme.accent.opacity(0.95), in: RoundedRectangle(cornerRadius: 6))
        .shadow(color: .black.opacity(0.28), radius: 6, y: 2)
    }
}
