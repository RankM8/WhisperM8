import SwiftUI

/// Pure Gruppierungs-/Sortier-/Suchlogik des Archiv-Modus — ohne View-State
/// testbar (`AgentArchiveListBuilderTests`). Sortier-Key ist `archivedAt`
/// (Fallback `lastActivityAt` nur für Legacy-Archivierte ohne Zeitstempel),
/// weil der Indexer `lastActivityAt` auch für archivierte Sessions weiter bumpt.
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

/// Archiv-Modus der Sidebar (Footer-Button): dieselbe Chat-Listen-UI wie die
/// normale Ansicht — Projekt-Ordner mit Chevron/Avatar/Count und
/// `SessionListButton`-Zeilen — nur eben mit archivierten Chats und
/// „Wiederherstellen" als einziger Aktion. Kein eigener Filter in der
/// Scope-Bar; der Modus ersetzt die Liste komplett und hat einen klaren
/// Zurück-Header.
extension AgentChatsView {
    /// Ersetzt Befehlszeilen + Scope-Bar + Chat-Liste, solange der
    /// Archiv-Modus aktiv ist (Footer bleibt sichtbar).
    @ViewBuilder
    var archiveSidebarContent: some View {
        archiveSidebarHeader
        archiveSearchField

        ScrollView {
            let groups = AgentArchiveListBuilder.build(
                sessions: archivedSidebarSessions,
                projects: workspace.projects,
                query: archiveSearchText
            )
            VStack(alignment: .leading, spacing: 2) {
                if archivedSidebarSessions.isEmpty {
                    archiveEmptyState(
                        title: "Keine archivierten Chats",
                        detail: "Archivierte Chats landen hier und lassen sich jederzeit wiederherstellen."
                    )
                } else if groups.isEmpty {
                    archiveEmptyState(title: "Keine Treffer für „\(archiveSearchText)“", detail: nil)
                } else {
                    ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                        ArchiveProjectGroup(
                            project: group.project,
                            sessions: group.sessions,
                            statusStore: runtimeStatusStore,
                            onRestore: { restoreArchivedSession($0) }
                        )
                    }
                }
            }
            .padding(.vertical, 6)
        }
    }

    /// Kopfzeile des Archiv-Modus: Zurück-Pfeil + Titel + Anzahl.
    private var archiveSidebarHeader: some View {
        HStack(spacing: 6) {
            Button {
                exitArchiveMode()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10, weight: .bold))
                    Text("Zurück")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .foregroundStyle(AgentTheme.textSecondary)
                .padding(.horizontal, 8)
                .frame(minHeight: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Archiv verlassen (Esc)")

            Spacer(minLength: 0)

            HStack(spacing: 5) {
                Image(systemName: "archivebox")
                    .font(.system(size: 10, weight: .semibold))
                Text("Archiv · \(archivedSidebarSessions.count)")
                    .font(.system(size: 11.5, weight: .semibold))
            }
            .foregroundStyle(AgentTheme.textPrimary)
        }
        .padding(.horizontal, 8)
        .padding(.top, 2)
        .padding(.bottom, 6)
    }

    /// Suchfeld des Archiv-Modus — gleiche Optik wie das normale „Filter…"-
    /// Feld, aber eigener State, damit der Sidebar-Filter nicht ins Archiv
    /// leakt (und umgekehrt).
    private var archiveSearchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AgentTheme.textTertiary)
            TextField("Archiv durchsuchen…", text: $archiveSearchText)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))
            if !archiveSearchText.isEmpty {
                Button {
                    archiveSearchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(AgentTheme.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9)
        .frame(maxWidth: .infinity, minHeight: 30, maxHeight: 30)
        .background(AgentTheme.control, in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 8)
        .padding(.bottom, 2)
    }

    func exitArchiveMode() {
        archiveModeActive = false
        archiveSearchText = ""
    }

    private func archiveEmptyState(title: String, detail: String?) -> some View {
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
        .padding(.horizontal, 14)
        .padding(.top, 10)
    }
}

/// Projektgruppe im Archiv-Modus: gleiche Optik wie `ProjectChatGroup`
/// (Chevron + ProjectAvatar + Name + Count, `SessionListButton`-Zeilen),
/// aber ohne Drag/Drop, ohne Projekt-Kontextmenü und mit „Wiederherstellen"
/// als Row-Aktion (Klick UND Hover-Button).
struct ArchiveProjectGroup: View {
    /// `nil` = Sammelgruppe „Ohne Projekt" (verwaiste Sessions).
    let project: AgentProject?
    let sessions: [AgentChatSession]
    let statusStore: AgentSessionRuntimeStatusStore
    var onRestore: (AgentChatSession) -> Void

    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            groupHeader

            if isExpanded {
                ForEach(sessions) { session in
                    SessionListButton(
                        session: session,
                        isSelected: false,
                        isOpenTab: false,
                        accentColorHex: project?.color,
                        statusStore: statusStore,
                        isAutoRenaming: false,
                        closeIcon: "arrow.uturn.backward",
                        closeHelp: "Wiederherstellen",
                        onSelect: { onRestore(session) },
                        onClose: { onRestore(session) }
                    )
                    .contextMenu {
                        Button("Wiederherstellen", systemImage: "arrow.uturn.backward") {
                            onRestore(session)
                        }
                    }
                }
            }
        }
    }

    private var groupHeader: some View {
        Button {
            withAnimation(.easeOut(duration: 0.12)) { isExpanded.toggle() }
        } label: {
            HStack(alignment: .center, spacing: 9) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(AgentTheme.textTertiary)
                    .frame(width: 12, height: 12)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .animation(.easeOut(duration: 0.12), value: isExpanded)

                if let project {
                    ProjectAvatar(project: project)
                } else {
                    Image(systemName: "questionmark.folder")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(AgentTheme.textTertiary)
                        .frame(width: 18, height: 18)
                }

                Text(project?.name ?? "Ohne Projekt")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AgentTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)

                Spacer(minLength: 6)

                Text("\(sessions.count)")
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(AgentTheme.textTertiary)
            }
            .padding(.leading, 8)
            .padding(.trailing, 8)
            .frame(minHeight: 30, maxHeight: 30)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
