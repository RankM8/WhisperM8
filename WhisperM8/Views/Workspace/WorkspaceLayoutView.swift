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
///
/// **Warum eine Kopfleiste je Zelle statt einer Geste auf der ganzen Flaeche:**
/// Der Inhalt ist ein `NSView` (SwiftTerm), das Mausereignisse selbst
/// verarbeitet. Eine Ziehgeste ueber der Flaeche wuerde entweder gar nicht
/// ausloesen oder die Textmarkierung im Terminal zerstoeren. Die Leiste ist der
/// einzige Ort, an dem beides nebeneinander funktioniert — und sie macht das
/// Ziehen ueberhaupt erst auffindbar.
///
/// **Kein `.draggable`:** Die Kombination `LazyVStack` + `.draggable` hat die
/// App im Mai 2026 eingefroren (Fix `60ca683`, Kommentar in
/// `AgentChatsSidebarViews.swift:199`). Hier laeuft alles ueber eine
/// `DragGesture`, deren Zustandsuebergaenge in `LayoutDragState` liegen —
/// getrennt geprueft, ohne Maus.
struct WorkspaceLayoutView<Content: View>: View {
    let layout: WorkspaceLayout
    /// Welche Session gerade den Fokus hat — nur zur Darstellung.
    var focusedSessionID: UUID?
    /// Abstand zwischen den Flaechen, in Punkten.
    var gap: CGFloat = 1
    /// Beschriftung der Kopfleiste; ohne Zuordnung greift ein Platzhalter.
    var titleForSession: (UUID) -> String = { _ in "Chat" }
    /// Wird gerufen, wenn eine Flaeche angeklickt wird.
    var onFocus: (UUID) -> Void = { _ in }
    /// Wird gerufen, wenn im Stapel gewechselt wird.
    var onActivate: (UUID) -> Void = { _ in }
    /// Ein Zug wurde ueber einem gueltigen Ziel losgelassen. Der Aufrufer
    /// wendet ihn ueber `LayoutEngine` an — die Ansicht aendert nie selbst.
    var onDrop: (UUID, LayoutDropResolver.Target) -> Void = { _, _ in }
    /// Der Inhalt einer Flaeche.
    @ViewBuilder let content: (UUID) -> Content

    /// Der laufende Zug. Alle Uebergaenge stecken in der Zustandsmaschine,
    /// hier steht nur, was gerade zu zeichnen ist.
    @State private var drag = LayoutDragState()

    /// Eigener Koordinatenraum: Die Geste meldet Positionen relativ zur
    /// Layout-Flaeche, damit sie ohne Umrechnung zu den `frames` passen.
    private static var space: String { "workspace.layout" }

    var body: some View {
        GeometryReader { proxy in
            let frames = LayoutGeometry.frames(
                for: layout,
                in: CGRect(origin: .zero, size: proxy.size)
            )

            ZStack(alignment: .topLeading) {
                // Bewusst kein verschachteltes Splitter-Layout: Die Geometrie
                // ist bereits ausgerechnet, jede Flaeche wird direkt gesetzt.
                // Das haelt die View-Hierarchie flach — SwiftUI muss beim
                // Umsortieren nur Rahmen aendern, keine Baeume umbauen.
                ForEach(layout.cells) { cell in
                    if let frame = frames[cell.id] {
                        cellView(cell, in: frame, frames: frames)
                            .frame(width: max(frame.width - gap, 0),
                                   height: max(frame.height - gap, 0))
                            .offset(x: frame.minX, y: frame.minY)
                    }
                }

                // Die Zielvorschau liegt ueber allem und faengt nichts ab.
                // Ohne sie waere die Zwei-Zonen-Regel ein Ratespiel: Ring
                // ersetzt, Kern stapelt, Kante teilt — das sieht man sonst
                // erst am Ergebnis.
                dropPreview(frames: frames)
                    .allowsHitTesting(false)
            }
            .coordinateSpace(name: Self.space)
        }
        .background(AgentTheme.background)
    }

    // MARK: - Flaeche

    @ViewBuilder
    private func cellView(
        _ cell: WorkspaceLayout.Cell,
        in frame: CGRect,
        frames: [UUID: CGRect]
    ) -> some View {
        let isFocused = cell.sessions.contains { $0 == focusedSessionID }
        let isDragSource = drag.draggedSession.map { cell.sessions.contains($0) } ?? false

        VStack(spacing: 0) {
            WorkspaceCellBar(
                cell: cell,
                titleForSession: titleForSession,
                onActivate: onActivate
            )
            .gesture(dragGesture(for: cell, frames: frames))

            // `.id(cell.active)` bindet den Inhalt an die SESSION, nicht an die
            // Zelle oder ihre Position. Wandert ein Chat in eine andere Zelle,
            // bleibt seine Ansicht dieselbe — und damit sein Terminal.
            content(cell.active)
                .id(cell.active)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(AgentTheme.background)
        // Die Quelle blasst ab, solange sie gezogen wird — sonst sieht es aus,
        // als passiere nichts.
        .opacity(isDragSource ? 0.55 : 1)
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

    // MARK: - Ziehen

    /// `minimumDistance: 0`, damit die Geste ab dem ersten Ereignis meldet —
    /// die Entscheidung „Klick oder Zug" faellt in `LayoutDragState` an der
    /// dort gepruefen Schwelle, nicht in SwiftUI.
    private func dragGesture(
        for cell: WorkspaceLayout.Cell,
        frames: [UUID: CGRect]
    ) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
            .onChanged { value in
                if case .idle = drag.phase {
                    drag.begin(session: cell.active, at: value.startLocation)
                }
                drag.move(to: value.location, frames: frames, sourceCellID: cell.id)
            }
            .onEnded { _ in
                // `end()` liefert nur bei echtem Zug MIT Ziel etwas zurueck.
                // Alles andere war ein Klick — und ein Klick fokussiert.
                if let ergebnis = drag.end() {
                    onDrop(ergebnis.session, ergebnis.target)
                } else {
                    onFocus(cell.active)
                }
            }
    }

    // MARK: - Zielvorschau

    @ViewBuilder
    private func dropPreview(frames: [UUID: CGRect]) -> some View {
        switch drag.target {
        case let .replace(cellID):
            if let frame = frames[cellID] {
                previewShape(in: frame, filled: false)
            }

        case let .stack(cellID):
            if let frame = frames[cellID] {
                // Der Kern, wie ihn der Resolver versteht — die Vorschau zeigt
                // dieselbe Flaeche, gegen die spaeter aufgeloest wird.
                previewShape(in: coreRect(of: frame), filled: true)
            }

        case let .edge(cellID, edge):
            if let frame = frames[cellID] {
                previewShape(in: edgeStrip(of: frame, edge: edge), filled: true)
            }

        case .none:
            EmptyView()
        }
    }

    @ViewBuilder
    private func previewShape(in rect: CGRect, filled: Bool) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(AgentTheme.accent.opacity(filled ? 0.22 : 0.08))
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(AgentTheme.accent.opacity(0.9), lineWidth: 2)
            }
            .frame(width: max(rect.width, 0), height: max(rect.height, 0))
            .offset(x: rect.minX, y: rect.minY)
    }

    /// Der innere Kern einer Flaeche — dieselbe Rechnung wie im Resolver.
    private func coreRect(of frame: CGRect) -> CGRect {
        let breite = frame.width * LayoutDropResolver.coreFraction
        let hoehe = frame.height * LayoutDropResolver.coreFraction
        return CGRect(
            x: frame.midX - breite / 2,
            y: frame.midY - hoehe / 2,
            width: breite,
            height: hoehe
        )
    }

    /// Der Streifen an einer Kante, an der eine neue Flaeche entstehen wuerde.
    private func edgeStrip(of frame: CGRect, edge: LayoutEngine.Edge) -> CGRect {
        let waagerecht = min(
            frame.width * LayoutDropResolver.edgeFraction,
            LayoutDropResolver.maximumEdgeInset
        )
        let senkrecht = min(
            frame.height * LayoutDropResolver.edgeFraction,
            LayoutDropResolver.maximumEdgeInset
        )

        switch edge {
        case .leading:
            return CGRect(x: frame.minX, y: frame.minY, width: waagerecht, height: frame.height)
        case .trailing:
            return CGRect(x: frame.maxX - waagerecht, y: frame.minY, width: waagerecht, height: frame.height)
        case .top:
            return CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: senkrecht)
        case .bottom:
            return CGRect(x: frame.minX, y: frame.maxY - senkrecht, width: frame.width, height: senkrecht)
        }
    }
}

/// Die Kopfleiste einer Flaeche — Beschriftung, Stapelwechsel und Griff zum
/// Ziehen in einem.
///
/// Sie erscheint bei JEDER Zelle, nicht nur bei gestapelten: Ohne sie gaebe es
/// keinen Ort, an dem sich eine Flaeche anfassen laesst, ohne dem Terminal
/// darunter die Maus wegzunehmen. Bei einem einzelnen Chat zeigt sie nur
/// dessen Titel.
struct WorkspaceCellBar: View {
    let cell: WorkspaceLayout.Cell
    var titleForSession: (UUID) -> String = { _ in "Chat" }
    var onActivate: (UUID) -> Void = { _ in }

    var body: some View {
        HStack(spacing: 2) {
            if cell.isStacked {
                ForEach(cell.sessions, id: \.self) { session in
                    Button {
                        onActivate(session)
                    } label: {
                        label(for: session)
                    }
                    .buttonStyle(.plain)
                }
            } else {
                label(for: cell.active)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity)
        .background(AgentTheme.background)
        // Der ganze Streifen ist Griff — auch die Luecken zwischen den Titeln.
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func label(for session: UUID) -> some View {
        Text(titleForSession(session))
            .font(.system(size: 11, weight: session == cell.active ? .semibold : .regular))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                session == cell.active && cell.isStacked
                    ? AgentTheme.accent.opacity(0.18)
                    : Color.clear
            )
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
