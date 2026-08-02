import SwiftUI

/// Zeichnet ein `WorkspaceLayout` — die Flaechen kommen aus `LayoutGeometry`,
/// der Inhalt vom Aufrufer.
///
/// **Warum generisch:** Die Ansicht kennt keine Terminals. Sie bekommt eine
/// Session-ID und fragt den Aufrufer, was dort hineingehoert. Das haelt sie
/// frei von der Chat-Logik und macht sie ohne laufende App pruefbar.
///
/// **Die Regel, an der alles haengt:** Ein Terminal darf beim Umsortieren
/// niemals neu aufgebaut werden — ein neuer PTY heisst Scrollback weg,
/// laufender Befehl weg. Deshalb ist die Identitaet einer Flaeche die
/// Session-ID (`.id(sessionID)`), nicht ihre Position, und der Inhalt haengt
/// direkt unter dem `ForEach` ohne Zwischenschichten, die bei Umsortierung die
/// Sicht-Identitaet aendern koennten. Der Zaehler `pane.mounted` deckt jeden
/// Verstoss auf.
struct WorkspaceLayoutView<Content: View>: View {
    let layout: WorkspaceLayout
    /// Welche Session gerade den Fokus hat — nur zur Darstellung.
    var focusedSessionID: UUID?
    /// Abstand zwischen den Flaechen, in Punkten.
    var gap: CGFloat = 1
    /// Wird gerufen, wenn eine Flaeche angeklickt wird.
    var onFocus: (UUID) -> Void = { _ in }
    /// Wird gerufen, wenn im Stapel gewechselt wird.
    var onActivate: (UUID) -> Void = { _ in }
    /// Der Inhalt einer Flaeche.
    @ViewBuilder let content: (UUID) -> Content

    var body: some View {
        GeometryReader { proxy in
            let frames = LayoutGeometry.frames(for: layout, in: CGRect(origin: .zero, size: proxy.size))

            ZStack(alignment: .topLeading) {
                // Bewusst kein verschachteltes Splitter-Layout: Die Geometrie
                // ist bereits ausgerechnet, jede Flaeche wird direkt gesetzt.
                // Das haelt die View-Hierarchie flach — SwiftUI muss beim
                // Umsortieren nur Rahmen aendern, keine Baeume umbauen.
                ForEach(layout.cells) { cell in
                    if let frame = frames[cell.id] {
                        cellView(cell, in: frame)
                            .frame(width: max(frame.width - gap, 0),
                                   height: max(frame.height - gap, 0))
                            .offset(x: frame.minX, y: frame.minY)
                    }
                }
            }
        }
        .background(AgentTheme.background)
    }

    @ViewBuilder
    private func cellView(_ cell: WorkspaceLayout.Cell, in frame: CGRect) -> some View {
        let isFocused = cell.sessions.contains { $0 == focusedSessionID }

        VStack(spacing: 0) {
            if cell.isStacked {
                WorkspaceStackBar(
                    cell: cell,
                    onActivate: onActivate
                )
            }
            // `.id(cell.active)` bindet den Inhalt an die SESSION, nicht an die
            // Zelle oder ihre Position. Wandert ein Chat in eine andere Zelle,
            // bleibt seine Ansicht dieselbe — und damit sein Terminal.
            content(cell.active)
                .id(cell.active)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(AgentTheme.background)
        .overlay {
            if isFocused {
                Rectangle()
                    .strokeBorder(AgentTheme.accent.opacity(0.8), lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onFocus(cell.active) }
    }
}

/// Die Leiste ueber einer Zelle mit mehreren Chats.
///
/// Sie erscheint nur, wenn tatsaechlich gestapelt ist — eine Zelle mit einem
/// einzigen Chat zeigt keine Leiste und verliert dadurch keine Hoehe.
struct WorkspaceStackBar: View {
    let cell: WorkspaceLayout.Cell
    var onActivate: (UUID) -> Void = { _ in }
    /// Wird zur Beschriftung gebraucht; ohne Zuordnung greift ein Platzhalter.
    var titleForSession: (UUID) -> String = { _ in "Chat" }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(cell.sessions, id: \.self) { session in
                Button {
                    onActivate(session)
                } label: {
                    Text(titleForSession(session))
                        .font(.system(size: 11, weight: session == cell.active ? .semibold : .regular))
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            session == cell.active
                                ? AgentTheme.accent.opacity(0.18)
                                : Color.clear
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(AgentTheme.background)
    }
}
