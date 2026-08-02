import SwiftUI

/// Vereinheitlichtes Session-Kontextmenü: EIN Kompositions-Einstieg
/// (`sessionContextMenu`) plus thematische Sektions-Builder. Welche Sektionen
/// ein Kontext zeigt, entscheidet die pure `SessionMenuPolicy` (unit-getestet)
/// — neue Menüpunkte werden hier EINMAL eingebaut statt in acht Kopien.
/// Ist-/Ziel-Matrix und Produktentscheidungen:
/// docs/plans/kontextmenu-vereinheitlichung.md.
extension AgentChatsView {
    /// Live-Traits für die Policy — die einzige Stelle, die dafür auf
    /// Stores/Registries zugreift.
    func sessionMenuTraits(for session: AgentChatSession) -> SessionMenuTraits {
        SessionMenuTraits(
            isTabOpen: openTabIDs.contains(session.id),
            isBackgroundChat: session.isBackgroundChat,
            supportsRuntime: !session.isSubagentJob || jobRuntimeModel.isTakenOver(session.id),
            canStopSubagentJob: session.isSubagentJob
                && jobRuntimeModel.snapshotsBySessionID[session.id]?.isActive == true
                && jobRuntimeModel.snapshotsBySessionID[session.id]?.supervisorPid != nil
        )
    }

    /// Das eine Session-Kontextmenü für alle UI-Orte. `removalWorkspace`
    /// liefert die Workspace-Entity für den „Aus Workspace „X" entfernen"-Kopf
    /// (nur `.workspaceRow`/`.gridPane`).
    @ViewBuilder
    func sessionContextMenu(
        _ session: AgentChatSession,
        context: SessionMenuContext,
        removalWorkspace: AgentGridWorkspace? = nil
    ) -> some View {
        let plan = SessionMenuPolicy.plan(for: context, traits: sessionMenuTraits(for: session))

        // Kontext-Kopf
        if plan.showsCloseTab {
            Button(
                plan.allowsBulk ? bulkLabel("Tab schließen", "%d Tabs schließen", for: session) : "Tab schließen",
                systemImage: "xmark.square"
            ) {
                if plan.allowsBulk { closeTabsInSelection(session) } else { closeTab(session) }
            }
        }
        if plan.showsWorkspaceRemovalHead, let removalWorkspace {
            Button("Aus Workspace „\(removalWorkspace.name)“ entfernen", systemImage: "minus.circle") {
                removeSessionFromWorkspace(session.id, workspaceID: removalWorkspace.id)
            }
        }
        if plan.showsMaximize {
            Button("Maximieren", systemImage: "arrow.up.left.and.arrow.down.right") {
                maximizePane(session.id)
            }
        }
        if plan.showsCloseTab || plan.showsMaximize
            || (plan.showsWorkspaceRemovalHead && removalWorkspace != nil) {
            Divider()
        }

        // Benennen
        Button("Umbenennen…", systemImage: "pencil") {
            beginRename(session)
        }
        if plan.showsAutoTitle {
            Button("Titel automatisch generieren", systemImage: "sparkles") {
                forceAutoNameSession(session)
            }
            .disabled(session.externalSessionID == nil)
        }

        // Laufzeit
        if plan.showsRuntime {
            runtimeMenuItem(session)
        }
        if plan.showsSubagentStop {
            subagentStopMenuItem(session)
        }

        // Verwalten (Bausteine blenden sich selbst aus, wenn unpassend)
        if plan.showsManagement {
            forkMenuItem(session)
            moveToAccountMenu(session)
        }

        // Fenster / Workspace
        if plan.showsWindowWorkspace {
            Divider()
            if plan.showsWindowMove {
                windowMoveMenuItem(session, allowsBulk: plan.allowsBulk)
            }
            workspaceMembershipMenu(for: session, includeRemoval: plan.includesMembershipRemoval)
            newWorkspaceMenuItem(for: session, allowsBulk: plan.allowsBulk)
        }

        // Darstellung
        if plan.showsAppearance {
            Divider()
            pinMenuItem(session, allowsBulk: plan.allowsBulk)
            tabColorMenu(for: session, allowsBulk: plan.allowsBulk)
        }

        // Background-Lifecycle (`claude --bg`)
        if plan.showsBackground {
            Divider()
            backgroundLifecycleMenuItems(session)
        }

        // Ende
        Divider()
        archiveMenuItem(session, allowsBulk: plan.allowsBulk)
    }

    // MARK: - Einzel-Bausteine

    /// Start/Resume/Restart — Labels bewusst identisch zum primären
    /// Header-Button („Start"/„Resume"/„Restart", nicht „Start Terminal").
    @ViewBuilder
    private func runtimeMenuItem(_ session: AgentChatSession) -> some View {
        let isRunning = terminalRegistry.controller(for: session.id)?.isRunning == true
        Button(
            isRunning ? "Restart" : (session.externalSessionID == nil ? "Start" : "Resume"),
            systemImage: isRunning ? "arrow.clockwise" : "play.fill"
        ) {
            sessionActionRequest = AgentSessionActionRequest(
                sessionID: session.id,
                kind: isRunning ? .restart : .start
            )
        }
    }

    /// „Job stoppen" für laufende Codex-Subagent-Kinder — derselbe Weg wie
    /// `agent stop`: SIGTERM an den Supervisor (vgl. SubagentJobDetailView).
    @ViewBuilder
    private func subagentStopMenuItem(_ session: AgentChatSession) -> some View {
        Button("Job stoppen", systemImage: "stop.circle") {
            guard let pid = jobRuntimeModel.snapshotsBySessionID[session.id]?.supervisorPid else { return }
            _ = kill(pid, SIGTERM)
            AgentJobWorkspaceSync.shared.requestSync(reason: "context-menu-stop")
        }
    }

    /// „In neues Fenster verschieben" — Bulk verschiebt die ganze Auswahl,
    /// singulär (Einzelansicht/Grid) exakt diese eine Session.
    @ViewBuilder
    private func windowMoveMenuItem(_ session: AgentChatSession, allowsBulk: Bool) -> some View {
        let count = allowsBulk ? actionGroup(for: session).count : 1
        Button(
            count > 1 ? "\(count) Tabs in neues Fenster" : "In neues Fenster verschieben",
            systemImage: "macwindow.badge.plus"
        ) {
            if allowsBulk {
                moveSelectionToNewWindow(session)
            } else {
                moveSingleTabToNewWindow(session)
            }
        }
    }

    /// Singuläre Variante von `moveSelectionToNewWindow` — ignoriert eine
    /// eventuell bestehende Mehrfachauswahl (strikt-singuläre Kontexte).
    private func moveSingleTabToNewWindow(_ session: AgentChatSession) {
        guard openTabIDs.contains(session.id) else { return }
        let newWindowID = windowStore.detachToNewWindow(session.id, from: windowID)
        DispatchQueue.main.async {
            openWindow(id: WindowRequest.agentChatWindowGroupID, value: newWindowID)
        }
    }

    @ViewBuilder
    private func newWorkspaceMenuItem(for session: AgentChatSession, allowsBulk: Bool) -> some View {
        if allowsBulk {
            newWorkspaceFromSelectionButton(for: session)
        } else {
            Button("Neuer Workspace mit diesem Chat", systemImage: "plus.square.on.square") {
                createWorkspaceFromSelection([session.id])
            }
        }
    }

    /// Anpinnen/Loslösen — Icon folgt dem Pin-Zustand der angeklickten
    /// Session (vorher hart codiert und teils widersprüchlich zum Label).
    @ViewBuilder
    private func pinMenuItem(_ session: AgentChatSession, allowsBulk: Bool) -> some View {
        let isPinned = pinnedSessionIDs.contains(session.id)
        Button(
            allowsBulk ? pinLabel(for: session) : (isPinned ? "Loslösen" : "Anpinnen"),
            systemImage: isPinned ? "pin.slash" : "pin"
        ) {
            if allowsBulk { togglePinSelection(session) } else { togglePin(session.id) }
        }
    }

    @ViewBuilder
    private func archiveMenuItem(_ session: AgentChatSession, allowsBulk: Bool) -> some View {
        if allowsBulk {
            Button(archiveLabel(for: session), systemImage: archiveIcon(for: session)) {
                archiveSelection(session)
            }
        } else {
            Button(
                session.isTerminal ? "Terminal schließen" : "Archivieren",
                systemImage: session.isTerminal ? "xmark.circle" : "archivebox"
            ) {
                requestArchive([session])
            }
        }
    }

    /// Lifecycle-Aktionen, die nur für `.backgroundChat`-Sessions Sinn
    /// ergeben (Policy hängt sie nur dort ein). Disabled-Zustand: Aktion
    /// läuft bereits oder Short-ID noch nicht bekannt (Spawn pending oder
    /// fehlgeschlagen).
    @ViewBuilder
    func backgroundLifecycleMenuItems(_ session: AgentChatSession) -> some View {
        let hasID = session.hasBackgroundShortID
        let busy = pendingLifecycleSessions.contains(session.id)
        Button("Logs anzeigen", systemImage: "doc.text.magnifyingglass") {
            showBackgroundLogs(for: session)
        }
        .disabled(!hasID || busy)
        Button("Stoppen", systemImage: "stop.circle") {
            performBackgroundLifecycle(.stop, on: session)
        }
        .disabled(!hasID || busy)
        Button("Respawn", systemImage: "arrow.clockwise.circle") {
            performBackgroundLifecycle(.respawn, on: session)
        }
        .disabled(!hasID || busy)
        Button("Vom Supervisor entfernen", systemImage: "trash", role: .destructive) {
            performBackgroundLifecycle(.rm, on: session)
        }
        .disabled(!hasID || busy)
    }
}
