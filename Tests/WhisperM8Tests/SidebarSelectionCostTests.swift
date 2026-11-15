import AppKit
import SwiftUI
import XCTest
@testable import WhisperM8

/// WM8-101: Was kostet ein Auswahlwechsel in der Seitenleiste mit so vielen
/// Projekten wie im echten Workspace (15.11.2026: 248 Projekte, 5.913 Chats)?
/// Gemessen wird Body-Auswertung, Layout und Zeichnen einer gehosteten Liste
/// aus `ProjectChatGroup`, so zusammengesetzt wie in `sidebarProjectGroups`.
///
/// Messlauf, keine Pflichtprüfung: läuft nur mit `WM8_PERF_BENCH=1`, weil
/// Zeiten auf einer belasteten Maschine schwanken.
@MainActor
final class SidebarSelectionCostTests: XCTestCase {
    @Observable
    final class Selection {
        var selected: UUID?
        /// Steht für eine Workspace-Änderung ohne Auswahlwechsel: der Body
        /// der Liste läuft neu, die Eingaben der Gruppen bleiben gleich.
        var revision = 0
    }

    struct Fixture {
        let projects: [AgentProject]
        let blocks: [UUID: SidebarProjectBlocks]
        let expanded: Set<UUID>
        let statusStore: AgentSessionRuntimeStatusStore
    }

    static func makeFixture(projectCount: Int = 248, chatsPerProject: Int = 24, expandedCount: Int = 30) -> Fixture {
        let statusStore = AgentSessionRuntimeStatusStore()
        var projects: [AgentProject] = []
        var blocks: [UUID: SidebarProjectBlocks] = [:]
        for index in 0..<projectCount {
            let project = AgentProject(name: "projekt-\(index)", path: "/Users/demo/repos/projekt-\(index)",
                                       color: "#3D6DF2", lastBranch: "main", createdManually: true)
            let sessions = (0..<chatsPerProject).map { chatIndex -> AgentChatSession in
                var session = AgentChatSession(provider: .claude, projectID: project.id,
                                               title: "Chat \(chatIndex) in Projekt \(index)")
                session.createdManually = true
                session.status = .closed
                session.lastActivityAt = Date().addingTimeInterval(-Double(chatIndex * 60))
                return session
            }
            projects.append(project)
            blocks[project.id] = AgentSidebarSorting.blocks(
                sortedSessions: sessions, runningSessionIDs: [], workspaceBySession: [:], workspaces: [])
        }
        let expanded = Set(projects.prefix(expandedCount).map(\.id))
        return Fixture(projects: projects, blocks: blocks, expanded: expanded, statusStore: statusStore)
    }

    /// Heutige Zusammensetzung: jede Gruppe bekommt die globale Auswahl und
    /// frische Closures, wird also bei jedem Wechsel neu ausgewertet.
    struct CurrentList: View {
        let fixture: Fixture
        let selection: Selection

        var body: some View {
            let _ = selection.revision
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(fixture.projects) { project in
                        ProjectChatGroup(
                            project: project, blocks: fixture.blocks[project.id] ?? SidebarProjectBlocks(),
                            isExpanded: fixture.expanded.contains(project.id),
                            selectedSessionID: selection.selected,
                            multiSelection: [], openTabIDs: [],
                            onSelectProject: { _ = project.id }, onToggleExpanded: { _ = project.id }, onSelectSession: { _ in }, onNewChat: { _ in },
                            canOpenAsWorkspace: false, onOpenAsWorkspace: {}, onCloseSession: { _ in },
                            sidebarScope: .all, onRename: { _, _ in },
                            sessionMenu: { _ in AnyView(EmptyView()) }, subagentChildMenu: { _ in AnyView(EmptyView()) },
                            statusStore: fixture.statusStore, autoRenamingSessionIDs: [],
                            onRenameProjectRequest: { _ in }, onSetProjectColor: { _, _ in }, onChooseProjectIcon: { _ in },
                            onAutoDetectProjectIcon: { _ in }, onClearProjectIcon: { _ in }, onDeleteProject: { _ in },
                            onSessionDrop: { _, _, _ in }, onProjectDrop: { _, _ in }
                        )
                    }
                }
            }
        }
    }

    /// Neue Zusammensetzung wie in `sidebarProjectGroups`: zugeschnittene
    /// Eingaben, Gruppe hinter `SidebarSkippingGroup(...).equatable()`.
    struct NarrowedList: View {
        let fixture: Fixture
        let selection: Selection

        var body: some View {
            let _ = selection.revision
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(fixture.projects) { project in
                        let blocks = fixture.blocks[project.id] ?? SidebarProjectBlocks()
                        let inputs = SidebarProjectGroupInputs.narrowed(
                            blocks: blocks, selectedSessionID: selection.selected, multiSelection: [], openTabIDs: [],
                            autoRenamingSessionIDs: [], missingTranscriptSessionIDs: [], subagentChildrenByParent: [:],
                            workingSubagentSessionIDs: [], erroredSubagentSessionIDs: [], unreadSubagentSessionIDs: [],
                            expandedSubagentParentIDs: [])
                        let isExpanded = fixture.expanded.contains(project.id)
                        SidebarSkippingGroup(key: SidebarProjectGroupKey(
                            project: project, blocks: blocks, inputs: inputs, isExpanded: isExpanded,
                            worktreeProjects: [], activeSessionIDs: [], isWorkspaceOpen: false,
                            workspaceOccupancyLabel: nil, sidebarScope: .all, isSearching: false, stoppedFoldOverride: nil,
                            menu: SidebarProjectGroupInputsTests.menu()
                        )) {
                            ProjectChatGroup(
                                project: project, blocks: blocks, isExpanded: isExpanded,
                                selectedSessionID: inputs.selectedSessionID,
                                multiSelection: inputs.multiSelection, openTabIDs: inputs.openTabIDs,
                                onSelectProject: {}, onToggleExpanded: {}, onSelectSession: { _ in }, onNewChat: { _ in },
                                canOpenAsWorkspace: false, onOpenAsWorkspace: {}, onCloseSession: { _ in },
                                sidebarScope: .all, onRename: { _, _ in },
                                sessionMenu: { _ in AnyView(EmptyView()) }, subagentChildMenu: { _ in AnyView(EmptyView()) },
                                statusStore: fixture.statusStore, autoRenamingSessionIDs: inputs.autoRenamingSessionIDs,
                                onRenameProjectRequest: { _ in }, onSetProjectColor: { _, _ in }, onChooseProjectIcon: { _ in },
                                onAutoDetectProjectIcon: { _ in }, onClearProjectIcon: { _ in }, onDeleteProject: { _ in },
                                onSessionDrop: { _, _, _ in }, onProjectDrop: { _, _ in }
                            )
                        }
                        .equatable()
                    }
                }
            }
        }
    }

    struct Measurement {
        let firstMs: Double
        let switchMs: [Double]
        var medianSwitchMs: Double { switchMs.sorted()[switchMs.count / 2] }
    }

    static func measure<V: View>(_ root: V, selection: Selection, targets: [UUID], bumpOnly: Bool = false) -> Measurement {
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 900),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        host.frame = CGRect(x: 0, y: 0, width: 280, height: 900)
        window.contentView = host
        let clock = ContinuousClock()
        func settle() -> Double {
            let start = clock.now
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            RunLoop.main.run(until: Date())
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            let elapsed = clock.now - start
            return Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000
        }
        let first = settle()
        var switches: [Double] = []
        for target in targets {
            if bumpOnly { selection.revision += 1 } else { selection.selected = target }
            switches.append(settle())
        }
        window.contentView = nil
        window.close()
        return Measurement(firstMs: first, switchMs: switches)
    }

    func testSelectionChangeCostWithRealisticWorkspace() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["WM8_PERF_BENCH"] == "1", "Messlauf: WM8_PERF_BENCH=1")
        let fixture = Self.makeFixture()
        // Wechsel zwischen Chats in sichtbaren, aufgeklappten Gruppen.
        let targets = (0..<12).map { index in
            fixture.blocks[fixture.projects[index % 6].id]!.rows[index % 3].id
        }
        let selection = Selection()
        let current = Self.measure(CurrentList(fixture: fixture, selection: selection), selection: selection, targets: targets)
        let narrowedSelection = Selection()
        let narrowed = Self.measure(NarrowedList(fixture: fixture, selection: narrowedSelection),
                                    selection: narrowedSelection, targets: targets)
        print("SIDEBAR_BENCH narrowed first=\(Int(narrowed.firstMs))ms switchMedian=\(Int(narrowed.medianSwitchMs))ms all=\(narrowed.switchMs.map { Int($0) })")
        let floorSelection = Selection()
        let floor = Self.measure(NarrowedList(fixture: fixture, selection: floorSelection),
                                 selection: floorSelection, targets: (0..<12).map { _ in UUID() })
        print("SIDEBAR_BENCH floor(no group affected) switchMedian=\(Int(floor.medianSwitchMs))ms")
        let bumpCurrent = Selection()
        let bumpCur = Self.measure(CurrentList(fixture: fixture, selection: bumpCurrent), selection: bumpCurrent,
                                   targets: targets, bumpOnly: true)
        let bumpNarrowed = Selection()
        let bumpNar = Self.measure(NarrowedList(fixture: fixture, selection: bumpNarrowed), selection: bumpNarrowed,
                                   targets: targets, bumpOnly: true)
        print("SIDEBAR_BENCH workspaceChange current=\(Int(bumpCur.medianSwitchMs))ms narrowed=\(Int(bumpNar.medianSwitchMs))ms")
        print("SIDEBAR_BENCH current first=\(Int(current.firstMs))ms switchMedian=\(Int(current.medianSwitchMs))ms all=\(current.switchMs.map { Int($0) })")
    }
}
