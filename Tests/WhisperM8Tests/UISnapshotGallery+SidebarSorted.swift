import SwiftUI
@testable import WhisperM8

/// Seitenleiste A (WM8-80): Projektgruppen mit Workspace-Hinweis, laufenden
/// Chats vor gestoppten, Faltzeile „N gestoppt“ (zu unter „Aktiv“, offen
/// unter „Zuletzt“) und dem Trenner vor Projekten ohne laufende Chats.
extension UISnapshotGallery {
    @MainActor
    static func sidebarSortedFixtures() -> [Fixture] {
        let statusStore = AgentSessionRuntimeStatusStore()
        let listm8 = AgentProject(name: "ListM8", path: "/Users/demo/repos/ListM8", color: "#E8590C",
                                  lastBranch: "develop", createdManually: true)
        let whisperm8 = AgentProject(name: "whisperm8", path: "/Users/demo/repos/whisperm8", color: "#3D6DF2",
                                     lastBranch: "main", createdManually: true)
        let buchhaltung = AgentProject(name: "buchhaltung", path: "/Users/demo/repos/buchhaltung", color: "#4A90E2",
                                       lastBranch: "main", createdManually: true)

        func chat(_ title: String, _ project: AgentProject, minutesAgo: Double,
                  _ status: AgentSessionRuntimeStatus? = nil) -> AgentChatSession {
            var session = AgentChatSession(provider: .claude, projectID: project.id, title: title)
            session.createdManually = true
            session.status = .closed
            session.lastActivityAt = Date().addingTimeInterval(-minutesAgo * 60)
            if let status { statusStore.setStatus(status, for: session.id) }
            return session
        }

        let pia = chat("2 Pia · Linear: Feedback umsetzen", listm8, minutesAgo: 1, .working)
        let una = chat("1 Una · Feedback: Wünsche sammeln", listm8, minutesAgo: 3, .idle)
        let jarvis = chat("Jarvis: Supervisor ListM8", listm8, minutesAgo: 2, .idle)
        let listStopped = [
            chat("4 Ben · Fix: Exportierte Leads", listm8, minutesAgo: 18),
            chat("3 Kit · Kurs: Übersicht der Module", listm8, minutesAgo: 19),
            chat("2 Max · MCP: Kampagnen anlegen", listm8, minutesAgo: 19),
        ]
        let gus = chat("WM8-69 Gus · Limit: Chats erkennen", whisperm8, minutesAgo: 1, .working)
        let vic = chat("WM8-12 Vic · Neustart ohne Verlust", whisperm8, minutesAgo: 1, .awaitingInput)
        let claude = chat("Claude Chat", whisperm8, minutesAgo: 5, .idle)
        let wmStopped = [
            chat("Ole · Terminal-Tab: fertig", whisperm8, minutesAgo: 60),
            chat("WM8-61 Dex · Arbeitskopie-Marke", whisperm8, minutesAgo: 11 * 60),
        ]
        let buch = chat("Belege März abgleichen", buchhaltung, minutesAgo: 3 * 24 * 60)

        let dealSupply = AgentGridWorkspace(name: "DealSupply", slots: [una.id, pia.id], capacity: 2)
        let wmAktiv = AgentGridWorkspace(name: "WM8 Aktiv", slots: [gus.id, vic.id], capacity: 2)
        let workspaces = [wmAktiv, dealSupply]
        let workspaceBySession = AgentTabOrder.workspaceBySession(gridWorkspaces: workspaces)
        let running: Set<UUID> = [pia.id, una.id, jarvis.id, gus.id, vic.id, claude.id]

        func blocks(_ sessions: [AgentChatSession]) -> SidebarProjectBlocks {
            AgentSidebarSorting.blocks(sortedSessions: sessions, runningSessionIDs: running,
                                       workspaceBySession: workspaceBySession, workspaces: workspaces)
        }

        func group(_ project: AgentProject, _ blocks: SidebarProjectBlocks, scope: SidebarScope) -> some View {
            ProjectChatGroup(
                project: project, blocks: blocks, isExpanded: true, selectedSessionID: nil,
                multiSelection: [], openTabIDs: Set(blocks.running.map(\.id)),
                onSelectProject: {}, onToggleExpanded: {}, onSelectSession: { _ in }, onNewChat: { _ in },
                canOpenAsWorkspace: true, onOpenAsWorkspace: {}, onCloseSession: { _ in },
                sidebarScope: scope, onRename: { _, _ in },
                sessionMenu: { _ in AnyView(EmptyView()) }, subagentChildMenu: { _ in AnyView(EmptyView()) },
                statusStore: statusStore, autoRenamingSessionIDs: [],
                onRenameProjectRequest: { _ in }, onSetProjectColor: { _, _ in }, onChooseProjectIcon: { _ in },
                onAutoDetectProjectIcon: { _ in }, onClearProjectIcon: { _ in }, onDeleteProject: { _ in },
                onSessionDrop: { _, _, _ in }, onProjectDrop: { _, _ in }
            )
        }

        func list(scope: SidebarScope) -> AnyView {
            AnyView(VStack(alignment: .leading, spacing: 2) {
                group(listm8, blocks([pia, una, jarvis] + listStopped), scope: scope)
                group(whisperm8, blocks([gus, vic, claude] + wmStopped), scope: scope)
                SidebarCalmProjectsBand()
                group(buchhaltung, blocks([buch]), scope: scope)
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(AppTheme.sidebar))
        }

        return [
            Fixture(name: "seitenleiste-sortiert-aktiv", size: CGSize(width: 270, height: 330)) { list(scope: .active) },
            Fixture(name: "seitenleiste-sortiert-zuletzt", size: CGSize(width: 270, height: 470)) { list(scope: .recent) },
        ]
    }
}
