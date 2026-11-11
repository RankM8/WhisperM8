import SwiftUI

/// Durchsuchbares Dropdown des „Neuer Chat"-Split-Buttons: alle Projekte
/// (Badge + Name + Branch), das aktuelle Ziel markiert, plus „Projekt
/// hinzufügen…".
///
/// Eigene View mit eigenem Zustand: Suchbegriff und Markierung ändern sich bei
/// jedem Pfeil-Schritt (Tastatur oder Controller). Lägen sie in der
/// `AgentChatsView`, würde jeder Schritt das ganze Fenster samt Seitenleiste
/// neu auswerten — das machte die Auswahl spürbar träge. Beim Öffnen entsteht
/// die View neu, Suchbegriff und Markierung starten also immer frisch.
struct NewChatProjectPicker: View {
    /// Projekte in Anzeige-Reihenfolge (manuell hinzugefügte, sortiert).
    let projects: [AgentProject]
    /// Aktuelles Ziel-Projekt (Häkchen).
    let selectedProjectID: UUID?
    /// Vorauswahl beim Öffnen (Controller „Create“), einmalig abgeholt.
    let takePreferredProjectID: () -> UUID?
    let onPick: (AgentProject) -> Void
    let onAddProject: () -> Void
    let onDismiss: () -> Void

    @State private var query = ""
    /// Markiertes Ergebnis (aktive Auswahl). `nil` = keine Markierung (leere
    /// Ergebnisliste → Enter tut nichts).
    @State private var highlightedID: UUID?
    /// Zeitpunkt des letzten Pfeil-Schritts. Scrollt die Liste dabei unter
    /// dem ruhenden Mauszeiger weiter, meldet SwiftUI ein Hover auf der Zeile
    /// darunter — das darf die Markierung nicht zurückziehen.
    @State private var lastKeyMove = Date.distantPast
    /// Zählt Pfeil-Schritte und Filterwechsel. Nur sie scrollen die Liste —
    /// ein Hover darf sie nicht bewegen, sonst kriecht sie unter einem
    /// ruhenden Mauszeiger an der Randzeile weiter.
    @State private var scrollRequest = 0
    @FocusState private var searchFocused: Bool

    private var filteredProjects: [AgentProject] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return projects }
        return projects.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    var body: some View {
        let visible = filteredProjects
        let ids = visible.map(\.id)
        return VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(AgentTheme.textTertiary)
                TextField("Search projects…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($searchFocused)
                    .accessibilityLabel("Search projects")
                    .onSubmit { confirmHighlighted(in: visible) }
            }
            .padding(.horizontal, 11)
            .frame(height: 36)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(visible) { project in
                            row(project)
                                .id(project.id)
                        }
                        if visible.isEmpty {
                            (query.isEmpty ? Text("No projects yet") : Text("No project found"))
                                .font(.system(size: 11))
                                .foregroundStyle(AgentTheme.textTertiary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 260)
                // Die Markierung bleibt nach Pfeil-Schritten sichtbar: nur so
                // weit scrollen, wie nötig (Anker nil), ohne Animation, damit
                // gehaltene Pfeile nicht hinterherlaufen.
                .onChange(of: scrollRequest) {
                    guard let highlightedID else { return }
                    proxy.scrollTo(highlightedID)
                }
                .onAppear {
                    searchFocused = true
                    // Schutzzeit wie nach einem Pfeil-Schritt: Ein Mauszeiger,
                    // der beim Öffnen schon über der Liste steht, übernimmt die
                    // Vorauswahl nicht.
                    lastKeyMove = Date()
                    // Vorauswahl vom Controller (Create), sonst das erste Projekt.
                    highlightedID = ProjectPickerKeyboard.normalize(takePreferredProjectID(), in: ids)
                    if let highlightedID {
                        // Erst nach dem ersten Layout steht die Zeile bereit.
                        DispatchQueue.main.async { proxy.scrollTo(highlightedID) }
                    }
                }
            }

            Divider()

            Button {
                onAddProject()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 12))
                        .frame(width: 16)
                    Text("Add project…")
                        .font(.system(size: 12, weight: .medium))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(AgentTheme.textSecondary)
                .padding(.horizontal, 11)
                .frame(height: 38)
                .contentShape(Rectangle())
            }
            .buttonStyle(PopoverRowButtonStyle())
        }
        .frame(width: 270)
        .background(AgentTheme.panel)
        // Pfeiltasten bubblen aus dem fokussierten (einzeiligen) Suchfeld hoch:
        // Up/Down navigieren die Ergebnisse, Left/Right bleiben Cursor im Feld.
        .onKeyPress(.downArrow) {
            step(1, in: ids)
            return .handled
        }
        .onKeyPress(.upArrow) {
            step(-1, in: ids)
            return .handled
        }
        .onKeyPress(.escape) {
            onDismiss()
            return .handled
        }
        // Filterwechsel: Markierung auf gültige Auswahl bzw. erstes Ergebnis setzen.
        .onChange(of: query) {
            highlightedID = ProjectPickerKeyboard.normalize(highlightedID, in: filteredProjects.map(\.id))
            scrollRequest += 1
        }
    }

    private func row(_ project: AgentProject) -> some View {
        let isHighlighted = project.id == highlightedID
        return Button {
            onPick(project)
        } label: {
            HStack(spacing: 8) {
                ProjectAvatar(project: project, size: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(project.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AgentTheme.textPrimary)
                        .lineLimit(1)
                    Text(project.lastBranch ?? project.path)
                        .font(.system(size: 11))
                        .foregroundStyle(AgentTheme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
                if project.id == selectedProjectID {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(AgentTheme.accent)
                }
            }
            .padding(.horizontal, 11)
            .frame(height: 36)
            .background(isHighlighted ? AgentTheme.hover : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(PopoverRowButtonStyle())
        .accessibilityAddTraits(isHighlighted ? .isSelected : [])
        .onHover { inside in
            guard inside, Date().timeIntervalSince(lastKeyMove) > 0.4 else { return }
            highlightedID = project.id
        }
    }

    private func step(_ direction: Int, in ids: [UUID]) {
        lastKeyMove = Date()
        highlightedID = ProjectPickerKeyboard.move(from: highlightedID, in: ids, direction: direction)
        scrollRequest += 1
    }

    /// Enter im Suchfeld: öffnet das markierte Projekt. Tut bei leerer
    /// Ergebnisliste nichts.
    private func confirmHighlighted(in visible: [AgentProject]) {
        guard let id = highlightedID,
              let project = visible.first(where: { $0.id == id }) else { return }
        onPick(project)
    }
}
