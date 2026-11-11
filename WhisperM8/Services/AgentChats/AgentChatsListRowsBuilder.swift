import Foundation

/// Baut die Zeilen der Liste links in der Reihenfolge, in der sie zu sehen
/// sind — für die Navigation ohne Maus. Pur: bekommt nur, was die
/// Seitenleiste gerade zeigt.
///
/// Reihenfolge wie in der Ansicht: angeheftete Chats, Workspaces mit ihren
/// Chats, dann die Chat-Liste (flach oder nach Projekt). Eingeklappte
/// Abschnitte und Gruppen liefern keine Kind-Zeilen. Zeilen von Subagenten
/// sind bewusst nicht dabei.
enum AgentChatsListRowsBuilder {
    struct Chat: Equatable {
        var id: UUID
        var projectID: UUID
    }

    struct Workspace: Equatable {
        var id: UUID
        var isCollapsed: Bool
        /// Chats in Slot-Reihenfolge, ohne leere Slots.
        var chats: [Chat]
    }

    struct Project: Equatable {
        var id: UUID
        var isExpanded: Bool
        /// Die Chats, die die Gruppe gerade zeigt (nach ihrem Zeilen-Limit).
        var visibleChats: [UUID]
        var activeSessionIDs: Set<UUID>
    }

    struct Input: Equatable {
        var pinned: [Chat] = []
        var isPinnedCollapsed = false
        var workspaces: [Workspace] = []
        var isWorkspacesCollapsed = false
        /// Die Chat-Liste ist zugeklappt (und keine Suche überstimmt das).
        var isChatListHidden = false
        /// Flache Ansicht: Chats ohne Projektgruppen. `nil` = gruppiert.
        var flatChats: [Chat]?
        var projects: [Project] = []
    }

    static func rows(_ input: Input) -> [AgentChatsListRow] {
        var rows: [AgentChatsListRow] = []
        var seen = Set<SidebarNavigationRow>()
        func append(_ row: AgentChatsListRow) {
            // Derselbe Chat kann angeheftet UND in der Liste stehen: Die
            // Navigation kennt ihn einmal, an der ersten Stelle.
            guard seen.insert(row.row).inserted else { return }
            rows.append(row)
        }

        if !input.isPinnedCollapsed {
            for chat in input.pinned {
                append(AgentChatsListRow(row: .chat(chat.id), projectID: chat.projectID))
            }
        }
        if !input.isWorkspacesCollapsed {
            for workspace in input.workspaces {
                append(AgentChatsListRow(row: .workspace(workspace.id), projectID: workspace.chats.first?.projectID))
                guard !workspace.isCollapsed else { continue }
                for chat in workspace.chats {
                    append(AgentChatsListRow(
                        row: .workspaceChat(session: chat.id, workspace: workspace.id), projectID: chat.projectID))
                }
            }
        }
        guard !input.isChatListHidden else { return rows }
        if let flatChats = input.flatChats {
            for chat in flatChats {
                append(AgentChatsListRow(row: .chat(chat.id), projectID: chat.projectID))
            }
        } else {
            for project in input.projects {
                append(AgentChatsListRow(
                    row: .project(project.id), projectID: project.id, activeSessionIDs: project.activeSessionIDs))
                guard project.isExpanded else { continue }
                for chatID in project.visibleChats {
                    append(AgentChatsListRow(row: .chat(chatID), projectID: project.id))
                }
            }
        }
        return rows
    }
}
