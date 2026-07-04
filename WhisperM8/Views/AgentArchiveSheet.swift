import SwiftUI

/// Pure Gruppierungs-/Sortier-/Suchlogik des Archiv-Sheets — ohne View-State
/// testbar (`AgentArchiveSheetTests`). Sortier-Key ist `archivedAt` (Fallback
/// `lastActivityAt` nur für Legacy-Archivierte ohne Zeitstempel), weil der
/// Indexer `lastActivityAt` auch für archivierte Sessions weiter bumpt.
enum AgentArchiveListBuilder {
    struct Group: Equatable {
        /// `nil` = Sammelgruppe „Ohne Projekt" (verwaiste `projectID`, defensiv —
        /// `deleteProject` entfernt archivierte Sessions normalerweise mit).
        let project: AgentProject?
        let sessions: [AgentChatSession]
    }

    static func sortKey(_ session: AgentChatSession) -> Date {
        session.archivedAt ?? session.lastActivityAt
    }

    static func build(
        sessions: [AgentChatSession],
        projects: [AgentProject],
        query: String
    ) -> [Group] {
        let projectByID = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)

        let matching = sessions.filter { session in
            guard !trimmedQuery.isEmpty else { return true }
            if session.title.localizedCaseInsensitiveContains(trimmedQuery) { return true }
            if let name = projectByID[session.projectID]?.name,
               name.localizedCaseInsensitiveContains(trimmedQuery) {
                return true
            }
            return false
        }

        var sessionsByProject: [UUID?: [AgentChatSession]] = [:]
        for session in matching {
            let key: UUID? = projectByID[session.projectID] != nil ? session.projectID : nil
            sessionsByProject[key, default: []].append(session)
        }

        var groups: [Group] = sessionsByProject.map { key, group in
            Group(
                project: key.flatMap { projectByID[$0] },
                sessions: group.sorted { sortKey($0) > sortKey($1) }
            )
        }
        // Jüngste Gruppe zuerst; die „Ohne Projekt"-Sammelgruppe immer ans Ende.
        groups.sort { lhs, rhs in
            switch (lhs.project, rhs.project) {
            case (nil, nil): return false
            case (nil, _): return false
            case (_, nil): return true
            default:
                let lhsNewest = lhs.sessions.first.map(sortKey) ?? .distantPast
                let rhsNewest = rhs.sessions.first.map(sortKey) ?? .distantPast
                return lhsNewest > rhsNewest
            }
        }
        return groups
    }
}

/// Archiv-Sheet (Footer-Button der Sidebar): nach Projekt gruppierte Liste
/// archivierter Chats mit Suche und „Wiederherstellen". Reine Anzeige —
/// die Datenmutation läuft über die Callbacks in AgentChatsView.
struct AgentArchiveSheet: View {
    /// Vorgefilterte archivierte Sessions (`archivedSessionsForSheet` in
    /// AgentChatsView — geteilt mit dem Footer-Badge, damit Count und Liste
    /// nie auseinanderlaufen).
    let sessions: [AgentChatSession]
    let projects: [AgentProject]
    var onRestore: (AgentChatSession) -> Void
    var onClose: () -> Void

    @State private var searchText = ""

    private var groups: [AgentArchiveListBuilder.Group] {
        AgentArchiveListBuilder.build(sessions: sessions, projects: projects, query: searchText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if sessions.isEmpty {
                emptyState(
                    title: "Keine archivierten Chats",
                    detail: "Archivierte Chats landen hier und lassen sich jederzeit wiederherstellen."
                )
            } else {
                searchField
                if groups.isEmpty {
                    emptyState(title: "Keine Treffer für „\(searchText)“", detail: nil)
                } else {
                    groupedList
                }
            }
        }
        .padding(18)
        .frame(width: 480, height: 520)
        .background(AgentTheme.panel)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "archivebox")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(AgentTheme.textSecondary)
            Text("Archiv")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AgentTheme.textPrimary)
            Text("\(sessions.count)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AgentTheme.textTertiary)
            Spacer()
            Button("Fertig") { onClose() }
                .keyboardShortcut(.cancelAction)
        }
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AgentTheme.textTertiary)
            TextField("Suchen…", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(AgentTheme.surface, in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(AgentTheme.border, lineWidth: 1))
    }

    private var groupedList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                    Text((group.project?.name ?? "Ohne Projekt").uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.6)
                        .foregroundStyle(AgentTheme.textTertiary)
                        .padding(.horizontal, 10)
                        .padding(.top, 10)
                        .padding(.bottom, 4)

                    ForEach(group.sessions) { session in
                        ArchivedSessionRow(
                            session: session,
                            project: group.project,
                            onRestore: { onRestore(session) }
                        )
                    }
                }
            }
        }
    }

    private func emptyState(title: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AgentTheme.textSecondary)
            if let detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(AgentTheme.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.top, 8)
    }
}

/// Zeile im Archiv-Sheet: Projekt-Badge + Titel, rechts Relativzeit der
/// Archivierung bzw. bei Hover der Wiederherstellen-Button. Bewusst NICHT
/// `SessionListButton` — dessen Status-Dots/Hover-X/Drag wären hier falsch.
private struct ArchivedSessionRow: View {
    let session: AgentChatSession
    let project: AgentProject?
    var onRestore: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onRestore) {
            HStack(spacing: 8) {
                if let project {
                    ProjectAvatar(project: project, size: 14)
                } else {
                    ProviderIcon(provider: session.provider, size: 11, tint: AgentTheme.textTertiary)
                        .frame(width: 14, alignment: .center)
                }

                Text(session.title)
                    .font(.system(size: 12))
                    .foregroundStyle(AgentTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(session.title)

                Spacer(minLength: 0)

                if isHovered {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 9, weight: .bold))
                        Text("Wiederherstellen")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(AgentTheme.textSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(AgentTheme.hover, in: RoundedRectangle(cornerRadius: 3))
                    .help("Wiederherstellen — Chat erscheint wieder in der Sidebar")
                } else {
                    Text(archivedLabel)
                        .font(.system(size: 10))
                        .foregroundStyle(AgentTheme.textTertiary)
                }
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 28, maxHeight: 28, alignment: .leading)
            .background(
                isHovered ? AgentTheme.hover : Color.clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }

    private var archivedLabel: String {
        let relative = SidebarRelativeTime.short(AgentArchiveListBuilder.sortKey(session))
        return relative == "jetzt" ? "gerade archiviert" : "archiviert vor \(relative)"
    }
}
