import SwiftUI
@testable import WhisperM8

/// Options-Menü des Controllers als Karte am Chat (Runde 5): nachgebautes
/// Fenster mit Seitenleiste, Kopf, Kacheln und Terminal-Fläche. Die Karte
/// hängt über dieselben Anker und dieselbe Platzierung wie in der App
/// (`ControllerMenuAnchorKey`, `ControllerMenuCardResolver`).
extension UISnapshotGallery {
    @MainActor
    static func controllerMenuCardFixtures() -> [Fixture] {
        let windowID = UUID()
        let selected = UUID(), other1 = UUID(), other2 = UUID(), other3 = UUID()
        let workspaceID = UUID()
        let projectID = UUID()

        func accounts() -> [ControllerAccountChoice] {
            var list = [
                ControllerAccountChoice(kind: .claude, name: "main", label: "main", isCurrent: true, isLoggedIn: true),
                ControllerAccountChoice(kind: .claude, name: "work", label: "work", isCurrent: false, isLoggedIn: true),
            ]
            list[0].fiveHourUsed = 42
            list[0].weekUsed = 61
            list[1].fiveHourUsed = 12
            list[1].weekUsed = 28
            return ControllerAccountHeadroom.marked(list)
        }
        func chatInfo(inWorkspace: Bool, gridVisible: Bool = true,
                      title: String = "2 Lux · Integrationen") -> ControllerChatActionInfo {
            var chat = ControllerChatActionInfo(title: title, isPinned: false, canFork: true)
            chat.accounts = accounts()
            chat.hasProject = true
            chat.projectOpenTargetName = "PhpStorm"
            chat.canRefreshTitle = true
            chat.canRestart = true
            chat.hasTab = true
            chat.addableWorkspaces = [ControllerWorkspaceChoice(
                id: UUID(), name: "Ops", colorHex: "#3FA873", chatCount: 2, hasWaitingChat: false, isCurrent: false)]
            if inWorkspace {
                chat.notesAvailable = gridVisible
                chat.notesDefaultOpen = true
                chat.tileNoteOpen = gridVisible ? false : nil
                chat.removableWorkspaceName = "Marketing"
                chat.shownInWorkspace = ControllerWorkspaceContext(
                    id: workspaceID, name: "Marketing", gridVisible: gridVisible, chatIsMember: true, isCurated: true,
                    capacities: [
                        ControllerCapacityChoice(capacity: 2, label: "1×2", isCurrent: false, needsSelection: true),
                        ControllerCapacityChoice(capacity: 3, label: "2+1", isCurrent: false, needsSelection: true),
                        ControllerCapacityChoice(capacity: 4, label: "2×2", isCurrent: true, needsSelection: false),
                        ControllerCapacityChoice(capacity: 6, label: "3×2", isCurrent: false, needsSelection: false),
                    ])
            }
            return chat
        }
        func menu(_ chat: ControllerChatActionInfo, selected item: ControllerMenuItem? = nil,
                  open submenu: Bool = false, steps: Int = 0, session: UUID? = nil) -> ControllerMenuModel {
            let target = session ?? selected
            // Eingaben nur in den ausgewählten Chat (in der Liste kann eine
            // andere Zeile markiert sein).
            let setup = ControllerMenuSetup(
                acceptsInput: target == selected, profile: .claude, sessionID: target, target: .chat(target), chat: chat)
            var model = ControllerMenuModel(setup: setup, selected: item)
            if submenu { _ = model.openSubmenu() }
            if steps != 0 { model.move(steps) }
            return model
        }
        /// Setzt das geteilte Modell so, wie es der Ausführer bei offenem Menü hält.
        func show(_ model: ControllerMenuModel, area: ControllerFocusArea, marked: SidebarNavigationRow? = nil) {
            let ui = ControllerUIModel.shared
            ui.menu = model
            ui.area = area
            ui.markedRow = marked
            ui.listWindowID = marked == nil ? nil : windowID
            ui.targetTitle = "2 Lux · Integrationen"
        }

        // MARK: Bausteine des nachgebauten Fensters

        func sidebar(markable: Bool) -> some View {
            func row(_ title: String, _ row: SidebarNavigationRow?, dot: Color?, indent: Bool = true,
                     bold: Bool = false, chosen: Bool = false) -> AnyView {
                let content = HStack(spacing: 8) {
                    if let dot { Circle().fill(dot).frame(width: 7, height: 7) }
                    Text(verbatim: title)
                        .font(.system(size: 12.5, weight: bold ? .semibold : .regular))
                        .foregroundStyle(AppTheme.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.leading, indent ? 22 : 10)
                .padding(.trailing, 10)
                .frame(height: 28)
                .background(chosen ? AppTheme.selection : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                .padding(.horizontal, 4)
                if let row, markable { return AnyView(content.controllerListRow(row)) }
                return AnyView(content)
            }
            return VStack(alignment: .leading, spacing: 2) {
                row("WORKSPACES", nil, dot: nil, indent: false, bold: true)
                row("Marketing", nil, dot: nil, indent: false, bold: true)
                row("1 Moe · Doku: auf den neuesten Stand", .chat(other1), dot: AppTheme.statusWorking)
                row("2 Lux · Integrationen", .chat(selected), dot: AppTheme.statusAwaiting, chosen: true)
                row("3 Kit · Release-Notizen", .chat(other2), dot: AppTheme.textTertiary)
                row("whisperm8", .project(projectID), dot: nil, indent: false, bold: true)
                row("Controller Insel", .chat(other3), dot: AppTheme.statusWorking)
                row("E2E Befunde Raster", nil, dot: AppTheme.textTertiary)
                row("Release Notizen 2.26", nil, dot: AppTheme.textTertiary)
                Spacer(minLength: 0)
            }
            .padding(.top, 10)
            .frame(width: 250)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(AppTheme.sidebar)
            .environment(\.agentChatsWindowID, windowID)
        }
        func terminalLines(_ count: Int) -> some View {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(0..<count, id: \.self) { index in
                    Text(verbatim: index % 3 == 0 ? "⏺ Read(WhisperM8/Views/AgentChatsView.swift)"
                        : (index % 3 == 1 ? "  ⎿  Read 3720 lines" : "Die Karte hängt jetzt am Chat-Kopf."))
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(AppTheme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            // Wie das Terminal: die Fläche gibt die Höhe vor, Text darüber wird abgeschnitten.
            .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
            .clipped()
            .background(AppTheme.background)
        }
        func tabBar() -> some View {
            HStack(spacing: 2) {
                ForEach(["Doku", "2 Lux · Integrationen", "Release"], id: \.self) { title in
                    Text(verbatim: title)
                        .font(.system(size: 11.5))
                        .foregroundStyle(AppTheme.textSecondary)
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .background(title.hasPrefix("2") ? AppTheme.tabSelected : Color.clear)
                }
                Spacer(minLength: 0)
            }
            .frame(height: 32)
            .background(AppTheme.tabBar)
        }
        func chatHeader() -> some View {
            HStack(spacing: 8) {
                Circle().fill(AppTheme.statusAwaiting).frame(width: 8, height: 8)
                Text(verbatim: "2 Lux · Integrationen")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                Text(verbatim: "whisperm8 · feat/controller-runde5")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(AppTheme.textTertiary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                ForEach(["+ Claude", "+ Codex", "Restart"], id: \.self) { label in
                    Text(verbatim: label)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(AppTheme.textPrimary)
                        .padding(.horizontal, 7)
                        .frame(height: 22)
                        .background(AppTheme.control.opacity(0.48), in: RoundedRectangle(cornerRadius: 5))
                }
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AppTheme.textTertiary)
                    .frame(width: 22, height: 22)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .controllerMenuAnchor(.header, sessionID: selected)
            .background(AppTheme.header)
        }
        func tile(_ title: String, id: UUID, focused: Bool) -> some View {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Circle().fill(focused ? AppTheme.statusAwaiting : AppTheme.statusWorking).frame(width: 7, height: 7)
                    Text(verbatim: title)
                        .font(.system(size: 12, weight: focused ? .semibold : .regular))
                        .foregroundStyle(focused ? AppTheme.textPrimary : AppTheme.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    ForEach(["arrow.clockwise", "arrow.up.left.and.arrow.down.right", "minus"], id: \.self) { icon in
                        Image(systemName: icon)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(AppTheme.textSecondary)
                            .frame(width: 16, height: 16)
                            .background(AppTheme.hover, in: RoundedRectangle(cornerRadius: 3))
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(AppTheme.header.opacity(focused ? 1 : 0.55))
                .controllerMenuAnchor(.tile, sessionID: id)
                terminalLines(8)
            }
            .overlay { if focused { Rectangle().strokeBorder(AppTheme.accent.opacity(0.6), lineWidth: 1) } }
        }
        func workspaceHeader() -> some View {
            HStack(spacing: 10) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppTheme.accent)
                Text(verbatim: "Marketing")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                Text(verbatim: "4/4 occupied")
                    .font(.system(size: 11))
                    .foregroundStyle(AppTheme.textTertiary)
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 10)
            .frame(height: 38)
            .background(AppTheme.header)
        }
        func legend() -> some View {
            HStack {
                Text(verbatim: "✕ Senden   ○ Zurück   Options Menü   L2 Wohin")
                    .font(.system(size: 11))
                    .foregroundStyle(AppTheme.textSecondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: ControllerLegendBar.height)
            .background(AppTheme.tabBar)
        }
        /// Fenster mit der Karte darüber, aufgelöst wie in der App.
        func window(markable: Bool = false, @ViewBuilder main: () -> some View) -> AnyView {
            AnyView(
                HStack(spacing: 0) {
                    sidebar(markable: markable)
                    Rectangle().fill(AppTheme.border).frame(width: 1)
                    VStack(spacing: 0) {
                        main()
                        legend()
                    }
                }
                .overlayPreferenceValue(ControllerMenuAnchorKey.self) { anchors in
                    ControllerMenuCardResolver(
                        menu: ControllerUIModel.shared.menu ?? menu(chatInfo(inWorkspace: false)),
                        fallbackTitle: nil, anchors: anchors, bottomInset: ControllerLegendBar.height)
                }
            )
        }
        func singleView() -> AnyView {
            window {
                tabBar()
                chatHeader()
                terminalLines(30)
            }
        }
        func gridView(focused: UUID) -> AnyView {
            window {
                tabBar()
                workspaceHeader()
                VStack(spacing: 1) {
                    HStack(spacing: 1) {
                        tile("1 Moe · Doku", id: other1, focused: focused == other1)
                        tile("2 Lux · Integrationen", id: selected, focused: focused == selected)
                    }
                    HStack(spacing: 1) {
                        tile("3 Kit · Release-Notizen", id: other2, focused: focused == other2)
                        tile("Controller Insel", id: other3, focused: focused == other3)
                    }
                }
                .background(AppTheme.border)
            }
        }
        func listView() -> AnyView {
            window(markable: true) {
                tabBar()
                chatHeader()
                terminalLines(30)
            }
        }

        let large = CGSize(width: 1280, height: 900)
        return [
            // Einzelansicht: rechts unter dem Chat-Kopf (beim „…“).
            Fixture(name: "controller-menue-karte-einzelansicht", size: large) {
                show(menu(chatInfo(inWorkspace: false)), area: .content)
                return singleView()
            },
            // Raster: am Kopf der fokussierten Kachel, mit Gruppe „Workspace“.
            Fixture(name: "controller-menue-karte-raster", size: large) {
                show(menu(chatInfo(inWorkspace: true), selected: .removeFromWorkspace), area: .content)
                return gridView(focused: selected)
            },
            // Raster: Untermenü „Rastergröße“ (Verkleinern mit Auswahl ist aus).
            Fixture(name: "controller-menue-karte-rastergroesse", size: large) {
                show(menu(chatInfo(inWorkspace: true), selected: .gridCapacity, open: true, steps: 1), area: .content)
                return gridView(focused: selected)
            },
            // Liste: neben der markierten Zeile.
            Fixture(name: "controller-menue-karte-liste", size: large) {
                show(menu(chatInfo(inWorkspace: false, title: "3 Kit · Release-Notizen"), selected: .rename, session: other2),
                     area: .list, marked: .chat(other2))
                return listView()
            },
            // Projekt-Zeile markiert: Das Menü gilt dem ausgewählten Chat und hängt
            // an dessen Kopf, nicht neben der Projekt-Zeile (Review Runde 5).
            Fixture(name: "controller-menue-karte-liste-projektzeile", size: large) {
                show(menu(chatInfo(inWorkspace: false), selected: .rename), area: .list, marked: .project(projectID))
                return listView()
            },
            // Langes Menü im kleinen Fenster: die Liste scrollt in der Karte.
            Fixture(name: "controller-menue-karte-klein", size: CGSize(width: 760, height: 460)) {
                show(menu(chatInfo(inWorkspace: true), selected: .removeFromWorkspace), area: .content)
                return singleView()
            },
            // Große Kachel (Einzelansicht aus dem Raster): Workspace ohne Notizen.
            Fixture(name: "controller-menue-karte-grosse-kachel", size: large) {
                show(menu(chatInfo(inWorkspace: true, gridVisible: false), selected: .renameWorkspace), area: .content)
                return singleView()
            },
        ]
    }
}
