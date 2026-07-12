import AppKit
import SwiftUI

/// Kompakt-Modus („Projekt-Cockpit"): das Agent-Chats-Fenster verwandelt sich
/// in eine schmale Palette — oben die Chat-Liste des aktuellen Projekts,
/// darunter der aktive Chat als Live-PTY. Kein neues Fenster, kein Panel:
/// nur ein per-Fenster-Zustand im `AgentWindowStore` (`isCompact`) plus
/// NSWindow-Frame-Wechsel. Sidebar/Tabs/Inspector verschwinden rein optisch;
/// ihr State bleibt unangetastet und kommt beim Vergrößern exakt zurück.
/// Plan: docs/plans/kompakt-chat-fenster.md
extension AgentChatsView {
    static let compactWindowSize = NSSize(width: 380, height: 580)
    static let compactMinWindowSize = NSSize(width: 340, height: 480)
    static let compactMaxWindowSize = NSSize(width: 520, height: 900)

    var isCompactMode: Bool { windowStore.isCompact(in: windowID) }

    // MARK: - Fenster-Metamorphose

    func toggleCompactMode() {
        if isCompactMode {
            expandFromCompact()
        } else {
            enterCompactMode()
        }
    }

    /// Verkleinern: aktuellen Frame als Rückkehr-Ziel merken, Constraints
    /// setzen, dann animiert auf die Kompakt-Größe — obere rechte Ecke bleibt
    /// stehen (das Fenster „zieht sich zusammen", statt zu springen).
    func enterCompactMode() {
        // Der Tab-Strip verschwindet ohne onHover(false) — Flag manuell
        // zurücksetzen, sonst blockiert es den Doppelklick-Expand.
        isHoveringTabStrip = false
        guard let window = hostWindow else {
            windowStore.setCompact(true, in: windowID)
            return
        }
        let current = window.frame
        windowStore.setCompact(
            true,
            in: windowID,
            expandedFrame: AgentWindowFrame(
                x: current.origin.x, y: current.origin.y,
                width: current.width, height: current.height
            )
        )
        window.minSize = Self.compactMinWindowSize
        window.maxSize = Self.compactMaxWindowSize
        var target = NSRect(
            x: current.maxX - Self.compactWindowSize.width,
            y: current.maxY - Self.compactWindowSize.height,
            width: Self.compactWindowSize.width,
            height: Self.compactWindowSize.height
        )
        target = clampedToVisibleScreen(target, of: window)
        window.setFrame(target, display: true, animate: true)
    }

    /// Vergrößern: gemerkten Frame WIEDERHERSTELLEN (vor `setCompact(false)`
    /// lesen — das Umschalten leert ihn), Constraints zurücksetzen, Pin lösen.
    func expandFromCompact() {
        let stored = windowStore.expandedFrame(in: windowID)
        windowStore.setCompact(false, in: windowID)
        setCompactPinned(false)
        // Header-Buttons verschwinden ohne onHover(false) — Flag manuell
        // zurücksetzen, sonst blockiert es den Doppelklick-Zoom im großen
        // Fenster.
        isHoveringCompactControls = false
        guard let window = hostWindow else { return }
        window.minSize = .zero
        window.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        var target = stored.map {
            NSRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height)
        } ?? NSRect(
            x: window.frame.maxX - 1100,
            y: window.frame.maxY - 720,
            width: 1100, height: 720
        )
        target = clampedToVisibleScreen(target, of: window)
        window.setFrame(target, display: true, animate: true)
    }

    /// Launch-Restore: ein als kompakt persistiertes Fenster bekommt beim
    /// Auflösen des NSWindow sofort Constraints + Kompakt-Größe — ohne
    /// Animation, damit die Scene-Default-Größe (1100×720) nicht aufblitzt.
    /// Idempotent (onResolve feuert bei jedem updateNSView): der Frame wird
    /// nur angefasst, wenn er die Kompakt-Constraints verletzt — eine
    /// User-Resize INNERHALB der Grenzen bleibt unangetastet.
    func applyCompactWindowChromeIfNeeded(_ window: NSWindow) {
        guard isCompactMode else { return }
        window.minSize = Self.compactMinWindowSize
        window.maxSize = Self.compactMaxWindowSize
        let frame = window.frame
        guard frame.width > Self.compactMaxWindowSize.width + 1
            || frame.height > Self.compactMaxWindowSize.height + 1
            || frame.width < Self.compactMinWindowSize.width - 1
            || frame.height < Self.compactMinWindowSize.height - 1 else { return }
        var target = NSRect(
            x: frame.maxX - Self.compactWindowSize.width,
            y: frame.maxY - Self.compactWindowSize.height,
            width: Self.compactWindowSize.width,
            height: Self.compactWindowSize.height
        )
        target = clampedToVisibleScreen(target, of: window)
        window.setFrame(target, display: true, animate: false)
    }

    /// Always-on-top-Pin — expliziter Toggle, ephemer (nie persistiert).
    func setCompactPinned(_ pinned: Bool) {
        isCompactPinned = pinned
        hostWindow?.level = pinned ? .floating : .normal
    }

    /// Hält das Fenster vollständig im sichtbaren Screen-Bereich — sonst kann
    /// die Rückverwandlung auf einem kleineren/anderen Display offscreen landen.
    private func clampedToVisibleScreen(_ rect: NSRect, of window: NSWindow) -> NSRect {
        guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return rect }
        var clamped = rect
        clamped.size.width = min(clamped.width, visible.width)
        clamped.size.height = min(clamped.height, visible.height)
        clamped.origin.x = min(max(clamped.origin.x, visible.minX), visible.maxX - clamped.width)
        clamped.origin.y = min(max(clamped.origin.y, visible.minY), visible.maxY - clamped.height)
        return clamped
    }

    // MARK: - Kompakt-Layout

    /// Ersetzt bei `isCompact` den gesamten Sidebar+Tabs+Content-Aufbau
    /// (Muster: Archiv-Modus). Tab-Strip und Sidebar sind nur ausgeblendet —
    /// `openTabIDs` bleibt die eine Wahrheit, die Liste unten öffnet Tabs mit
    /// derselben Semantik wie ein Sidebar-Klick.
    var compactContent: some View {
        VStack(spacing: 0) {
            compactHeader
            Rectangle().fill(AgentTheme.border).frame(height: 1)
            if workspace.projects.isEmpty {
                ContentUnavailableView(
                    "Kein Projekt",
                    systemImage: "folder.badge.questionmark",
                    description: Text("Lege im großen Fenster ein Projekt an, um das Cockpit zu nutzen.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                compactSessionList
                Rectangle().fill(AgentTheme.border).frame(height: 1)
                compactDetail
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AgentTheme.background)
    }

    /// Titelzone: Ampel-Lücke, Projekt-Menü, Working-Chip, Pin + Expand.
    /// Alles dauerhaft sichtbar (kein Hover-only). Die Buttons melden ihren
    /// Hover nach oben (`isHoveringCompactControls`), damit der Doppelklick-
    /// Monitor sie aus der „Expand per Doppelklick"-Zone ausnimmt.
    private var compactHeader: some View {
        HStack(spacing: 8) {
            // Platz für die Ampel-Buttons (Sidebar ist im Kompakt-Modus weg).
            Spacer().frame(width: 70)

            if let project = selectedProject {
                Menu {
                    ForEach(AgentSessionStore.sortedProjects(workspace.projects)) { candidate in
                        Button {
                            selectedProjectID = candidate.id
                        } label: {
                            if candidate.id == project.id {
                                Label(candidate.name, systemImage: "checkmark")
                            } else {
                                Text(candidate.name)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        ProjectAvatar(project: project, size: 16)
                        Text(project.name)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(AgentTheme.textPrimary)
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(AgentTheme.textTertiary)
                    }
                    .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Projekt wechseln")

                CompactWorkingCountChip(
                    sessionIDs: compactProjectSessions.map(\.id),
                    statusStore: runtimeStatusStore
                )
            } else {
                Text("Kein Projekt")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AgentTheme.textTertiary)
            }

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                TitlebarIconButton(
                    systemImage: isCompactPinned ? "pin.fill" : "pin",
                    help: isCompactPinned ? "Nicht mehr im Vordergrund halten" : "Immer im Vordergrund",
                    isActive: isCompactPinned
                ) {
                    setCompactPinned(!isCompactPinned)
                }
                TitlebarIconButton(
                    systemImage: "arrow.up.left.and.arrow.down.right",
                    help: "Fenster vergrößern (⌘⇧M)"
                ) {
                    toggleCompactMode()
                }
            }
            .onHover { isHoveringCompactControls = $0 }
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
        .background(AgentTheme.header)
    }

    /// Flache Liste aller Chats des Fenster-Projekts — dieselbe Row wie in
    /// der Sidebar (`SessionListButton`, inkl. Live-Status per Per-Item-
    /// Publisher). Klick = Sidebar-Semantik: Tab öffnen/fokussieren.
    private var compactSessionList: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(compactProjectSessions) { session in
                    SessionListButton(
                        session: session,
                        isSelected: session.id == selectedSession?.id,
                        isOpenTab: openTabIDs.contains(session.id),
                        accentColorHex: selectedProject?.color,
                        statusStore: runtimeStatusStore,
                        isAutoRenaming: false,
                        onSelect: {
                            openTab(session.id)
                            selectedSessionID = session.id
                        },
                        onClose: { requestArchive([session]) }
                    )
                }

                Button {
                    createDefaultSession()
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(AgentTheme.textTertiary)
                            .frame(width: 16, height: 16)
                            .background(AgentTheme.control.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                        Text("Neuer Chat")
                            .font(.system(size: 12))
                            .foregroundStyle(AgentTheme.textSecondary)
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(selectedProject == nil)
            }
            .padding(8)
        }
        .frame(maxHeight: 230)
        .background(AgentTheme.header.opacity(0.5))
    }

    /// Aktiver Chat als Live-PTY: exakt derselbe Detail-Pfad wie im großen
    /// Fenster (`sessionDetailContent`) — `attach()` hängt die bestehende
    /// Terminal-View verlustfrei um, SwiftTerm meldet die neue Spaltenzahl.
    @ViewBuilder
    private var compactDetail: some View {
        if let selectedSession,
           let project = workspace.projects.first(where: { $0.id == selectedSession.projectID }) {
            sessionDetailContent(for: selectedSession, project: project)
                .id(selectedSession.id)
                .padding(8)
        } else {
            ContentUnavailableView("Kein Agent Chat", systemImage: "terminal")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Sessions des Kontext-Projekts (manuell erstellt, nicht archiviert) in
    /// Sidebar-Sortierung — bewusst dieselbe Filterlogik wie `projectSessions`
    /// (dort private, nur Inspector-Datenquelle).
    private var compactProjectSessions: [AgentChatSession] {
        guard let selectedProject else { return [] }
        return AgentSessionStore.sortedSessions(
            workspace.sessions.filter {
                $0.projectID == selectedProject.id
                    && $0.status != .archived
                    && $0.isManuallyCreated
            }
        )
    }

    // MARK: - Geteilter Session-Detail-Pfad

    /// Detail-Ansicht einer Session (Subagent-Job-View bzw. PTY-DetailView) —
    /// aus `mainWorkspace` extrahiert, damit Kompakt-Modus und großes Fenster
    /// EXAKT denselben Pfad nutzen (gleiches Verhalten, gleiche Hook-Wiring).
    @ViewBuilder
    func sessionDetailContent(for session: AgentChatSession, project: AgentProject) -> some View {
        // Subagent-Jobs rendern die Job-Detail-View (Report + Live-Transcript
        // + Composer) — bis zur Übernahme, dann übernimmt der PTY-Pfad.
        if session.isSubagentJob && !jobRuntimeModel.isTakenOver(session.id) {
            SubagentJobDetailView(
                session: session,
                project: project,
                jobRuntimeModel: jobRuntimeModel,
                onTakeOver: { takeOverSubagentJob(session) },
                onAppearClearUnread: { windowStore.clearSubagentUnread(session.id) }
            )
        } else {
            AgentSessionDetailView(
                project: project,
                session: session,
                terminalRegistry: terminalRegistry,
                actionRequest: sessionActionRequest,
                onStateChanged: loadWorkspaceFast,
                onSessionLaunched: { sessionID in
                    AgentSessionStatusCoordinator.shared.sessionLaunched(sessionID: sessionID)
                },
                onSessionTerminated: { sessionID, exitCode in
                    AgentSessionStatusCoordinator.shared.sessionTerminated(sessionID: sessionID, exitCode: exitCode)
                },
                onExternalSessionIDBound: { sessionID in
                    AgentSessionStatusCoordinator.shared.externalSessionIDBound(sessionID: sessionID)
                },
                onPrepareClaudeHookArguments: { sessionID in
                    AgentSessionStatusCoordinator.shared.prepareLaunchArguments(localSessionID: sessionID)
                },
                onClaudeHookLaunched: { sessionID in
                    AgentSessionStatusCoordinator.shared.hookLaunchDidStart(sessionID: sessionID)
                }
            )
        }
    }
}

/// Working-Zähler des Kompakt-Headers — eigene kleine View mit eigener
/// Subscription auf `$statuses`, damit Status-Ticks nur den Chip invalidieren
/// (der Parent-Body darf `.statuses` nicht lesen — P4-Regel).
private struct CompactWorkingCountChip: View {
    let sessionIDs: [UUID]
    let statusStore: AgentSessionRuntimeStatusStore

    @State private var workingCount = 0

    var body: some View {
        Group {
            if workingCount > 0 {
                HStack(spacing: 4) {
                    Circle().fill(Color.green).frame(width: 5, height: 5)
                    Text("\(workingCount)")
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Color.green)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.green.opacity(0.10), in: Capsule())
                .overlay(Capsule().stroke(Color.green.opacity(0.25), lineWidth: 1))
                .help("\(workingCount) \(workingCount == 1 ? "Agent arbeitet" : "Agenten arbeiten")")
            }
        }
        .onReceive(statusStore.$statuses) { statuses in
            let count = sessionIDs.filter { statuses[$0] == .working }.count
            if count != workingCount { workingCount = count }
        }
    }
}
