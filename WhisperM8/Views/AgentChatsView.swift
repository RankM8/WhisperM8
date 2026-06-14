import AppKit
import SwiftUI

struct AgentChatsView: View {
    @State private var store = AgentSessionStore()
    /// P1 S6: Live-Projektion des Workspace-Stands. Facade-Mutationen
    /// spiegeln sich hier automatisch — die früheren ~24 manuellen
    /// `workspace = store.loadWorkspace()`-Reloads entfallen.
    @State private var workspaceModel = AgentWorkspaceUIModel.shared
    private var workspace: AgentWorkspace { workspaceModel.workspace }
    @State private var selectedProjectID: UUID?
    @State private var selectedSessionID: UUID?
    @State private var expandedProjectIDs: Set<UUID> = []
    @State private var searchText = ""
    @State private var errorMessage: String?
    @State private var isIndexingSessions = false
    @State private var indexRefreshTask: Task<Void, Never>?
    @State private var lastIndexStats: [AgentSessionIndexStats] = []
    @State private var sessionActionRequest: AgentSessionActionRequest?
    @StateObject private var terminalRegistry = AgentTerminalRegistry.shared
    /// Live-Status-Store für die Sidebar-Indikatoren. Wird vom
    /// `AgentSessionRuntimeWatcher` gepflegt, ephemeral (nicht persistiert).
    ///
    /// P4, WICHTIG: bewusst `@State` statt `@StateObject` — Status-Ticks
    /// dürfen NICHT den gesamten Body invalidieren; die Rows subscriben
    /// per-Item via `statusPublisher(for:)`. Der Body darf `.statuses`
    /// deshalb NIE direkt lesen (sonst stale UI ohne Invalidation).
    @State private var runtimeStatusStore = AgentSessionRuntimeStatusStore()
    /// Lazy-init in `setupRuntimeServicesIfNeeded()`, weil beide Services Refs
    /// auf Store + Closures brauchen, die wir vor `body` nicht haben.
    @State private var runtimeWatcher: AgentSessionRuntimeWatcher?
    @State private var autoNamer: AgentSessionAutoNamer?
    /// Mirror der `autoNamer.inFlight`-Set — wird via NotificationCenter
    /// aktualisiert, damit SwiftUI Re-Renders triggert. Wir koennen das nicht
    /// ueber @Observable machen weil autoNamer lazy-init in einem optionalen
    /// State lebt.
    @State private var autoRenamingSessionIDs: Set<UUID> = []
    /// Hook-Bridge fuer Real-Time-Detection von SessionStart/SessionEnd via
    /// Claude-Code-Hooks. Event-driven via `DispatchSource` — 0% idle CPU.
    @State private var claudeHookBridge: ClaudeHookBridge?
    /// Pending ambiguous-rebind-Picker. `nil` solange keine
    /// Mehrdeutigkeit erkannt wurde.
    @State private var pendingAmbiguousRebind: AmbiguousRebindRequest?
    @SceneStorage("agentChatsInspectorVisible") private var isInspectorVisible = false
    @SceneStorage("agentChatsSidebarVisible") private var isSidebarVisible = true
    /// Gemerktes Ziel für „Projekt öffnen in …" (Default PhpStorm, Finder
    /// wählbar). Die Wahl im Menü setzt den neuen Default.
    @AppStorage("agentProjectOpenTarget") private var projectOpenTargetRaw = ProjectOpenTarget.phpStorm.rawValue
    /// Offene Tabs der globalen Tab-Bar in Anzeige-Reihenfolge —
    /// projektübergreifend (UI-State Schema v2). Persistiert via AgentUIState.
    @State private var openTabIDs: [UUID] = []
    /// In der Sidebar angepinnte Chats (Pin-Reihenfolge). Gepinnte Sessions
    /// erscheinen exklusiv in der „Gepinnt"-Sektion. Persistiert.
    @State private var pinnedSessionIDs: [UUID] = []
    /// Das NSWindow des Agent-Chats-Fensters — vom `AgentChatsWindowAccessor`
    /// aufgelöst. Dient als Scope-Anker für den Cmd-W-Monitor (nur Events
    /// dieses Fensters schließen Tabs; Settings/Onboarding bleiben unberührt).
    @State private var hostWindow: NSWindow?
    /// Lokaler `keyDown`-Monitor für „Tab schließen" (Cmd-W). Wird in
    /// `onAppear` installiert, in `onDisappear` abgebaut. `Any?` weil
    /// `addLocalMonitorForEvents` ein opaques Token zurückgibt.
    @State private var closeTabKeyMonitor: Any?
    /// Lokaler `leftMouseDown`-Monitor für „Doppelklick auf die oberste Leiste
    /// = Fenster zoomen". Ersetzt das native Titelleisten-Verhalten, das durch
    /// hiddenTitleBar/fullSizeContentView verloren geht.
    @State private var titleBarZoomMonitor: Any?
    /// `true` waehrend wir den UIState aus der Sidecar-Datei laden. Verhindert
    /// dass die initialen .onChange-Trigger waehrend des Loads zurueck-saven.
    @State private var isLoadingPersistedUIState = true
    /// Debounce-Timer fuer Save-Operationen — verhindert Write-Spam bei
    /// rapid tab-switches.
    @State private var uiStatePersistTask: Task<Void, Never>?
    @State private var renameTargetID: UUID?
    @State private var renameDraft: String = ""
    @State private var renameProjectTargetID: UUID?
    @State private var renameProjectDraft: String = ""
    /// Projekt, für das gerade der Lösch-Bestätigungsdialog offen ist.
    @State private var projectPendingDeletion: AgentProject?
    /// Projekte, für die wir in dieser App-Session schon einen Auto-Icon-Lookup
    /// gestartet haben — verhindert wiederholte Filesystem-Scans bei jedem
    /// Workspace-Reload.
    @State private var iconLookupAttempted: Set<UUID> = []

    /// Wenn nicht-nil, zeigen wir das Background-Dispatch-Modal als Sheet.
    /// Bindet an ein Snapshot des aktuell selektierten Projekts, damit der
    /// User waehrend des Modals nicht aus Versehen das Projekt wechselt.
    @State private var pendingBackgroundDispatch: PendingBackgroundDispatch?
    /// Local-Session-ID einer Background-Session, die gerade noch spawned —
    /// die UI zeigt den Tab schon, aber `claude attach` startet erst nach
    /// dem Spawn-Callback. Verhindert dass der Detail-View sofort prepareCommand
    /// fuehrt (was ohne Short-ID failen wuerde).
    @State private var spawningBackgroundSessions: Set<UUID> = []
    /// Aktive Lifecycle-Aktionen (Logs/Stop/Respawn/Rm) — kennzeichnet die
    /// Session-ID waehrend des Subprocess-Aufrufs, damit das Context-Menu
    /// re-entrant-sicher ist.
    @State private var pendingLifecycleSessions: Set<UUID> = []
    /// Wenn nicht-nil, zeigen wir das Logs-Sheet fuer diese BG-Session.
    @State private var pendingBackgroundLogs: BackgroundLogsPresentation?
    /// `true` solange beim App-Start der Health-Check noch laeuft —
    /// verhindert mehrfache parallele Laeufe.
    @State private var hasRunStartupHealthCheck = false
    /// Session-IDs, fuer die wir ueber einen `Notification`-Hook ein
    /// "Needs Input"-Signal bekommen haben. Wird vom Notification-Listener
    /// gepflegt; die Sidebar pulst diese Sessions zusaetzlich zum
    /// regulaeren Runtime-Status.
    @State private var awaitingInputSessionIDs: Set<UUID> = []
    /// `true` solange das Sub-Agent-Library-Sheet sichtbar ist.
    @State private var subAgentLibrarySheet: SubAgentLibraryPresentation?
    /// Live-Tracker fuer die aktive Sub-Session innerhalb eines
    /// `.agentView`-TUI-Tabs. Polls `~/.claude/jobs/*/state.json` und meldet,
    /// wo der User gerade tippt / Claude gerade antwortet.
    @StateObject private var activeBackgroundTracker = ActiveBackgroundSessionTracker()

    private var selectedProject: AgentProject? {
        workspace.projects.first { $0.id == selectedProjectID } ?? workspace.projects.first
    }

    /// Sessions des Kontext-Projekts — nur noch Datenquelle für den
    /// Inspector. Die Tab-Bar ist global (`headerTabs`).
    private var projectSessions: [AgentChatSession] {
        guard let selectedProject else { return [] }
        return AgentSessionStore.sortedSessions(
            workspace.sessions.filter {
                $0.projectID == selectedProject.id
                    && $0.status != .archived
                    && $0.isManuallyCreated
            }
        )
    }

    /// Globale Tab-Bar: alle offenen Tabs über alle Projekte, in der
    /// Reihenfolge von `openTabIDs`.
    private var headerTabs: [AgentChatSession] {
        let byID = Dictionary(workspace.sessions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return openTabIDs.compactMap { byID[$0] }.filter { $0.status != .archived }
    }

    private var selectedSession: AgentChatSession? {
        guard let selectedSessionID else { return headerTabs.first }
        return workspace.sessions.first { $0.id == selectedSessionID && $0.status != .archived }
            ?? headerTabs.first
    }

    /// Projekt der selektierten Session — kann kurzzeitig vom
    /// Kontext-Projekt abweichen, bis `selectedProjectID` der Selektion
    /// gefolgt ist (onChange).
    private var selectedSessionProject: AgentProject? {
        guard let selectedSession else { return nil }
        return workspace.projects.first { $0.id == selectedSession.projectID }
    }

    private var manualProjects: [AgentProject] {
        AgentSessionStore.sortedProjects(
            workspace.projects.filter(\.isManuallyAdded)
        )
    }

    // P4: Die frühere computed-Property `visibleProjects` lebt jetzt als
    // pure Funktion in `AgentSidebarModelBuilder` und wird in
    // `hashboardSidebar` einmal pro Body-Eval gebunden.

    private var runningResourceDescriptors: [AgentResourceSessionDescriptor] {
        // Quelle: `workspace.sessions` ist `@State` — Updates triggern Re-Render der View
        // und damit Re-Berechnung dieser Property. `terminalRegistry.runningControllers`
        // hingegen tut das nicht zuverlässig, weil `controller.isRunning` ein innerer
        // ObservableObject-State ist und kein `@Published` auf der Registry selbst.
        workspace.sessions.compactMap { session in
            guard session.status == .running,
                  let project = workspace.projects.first(where: { $0.id == session.projectID })
            else {
                return nil
            }

            return AgentResourceSessionDescriptor(
                id: session.id,
                projectName: project.name,
                projectPath: project.path,
                title: session.title,
                provider: session.provider,
                rootProcessID: terminalRegistry.controller(for: session.id)?.processID
            )
        }
    }

    var body: some View {
        let _ = PerfSignposts.sidebar.emitEvent("sidebar.bodyEval.chats")
        HStack(spacing: 0) {
            if isSidebarVisible {
                hashboardSidebar
                    .frame(width: 276)
            }

            mainWorkspace
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if isInspectorVisible {
                ProjectDetailPanel(
                    project: selectedProject,
                    session: selectedSession,
                    sessions: projectSessions,
                    onRefresh: { AgentScanCoordinator.shared.requestScan(reason: .manual) },
                    onNewCodexChat: { createSession(provider: .codex) },
                    onNewClaudeChat: { createSession(provider: .claude) },
                    onOpenPHPStorm: openSelectedProjectInPHPStorm
                )
                .frame(width: 292)
            }
        }
        // Bewusst KEINE feste Mindestgröße mehr — der User soll das Fenster
        // so klein ziehen können, wie er will. Die einzige Untergrenze ist
        // jetzt der natürliche Platzbedarf des Inhalts (fixe Sidebar/Inspector
        // lassen sich per Toggle ausblenden, um noch kleiner zu werden).
        .background(AgentTheme.background)
        .background(AgentChatsWindowAccessor(onResolve: { hostWindow = $0 }))
        .ignoresSafeArea(.all, edges: .top)
        .sheet(isPresented: Binding(
            get: { renameTargetID != nil },
            set: { if !$0 { renameTargetID = nil } }
        )) {
            renameSheet
        }
        .sheet(isPresented: Binding(
            get: { renameProjectTargetID != nil },
            set: { if !$0 { renameProjectTargetID = nil } }
        )) {
            renameProjectSheet
        }
        .confirmationDialog(
            "Projekt löschen?",
            isPresented: Binding(
                get: { projectPendingDeletion != nil },
                set: { if !$0 { projectPendingDeletion = nil } }
            ),
            presenting: projectPendingDeletion
        ) { project in
            Button("Löschen: \(project.name)", role: .destructive) {
                deleteProject(project)
            }
            Button("Abbrechen", role: .cancel) {}
        } message: { project in
            let count = workspace.sessions.filter { $0.projectID == project.id }.count
            Text("Entfernt das Projekt und seine \(count) \(count == 1 ? "Chat" : "Chats") aus WhisperM8. Das Repo auf der Festplatte und die Claude/Codex-Transcripts bleiben unangetastet.")
        }
        .sheet(item: $pendingBackgroundDispatch) { pending in
            BackgroundDispatchModal(
                project: pending.project,
                availableSubAgents: pending.subAgents,
                onCancel: { pendingBackgroundDispatch = nil },
                onDispatch: { request in
                    pendingBackgroundDispatch = nil
                    Task { await dispatchBackgroundAgent(in: pending.project, request: request) }
                }
            )
        }
        .sheet(item: $pendingBackgroundLogs) { presentation in
            BackgroundAgentLogsSheet(
                presentation: presentation,
                onClose: { pendingBackgroundLogs = nil }
            )
        }
        .sheet(item: $subAgentLibrarySheet) { presentation in
            SubAgentLibrarySheet(
                presentation: presentation,
                onClose: { subAgentLibrarySheet = nil }
            )
        }
        .sheet(item: $pendingAmbiguousRebind) { request in
            AgentSessionAmbiguousRebindPicker(
                request: request,
                onChoice: { externalID in
                    applyAmbiguousRebindChoice(request: request, externalID: externalID)
                    pendingAmbiguousRebind = nil
                },
                onCancel: {
                    pendingAmbiguousRebind = nil
                }
            )
        }
        .onAppear {
            setupRuntimeServicesIfNeeded()
            loadWorkspaceFast()
            loadPersistedUIState()
            syncActiveAgentChat()
            migrateIconDetectionIfNeeded()
            attemptAutoDetectProjectIcons()
            runBackgroundAgentStartupHealthCheckIfNeeded()
            updateActiveBackgroundTrackerIfNeeded()
            installCloseTabShortcutIfNeeded()
            installTitleBarZoomHandlerIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: AgentChatsView.backgroundNeedsInputNotification)) { note in
            if let id = note.userInfo?["localID"] as? UUID {
                awaitingInputSessionIDs.insert(id)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: AgentChatsView.backgroundNeedsInputClearedNotification)) { note in
            if let id = note.userInfo?["localID"] as? UUID {
                awaitingInputSessionIDs.remove(id)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: AgentChatsView.ambiguousRebindNotification)) { note in
            guard let request = note.userInfo?["request"] as? AmbiguousRebindRequest else { return }
            // Wenn der User gerade nicht in diesem Tab ist, ueberspringen wir
            // den Picker und loggen es — die naechste UI-Interaktion kann
            // den Picker erneut triggern via Resume-Button.
            guard request.localSessionID == selectedSessionID else {
                Logger.claudeRecovery.info("recovery_picker_skipped reason=tab-not-selected localID=\(request.localSessionID.uuidString, privacy: .public)")
                return
            }
            pendingAmbiguousRebind = request
            Logger.claudeRecovery.info("recovery_picker_shown localID=\(request.localSessionID.uuidString, privacy: .public) candidates=\(request.candidates.count)")
        }
        .onChange(of: workspace.projects.map(\.id)) { _, _ in
            // Neue Projekte (z.B. nach Sessions-Scan) → ggf. Icon resolven.
            attemptAutoDetectProjectIcons()
        }
        .onDisappear {
            indexRefreshTask?.cancel()
            activeBackgroundTracker.stop()
            removeCloseTabShortcut()
            removeTitleBarZoomHandler()
            // Window zu → kein aktiver Chat mehr für Recording-Coordinator.
            AppState.shared.activeAgentChat = nil
        }
        .onChange(of: selectedSessionID) { _, newValue in
            syncActiveAgentChat()
            // Kontext-Projekt folgt der Selektion — Tabs sind global, das
            // Projekt ist nur noch Ziel für „Neuer Chat" und den Inspector.
            if let sessionID = newValue,
               let session = workspace.sessions.first(where: { $0.id == sessionID }) {
                selectedProjectID = session.projectID
            }
            schedulePersistUIState()
            updateActiveBackgroundTrackerIfNeeded()
        }
        .onChange(of: selectedProjectID) { _, _ in
            syncActiveAgentChat()
            schedulePersistUIState()
        }
        .onChange(of: workspace) { _, _ in
            syncActiveAgentChat()
            // P1 S6: Selektion darf nach Mutationen (z. B. deleteSession aus
            // dem Spawn-Fehlerpfad) nie auf Gelöschtes zeigen.
            reconcileSelection()
        }
        .onChange(of: openTabIDs) { _, _ in schedulePersistUIState() }
        .onChange(of: pinnedSessionIDs) { _, _ in schedulePersistUIState() }
        .onChange(of: expandedProjectIDs) { _, _ in schedulePersistUIState() }
        .onReceive(NotificationCenter.default.publisher(for: AgentScanCoordinator.scanRunningChangedNotification)) { note in
            guard let running = note.userInfo?["running"] as? Bool else { return }
            if running {
                // Spinner nur bei bewusst ausgelösten Scans: User-Refresh
                // (.manual) und App-Start (.launch). Die stillen
                // Hintergrund-Scans (.foreground bei Cmd-Tab, .fsEvent bei
                // externen Transcript-Writes) laufen unsichtbar — sonst
                // flackert das Label im Sekundentakt, obwohl es nichts zu
                // melden gibt.
                let reason = note.userInfo?["reason"] as? String
                isIndexingSessions = reason == AgentScanCoordinator.Reason.manual.rawValue
                    || reason == AgentScanCoordinator.Reason.launch.rawValue
            } else {
                // Abschluss räumt den Spinner immer ab, egal welcher Scan lief.
                isIndexingSessions = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: AgentSessionAutoNamer.inFlightDidChangeNotification)) { _ in
            autoRenamingSessionIDs = autoNamer?.inFlight ?? []
        }
        .onReceive(NotificationCenter.default.publisher(for: AgentScanCoordinator.scanDidCompleteNotification)) { _ in
            // Workspace neu laden — der Coordinator hat moeglicherweise neue
            // Sessions importiert oder Stale-Running-States gefixt.
            loadWorkspaceFast()
            attemptAutoDetectProjectIcons()
            // Auto-Rename fuer alle generisch-benannten Sessions anstossen.
            forceAutoNameUntitledSessions()
        }
    }

    // MARK: - UI-State Persistenz (Sidecar agent-ui-state.json)

    /// Laedt den persistierten UI-State und populiert die `@State`-Vars.
    /// Garbage-Collection laeuft im Store (entfernt stale UUIDs).
    /// First-Load-Migration ebenfalls im Store (populiert aus Workspace
    /// wenn die Sidecar-Datei fehlt).
    private func loadPersistedUIState() {
        let state = store.loadUIState()

        openTabIDs = state.openTabIDs
        pinnedSessionIDs = state.pinnedSessionIDs
        expandedProjectIDs = Set(state.expandedProjectIDs)

        // Session-Selection global; das Kontext-Projekt folgt der Session.
        // Fallback: persistiertes Projekt, sonst lässt loadWorkspaceFast
        // den Default setzen.
        if let sid = state.selectedSessionID,
           let session = workspace.sessions.first(where: { $0.id == sid && $0.status != .archived }) {
            selectedSessionID = sid
            selectedProjectID = session.projectID
        } else if let pid = state.selectedProjectID,
                  workspace.projects.contains(where: { $0.id == pid }) {
            selectedProjectID = pid
        }

        isLoadingPersistedUIState = false
    }

    /// Schedules ein debounced Save (500 ms) damit rapid tab-switches keinen
    /// Write-Spam verursachen. Beim ersten Load wird kein Save ausgeloest.
    private func schedulePersistUIState() {
        guard !isLoadingPersistedUIState else { return }
        uiStatePersistTask?.cancel()
        let snapshot = currentUIStateSnapshot()
        let storeRef = store
        uiStatePersistTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            try? storeRef.saveUIState(snapshot)
        }
    }

    /// Baut aus den aktuellen @State-Vars einen `AgentUIState` (Schema v2).
    /// Die Tab-Reihenfolge ist bereits die Anzeige-Reihenfolge der Bar.
    private func currentUIStateSnapshot() -> AgentUIState {
        AgentUIState(
            openTabIDs: openTabIDs,
            pinnedSessionIDs: pinnedSessionIDs,
            selectedSessionID: selectedSessionID,
            selectedProjectID: selectedProjectID,
            expandedProjectIDs: Array(expandedProjectIDs)
        )
    }

    /// Aktiviert den Tracker fuer "in TUI aktive Sub-Session" nur, wenn
    /// der gerade selektierte Tab ein `.agentView` ist. Sonst lassen wir
    /// das Polling schlafen, um keine Disk-I/O zu produzieren, wenn der
    /// User in einem normalen Chat ist.
    /// Verdrahtet ausserdem den Keystroke-Listener am TUI-Terminal: jeder
    /// Tastendruck triggert einen sofortigen `nudge()` am Tracker — so
    /// reagiert die "letzte Aktivitaet"-Anzeige sub-Sekunden-schnell beim
    /// Navigieren, statt aufs 5-Sekunden-Polling zu warten.
    private func updateActiveBackgroundTrackerIfNeeded() {
        // Vorigen Listener (falls vom letzten Tab da) abhaengen.
        for controller in terminalRegistry.runningControllers {
            controller.setUserKeystrokeListener(nil)
        }

        guard selectedSession?.isAgentView == true else {
            activeBackgroundTracker.stop()
            return
        }
        activeBackgroundTracker.start()

        // Neuen Listener nur am Controller der aktuell selektierten .agentView-
        // Session anhaengen — andere Controller bleiben unangetastet.
        if let session = selectedSession,
           let controller = terminalRegistry.controller(for: session.id) {
            controller.setUserKeystrokeListener { [weak activeBackgroundTracker] in
                activeBackgroundTracker?.nudge()
            }
        }
    }

    /// Spiegelt die aktuelle Selection (Session + Projekt) in `AppState.activeAgentChat`.
    /// Wird beim Recording-Start vom Coordinator gelesen und ins Context-Bundle übernommen.
    private func syncActiveAgentChat() {
        guard let project = selectedProject,
              let session = selectedSession,
              session.status != .archived
        else {
            if AppState.shared.activeAgentChat != nil {
                AppState.shared.activeAgentChat = nil
            }
            return
        }

        let ref = AgentChatContextRef(
            sessionID: session.id,
            provider: session.provider,
            projectName: project.name,
            projectPath: project.path,
            title: session.title,
            externalSessionID: session.externalSessionID,
            kind: session.effectiveKind,
            backgroundShortID: session.backgroundShortID
        )
        if AppState.shared.activeAgentChat != ref {
            AppState.shared.activeAgentChat = ref
        }
    }

    private var renameSheet: some View {
        let originalTitle = renameTargetID
            .flatMap { id in workspace.sessions.first(where: { $0.id == id })?.title }
            ?? ""
        return VStack(alignment: .leading, spacing: 14) {
            Text("Chat umbenennen")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AgentTheme.textPrimary)

            TextField("Tab-Name", text: $renameDraft)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(AgentTheme.surface, in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(AgentTheme.border, lineWidth: 1))
                .onSubmit { commitRename() }

            HStack {
                Spacer()
                Button("Abbrechen") { renameTargetID = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Speichern") { commitRename() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || renameDraft == originalTitle
                    )
            }
        }
        .padding(18)
        .frame(width: 360)
        .background(AgentTheme.panel)
    }

    private func commitRename() {
        guard let id = renameTargetID else { return }
        let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        renameSession(id: id, title: trimmed)
        renameTargetID = nil
    }

    private var renameProjectSheet: some View {
        let originalName = renameProjectTargetID
            .flatMap { id in workspace.projects.first(where: { $0.id == id })?.name }
            ?? ""
        return VStack(alignment: .leading, spacing: 14) {
            Text("Projekt umbenennen")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AgentTheme.textPrimary)

            TextField("Projekt-Name", text: $renameProjectDraft)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(AgentTheme.surface, in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(AgentTheme.border, lineWidth: 1))
                .onSubmit { commitProjectRename() }

            HStack {
                Spacer()
                Button("Abbrechen") { renameProjectTargetID = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Speichern") { commitProjectRename() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        renameProjectDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || renameProjectDraft == originalName
                    )
            }
        }
        .padding(18)
        .frame(width: 360)
        .background(AgentTheme.panel)
    }

    private func commitProjectRename() {
        guard let id = renameProjectTargetID else { return }
        let trimmed = renameProjectDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        renameProject(id: id, name: trimmed)
        renameProjectTargetID = nil
    }

    private var hashboardSidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                // Reservierter Bereich für die macOS-Window-Controls (rot/gelb/grün
                // floaten transparent über der Sidebar bei x ≈ 8–78).
                Spacer().frame(width: 70)
                Spacer(minLength: 4)
                AgentResourceSummaryButton(descriptors: runningResourceDescriptors)
            }
            .padding(.trailing, 8)
            .frame(height: 28)

            if isIndexingSessions {
                Label("Sessions werden gescannt", systemImage: "arrow.triangle.2.circlepath")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(AgentTheme.textTertiary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
            }

            // Fest verankert: Befehle (Neuer Chat / Aktualisieren / Projekt
            // hinzufügen) + Filter scrollen NICHT mit — nur die Chat-Liste
            // darunter scrollt.
            sidebarCommandRows
                .padding(.horizontal, 8)
                .padding(.top, 2)
                .padding(.bottom, 6)

            ScrollView {
                // P4: Sidebar-Modell EINMAL pro Body-Eval bauen (Gruppierung +
                // Suche in einem Durchlauf) statt pro Projekt neu zu filtern
                // und zu sortieren.
                let openTabIDSet = Set(openTabIDs)
                let sessionsByProject = AgentSidebarModelBuilder.sessionsByProject(
                    workspaceSessions: workspace.sessions,
                    pinnedSessionIDs: Set(pinnedSessionIDs)
                )
                let visibleProjects = AgentSidebarModelBuilder.visibleProjects(
                    manualProjects: manualProjects,
                    sessionsByProject: sessionsByProject,
                    query: searchText
                )
                let trimmedQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                let visiblePinned = AgentSidebarModelBuilder.pinnedSessions(
                    workspaceSessions: workspace.sessions,
                    pinnedSessionIDs: pinnedSessionIDs
                ).filter { trimmedQuery.isEmpty || $0.title.localizedCaseInsensitiveContains(trimmedQuery) }
                // isRunning-Flips published die Registry nicht selbst; frisch
                // wird das Set bei jedem Body-Eval (Registry-Inserts/Removes
                // sind @Published und triggern den). Für Live-Status zählt
                // ohnehin `liveStatus` in der Row — isRunning ist nur der
                // Fallback, solange der Watcher noch keinen Status hat.
                let runningSessionIDs = terminalRegistry.activeSessionIDs
                VStack(alignment: .leading, spacing: 8) {
                    if visibleProjects.isEmpty && searchText.isEmpty {
                        sidebarEmptyState
                    }

                    if !visiblePinned.isEmpty {
                        sidebarSectionLabel("Gepinnt", systemImage: "pin")
                        ForEach(visiblePinned) { session in
                            pinnedRow(session, runningSessionIDs: runningSessionIDs)
                        }
                        sidebarSectionLabel("Chats")
                    }

                    ForEach(visibleProjects) { project in
                        ProjectChatGroup(
                            project: project,
                            sessions: sessionsByProject[project.id] ?? [],
                            isExpanded: expandedProjectIDs.contains(project.id) || !searchText.isEmpty,
                            selectedSessionID: selectedSessionID,
                            openTabIDs: openTabIDSet,
                            onSelectProject: {
                                selectProject(project.id)
                            },
                            onToggleExpanded: {
                                toggleProject(project.id)
                            },
                            onSelectSession: { sessionID in
                                selectedProjectID = project.id
                                expandedProjectIDs.insert(project.id)
                                openTab(sessionID)
                                selectedSessionID = sessionID
                                AppPreferences.shared.agentDefaultProjectPath = project.path
                            },
                            onNewChat: {
                                selectedProjectID = project.id
                                expandedProjectIDs.insert(project.id)
                                createDefaultSession()
                            },
                            onCloseSession: { archiveSession($0) },
                            onPinSession: { pinSession($0) },
                            onForkSession: { forkSession($0) },
                            onRenameRequest: { beginRename($0) },
                            onAutoNameRequest: { forceAutoNameSession($0) },
                            onRename: renameSession,
                            onSetColor: setSessionColor,
                            runningSessionIDs: runningSessionIDs,
                            statusStore: runtimeStatusStore,
                            awaitingInputSessionIDs: awaitingInputSessionIDs,
                            autoRenamingSessionIDs: autoRenamingSessionIDs,
                            onRenameProjectRequest: { beginRenameProject($0) },
                            onSetProjectColor: setProjectColor,
                            onChooseProjectIcon: { chooseProjectIcon($0) },
                            onAutoDetectProjectIcon: { reAutoDetectProjectIcon($0) },
                            onClearProjectIcon: { clearProjectIcon($0) },
                            onDeleteProject: { projectPendingDeletion = $0 },
                            onSessionDrop: { dropped, beforeID, targetProjectID in
                                dropSession(dropped, in: targetProjectID, beforeSessionID: beforeID)
                            },
                            onProjectDrop: { dropped, beforeID in
                                dropProject(dropped, beforeProjectID: beforeID)
                            }
                        )
                    }
                }
                .padding(.vertical, 6)
            }

            Spacer(minLength: 0)

            sidebarFooter
        }
        .background(AgentTheme.sidebar)
    }

    /// Kleines Uppercase-Label über einer Sidebar-Sektion („Gepinnt", „Chats").
    private func sidebarSectionLabel(_ text: String, systemImage: String? = nil) -> some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 8, weight: .bold))
            }
            Text(text.uppercased())
                .font(.system(size: 9, weight: .bold))
                .tracking(0.6)
            Spacer(minLength: 0)
        }
        .foregroundStyle(AgentTheme.textTertiary)
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 2)
    }

    /// Zeile der Gepinnt-Sektion inkl. Kontextmenü (Loslösen, Umbenennen,
    /// Auto-Titel, Farbe, Schließen). Gepinnte Chats sind projektübergreifend —
    /// das Repo-Badge stellt die Zuordnung her.
    @ViewBuilder
    private func pinnedRow(_ session: AgentChatSession, runningSessionIDs: Set<UUID>) -> some View {
        PinnedSessionRow(
            session: session,
            project: workspace.projects.first { $0.id == session.projectID },
            isSelected: selectedSessionID == session.id,
            isRunning: runningSessionIDs.contains(session.id),
            statusStore: runtimeStatusStore,
            isAwaitingInput: awaitingInputSessionIDs.contains(session.id),
            onSelect: {
                openTab(session.id)
                selectedSessionID = session.id
            },
            onClose: { archiveSession(session) }
        )
        .contextMenu {
            Button("Loslösen", systemImage: "pin.slash") {
                unpinSession(session.id)
            }
            Divider()
            Button("Umbenennen…", systemImage: "pencil") {
                beginRename(session)
            }
            Button("Titel automatisch generieren", systemImage: "sparkles") {
                forceAutoNameSession(session)
            }
            .disabled(session.externalSessionID == nil)
            forkMenuItem(session)
            tabColorMenu(for: session)
            Divider()
            Button("Chat schließen", systemImage: "xmark", role: .destructive) {
                archiveSession(session)
            }
        }
    }

    private var sidebarEmptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Noch keine Projekte")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AgentTheme.textSecondary)
            Text("Füge ein Projekt hinzu, um Codex- oder Claude-Chats darin anzulegen.")
                .font(.system(size: 11))
                .foregroundStyle(AgentTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                addProject()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 11, weight: .medium))
                    Text("Projekt hinzufügen")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(AgentTheme.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(AgentTheme.surface, in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(AgentTheme.border, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var sidebarFooter: some View {
        HStack(spacing: 4) {
            Button {
                WindowRequestCenter.shared.request(.settings)
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 16)
                    Text("Settings")
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                }
                .foregroundStyle(AgentTheme.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(SidebarRowButtonStyle())
            .help("Einstellungen öffnen")

            Button {
                WindowRequestCenter.shared.request(.onboarding)
            } label: {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AgentTheme.textSecondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Onboarding / Hilfe öffnen")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
    }

    private var defaultAgentProvider: AgentProvider {
        AppPreferences.shared.defaultAgentLaunchTarget.provider
    }

    private var defaultAgentKind: AgentSessionKind? {
        AppPreferences.shared.defaultAgentLaunchTarget.kind
    }

    private func createDefaultSession() {
        let target = AppPreferences.shared.defaultAgentLaunchTarget
        createSession(provider: target.provider, kind: target.kind)
    }

    private var sidebarCommandRows: some View {
        VStack(spacing: 1) {
            Button {
                createDefaultSession()
            } label: {
                SidebarCommandRow(icon: "square.stack.3d.up", title: "Neuer Chat", isActive: selectedProject != nil)
            }
            .buttonStyle(SidebarRowButtonStyle())
            .disabled(selectedProject == nil)
            .help("Neuen Codex Chat im aktuellen Projekt starten")

            Button {
                AgentScanCoordinator.shared.requestScan(reason: .manual)
            } label: {
                SidebarCommandRow(icon: "arrow.clockwise", title: "Aktualisieren")
            }
            .buttonStyle(SidebarRowButtonStyle())
            .keyboardShortcut("r", modifiers: .command)
            .help("Sessions neu einlesen (⌘R)")

            Button {
                addProject()
            } label: {
                SidebarCommandRow(icon: "plus", title: "Projekt hinzufügen", trailingIcon: "folder.badge.plus")
            }
            .buttonStyle(SidebarRowButtonStyle())
            .help("Ordner als Projekt hinzufügen")

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(AgentTheme.textTertiary)
                TextField("Filter…", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(AgentTheme.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 2)
        }
    }

    private var mainWorkspace: some View {
        VStack(spacing: 0) {
            projectChatStrip

            if let selectedSession, let project = selectedSessionProject {
                AgentSessionDetailView(
                    project: project,
                    session: selectedSession,
                    terminalRegistry: terminalRegistry,
                    actionRequest: sessionActionRequest,
                    onStateChanged: loadWorkspaceFast,
                    onSessionLaunched: { sessionID in
                        attachWatcher(sessionID: sessionID)
                    },
                    onSessionTerminated: { sessionID, exitCode in
                        runtimeWatcher?.markTerminated(sessionID: sessionID, exitCode: exitCode)
                        claudeHookBridge?.stopTracking(localSessionID: sessionID)
                    },
                    onExternalSessionIDBound: { sessionID in
                        attachWatcher(sessionID: sessionID)
                    },
                    onPrepareClaudeHookArguments: { sessionID in
                        claudeHookBridge?.prepareLaunch(localSessionID: sessionID) ?? []
                    },
                    onClaudeHookLaunched: { sessionID in
                        claudeHookBridge?.startTracking(localSessionID: sessionID)
                    }
                )
                .id(selectedSession.id)
                .padding(.top, 14)
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
                .background(AgentTheme.background)
            } else {
                ContentUnavailableView("Kein Agent Chat", systemImage: "terminal")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(AgentTheme.background)
    }

    private var projectChatStrip: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                if !isSidebarVisible {
                    Spacer().frame(width: 70)
                }

                TitlebarIconButton(systemImage: "sidebar.left", help: isSidebarVisible ? "Sidebar ausblenden" : "Sidebar einblenden", isActive: isSidebarVisible) {
                    isSidebarVisible.toggle()
                }

                if !headerTabs.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        let runningSessionIDs = terminalRegistry.activeSessionIDs
                        HStack(spacing: 4) {
                            ForEach(headerTabs) { session in
                                ChatTabButton(
                                    session: session,
                                    project: workspace.projects.first { $0.id == session.projectID },
                                    isSelected: session.id == selectedSession?.id,
                                    isRunning: runningSessionIDs.contains(session.id),
                                    statusStore: runtimeStatusStore,
                                    isAwaitingInput: awaitingInputSessionIDs.contains(session.id),
                                    onSelect: {
                                        selectedSessionID = session.id
                                    },
                                    onClose: {
                                        closeTab(session)
                                    }
                                )
                                // Mittelklick (Mausrad) schließt den Tab — wie im Browser.
                                .onMiddleClick { closeTab(session) }
                                .draggable(DraggableSession(sessionID: session.id, sourceProjectID: session.projectID))
                                .dropDestination(for: DraggableSession.self) { items, _ in
                                    guard let dropped = items.first else { return false }
                                    // Tab-Reorder = reine Anzeige-Reihenfolge der
                                    // globalen Bar — unabhängig vom Store-sortIndex.
                                    dropTab(dropped, before: session.id)
                                    return true
                                }
                                .contextMenu {
                                    sessionManagementMenu(session)
                                }
                            }
                        }
                    }
                    .background {
                        // Unsichtbare Shortcut-Anker: ⌘1–⌘9 springen auf
                        // Tab 1–9 der globalen Tab-Bar.
                        ForEach(Array(headerTabs.prefix(9).enumerated()), id: \.element.id) { index, session in
                            Button("") { selectedSessionID = session.id }
                                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                                .frame(width: 0, height: 0)
                                .opacity(0)
                                .accessibilityHidden(true)
                        }
                    }
                }

                Menu {
                    Button("Neuer Codex Chat") { createSession(provider: .codex) }
                    Button("Neuer Claude Chat") { createSession(provider: .claude) }
                    Divider()
                    Button("Neuer Hintergrund-Agent…") { presentBackgroundDispatchModal() }
                        .disabled(selectedProject == nil)
                    Divider()
                    Button("Neuer Claude Agent View") {
                        createSession(provider: .claude, kind: .agentView)
                    }
                    Divider()
                    Button("Sub-Agent-Bibliothek anzeigen…") { presentSubAgentLibrary() }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(AgentTheme.textSecondary)
                        .frame(width: 22, height: 22)
                        .background(AgentTheme.control.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(selectedProject == nil)
                .help("Neuen Chat anlegen")

                Spacer(minLength: 8)

                // Branch-Badge entfernt — die Branch steht ohnehin schon in
                // der Sidebar-Projekt-Zeile und im Project-Inspector, und
                // visueller Clutter im Titlebar-Bereich kostet mehr als er
                // hier liefert.

                TitlebarIconButton(systemImage: "sidebar.right", help: isInspectorVisible ? "Projekt-Kontext ausblenden" : "Projekt-Kontext anzeigen", isActive: isInspectorVisible) {
                    isInspectorVisible.toggle()
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)

            activeChatStatusRow
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
        }
        .background(AgentTheme.header)
    }

    /// Prominenter „in welchem Chat / welchem Repo bin ich"-Header — dritte
    /// Header-Zeile ueber dem PTY. Zeigt:
    /// - Session-Title (semibold) + Sub-Kind-Indikator (BG / VIEW)
    /// - Projekt-Name + Branch (kleiner, monospaced)
    /// - Bei `.agentView`-Tabs zusaetzlich: aktive Sub-Session innerhalb
    ///   der TUI, live-getrackt ueber `~/.claude/jobs/*/state.json`
    /// - Runtime-Info (Provider · Modell · Status) ganz rechts
    @ViewBuilder
    private var activeChatStatusRow: some View {
        HStack(alignment: .center, spacing: 10) {
            statusDot

            VStack(alignment: .leading, spacing: 2) {
                primaryTitleRow
                secondaryProjectRow
                if selectedSession?.isAgentView == true {
                    tuiActiveSubSessionRow
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Rechts in den freien Platz: die früher eigene Header-Zeile —
            // „+ Claude" / „+ Codex", die Session-Aktionen (Runtime · Restart ·
            // …-Menü) und der IDE-Opener. `fixedSize` hält die Controls auf
            // ihrer natürlichen Breite, sodass stattdessen der Projektpfad
            // links gekürzt wird.
            HStack(spacing: 8) {
                newChatButton(provider: .claude)
                newChatButton(provider: .codex)
                if let selectedSession {
                    selectedSessionHeaderControls(selectedSession)
                }
                if let project = selectedProject {
                    Menu {
                        ForEach(ProjectOpenTarget.allCases, id: \.self) { target in
                            Button {
                                // Wahl als neuen Default merken + sofort öffnen.
                                projectOpenTargetRaw = target.rawValue
                                openProject(project, in: target)
                            } label: {
                                Label("In \(target.label) öffnen", systemImage: target.systemImage)
                            }
                        }
                    } label: {
                        Image(systemName: projectOpenTarget.systemImage)
                            .font(.system(size: 11))
                            .foregroundStyle(AgentTheme.textTertiary)
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    } primaryAction: {
                        openProject(project, in: projectOpenTarget)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("In \(projectOpenTarget.label) öffnen · Pfeil für Auswahl")
                }
            }
            .fixedSize()
        }
    }

    private var projectOpenTarget: ProjectOpenTarget {
        ProjectOpenTarget(rawValue: projectOpenTargetRaw) ?? .phpStorm
    }

    /// Live-Anzeige der Sub-Session, in der zuletzt Aktivitaet passierte —
    /// nur sichtbar wenn der aktive Tab eine `.agentView`-TUI ist.
    /// Quelle: `ActiveBackgroundSessionTracker` (5s-Polling +
    /// Keystroke-Nudge). Wir labeln das explizit als "letzte Aktivitaet"
    /// und zeigen die relative Zeit dazu — denn wir koennen nicht
    /// erkennen, welche Row die TUI gerade selektiert hat, sondern nur,
    /// in welcher Session sich zuletzt etwas geschrieben hat.
    @ViewBuilder
    private var tuiActiveSubSessionRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.turn.down.right")
                .font(.system(size: 9))
                .foregroundStyle(.orange.opacity(0.8))
            if let active = activeBackgroundTracker.currentSession {
                Text("letzte Aktivität:")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(AgentTheme.textTertiary)
                Text(active.displayName)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(AgentTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text("·")
                    .font(.system(size: 10))
                    .foregroundStyle(AgentTheme.textTertiary)
                Image(systemName: "folder")
                    .font(.system(size: 9))
                    .foregroundStyle(AgentTheme.textTertiary)
                Text(active.projectDisplayName)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(AgentTheme.textSecondary)
                    .lineLimit(1)
                Text("·")
                    .font(.system(size: 10))
                    .foregroundStyle(AgentTheme.textTertiary)
                Text(active.shortID)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(AgentTheme.textTertiary)
                if let stateLabel = active.state, !stateLabel.isEmpty {
                    kindBadge(stateLabel.uppercased(), color: stateColor(for: stateLabel))
                }
                // Relative-Zeit-Anzeige fuer "vor wie lange". Bindet auf
                // `currentTimeForRelativeLabels`, damit der Text sich pro
                // Sekunde aktualisiert ohne den Tracker neu zu pollen.
                Text("· vor \(relativeDurationLabel(from: active.lastActivityAt))")
                    .font(.system(size: 10))
                    .foregroundStyle(AgentTheme.textTertiary)
                    .help("Zeitpunkt der letzten Schreibaktivität in der JSONL dieser Session. Reine TUI-Navigation ohne Schreiben ist nicht detektierbar.")
            } else {
                Text("letzte Aktivität: — keine Schreibaktivität im JSONL-Pool")
                    .font(.system(size: 10))
                    .foregroundStyle(AgentTheme.textTertiary)
                    .help("Sub-Sessions werden hier sichtbar, sobald Claude in deren JSONL schreibt oder du in der TUI eine Taste drückst. Reines Mit-den-Pfeiltasten-Navigieren reicht nicht — WhisperM8 hat keinen Direktzugriff auf den TUI-internen Fokus.")
            }
        }
    }

    /// Liefert "12s", "3m", "1h 4m" — kurze Beschriftung der Differenz
    /// zwischen `date` und jetzt. Pure-Funktion fuer einfache Testbarkeit.
    private func relativeDurationLabel(from date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 1 { return "gerade eben" }
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let remainingMinutes = minutes - hours * 60
        return remainingMinutes == 0 ? "\(hours)h" : "\(hours)h \(remainingMinutes)m"
    }

    /// Hex-Farbe fuer den State-Indikator pro TUI-State.
    private func stateColor(for state: String) -> Color {
        switch state.lowercased() {
        case "working", "running":
            return .green
        case "blocked", "needs_input", "awaiting":
            return .orange
        case "done", "completed", "succeeded":
            return AgentTheme.textTertiary
        case "errored", "failed":
            return .red
        default:
            return AgentTheme.textSecondary
        }
    }

    /// Klein-aber-prominenter Status-Dot links: gruen wenn das PTY laeuft,
    /// orange bei Needs-Input (Hook-Bridge), grau wenn keine Session da.
    @ViewBuilder
    private var statusDot: some View {
        if let selectedSession {
            let running = terminalRegistry.controller(for: selectedSession.id)?.isRunning == true
            let needsInput = awaitingInputSessionIDs.contains(selectedSession.id)
            let color: Color = {
                if needsInput { return .orange }
                if running { return .green }
                return AgentTheme.textTertiary
            }()
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
        } else {
            Circle()
                .fill(AgentTheme.textTertiary.opacity(0.4))
                .frame(width: 7, height: 7)
        }
    }

    @ViewBuilder
    private var primaryTitleRow: some View {
        HStack(spacing: 6) {
            if let selectedSession {
                Text(selectedSession.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AgentTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if selectedSession.isBackgroundChat {
                    kindBadge("BG", color: .indigo)
                        .help("Hintergrund-Agent · vom Claude-Supervisor gehostet")
                    if let shortID = selectedSession.backgroundShortID, !shortID.isEmpty {
                        Text(shortID)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(AgentTheme.textTertiary)
                            .help("Background-Agent Short-ID")
                    }
                } else if selectedSession.isAgentView {
                    kindBadge("VIEW", color: .orange)
                        .help("Claude Agents View · Multi-Session-Dashboard. Der aktive Sub-Chat innerhalb der TUI ist von WhisperM8 aus nicht erkennbar.")
                }
            } else if let selectedProject {
                Text(selectedProject.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AgentTheme.textPrimary)
                    .lineLimit(1)
            } else {
                Text("Kein Chat ausgewählt")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AgentTheme.textTertiary)
            }
        }
    }

    @ViewBuilder
    private var secondaryProjectRow: some View {
        if let project = selectedSessionProject ?? selectedProject {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(.system(size: 9))
                    .foregroundStyle(AgentTheme.textTertiary)
                Text(project.name)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(AgentTheme.textSecondary)
                    .lineLimit(1)
                if let branch = project.lastBranch, !branch.isEmpty {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 9))
                        .foregroundStyle(AgentTheme.textTertiary)
                    Text(branch)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(AgentTheme.textTertiary)
                        .lineLimit(1)
                }
                Text("·")
                    .font(.system(size: 10))
                    .foregroundStyle(AgentTheme.textTertiary)
                Text(project.path)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(AgentTheme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(project.path)
            }
        } else {
            Color.clear.frame(height: 12)
        }
    }

    @ViewBuilder
    private func kindBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .bold))
            .tracking(0.04)
            .foregroundStyle(color)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(color.opacity(0.16), in: RoundedRectangle(cornerRadius: 3))
            .overlay(
                RoundedRectangle(cornerRadius: 3).stroke(color.opacity(0.30), lineWidth: 0.5)
            )
            .fixedSize()
    }

    /// „＋ Claude" / „＋ Codex" — öffnet direkt einen neuen Tab mit diesem
    /// Provider im Kontext-Projekt (ersetzt den früheren Provider-Umschalter).
    private func newChatButton(provider: AgentProvider) -> some View {
        Button {
            createSession(provider: provider)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "plus")
                    .font(.system(size: 8, weight: .bold))
                ProviderIcon(provider: provider, size: 11, tint: AgentTheme.textSecondary)
                Text(provider.displayName)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(AgentTheme.textSecondary)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(AgentTheme.control.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(selectedProject == nil)
        .help("Neuen \(provider.displayName) Chat in \(selectedProject?.name ?? "—") öffnen")
    }

    private func selectedSessionHeaderControls(_ session: AgentChatSession) -> some View {
        let controller = terminalRegistry.controller(for: session.id)
        let isRunning = controller?.isRunning == true

        return HStack(spacing: 6) {
            HStack(spacing: 5) {
                Circle()
                    .fill(isRunning ? AgentTheme.textSecondary : AgentTheme.textTertiary)
                    .frame(width: 5, height: 5)
                Text(session.runtimeDisplayText)
                    .font(.system(size: 10, weight: .regular).monospacedDigit())
                    .foregroundStyle(AgentTheme.textTertiary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)

            Button {
                sessionActionRequest = AgentSessionActionRequest(
                    sessionID: session.id,
                    kind: isRunning ? .restart : .start
                )
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: isRunning ? "arrow.clockwise" : "play.fill")
                        .font(.system(size: 9, weight: .medium))
                    Text(isRunning ? "Restart" : (session.externalSessionID == nil ? "Start" : "Resume"))
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(AgentTheme.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(AgentTheme.control.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)

            Menu {
                Button(isRunning ? "Restart" : (session.externalSessionID == nil ? "Start Terminal" : "Resume Terminal"), systemImage: isRunning ? "arrow.clockwise" : "play.fill") {
                    sessionActionRequest = AgentSessionActionRequest(
                        sessionID: session.id,
                        kind: isRunning ? .restart : .start
                    )
                }
                Button("Umbenennen…", systemImage: "pencil") {
                    beginRename(session)
                }
                Button("Titel automatisch generieren", systemImage: "sparkles") {
                    forceAutoNameSession(session)
                }
                .disabled(session.externalSessionID == nil)
                forkMenuItem(session)
                Divider()
                Button(
                    pinnedSessionIDs.contains(session.id) ? "Loslösen" : "Anpinnen",
                    systemImage: pinnedSessionIDs.contains(session.id) ? "pin.slash" : "pin"
                ) {
                    togglePin(session.id)
                }
                tabColorMenu(for: session)
                Divider()
                Button("Tab schließen", systemImage: "xmark.square") {
                    closeTab(session)
                }
                Button("Chat schließen", systemImage: "xmark", role: .destructive) {
                    archiveSession(session)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AgentTheme.textTertiary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Chat-Aktionen")
        }
    }

    private func refresh() {
        loadWorkspaceFast()
        AgentScanCoordinator.shared.requestScan(reason: .manual)
    }

    /// Lazy-init der Runtime-Services. Wird einmal beim ersten `onAppear`
    /// aufgerufen — verträgt aber Re-Calls, weil sie sich mit `nil`-Check
    /// schützen. Wir können das nicht im `init()` machen, weil
    /// `runtimeStatusStore` ein `@StateObject` ist und vor `body` noch nicht
    /// instanziiert ist.
    private func setupRuntimeServicesIfNeeded() {
        if autoNamer == nil {
            autoNamer = AgentSessionAutoNamer(store: store)
        }
        if runtimeWatcher == nil {
            let store = self.store
            let statusStore = runtimeStatusStore
            let watcher = AgentSessionRuntimeWatcher(statusStore: statusStore) { [weak autoNamer] sessionID in
                AgentChatsView.handleTurnFinished(
                    sessionID: sessionID,
                    store: store,
                    autoNamer: autoNamer
                ) {
                    // Wir können hier kein `self` capturen (wäre stale beim
                    // mehrfachen Watcher-Init); der Workspace-Reload passiert
                    // beim nächsten `loadWorkspaceFast`-Tick (Indexer-Refresh
                    // bzw. UI-Reload).
                }
            }
            runtimeWatcher = watcher
        }
        if claudeHookBridge == nil {
            let store = self.store
            let registry = terminalRegistry
            let bridge = ClaudeHookBridge()
            bridge.setDecisionHandler { localID, event in
                AgentChatsView.handleClaudeHookEvent(
                    localID: localID,
                    event: event,
                    store: store,
                    terminalRegistry: registry
                )
            }
            claudeHookBridge = bridge
        }
    }

    /// Notification fuer den ambiguous-rebind-Picker (Phase 6).
    static let ambiguousRebindNotification = Notification.Name("AgentChatsView.ambiguousRebind")
    /// Wird vom Hook-Bridge-Handler bei `Notification`-Events gepostet —
    /// die View fuegt die `localID` aus `userInfo["localID"]` in
    /// `awaitingInputSessionIDs` ein.
    static let backgroundNeedsInputNotification = Notification.Name("AgentChatsView.backgroundNeedsInput")
    /// Pendant zum oberen — entfernt die localID wieder (z. B. nach
    /// `.preToolUse` oder `.sessionEnd`).
    static let backgroundNeedsInputClearedNotification = Notification.Name("AgentChatsView.backgroundNeedsInputCleared")

    /// Verarbeitet die User-Wahl im Ambiguous-Picker. `externalID == nil`
    /// bedeutet "Neue Session starten" — wir nullen die externe ID und
    /// markieren die Session als nicht gelauncht, damit der naechste
    /// Resume-Klick einen frischen Claude-Lauf startet.
    private func applyAmbiguousRebindChoice(request: AmbiguousRebindRequest, externalID: String?) {
        do {
            try store.updateSession(id: request.localSessionID) { session in
                let old = session.externalSessionID
                session.externalSessionID = externalID
                if externalID == nil {
                    session.hasLaunchedInitialPrompt = false
                }
                Logger.claudeRecovery.info("recovery_user_chose localID=\(request.localSessionID.uuidString, privacy: .public) old=\(old ?? "nil", privacy: .public) new=\(externalID ?? "nil", privacy: .public)")
            }
            Task { @MainActor in
                terminalRegistry.controller(for: request.localSessionID)?
                    .updateExternalSessionID(externalID)
            }
            loadWorkspaceFast()
        } catch {
            Logger.claudeRecovery.warning("recovery_user_chose_failed localID=\(request.localSessionID.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }

    /// Hook-Event-Handler: bei `SessionStart` mit nicht-leerer `session_id`
    /// updaten wir die externalSessionID; bei `SessionEnd(reason: "resume")`
    /// machen wir uns mental "darauf bereit, dass eine neue ID kommt" —
    /// behalten aber die alte ID bis das naechste SessionStart-Event kommt.
    private static func handleClaudeHookEvent(
        localID: UUID,
        event: ClaudeHookEvent,
        store: AgentSessionStore,
        terminalRegistry: AgentTerminalRegistry
    ) {
        switch event.hookEventName {
        case .sessionStart:
            guard let newID = event.sessionID, !newID.isEmpty else { return }
            do {
                try store.updateSession(id: localID) { session in
                    let old = session.externalSessionID
                    guard old != newID else { return }
                    session.externalSessionID = newID
                    Logger.claudeBinding.info("binding_launch_id_set localID=\(localID.uuidString, privacy: .public) old=\(old ?? "nil", privacy: .public) new=\(newID, privacy: .public)")
                }
                Task { @MainActor in
                    terminalRegistry.controller(for: localID)?.updateExternalSessionID(newID)
                }
            } catch {
                Logger.claudeBinding.warning("binding_launch_set_failed localID=\(localID.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            }
        case .sessionEnd:
            // /resume-Wechsel ist erwartet — naechstes SessionStart wird die
            // neue ID liefern. Nichts tun ausser Logging. Ein eventueller
            // "Needs input"-Pulse wird vom Notification-Listener selbst
            // bei .preToolUse / SessionStart geclearet — beim Ende ist die
            // Session ohnehin nicht mehr "awaiting".
            let reason = event.reason ?? "unknown"
            Logger.claudeBinding.info("binding_session_end localID=\(localID.uuidString, privacy: .public) reason=\(reason, privacy: .public)")
            NotificationCenter.default.post(
                name: AgentChatsView.backgroundNeedsInputClearedNotification,
                object: nil,
                userInfo: ["localID": localID]
            )
        case .preToolUse:
            // Tool-Use bedeutet: die Session arbeitet wieder, also ist ein
            // "Needs input"-Pulse veraltet. Wir clearen ihn — der naechste
            // Notification-Event setzt ihn bei Bedarf erneut.
            Logger.claudeBinding.debug("binding_pretool_use localID=\(localID.uuidString, privacy: .public)")
            NotificationCenter.default.post(
                name: AgentChatsView.backgroundNeedsInputClearedNotification,
                object: nil,
                userInfo: ["localID": localID]
            )
        case .notification:
            // Wichtiges Signal: Claude druckt Permission-Prompts und andere
            // Notifications hier hinein. Fuer Background-Sessions ist das
            // der einzige verlaessliche "Needs input"-Trigger (kein
            // interaktives PTY). Wir posten eine NotificationCenter-
            // Notification, die die View in `awaitingInputSessionIDs`
            // einfuegt — die Sidebar pulst den Status entsprechend.
            Logger.claudeBinding.info("binding_notification localID=\(localID.uuidString, privacy: .public)")
            NotificationCenter.default.post(
                name: AgentChatsView.backgroundNeedsInputNotification,
                object: nil,
                userInfo: ["localID": localID]
            )
        case .other:
            return
        }
    }

    /// Hängt den Watcher an eine laufende Session — entweder direkt nach
    /// `markLaunched` (externalSessionID kann noch fehlen) oder nach
    /// `bindExternalSessionIDWhenAvailable` (jetzt mit valider ID).
    /// Idempotent: bei wiederholtem Aufruf updated der Watcher die ID intern.
    private func attachWatcher(sessionID: UUID) {
        guard let watcher = runtimeWatcher else { return }
        let workspace = store.loadWorkspace()
        guard let session = workspace.sessions.first(where: { $0.id == sessionID }),
              let project = workspace.projects.first(where: { $0.id == session.projectID }) else {
            return
        }
        watcher.watch(
            sessionID: session.id,
            provider: session.provider,
            externalSessionID: session.externalSessionID,
            cwd: project.path,
            priorTurnFinishedAt: session.lastTurnAt
        )
    }

    /// Triggert beim turn-finished-Signal des Watchers das Persistieren des
    /// `lastTurnAt`-Stempels und den Auto-Namer. Bewusst static, damit der
    /// Closure beim Watcher-Init kein View-`self` festhält.
    private static func handleTurnFinished(
        sessionID: UUID,
        store: AgentSessionStore,
        autoNamer: AgentSessionAutoNamer?,
        onCompletion: @escaping () -> Void
    ) {
        let workspace = store.loadWorkspace()
        guard let session = workspace.sessions.first(where: { $0.id == sessionID }),
              let project = workspace.projects.first(where: { $0.id == session.projectID }) else {
            return
        }

        // Auto-Namer mit Snapshot starten (lastTurnAt ist hier noch nil) —
        // der `recordTurnEnded` läuft direkt danach und beeinflusst diesen
        // Snapshot nicht mehr.
        autoNamer?.handleTurnFinished(session: session, cwd: project.path) { _ in
            Task { @MainActor in onCompletion() }
        }

        do {
            try store.recordTurnEnded(id: sessionID)
        } catch {
            Logger.debug("Failed to record turn ended: \(error.localizedDescription)")
        }
    }

    private func loadWorkspaceFast() {
        PerfBudgets.sidebarWorkspaceLoad.withInterval { loadWorkspaceFastBody() }
    }

    /// Vom Signpost-Wrapper getrennt, damit die bestehende
    /// durationMs-Logzeile unverändert bleibt. Läuft auf dem MainActor!
    /// P1 S6: lädt nichts mehr manuell — der Workspace kommt live aus der
    /// `AgentWorkspaceUIModel`-Projektion; hier bleiben nur Stale-Cleanup
    /// und Selection-Fixup.
    private func loadWorkspaceFastBody() {
        let startedAt = Date()
        do {
            try store.markStaleRunningSessionsClosed(excluding: terminalRegistry.activeSessionIDs)
        } catch {
            errorMessage = error.localizedDescription
        }

        reconcileSelection()
        Logger.agentPerformance.debug("agent_chats_fast_load durationMs=\(Int(Date().timeIntervalSince(startedAt) * 1000)) projects=\(workspace.projects.count) sessions=\(workspace.sessions.count)")
    }

    /// Selection-/Expansion-Fixup nach Workspace-Änderungen: Selektion darf
    /// nie auf gelöschte Projekte/Sessions zeigen. Ändert nur dann etwas,
    /// wenn die aktuelle Selektion ungültig geworden ist.
    private func reconcileSelection() {
        // Tote/archivierte Sessions aus Tab-Bar und Pins entfernen
        // (z. B. nach deleteSession aus dem Spawn-Fehlerpfad).
        let liveIDs = Set(workspace.sessions.filter { $0.status != .archived }.map(\.id))
        if openTabIDs.contains(where: { !liveIDs.contains($0) }) {
            openTabIDs.removeAll { !liveIDs.contains($0) }
        }
        if pinnedSessionIDs.contains(where: { !liveIDs.contains($0) }) {
            pinnedSessionIDs.removeAll { !liveIDs.contains($0) }
        }

        if selectedProjectID == nil || !workspace.projects.contains(where: { $0.id == selectedProjectID }) {
            selectedProjectID = workspace.projects.first?.id
        }
        if expandedProjectIDs.isEmpty {
            expandedProjectIDs = Set(workspace.projects.prefix(3).map(\.id))
        }
        if let selectedProjectID {
            expandedProjectIDs.insert(selectedProjectID)
        }
        if selectedSessionID == nil || !liveIDs.contains(selectedSessionID!) {
            selectedSessionID = openTabIDs.first
        }
    }

    private func refreshSessionsInBackground(reason: String) {
        indexRefreshTask?.cancel()
        isIndexingSessions = true
        let startedAt = Date()
        let activeSessionIDs = terminalRegistry.activeSessionIDs

        indexRefreshTask = Task {
            defer {
                if !Task.isCancelled {
                    isIndexingSessions = false
                }
            }
            // P1 S5: Detached-Block macht nur noch das reine Indexing
            // (JSONL-Parsing off-main); der Merge läuft danach auf dem
            // MainActor über die Facade.
            let result = Task.detached(priority: .utility) {
                PerfBudgets.sidebarBackgroundIndex.withInterval {
                    let cacheStore = AgentSessionIndexCacheStore()
                    var cache = cacheStore.load()
                    let codex = CodexSessionIndexer().indexedSessionResult(cache: &cache)
                    let claude = ClaudeSessionIndexer().indexedSessionResult(cache: &cache)
                    cacheStore.save(cache)
                    return (sessions: codex.sessions + claude.sessions, stats: [codex.stats, claude.stats])
                }
            }

            guard !Task.isCancelled else { return }
            do {
                let indexResult = await result.value
                guard !Task.isCancelled else { return }
                try store.markStaleRunningSessionsClosed(excluding: activeSessionIDs)
                try store.mergeIndexedSessions(indexResult.sessions)
                lastIndexStats = indexResult.stats
                loadWorkspaceFast()
                // Manuelles Sessions-Scannen ist auch der natürliche Trigger,
                // um *alle* generisch benannten Sessions nachträglich vom
                // Auto-Namer benennen zu lassen — sowohl frisch indexierte
                // alte Sessions als auch solche, deren erster
                // Auto-Naming-Versuch vorher gescheitert ist.
                forceAutoNameUntitledSessions()
                Logger.agentPerformance.info("agent_chats_background_index reason=\(reason, privacy: .public) durationMs=\(Int(Date().timeIntervalSince(startedAt) * 1000)) stats=\(lastIndexStats.map { "\($0.provider.rawValue):\($0.scannedFiles)/\($0.cacheHits)/\($0.bytesRead)" }.joined(separator: ","), privacy: .public)")
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Drag-and-Drop coordinators

    /// Reordert die Sessions eines Projekts: Row-Drops werden vom Planner
    /// richtungsabhaengig eingeordnet, `nil` bedeutet ans Ende anhaengen.
    /// Cross-Project: wenn `droppedSession.sourceProjectID != projectID`,
    /// wird die Session zusätzlich in das Ziel-Projekt verschoben.
    private func dropSession(
        _ dropped: DraggableSession,
        in projectID: UUID,
        beforeSessionID: UUID?
    ) {
        switch AgentDragDropPlanner.sessionDropPlan(
            dropped: dropped,
            targetProjectID: projectID,
            beforeSessionID: beforeSessionID,
            workspace: workspace
        ) {
        case .reorder(let projectID, let orderedIDs):
            do {
                try store.reorderSessions(in: projectID, orderedIDs: orderedIDs)
            } catch {
                errorMessage = error.localizedDescription
            }
        case .move(let sessionID, let newProjectID, let targetIndex):
            do {
                try store.moveSessionToProject(
                    sessionID: sessionID,
                    newProjectID: newProjectID,
                    targetIndex: targetIndex
                )
            } catch {
                errorMessage = error.localizedDescription
            }
        case .none:
            return
        }
    }

    /// Reordert die Projekt-Reihenfolge in der Sidebar — `droppedProject`
    /// wird vor `beforeProjectID` einsortiert (`nil` = ans Ende).
    private func dropProject(
        _ dropped: DraggableProject,
        beforeProjectID: UUID?
    ) {
        let plan = AgentDragDropPlanner.projectDropPlan(
            dropped: dropped,
            beforeProjectID: beforeProjectID,
            visibleProjects: manualProjects
        )
        guard case .reorder(let orderedIDs) = plan else { return }
        do {
            try store.reorderProjects(orderedIDs: orderedIDs)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Manueller Trigger aus dem "…"-Menü eines Tabs oder Sidebar-Rechtsklick.
    /// Erzwingt eine Title-Generierung für genau diese Session — auch wenn sie
    /// schon mal automatisch benannt war oder das letzte Auto-Naming
    /// fehlgeschlagen ist. `canAutoRenameTitle` bleibt aktiv: wenn der User
    /// manuell umbenannt hat (`titleIsAutoGenerated == false`), schreiben wir
    /// trotzdem nichts.
    private func forceAutoNameSession(_ session: AgentChatSession) {
        guard let autoNamer else { return }
        guard let project = workspace.projects.first(where: { $0.id == session.projectID }) else {
            return
        }
        // P1 S6: Kein manuelles Reload mehr noetig — der AutoNamer schreibt
        // ueber die Facade, die Workspace-Projektion aktualisiert die UI.
        autoNamer.forceGenerateTitle(session: session, cwd: project.path) { _ in }
    }

    /// Geht durch alle nicht-archivierten Sessions, die noch einen generischen
    /// Default-Namen tragen ("Claude Chat" / "Codex Chat" / "… Chat") und ruft
    /// den Auto-Namer im Force-Modus auf. Nutzt `forceGenerateTitle`, das
    /// `lastTurnAt` und `alreadyAttempted` ignoriert — `canAutoRenameTitle`
    /// bleibt aber Schutz gegen User-Renames.
    private func forceAutoNameUntitledSessions() {
        guard let autoNamer else { return }

        let candidates: [(session: AgentChatSession, project: AgentProject)] = workspace.sessions.compactMap { session in
            guard session.status != .archived else { return nil }
            guard session.externalSessionID != nil else { return nil }
            guard isDefaultUntitled(session) else { return nil }
            guard let project = workspace.projects.first(where: { $0.id == session.projectID }) else { return nil }
            return (session, project)
        }

        guard !candidates.isEmpty else { return }

        for entry in candidates {
            autoNamer.forceGenerateTitle(session: entry.session, cwd: entry.project.path) { _ in }
        }
    }

    /// Liefert `true`, wenn die Session noch einen generischen
    /// Auto-Default-Namen trägt — und damit Kandidat für nachträgliches
    /// Auto-Naming ist.
    private func isDefaultUntitled(_ session: AgentChatSession) -> Bool {
        let normalized = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty
            || normalized == "Claude Chat"
            || normalized == "Codex Chat"
            || normalized.hasSuffix(" Chat")
    }

    /// Projekt-Klick setzt nur noch den Kontext (Ziel für „Neuer Chat",
    /// Inspector) — die globale Tab-Bar und die Selektion bleiben
    /// unangetastet.
    private func selectProject(_ projectID: UUID) {
        selectedProjectID = projectID
        expandedProjectIDs.insert(projectID)
        if let project = workspace.projects.first(where: { $0.id == projectID }) {
            AppPreferences.shared.agentDefaultProjectPath = project.path
        }
    }

    private func toggleProject(_ projectID: UUID) {
        if expandedProjectIDs.contains(projectID) {
            expandedProjectIDs.remove(projectID)
        } else {
            expandedProjectIDs.insert(projectID)
        }
    }

    private func addProject() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Project"

        if panel.runModal() == .OK, let url = panel.url {
            do {
                let project = try store.upsertProject(path: url.path, createdManually: true)
                selectedProjectID = project.id
                expandedProjectIDs.insert(project.id)
                AppPreferences.shared.agentDefaultProjectPath = project.path
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func createSession(provider: AgentProvider, kind: AgentSessionKind? = nil) {
        guard let selectedProject else { return }
        do {
            // Agent View hat keine externe Session-ID (es ist ein Dashboard
            // ueber viele Sessions). Auch der Titel ist anders.
            let isAgentView = kind == .agentView
            let title = isAgentView
                ? "Agent View"
                : "\(provider.displayName) Chat"
            // Vorbereitete externe Session-ID nur fuer normale Claude-Chats —
            // damit unsere Hook-Bridge die JSONL findet. Codex und Agent View
            // generieren ihre IDs intern.
            let externalSessionID: String? = (provider == .claude && !isAgentView)
                ? UUID().uuidString.lowercased()
                : nil
            let session = try store.createSession(
                provider: provider,
                projectPath: selectedProject.path,
                title: title,
                model: AppPreferences.shared.codexPostProcessingModelRaw,
                reasoningEffort: AppPreferences.shared.codexReasoningEffortRaw,
                externalSessionID: externalSessionID,
                shouldLaunchOnOpen: true,
                kind: kind
            )
            openTab(session.id)
            selectedSessionID = session.id
            sessionActionRequest = AgentSessionActionRequest(sessionID: session.id, kind: .start)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Fork (Claude Code)

    /// Forkt einen Claude-Chat: legt einen neuen Tab an und startet ihn als
    /// `claude --resume <quelle> --fork-session` — übernimmt den kompletten
    /// Stand der Quelle, zweigt aber in eine eigene Session-ID ab. Das
    /// Original läuft unverändert weiter. Die neue Fork-Session-ID bindet
    /// der SessionStart-Hook automatisch (siehe handleClaudeHookEvent).
    private func forkSession(_ source: AgentChatSession) {
        guard source.isForkable,
              let sourceExternalID = source.externalSessionID,
              let project = workspace.projects.first(where: { $0.id == source.projectID }) else {
            return
        }
        do {
            let forked = try store.createSession(
                provider: .claude,
                projectPath: project.path,
                title: forkTitle(for: source.title),
                externalSessionID: nil, // wird nach Launch via Hook gebunden
                shouldLaunchOnOpen: true,
                kind: .chat,
                forkSourceSessionID: sourceExternalID
            )
            // Farbe der Quelle erben, damit Fork und Original visuell
            // zusammengehören.
            if let color = source.color, !color.isEmpty {
                try? store.setSessionColor(id: forked.id, color: color)
            }
            openTab(forked.id)
            selectedSessionID = forked.id
            sessionActionRequest = AgentSessionActionRequest(sessionID: forked.id, kind: .start)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// "Foo" → "Foo (Fork)", "Foo (Fork)" → "Foo (Fork 2)", … — fortlaufend.
    private func forkTitle(for base: String) -> String {
        let trimmed = base.trimmingCharacters(in: .whitespaces)
        if let range = trimmed.range(of: #" \(Fork( \d+)?\)$"#, options: .regularExpression) {
            let stem = String(trimmed[..<range.lowerBound])
            let suffix = trimmed[range]
            let current = suffix.range(of: #"\d+"#, options: .regularExpression)
                .flatMap { Int(suffix[$0]) } ?? 1
            return "\(stem) (Fork \(current + 1))"
        }
        return "\(trimmed) (Fork)"
    }

    /// Gemeinsamer „Forken"-Menüeintrag — nur für forkbare Claude-Chats
    /// sichtbar (sonst leer). Wird in allen Chat-Kontextmenüs eingehängt.
    @ViewBuilder
    private func forkMenuItem(_ session: AgentChatSession) -> some View {
        if session.isForkable {
            Button("Forken", systemImage: "arrow.triangle.branch") {
                forkSession(session)
            }
        }
    }

    // MARK: - Background Agents (Phase 2)

    /// Oeffnet die Read-Only-Sub-Agent-Bibliothek als Sheet. Listet alle
    /// Sub-Agents aus `~/.claude/agents/` (User) + `.claude/agents/`
    /// (Projekt), grupiert nach Scope. Zweck: Discovery — der User sieht,
    /// was er dem `--agent`-Flag im Dispatch-Modal mitgeben kann.
    private func presentSubAgentLibrary() {
        let projectPath = selectedProject?.path
        let agents = SubAgentDiscovery.discover(projectPath: projectPath)
        subAgentLibrarySheet = SubAgentLibraryPresentation(
            projectName: selectedProject?.name,
            agents: agents
        )
    }

    /// Oeffnet das Background-Dispatch-Modal fuer das aktuell selektierte
    /// Projekt. Sub-Agent-Discovery laeuft synchron — die Listen sind klein
    /// und es ist FS-cached.
    private func presentBackgroundDispatchModal() {
        guard let project = selectedProject else { return }
        let subAgents = SubAgentDiscovery.discover(projectPath: project.path)
        pendingBackgroundDispatch = PendingBackgroundDispatch(
            project: project,
            subAgents: subAgents
        )
    }

    /// Spawnt einen neuen Background-Agent via `claude --bg`, persistiert die
    /// Short-ID auf die neu angelegte Session und triggert dann `claude attach`
    /// als PTY-Tab. Drei Stufen:
    ///
    /// 1. Persistieren — Tab erscheint sofort in der Sidebar (mit Pending-State).
    /// 2. Spawn — Subprocess-Aufruf, parsed Short-ID. Bei Fehler: errorMessage.
    /// 3. Attach — Short-ID auf Session schreiben + sessionActionRequest senden.
    @MainActor
    private func dispatchBackgroundAgent(in project: AgentProject, request: BackgroundDispatchRequest) async {
        // 1. Stub-Session anlegen (ohne Short-ID), Tab oeffnen.
        let session: AgentChatSession
        do {
            session = try store.createSession(
                provider: .claude,
                projectPath: project.path,
                title: backgroundSessionTitle(for: request),
                model: AppPreferences.shared.codexPostProcessingModelRaw,
                reasoningEffort: AppPreferences.shared.codexReasoningEffortRaw,
                externalSessionID: nil,
                initialPrompt: request.prompt,
                shouldLaunchOnOpen: false,
                kind: .backgroundChat,
                backgroundSubAgent: request.subAgent,
                backgroundPermissionMode: request.permissionMode
            )
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        spawningBackgroundSessions.insert(session.id)
        openTab(session.id)
        selectedSessionID = session.id

        // 2. Hook-Bridge vorbereiten — die Background-Session erbt die
        //    Settings vom Supervisor, also muessen wir `--settings <path>`
        //    schon beim Spawn-Subprocess setzen, nicht erst beim spaeteren
        //    `claude attach`. Wenn die Bridge nicht da ist (sehr alter
        //    State / kein Hook-Setup), spawnen wir ohne Settings — der
        //    Agent laeuft trotzdem, wir kriegen halt keine Live-Events.
        let settingsPath = claudeHookBridge?.prepareSettingsFile(localSessionID: session.id)

        // 3. Spawn via BackgroundAgentSpawner.
        let extraArgs = AgentCommandBuilder.parseArguments(AppPreferences.shared.claudeExtraArguments)
        do {
            let result = try await BackgroundAgentSpawner.spawn(
                initialPrompt: request.prompt,
                projectPath: project.path,
                settingsFilePath: settingsPath,
                subAgent: request.subAgent,
                permissionMode: request.permissionMode,
                extraArguments: extraArgs
            )
            // 4. Short-ID persistieren + Hook-Tracking starten + Attach triggern.
            try store.setBackgroundShortID(localSessionID: session.id, shortID: result.shortID)
            try store.updateSession(id: session.id) { updated in
                updated.hasLaunchedInitialPrompt = true
            }
            spawningBackgroundSessions.remove(session.id)
            if settingsPath != nil {
                claudeHookBridge?.startTracking(localSessionID: session.id)
            }
            sessionActionRequest = AgentSessionActionRequest(sessionID: session.id, kind: .start)
        } catch {
            // Spawn fehlgeschlagen — Stub-Session ist nutzlos (kein Attach
            // moeglich ohne Short-ID), also wieder loeschen statt als
            // "Session noch nicht gestartet"-Geist liegen lassen.
            spawningBackgroundSessions.remove(session.id)
            try? store.deleteSession(id: session.id)
            openTabIDs.removeAll { $0 == session.id }
            if selectedSessionID == session.id {
                selectedSessionID = openTabIDs.first
            }
            errorMessage = "Hintergrund-Agent konnte nicht gestartet werden: \(error.localizedDescription)"
        }
    }

    // MARK: - Background Agents · Phase 3 (Lifecycle)

    /// Oeffnet das Logs-Sheet fuer eine Background-Session. Ruft `claude
    /// logs <id>` asynchron auf und reicht das Ergebnis ins Sheet weiter —
    /// das Sheet selbst zeigt einen Spinner, solange wir laden.
    @MainActor
    private func showBackgroundLogs(for session: AgentChatSession) {
        guard let shortID = session.backgroundShortID, !shortID.isEmpty else { return }
        let presentation = BackgroundLogsPresentation(
            sessionID: session.id,
            shortID: shortID,
            title: session.title,
            state: .loading
        )
        pendingBackgroundLogs = presentation
        pendingLifecycleSessions.insert(session.id)
        Task { @MainActor in
            defer { pendingLifecycleSessions.remove(session.id) }
            do {
                let result = try await BackgroundAgentLifecycle.logs(shortID: shortID)
                // Nur uebernehmen, wenn das Sheet noch fuer dieselbe Short-ID offen ist —
                // sonst hat der User das Sheet schon geschlossen oder gewechselt.
                guard pendingBackgroundLogs?.id == presentation.id else { return }
                let combined = result.stdout + (result.stderr.isEmpty ? "" : "\n[stderr]\n" + result.stderr)
                pendingBackgroundLogs = presentation.with(state: .loaded(combined))
            } catch {
                guard pendingBackgroundLogs?.id == presentation.id else { return }
                pendingBackgroundLogs = presentation.with(state: .failed(error.localizedDescription))
            }
        }
    }

    /// Fuehrt eine Lifecycle-Aktion auf einer Background-Session aus. Bei
    /// `.rm` raeumen wir nach Erfolg auch den lokalen State auf (Tab
    /// schliessen + Session archivieren), bei den anderen Aktionen
    /// belassen wir die Session in der UI.
    @MainActor
    private func performBackgroundLifecycle(
        _ action: BackgroundAgentLifecycle.Action,
        on session: AgentChatSession
    ) {
        guard let shortID = session.backgroundShortID, !shortID.isEmpty else { return }
        pendingLifecycleSessions.insert(session.id)
        Task { @MainActor in
            defer { pendingLifecycleSessions.remove(session.id) }
            do {
                switch action {
                case .logs:
                    _ = try await BackgroundAgentLifecycle.logs(shortID: shortID)
                case .stop:
                    _ = try await BackgroundAgentLifecycle.stop(shortID: shortID)
                case .respawn:
                    _ = try await BackgroundAgentLifecycle.respawn(shortID: shortID)
                case .rm:
                    _ = try await BackgroundAgentLifecycle.remove(shortID: shortID)
                    forgetBackgroundSession(session.id)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Lokales Cleanup, wenn der User die Session vom Supervisor entfernt
    /// hat (oder der Health-Check sie als verwaist klassifiziert).
    /// Terminiert ggf. das PTY, archiviert die Session, schliesst den Tab.
    @MainActor
    private func forgetBackgroundSession(_ id: UUID) {
        if terminalRegistry.controller(for: id)?.isRunning == true {
            terminalRegistry.terminate(sessionID: id)
        }
        try? store.updateSession(id: id) { session in
            session.status = .archived
            session.backgroundShortID = nil
        }
        openTabIDs.removeAll { $0 == id }
        pinnedSessionIDs.removeAll { $0 == id }
        if selectedSessionID == id {
            selectedSessionID = openTabIDs.first
        }
    }

    /// Beim Window-Open: pro Short-ID einmal Health-Check fahren. Sessions,
    /// die der Supervisor nicht mehr kennt, werden lokal archiviert — sonst
    /// liessen sie sich nicht mehr attachen und blieben als Zombies in der
    /// Sidebar. Idempotent: laeuft pro Window-Lifetime nur einmal.
    private func runBackgroundAgentStartupHealthCheckIfNeeded() {
        guard !hasRunStartupHealthCheck else { return }
        hasRunStartupHealthCheck = true
        let candidates: [(UUID, String)] = workspace.sessions.compactMap { session in
            guard session.isBackgroundChat,
                  session.status != .archived,
                  let id = session.backgroundShortID,
                  !id.isEmpty
            else { return nil }
            return (session.id, id)
        }
        guard !candidates.isEmpty else { return }
        Task.detached(priority: .utility) {
            for (sessionID, shortID) in candidates {
                let outcome = await BackgroundAgentLifecycle.healthCheck(shortID: shortID)
                guard outcome == .unknown else { continue }
                await MainActor.run {
                    forgetBackgroundSession(sessionID)
                }
            }
        }
    }

    /// Kurzer Titel-Fallback, bis der AutoNamer einen besseren Namen aus dem
    /// Transcript ableitet. Zeigt direkt den Prompt-Anfang an.
    private func backgroundSessionTitle(for request: BackgroundDispatchRequest) -> String {
        let trimmed = request.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = trimmed.split(whereSeparator: { $0.isNewline }).first.map(String.init) ?? trimmed
        let cap = 60
        let snippet = firstLine.count > cap ? String(firstLine.prefix(cap - 1)) + "…" : firstLine
        return snippet.isEmpty ? "Hintergrund-Agent" : snippet
    }

    private func markSession(_ id: UUID, status: AgentChatStatus) {
        do {
            if status == .closed || status == .archived {
                terminalRegistry.terminate(sessionID: id)
            }
            try store.updateSession(id: id) { session in
                session.status = status
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func relaunch(_ id: UUID) {
        markSession(id, status: .pending)
        selectedSessionID = id
    }

    private func renameSession(id: UUID, title: String) {
        do {
            try store.renameSession(id: id, title: title)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func setSessionGroup(id: UUID, groupName: String?) {
        do {
            try store.setSessionGroup(id: id, groupName: groupName)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func setSessionColor(id: UUID, color: String?) {
        do {
            try store.setSessionColor(id: id, color: color)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Wiederverwendetes „Tab-Farbe"-Submenu (8er-Palette + Provider-Reset).
    @ViewBuilder
    private func tabColorMenu(for session: AgentChatSession) -> some View {
        Menu("Tab-Farbe") {
            ForEach(AgentChatColor.palette, id: \.self) { color in
                Button {
                    setSessionColor(id: session.id, color: color)
                } label: {
                    Label {
                        Text(AgentChatColorName.label(for: color))
                    } icon: {
                        Image(nsImage: colorSwatchImage(hex: color))
                    }
                }
            }
            Divider()
            Button("Provider-Farbe verwenden", systemImage: "arrow.uturn.backward") {
                setSessionColor(id: session.id, color: nil)
            }
        }
    }

    // MARK: - Pinning

    private func pinSession(_ id: UUID) {
        guard !pinnedSessionIDs.contains(id) else { return }
        pinnedSessionIDs.append(id)
    }

    private func unpinSession(_ id: UUID) {
        pinnedSessionIDs.removeAll { $0 == id }
    }

    private func togglePin(_ id: UUID) {
        pinnedSessionIDs.contains(id) ? unpinSession(id) : pinSession(id)
    }

    // MARK: - Project metadata actions

    /// Löscht ein Projekt (nach Bestätigung): beendet laufende Terminals
    /// seiner Sessions, entfernt Projekt + Sessions aus dem Workspace und
    /// räumt den UI-State (offene Tabs, Pins, Selektion) auf. Repo und
    /// externe Transcripts auf der Platte bleiben unangetastet.
    private func deleteProject(_ project: AgentProject) {
        let sessionIDs = Set(
            workspace.sessions.filter { $0.projectID == project.id }.map(\.id)
        )
        for id in sessionIDs where terminalRegistry.controller(for: id)?.isRunning == true {
            terminalRegistry.terminate(sessionID: id)
        }
        do {
            try store.deleteProject(id: project.id)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        openTabIDs.removeAll { sessionIDs.contains($0) }
        pinnedSessionIDs.removeAll { sessionIDs.contains($0) }
        expandedProjectIDs.remove(project.id)
        iconLookupAttempted.remove(project.id)
        if let selected = selectedSessionID, sessionIDs.contains(selected) {
            selectedSessionID = openTabIDs.first
        }
        if selectedProjectID == project.id {
            selectedProjectID = workspace.projects.first?.id
        }
        projectPendingDeletion = nil
    }

    private func beginRenameProject(_ project: AgentProject) {
        renameProjectTargetID = project.id
        renameProjectDraft = project.name
    }

    private func renameProject(id: UUID, name: String) {
        do {
            try store.renameProject(id: id, name: name)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func setProjectColor(id: UUID, color: String) {
        do {
            try store.setProjectColor(id: id, color: color)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Öffnet einen NSOpenPanel und speichert den absoluten Pfad als
    /// `customIconAbsolutePath` (Vorrang vor Auto-Detect-Pfad). Akzeptiert die
    /// üblichen Bildformate, die NSImage zuverlässig darstellt.
    private func chooseProjectIcon(_ project: AgentProject) {
        let panel = NSOpenPanel()
        panel.title = "Projekt-Icon wählen"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .gif, .svg, .icns, .ico, .image]
        panel.directoryURL = URL(fileURLWithPath: project.path)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.setProjectCustomIcon(id: project.id, absolutePath: url.path)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Setzt den Auto-Lookup-Status zurück und triggert sofort einen neuen
    /// Resolver-Lauf — User-getriggert via Context-Menü.
    private func reAutoDetectProjectIcon(_ project: AgentProject) {
        do {
            try store.clearProjectIcon(id: project.id)
            iconLookupAttempted.remove(project.id)
            attemptAutoDetectProjectIcons()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func clearProjectIcon(_ id: UUID) {
        do {
            try store.clearProjectIcon(id: id)
            iconLookupAttempted.insert(id)  // nicht direkt re-resolven
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Einmalige Migration nach Resolver-Verbesserungen: setzt den
    /// Auto-Lookup für alle Projekte OHNE manuell gewähltes Icon zurück,
    /// damit der verbesserte Resolver (`AgentProjectIconResolver.version`)
    /// beim folgenden `attemptAutoDetectProjectIcons()` erneut greift.
    /// Ohne das blieben Projekte, die der alte Resolver schon einmal (oft
    /// erfolglos) gescannt hat, dauerhaft ohne Icon. User-gewählte Icons
    /// (`customIconAbsolutePath`) bleiben unangetastet.
    private func migrateIconDetectionIfNeeded() {
        let key = "agentIconResolverVersion"
        let applied = UserDefaults.standard.integer(forKey: key)
        guard applied < AgentProjectIconResolver.version else { return }
        for project in workspace.projects {
            guard project.customIconAbsolutePath?.isEmpty ?? true else { continue }
            try? store.updateProject(id: project.id) { project in
                project.iconRelativePath = nil
                project.iconAutoLookupAttempted = nil
            }
        }
        iconLookupAttempted.removeAll()
        UserDefaults.standard.set(AgentProjectIconResolver.version, forKey: key)
    }

    /// Iteriert über alle Projekte und scannt deren Repos asynchron nach Icons,
    /// sofern noch kein Lookup gemacht wurde. Bewusst lazy: nur Projekte, deren
    /// `iconAutoLookupAttempted != true` und die in dieser App-Session noch
    /// nicht gescannt wurden.
    private func attemptAutoDetectProjectIcons() {
        let candidates = workspace.projects.filter { project in
            // Nur manuell hinzugefügte Projekte werden in der Sidebar gezeigt —
            // auto-importierte Pseudo-Projekte (versehentliche cwds wie Home/
            // Downloads) gar nicht erst scannen.
            project.isManuallyAdded
                && !iconLookupAttempted.contains(project.id)
                && project.iconAutoLookupAttempted != true
                && (project.customIconAbsolutePath?.isEmpty ?? true)
                && (project.iconRelativePath?.isEmpty ?? true)
        }
        guard !candidates.isEmpty else { return }

        for project in candidates {
            iconLookupAttempted.insert(project.id)
        }

        Task.detached(priority: .utility) { [store] in
            for project in candidates {
                let path = project.path
                let id = project.id
                let resolved = AgentProjectIconResolver.findIconRelativePath(in: path)
                do {
                    try store.applyAutoResolvedProjectIcon(id: id, relativePath: resolved)
                } catch {
                    Logger.debug("project_icon_auto_resolve_failed project=\(id.uuidString) error=\(error.localizedDescription)")
                }
            }
            await MainActor.run {
            }
        }
    }

    private func moveSession(id: UUID, direction: AgentSessionMoveDirection) {
        do {
            try store.moveSession(id: id, direction: direction)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @ViewBuilder
    private func sessionManagementMenu(_ session: AgentChatSession) -> some View {
        Group {
            Button("Tab schließen", systemImage: "xmark.square") {
                closeTab(session)
            }
            Divider()
            Button("Umbenennen…", systemImage: "pencil") {
                beginRename(session)
            }
            Button("Titel automatisch generieren", systemImage: "sparkles") {
                forceAutoNameSession(session)
            }
            .disabled(session.externalSessionID == nil)
            forkMenuItem(session)
            Divider()
            Button(
                pinnedSessionIDs.contains(session.id) ? "Loslösen" : "Anpinnen",
                systemImage: pinnedSessionIDs.contains(session.id) ? "pin.slash" : "pin"
            ) {
                togglePin(session.id)
            }
            tabColorMenu(for: session)
            if session.isBackgroundChat {
                Divider()
                backgroundLifecycleMenuItems(session)
            }
            Divider()
            Button("Chat schließen", systemImage: "xmark", role: .destructive) {
                archiveSession(session)
            }
        }
    }

    /// Lifecycle-Aktionen, die nur fuer `.backgroundChat`-Sessions Sinn
    /// ergeben. Werden in `sessionManagementMenu` nur fuer Background-Tabs
    /// eingehaengt. Disabled-Zustand: Aktion laeuft bereits oder Short-ID
    /// noch nicht bekannt (Spawn pending oder fehlgeschlagen).
    @ViewBuilder
    private func backgroundLifecycleMenuItems(_ session: AgentChatSession) -> some View {
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

    private func beginRename(_ session: AgentChatSession) {
        renameTargetID = session.id
        renameDraft = session.title
    }

    /// Öffnet einen Tab in der globalen Bar (ans Ende), falls noch nicht
    /// offen. Kein Persistenz-Cap zur Laufzeit — die Bar scrollt; gekappt
    /// wird beim nächsten Load (`AgentUIState.prune`).
    private func openTab(_ id: UUID) {
        guard !openTabIDs.contains(id) else { return }
        openTabIDs.append(id)
    }

    /// Schließt nur den TAB — die Session bleibt in der Sidebar erhalten
    /// und ein laufendes PTY läuft weiter (Status bleibt über den
    /// Sidebar-Dot sichtbar; erneutes Öffnen attached an denselben
    /// Terminal-Controller inkl. Scrollback).
    private func closeTab(_ session: AgentChatSession) {
        guard let index = openTabIDs.firstIndex(of: session.id) else {
            if selectedSessionID == session.id { selectedSessionID = openTabIDs.first }
            return
        }
        openTabIDs.remove(at: index)
        if selectedSessionID == session.id {
            // Nachbar-Tab selektieren (gleiche Position, sonst letzter).
            selectedSessionID = openTabIDs.indices.contains(index)
                ? openTabIDs[index]
                : openTabIDs.last
        }
    }

    /// Chat vollständig schließen: Terminal terminieren (falls läuft) und
    /// Session archivieren — dadurch verschwindet sie aus Tab-Bar UND
    /// Sidebar. Daten bleiben in der Workspace-Datei erhalten.
    private func archiveSession(_ session: AgentChatSession) {
        if terminalRegistry.controller(for: session.id)?.isRunning == true {
            terminalRegistry.terminate(sessionID: session.id)
        }

        do {
            try store.updateSession(id: session.id) { $0.status = .archived }
        } catch {
            errorMessage = error.localizedDescription
        }

        pinnedSessionIDs.removeAll { $0 == session.id }
        closeTab(session)
    }

    // MARK: - Cmd-W (Tab schließen)

    /// Installiert den lokalen `keyDown`-Monitor für Cmd-W. Idempotent —
    /// bei wiederholtem `onAppear` passiert nichts. Wir nutzen bewusst einen
    /// NSEvent-Monitor statt eines SwiftUI-Menü-Commands: Der Monitor fängt
    /// das Event ab, BEVOR es das Terminal (SwiftTerm-`keyDown`) oder das
    /// AppKit-Menü („Fenster schließen") erreicht — Cmd-W schließt damit
    /// auch dann den Tab, wenn der Fokus im Terminal liegt. Belegt durch den
    /// bestehenden `TerminalKeyboardShortcutHandler`, der so Cmd-Z/Cmd-⌫
    /// abfängt.
    private func installCloseTabShortcutIfNeeded() {
        guard closeTabKeyMonitor == nil else { return }
        closeTabKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handleCloseTabShortcut(event)
        }
    }

    private func removeCloseTabShortcut() {
        if let closeTabKeyMonitor {
            NSEvent.removeMonitor(closeTabKeyMonitor)
            self.closeTabKeyMonitor = nil
        }
    }

    /// Verarbeitet Cmd-W. Gibt `nil` zurück, wenn das Event konsumiert wurde
    /// (Tab geschlossen), sonst das Original-Event für die normale Pipeline.
    /// Bewusst nur für das Agent-Chats-Fenster (`event.window === hostWindow`):
    /// In Settings/Onboarding und über Sheets bleibt Cmd-W das System-„Schließen".
    /// Ohne offenen Tab fällt Cmd-W ebenfalls durch → das Fenster schließt
    /// sich wie gewohnt (Browser-Verhalten: letzter Tab zu → Fenster zu).
    private func handleCloseTabShortcut(_ event: NSEvent) -> NSEvent? {
        guard let hostWindow, event.window === hostWindow else { return event }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers == .command,
              event.charactersIgnoringModifiers == "w" else { return event }
        guard let session = selectedSession else { return event }
        closeTab(session)
        return nil
    }

    // MARK: - Doppelklick auf die oberste Leiste = Fenster zoomen

    private func installTitleBarZoomHandlerIfNeeded() {
        guard titleBarZoomMonitor == nil else { return }
        titleBarZoomMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            handleTitleBarDoubleClick(event)
        }
    }

    private func removeTitleBarZoomHandler() {
        if let titleBarZoomMonitor {
            NSEvent.removeMonitor(titleBarZoomMonitor)
            self.titleBarZoomMonitor = nil
        }
    }

    /// Doppelklick ins oberste 28px-Band des Agent-Chats-Fensters zoomt das
    /// Fenster (Standard-Titelleisten-Verhalten). Wir nutzen einen lokalen
    /// Maus-Monitor statt eines SwiftUI-Overlays, weil das Overlay die
    /// Doppelklicks über dem Tab-Strip nicht zuverlässig abfängt — der Monitor
    /// sieht das Event vor allem SwiftUI-Hit-Testing (gleiche Technik wie der
    /// Cmd-W-Monitor). Greift nur bei `clickCount == 2`, lässt die Traffic-
    /// Lights links (x < 80) in Ruhe und konsumiert nur den Zweitklick.
    private func handleTitleBarDoubleClick(_ event: NSEvent) -> NSEvent? {
        guard event.clickCount == 2,
              let window = hostWindow,
              event.window === window,
              let contentView = window.contentView else { return event }
        let topZone: CGFloat = 28
        let trafficLightWidth: CGFloat = 80
        let location = event.locationInWindow
        guard location.y >= contentView.bounds.height - topZone,
              location.x >= trafficLightWidth else { return event }
        TitleBarZoom.performSystemDoubleClickAction(on: window)
        return nil
    }

    /// Reordert die globale Tab-Bar: `dropped` landet vor `targetID`.
    /// Kommt der Drag aus der Sidebar (Session ohne offenen Tab), wird der
    /// Tab an der Drop-Position geöffnet.
    private func dropTab(_ dropped: DraggableSession, before targetID: UUID) {
        let id = dropped.sessionID
        guard id != targetID else { return }
        if let from = openTabIDs.firstIndex(of: id) {
            openTabIDs.remove(at: from)
        }
        let insertAt = openTabIDs.firstIndex(of: targetID) ?? openTabIDs.endIndex
        openTabIDs.insert(id, at: insertAt)
    }

    /// Wird vom Inspector-Button („PHPStorm öffnen") genutzt.
    private func openSelectedProjectInPHPStorm() {
        guard let selectedProject else { return }
        openProject(selectedProject, in: .phpStorm)
    }

    /// Öffnet das Projektverzeichnis im gewählten Ziel.
    private func openProject(_ project: AgentProject, in target: ProjectOpenTarget) {
        switch target {
        case .finder:
            NSWorkspace.shared.open(URL(fileURLWithPath: project.path))
        case .phpStorm:
            openInPhpStorm(path: project.path)
        }
    }

    /// Öffnet/fokussiert das Projekt in PhpStorm. Startet bewusst das
    /// gebündelte JetBrains-CLI-Binary mit dem Pfad statt `NSWorkspace.open`:
    /// Bei mehreren offenen PhpStorm-Projekten holt der macOS-open-Mechanismus
    /// nur die App nach vorne (zeigt das zuletzt benutzte Fenster), während
    /// das Binary die laufende Instanz anweist, GENAU dieses Projekt zu öffnen
    /// bzw. dessen Fenster zu fokussieren.
    private func openInPhpStorm(path: String) {
        let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.jetbrains.PhpStorm")
            ?? URL(fileURLWithPath: "/Applications/PhpStorm.app")
        let binaryURL = appURL.appendingPathComponent("Contents/MacOS/phpstorm")

        if FileManager.default.isExecutableFile(atPath: binaryURL.path) {
            let process = Process()
            process.executableURL = binaryURL
            process.arguments = [path]
            do {
                try process.run()
                return
            } catch {
                // Fällt unten auf den macOS-open-Weg zurück.
            }
        }

        // Fallback: App da, aber Binary-Start ging nicht.
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open(
            [URL(fileURLWithPath: path)],
            withApplicationAt: appURL,
            configuration: configuration
        ) { app, error in
            if app == nil || error != nil {
                DispatchQueue.main.async {
                    errorMessage = error?.localizedDescription ?? "PhpStorm konnte nicht geöffnet werden."
                }
            }
        }
    }
}

/// Ziel für „Projekt öffnen in …" — Default PhpStorm, Finder wählbar.
/// Die Wahl im Menü wird als neuer Default gemerkt (`agentProjectOpenTarget`).
enum ProjectOpenTarget: String, CaseIterable {
    case phpStorm
    case finder

    var label: String {
        switch self {
        case .phpStorm: return "PhpStorm"
        case .finder: return "Finder"
        }
    }

    var systemImage: String {
        switch self {
        case .phpStorm: return "chevron.left.forwardslash.chevron.right"
        case .finder: return "folder"
        }
    }
}

/// Snapshot der Daten, die das Background-Dispatch-Sheet braucht. Wir
/// kopieren das selektierte Projekt + die zum Zeitpunkt-des-Open gefundenen
/// Sub-Agents rein, damit das Modal unabhaengig von Workspace-Aenderungen
/// im Hintergrund bleibt.
struct PendingBackgroundDispatch: Identifiable, Equatable {
    let id = UUID()
    let project: AgentProject
    let subAgents: [SubAgent]
}

/// State-Snapshot fuer das BG-Logs-Sheet (`claude logs <id>`). Der `id`
/// dient als Stable-Identity, damit SwiftUI's `.sheet(item:)` das Sheet
/// nicht bei jedem State-Wechsel neu rebuilded — wir tauschen nur den
/// `state`-Wert aus.
struct BackgroundLogsPresentation: Identifiable, Equatable {
    enum State: Equatable {
        case loading
        case loaded(String)
        case failed(String)
    }

    let id = UUID()
    let sessionID: UUID
    let shortID: String
    let title: String
    var state: State

    func with(state newState: State) -> BackgroundLogsPresentation {
        var copy = self
        copy.state = newState
        return copy
    }
}

/// Snapshot fuer das Sub-Agent-Library-Sheet — wir kopieren die geladene
/// Liste rein, damit das Sheet beim Resize / Scrollen nicht jeden Frame
/// die FS-Discovery erneut faehrt.
struct SubAgentLibraryPresentation: Identifiable, Equatable {
    let id = UUID()
    let projectName: String?
    let agents: [SubAgent]
}

/// Read-Only-Liste aller Sub-Agents im aktiven User+Project-Scope.
/// Zweck: Discovery. Keine Edit-Aktionen — wenn der User editieren will,
/// macht er das in seinem Editor und re-discovered durch erneutes Oeffnen.
struct SubAgentLibrarySheet: View {
    let presentation: SubAgentLibraryPresentation
    var onClose: () -> Void

    private var grouped: [(scope: SubAgent.Scope, agents: [SubAgent])] {
        let projectAgents = presentation.agents.filter { $0.scope == .project }
        let userAgents = presentation.agents.filter { $0.scope == .user }
        var sections: [(SubAgent.Scope, [SubAgent])] = []
        if !projectAgents.isEmpty { sections.append((.project, projectAgents)) }
        if !userAgents.isEmpty { sections.append((.user, userAgents)) }
        return sections
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "books.vertical")
                    .foregroundStyle(AgentTheme.textSecondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sub-Agent-Bibliothek")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AgentTheme.textPrimary)
                    Text(presentation.projectName.map { "Scope: \($0) + global" } ?? "Scope: global")
                        .font(.system(size: 11))
                        .foregroundStyle(AgentTheme.textTertiary)
                }
                Spacer()
                Text("\(presentation.agents.count) Agents")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AgentTheme.textTertiary)
            }

            if presentation.agents.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(grouped, id: \.scope) { section in
                            sectionView(section.scope, agents: section.agents)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(minHeight: 260, maxHeight: 420)
            }

            HStack {
                Spacer()
                Button("Schließen") { onClose() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 600)
        .background(AgentTheme.panel)
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "tray")
                .font(.system(size: 22))
                .foregroundStyle(AgentTheme.textTertiary)
            Text("Keine Sub-Agents gefunden.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(AgentTheme.textSecondary)
            Text("Lege Markdown-Files unter ~/.claude/agents/ an oder im Projekt unter .claude/agents/.")
                .font(.system(size: 11))
                .foregroundStyle(AgentTheme.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
        .background(AgentTheme.surface, in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private func sectionView(_ scope: SubAgent.Scope, agents: [SubAgent]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(scope == .project ? "PROJEKT" : "GLOBAL")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.06)
                    .foregroundStyle(scope == .project ? .orange : AgentTheme.textTertiary)
                Text("· \(agents.count)")
                    .font(.system(size: 11))
                    .foregroundStyle(AgentTheme.textTertiary)
            }
            ForEach(agents) { agent in
                agentRow(agent)
            }
        }
    }

    @ViewBuilder
    private func agentRow(_ agent: SubAgent) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("@\(agent.name)")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(AgentTheme.textPrimary)
                if agent.isolationWorktree {
                    Label("worktree", systemImage: "square.stack.3d.up")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.indigo)
                }
                if let mode = agent.permissionMode {
                    Text(mode)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.purple)
                }
                if let model = agent.model {
                    Text(model)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(AgentTheme.textTertiary)
                }
                Spacer()
            }
            if let desc = agent.description, !desc.isEmpty {
                Text(desc)
                    .font(.system(size: 11))
                    .foregroundStyle(AgentTheme.textSecondary)
                    .lineLimit(3)
            }
            if agent.hasToolsRestriction, let tools = agent.toolsRaw {
                Text("Tools: \(tools)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(AgentTheme.textTertiary)
                    .lineLimit(2)
            }
            Text(agent.fileURL.path)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(AgentTheme.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AgentTheme.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6).stroke(AgentTheme.border, lineWidth: 1)
        )
    }
}

/// Modaler Sheet, der den Output von `claude logs <short-id>` anzeigt.
/// Read-only — refresht nicht selbststaendig. Schliesst per Esc oder
/// "Schliessen"-Button.
struct BackgroundAgentLogsSheet: View {
    let presentation: BackgroundLogsPresentation
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "doc.text.magnifyingglass")
                    .foregroundStyle(AgentTheme.textSecondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Logs · \(presentation.title)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AgentTheme.textPrimary)
                    Text("claude logs \(presentation.shortID)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(AgentTheme.textTertiary)
                }
                Spacer()
            }

            Group {
                switch presentation.state {
                case .loading:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Lade Logs …").foregroundStyle(AgentTheme.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                case .loaded(let output):
                    ScrollView {
                        Text(output.isEmpty ? "(kein Output)" : output)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(AgentTheme.textPrimary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                    .background(AgentTheme.surface, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6).stroke(AgentTheme.border, lineWidth: 1)
                    )
                    .frame(minHeight: 220, maxHeight: 380)
                case .failed(let message):
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                }
            }

            HStack {
                Spacer()
                Button("Schließen") { onClose() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 620)
        .background(AgentTheme.panel)
    }
}
