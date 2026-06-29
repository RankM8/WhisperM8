import AppKit
import SwiftUI

/// Liefert die nächste/vorherige Tab-ID mit Wrap-around (Browser-Verhalten).
/// `direction`: -1 = vorheriger, +1 = nächster Tab. Gibt `nil` zurück, wenn
/// keine Tabs offen sind. Ist `current` nicht (mehr) in der Liste, wird auf den
/// ersten Tab gesprungen. Window-frei → unit-testbar.
func adjacentTabID(in order: [UUID], current: UUID?, direction: Int) -> UUID? {
    guard !order.isEmpty else { return nil }
    guard let current, let idx = order.firstIndex(of: current) else { return order.first }
    return order[(idx + direction + order.count) % order.count]
}

/// Gesamtbreite des Tab-Strip-Inhalts (HStack aller Tabs).
private struct TabStripContentWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// Sichtbare Frame des Tab-Strip-ScrollViews in `.global` (Viewport-Breite +
/// X-Spanne fürs Mausrad-Hit-Test-Gating).
private struct TabStripFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

struct AgentChatsView: View {
    /// Benannter Coordinate-Space am Body-Root (window-relativ) — der
    /// Tab-Strip misst seine Frame darin fürs Mausrad-Hit-Test-Gating.
    private static let windowCoordinateSpaceName = "agentChatsWindow"
    /// Inhalts-Koordinatenraum der Tab-Leiste — Frame-Messung UND Drop-Location
    /// liegen darin (scroll-sicher, kein `.global`/`.local`-Mismatch).
    private static let tabStripContentSpace = "tabStripContent"

    let windowID: UUID
    @Environment(\.openWindow) var openWindow
    @State var store = AgentSessionStore()
    /// P1 S6: Live-Projektion des Workspace-Stands. Facade-Mutationen
    /// spiegeln sich hier automatisch — die früheren ~24 manuellen
    /// `workspace = store.loadWorkspace()`-Reloads entfallen.
    @State private var workspaceModel = AgentWorkspaceUIModel.shared
    var workspace: AgentWorkspace { workspaceModel.workspace }

    /// Phase-3 (S7-A): testbare Store-Aktionen. Zustandslos → on-demand erzeugt.
    /// internal, damit die Extensions (Session/Project-Lifecycle) es nutzen.
    var viewModel: AgentChatsViewModel { AgentChatsViewModel(store: store) }
    // MARK: - Fenster-/Tab-State (Single Source of Truth: AgentWindowStore)
    // Diese fuenf Properties sind Bridges auf den GETEILTEN Store: der Getter
    // liest den Slice DIESES Fensters, der Setter schreibt ueber Store-Mutationen
    // (die alle Invarianten + Persistenz erledigen). Kein Pro-View-@State, kein
    // NotificationCenter-Sync, kein Disk-Roundtrip mehr — der Zustand existiert
    // nur einmal im Store. `.append/.removeAll/.insert` an diesen Properties
    // funktionieren via Swifts get→modify→set über den `nonmutating set`.
    // @State (nicht let), damit SwiftUIs Observation-Tracking zuverlässig
    // greift: Reads über die Bridges unten lassen die View bei Store-Mutationen
    // (auch aus ANDEREN Fenstern) neu rendern.
    @State var windowStore = AgentWindowStore.shared
    var selectedProjectID: UUID? {
        get { windowStore.selectedProject(in: windowID) }
        nonmutating set { windowStore.setSelectedProject(newValue, in: windowID) }
    }
    var selectedSessionID: UUID? {
        get { windowStore.selectedSession(in: windowID) }
        nonmutating set { windowStore.setSelectedSession(newValue, in: windowID) }
    }
    var expandedProjectIDs: Set<UUID> {
        get { Set(windowStore.expandedProjectIDs) }
        nonmutating set { windowStore.setExpandedProjectIDs(Array(newValue)) }
    }
    var openTabIDs: [UUID] {
        get { windowStore.openTabIDs(in: windowID) }
        nonmutating set { windowStore.setOpenTabIDs(newValue, in: windowID) }
    }
    var pinnedSessionIDs: [UUID] {
        get { windowStore.pinnedSessionIDs }
        nonmutating set { windowStore.setPinnedSessionIDs(newValue) }
    }
    @State private var searchText = ""
    @State var errorMessage: String?
    @State var isIndexingSessions = false
    @State var indexRefreshTask: Task<Void, Never>?
    @State var lastIndexStats: [AgentSessionIndexStats] = []
    @State var sessionActionRequest: AgentSessionActionRequest?
    @StateObject var terminalRegistry = AgentTerminalRegistry.shared
    /// Live-Status-Store für die Sidebar-Indikatoren. Wird vom
    /// `AgentSessionRuntimeWatcher` gepflegt, ephemeral (nicht persistiert).
    ///
    /// P4, WICHTIG: bewusst `@State` statt `@StateObject` — Status-Ticks
    /// dürfen NICHT den gesamten Body invalidieren; die Rows subscriben
    /// per-Item via `statusPublisher(for:)`. Der Body darf `.statuses`
    /// deshalb NIE direkt lesen (sonst stale UI ohne Invalidation).
    @State var runtimeStatusStore = AgentSessionRuntimeStatusStore()
    /// Lazy-init in `setupRuntimeServicesIfNeeded()`, weil beide Services Refs
    /// auf Store + Closures brauchen, die wir vor `body` nicht haben.
    @State var runtimeWatcher: AgentSessionRuntimeWatcher?
    @State var autoNamer: AgentSessionAutoNamer?

    /// Etappe-0 Tab-Drag: gemessene Tab-Frames (Inhalts-Space) + aktueller
    /// Einfüge-Index während eines Drags (ephemer, nicht persistiert).
    @State private var tabFrames: [UUID: CGRect] = [:]
    /// internal, da der `leftMouseUp`-Monitor (in +Shortcuts) ihn zurücksetzt.
    @State var tabInsertionIndex: Int?

    /// Multi-Select der Tab-Leiste (ephemer, pro Fenster): leer = Einzel-Auswahl,
    /// sonst ≥ 2 IDs inkl. aktivem Tab. internal, da `handleTabClick` in +Tabs liegt.
    @State var multiSelection: Set<UUID> = []
    /// Mirror der `autoNamer.inFlight`-Set — wird via NotificationCenter
    /// aktualisiert, damit SwiftUI Re-Renders triggert. Wir koennen das nicht
    /// ueber @Observable machen weil autoNamer lazy-init in einem optionalen
    /// State lebt.
    @State private var autoRenamingSessionIDs: Set<UUID> = []
    /// Hook-Bridge fuer Real-Time-Detection von SessionStart/SessionEnd via
    /// Claude-Code-Hooks. Event-driven via `DispatchSource` — 0% idle CPU.
    @State var claudeHookBridge: ClaudeHookBridge?
    /// Pending ambiguous-rebind-Picker. `nil` solange keine
    /// Mehrdeutigkeit erkannt wurde.
    @State private var pendingAmbiguousRebind: AmbiguousRebindRequest?
    @SceneStorage("agentChatsInspectorVisible") private var isInspectorVisible = false
    @SceneStorage("agentChatsSidebarVisible") private var isSidebarVisible = true
    /// Gemerktes Ziel für „Projekt öffnen in …" (Default PhpStorm, Finder
    /// wählbar). Die Wahl im Menü setzt den neuen Default.
    @AppStorage("agentProjectOpenTarget") private var projectOpenTargetRaw = ProjectOpenTarget.phpStorm.rawValue
    /// Welche Chats die Sidebar zeigt (Aktiv·Zuletzt·Alle). Default `.active`
    /// hält die Liste klein; `@AppStorage` persistiert fensterweit ohne
    /// Schema-Migration. Die Suche überstimmt den Scope (siehe `effectiveScope`).
    @AppStorage("agentSidebarScope") private var sidebarScope: SidebarScope = .active
    /// Anordnung der Chat-Liste (gruppiert nach Projekt vs. flach/zeitlich).
    @AppStorage("agentSidebarLayout") private var sidebarLayout: SidebarLayout = .grouped
    /// IDs abgeschlossener Sessions, deren Transkript nicht mehr auf der Platte
    /// liegt („tote Zeiger"). Off-main berechnet (`refreshMissingTranscripts`),
    /// driftet die Sidebar zum Ausgrauen + Hinweis. Ephemeral, nicht persistiert.
    @State private var missingTranscriptIDs: Set<UUID> = []
    @State private var missingTranscriptTask: Task<Void, Never>?
    /// Das NSWindow des Agent-Chats-Fensters — vom `AgentChatsWindowAccessor`
    /// aufgelöst. Dient als Scope-Anker für den Cmd-W-Monitor (nur Events
    /// dieses Fensters schließen Tabs; Settings/Onboarding bleiben unberührt).
    @State var hostWindow: NSWindow?
    /// Lokaler `keyDown`-Monitor für „Tab schließen" (Cmd-W). Wird in
    /// `onAppear` installiert, in `onDisappear` abgebaut. `Any?` weil
    /// `addLocalMonitorForEvents` ein opaques Token zurückgibt.
    @State var closeTabKeyMonitor: Any?
    /// Lokaler `leftMouseDown`-Monitor für „Doppelklick auf die oberste Leiste
    /// = Fenster zoomen". Ersetzt das native Titelleisten-Verhalten, das durch
    /// hiddenTitleBar/fullSizeContentView verloren geht.
    @State var titleBarZoomMonitor: Any?
    /// Lokaler `scrollWheel`-Monitor: übersetzt vertikales Mausrad über dem
    /// Tab-Strip in horizontales (tab-weises) Scrollen. SwiftUI scrollt einen
    /// `ScrollView(.horizontal)` nicht per Mausrad — Trackpad-Gesten bleiben
    /// unangetastet (siehe `handleTabStripScroll`).
    @State var tabStripScrollMonitor: Any?
    /// Lokaler `leftMouseUp`-Monitor: setzt die Tab-Einfügelinie beim Loslassen
    /// zurück. `.draggable` cancelt die parallele DragGesture (kein `onEnded`)
    /// und `DropDelegate.dropExited`/`performDrop` feuern bei Cancel/Außerhalb-
    /// Drop nicht zuverlässig — mouseUp ist der einzige verlässliche Geber.
    @State var tabDragEndMonitor: Any?
    /// Frame des Tab-Strips im benannten Window-Coordinate-Space
    /// (`windowCoordinateSpaceName`). Dient dem Scroll-Monitor als X-Spanne
    /// fürs Hit-Test-Gating. Bewusst window-relativ statt `.global`, damit der
    /// Vergleich mit `event.locationInWindow.x` auch auf Zweit-Monitoren und im
    /// Vollbild stimmt (gleicher Ursprung am linken Fensterrand).
    @State private var stripFrameInWindow: CGRect = .zero
    /// „Anker"-Session, an die das Mausrad den Strip scrollt (führender Tab).
    /// Als UUID (nicht Index) gespeichert, damit die Identität über Reorder und
    /// Tab-Close stabil bleibt — kein veralteter Index, kein Out-of-Range.
    @State var stripWheelAnchorID: UUID?
    /// Bump-Trigger: erhöht sich pro Mausrad-Rasterung, der ScrollViewReader
    /// scrollt daraufhin zu `stripWheelAnchorID`.
    @State var stripWheelTick: Int = 0
    /// `true` während die Maus über dem Tab-Strip schwebt. Gating für den
    /// Mausrad-Monitor — robust statt fragiler Koordinaten-Umrechnung
    /// (AppKit `locationInWindow` ↔ SwiftUI-Frame brach im Fenstermodus durch
    /// den Titelleisten-Versatz). `.onHover` ist in beiden Modi identisch.
    @State var isHoveringTabStrip = false
    /// Sichtbare Breite des Tab-Strip-ScrollViews + Gesamtbreite seines Inhalts.
    /// Differenz > 0 ⇒ Überlauf ⇒ Chevron-Overflow-Menü einblenden.
    @State private var stripViewportWidth: CGFloat = 0
    @State private var stripContentWidth: CGFloat = 0
    @State private var renameTargetID: UUID?
    @State private var renameDraft: String = ""
    @State var renameProjectTargetID: UUID?
    @State var renameProjectDraft: String = ""
    /// Projekt, für das gerade der Lösch-Bestätigungsdialog offen ist.
    @State var projectPendingDeletion: AgentProject?
    /// Projekte, für die wir in dieser App-Session schon einen Auto-Icon-Lookup
    /// gestartet haben — verhindert wiederholte Filesystem-Scans bei jedem
    /// Workspace-Reload.
    @State var iconLookupAttempted: Set<UUID> = []

    /// Wenn nicht-nil, zeigen wir das Background-Dispatch-Modal als Sheet.
    /// Bindet an ein Snapshot des aktuell selektierten Projekts, damit der
    /// User waehrend des Modals nicht aus Versehen das Projekt wechselt.
    @State var pendingBackgroundDispatch: PendingBackgroundDispatch?
    /// Local-Session-ID einer Background-Session, die gerade noch spawned —
    /// die UI zeigt den Tab schon, aber `claude attach` startet erst nach
    /// dem Spawn-Callback. Verhindert dass der Detail-View sofort prepareCommand
    /// fuehrt (was ohne Short-ID failen wuerde).
    @State var spawningBackgroundSessions: Set<UUID> = []
    /// Aktive Lifecycle-Aktionen (Logs/Stop/Respawn/Rm) — kennzeichnet die
    /// Session-ID waehrend des Subprocess-Aufrufs, damit das Context-Menu
    /// re-entrant-sicher ist.
    @State var pendingLifecycleSessions: Set<UUID> = []
    /// Wenn nicht-nil, zeigen wir das Logs-Sheet fuer diese BG-Session.
    @State var pendingBackgroundLogs: BackgroundLogsPresentation?
    /// `true` solange beim App-Start der Health-Check noch laeuft —
    /// verhindert mehrfache parallele Laeufe.
    @State var hasRunStartupHealthCheck = false
    /// Session-IDs, fuer die wir ueber einen `Notification`-Hook ein
    /// "Needs Input"-Signal bekommen haben. Wird vom Notification-Listener
    /// gepflegt; die Sidebar pulst diese Sessions zusaetzlich zum
    /// regulaeren Runtime-Status.
    @State private var awaitingInputSessionIDs: Set<UUID> = []
    /// Drossel für den Fertig-Ton (Stop-Hook): kein zweiter Ton innerhalb von
    /// 2 s, falls mehrere Sessions kurz hintereinander stoppen.
    @State var lastStopSoundAt: Date?
    /// Popover des „Neuer Chat"-Split-Buttons (▾): Ziel-Projekt wählen/suchen.
    @State var showNewChatProjectPicker = false
    @State var newChatProjectQuery = ""
    /// `true` solange das Sub-Agent-Library-Sheet sichtbar ist.
    @State var subAgentLibrarySheet: SubAgentLibraryPresentation?
    /// Live-Tracker fuer die aktive Sub-Session innerhalb eines
    /// `.agentView`-TUI-Tabs. Polls `~/.claude/jobs/*/state.json` und meldet,
    /// wo der User gerade tippt / Claude gerade antwortet.
    @StateObject private var activeBackgroundTracker = ActiveBackgroundSessionTracker()

    var selectedProject: AgentProject? {
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
    var headerTabs: [AgentChatSession] {
        let byID = Dictionary(workspace.sessions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return openTabIDs.compactMap { byID[$0] }.filter { $0.status != .archived }
    }

    var selectedSession: AgentChatSession? {
        guard let selectedSessionID else { return headerTabs.first }
        return workspace.sessions.first { $0.id == selectedSessionID && $0.status != .archived }
            ?? headerTabs.first
    }

    /// `true`, wenn der Tab-Strip-Inhalt breiter ist als sein sichtbarer
    /// Bereich — dann blenden wir das Chevron-Overflow-Menü ein. Im Fullscreen
    /// (alle Tabs passen rein) ist das `false`.
    private var hasTabOverflow: Bool {
        stripContentWidth > stripViewportWidth + 1
    }

    /// Projekt der selektierten Session — kann kurzzeitig vom
    /// Kontext-Projekt abweichen, bis `selectedProjectID` der Selektion
    /// gefolgt ist (onChange).
    private var selectedSessionProject: AgentProject? {
        guard let selectedSession else { return nil }
        return workspace.projects.first { $0.id == selectedSession.projectID }
    }

    var manualProjects: [AgentProject] {
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
        .coordinateSpace(.named(Self.windowCoordinateSpaceName))
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
            // Fenster-/Tab-State kommt live aus AgentWindowStore (SSoT) — kein
            // Laden in lokalen @State mehr. Nur Selektion gegen den (gerade
            // geladenen) Workspace bereinigen.
            reconcileSelection()
            syncActiveAgentChat()
            migrateIconDetectionIfNeeded()
            attemptAutoDetectProjectIcons()
            runBackgroundAgentStartupHealthCheckIfNeeded()
            updateActiveBackgroundTrackerIfNeeded()
            installCloseTabShortcutIfNeeded()
            installTitleBarZoomHandlerIfNeeded()
            installTabStripScrollMonitorIfNeeded()
            installTabDragEndMonitorIfNeeded()
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
        .onReceive(NotificationCenter.default.publisher(for: AgentChatsView.agentDidStopNotification)) { note in
            guard let id = note.userInfo?["localID"] as? UUID else { return }
            // Turn fertig (Stop-Hook): sofort idle — schneller + robuster als
            // der 1,5-s-Transkript-Poll, und deckt Background-Agents ab.
            runtimeStatusStore.setStatus(.idle, for: id)
            playAgentStopSoundIfEnabled()
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
            removeTabStripScrollMonitor()
            removeTabDragEndMonitor()
            // Window zu → kein aktiver Chat mehr für Recording-Coordinator.
            AppState.shared.activeAgentChat = nil
        }
        .onChange(of: selectedSessionID) { _, newValue in
            syncActiveAgentChat()
            // Kontext-Projekt folgt der Selektion — Tabs sind global, das
            // Projekt ist nur noch Ziel für „Neuer Chat" und den Inspector.
            // (Persistenz erledigt der Store automatisch bei jeder Mutation.)
            if let sessionID = newValue,
               let session = workspace.sessions.first(where: { $0.id == sessionID }) {
                selectedProjectID = session.projectID
            }
            updateActiveBackgroundTrackerIfNeeded()
        }
        .onChange(of: selectedProjectID) { _, _ in
            syncActiveAgentChat()
        }
        .onChange(of: workspace) { _, _ in
            syncActiveAgentChat()
            // P1 S6: Selektion darf nach Mutationen (z. B. deleteSession aus
            // dem Spawn-Fehlerpfad) nie auf Gelöschtes zeigen.
            reconcileSelection()
        }
        .onChange(of: openTabIDs) { _, _ in
            closeWindowIfEmptyAndSecondary()
        }
        .onChange(of: isHoveringTabStrip) { _, hovering in
            // Window-Drag hover-gesteuert: über dem Tab-Strip AUS (Klick/Drag
            // bewegt den Tab, nicht das Fenster), auf freien Flächen AN. Setzen
            // schon beim Hover — nicht erst beim mouseDown — umgeht das frühere
            // Timing-Problem, bei dem ein Tab-Drag doch das Fenster zog.
            hostWindow?.isMovable = !hovering
        }
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

    /// Schliesst dieses Fenster, wenn es zu einem leeren Sekundaerfenster
    /// geworden ist (letzter Tab raus/verschoben). Der Store entfernt den
    /// State-Eintrag; das NSWindow wird async geschlossen — nie im Stack einer
    /// laufenden Geste, sonst zieht es die View unter dem Handler weg.
    private func closeWindowIfEmptyAndSecondary() {
        guard windowStore.removeWindowIfEmpty(windowID) else { return }
        DispatchQueue.main.async { hostWindow?.performClose(nil) }
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
                .padding(.top, 2)
                .padding(.bottom, 6)

            sidebarScopeBar

            ScrollView {
                // P4: Sidebar-Modell EINMAL pro Body-Eval bauen (Gruppierung +
                // Suche in einem Durchlauf) statt pro Projekt neu zu filtern
                // und zu sortieren.
                let openTabIDSet = Set(openTabIDs)
                // isRunning-Flips published die Registry nicht selbst; frisch
                // wird das Set bei jedem Body-Eval (Registry-Inserts/Removes
                // sind @Published und triggern den). Für Live-Status zählt
                // ohnehin `liveStatus` in der Row — isRunning ist nur der
                // Fallback, solange der Watcher noch keinen Status hat.
                let runningSessionIDs = terminalRegistry.activeSessionIDs
                let scopeFilter = makeScopeFilter(
                    openTabIDs: openTabIDSet,
                    runningSessionIDs: runningSessionIDs
                )
                let sessionsByProject = AgentSidebarModelBuilder.sessionsByProject(
                    workspaceSessions: workspace.sessions,
                    pinnedSessionIDs: Set(pinnedSessionIDs),
                    scope: scopeFilter
                )
                // Im gefilterten Scope leere Projektgruppen ausblenden — sonst
                // stünden in „Aktiv" lauter Projekte ohne Zeilen. In `.all` (und
                // bei leerer Suche) bleiben alle Projekte sichtbar, damit man in
                // ein leeres Projekt hinein einen Chat anlegen kann.
                let visibleProjects = AgentSidebarModelBuilder.visibleProjects(
                    manualProjects: manualProjects,
                    sessionsByProject: sessionsByProject,
                    query: searchText
                ).filter { effectiveScope == .all || !(sessionsByProject[$0.id] ?? []).isEmpty }
                let flatSessions = AgentSidebarModelBuilder.flatSessions(
                    workspaceSessions: workspace.sessions,
                    pinnedSessionIDs: Set(pinnedSessionIDs),
                    scope: scopeFilter
                )
                let trimmedQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                let visiblePinned = AgentSidebarModelBuilder.pinnedSessions(
                    workspaceSessions: workspace.sessions,
                    pinnedSessionIDs: pinnedSessionIDs
                ).filter { trimmedQuery.isEmpty || $0.title.localizedCaseInsensitiveContains(trimmedQuery) }
                let chatListIsEmpty = (sidebarLayout == .flat ? flatSessions.isEmpty : visibleProjects.isEmpty)
                VStack(alignment: .leading, spacing: 2) {
                    if manualProjects.isEmpty {
                        sidebarEmptyState
                    } else if chatListIsEmpty && visiblePinned.isEmpty {
                        scopeEmptyHint
                    }

                    if !visiblePinned.isEmpty {
                        sidebarSectionLabel("Gepinnt", systemImage: "pin")
                        ForEach(visiblePinned) { session in
                            pinnedRow(session, runningSessionIDs: runningSessionIDs)
                        }
                        if !chatListIsEmpty {
                            sidebarSectionLabel("Chats")
                        }
                    }

                    if sidebarLayout == .flat {
                        ForEach(flatSessions) { session in
                            flatRow(session, runningSessionIDs: runningSessionIDs)
                        }
                    } else {
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
                            missingTranscriptSessionIDs: missingTranscriptIDs,
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
                }
                .padding(.vertical, 6)
            }

            Spacer(minLength: 0)

            sidebarFooter
        }
        .background(AgentTheme.sidebar)
        .onAppear { refreshMissingTranscripts() }
        .onChange(of: workspace.sessions.count) { _, _ in refreshMissingTranscripts() }
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
        .padding(.horizontal, 14)
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
            isMissingTranscript: missingTranscriptIDs.contains(session.id),
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

    /// Zeile der flachen (ungruppierten) Ansicht: Repo-Badge + Titel + Status
    /// (`PinnedSessionRow` wiederverwendet, da projektübergreifend). Kontextmenü
    /// wie eine normale Chat-Zeile, nur „Anpinnen" statt „Loslösen".
    @ViewBuilder
    private func flatRow(_ session: AgentChatSession, runningSessionIDs: Set<UUID>) -> some View {
        PinnedSessionRow(
            session: session,
            project: workspace.projects.first { $0.id == session.projectID },
            isSelected: selectedSessionID == session.id,
            isRunning: runningSessionIDs.contains(session.id),
            statusStore: runtimeStatusStore,
            isAwaitingInput: awaitingInputSessionIDs.contains(session.id),
            isMissingTranscript: missingTranscriptIDs.contains(session.id),
            onSelect: {
                selectedProjectID = session.projectID
                openTab(session.id)
                selectedSessionID = session.id
            },
            onClose: { archiveSession(session) }
        )
        .contextMenu {
            Button("Umbenennen…", systemImage: "pencil") {
                beginRename(session)
            }
            Button("Titel automatisch generieren", systemImage: "sparkles") {
                forceAutoNameSession(session)
            }
            .disabled(session.externalSessionID == nil)
            forkMenuItem(session)
            Divider()
            Button("Anpinnen", systemImage: "pin") {
                pinSession(session.id)
            }
            tabColorMenu(for: session)
            Divider()
            Button("Chat schließen", systemImage: "xmark", role: .destructive) {
                archiveSession(session)
            }
        }
    }

    /// Hinweis, wenn der aktive Scope (Aktiv/Zuletzt) keine Chats zeigt, es aber
    /// Projekte/Chats gibt — damit sich nichts „verloren" anfühlt: ein Klick
    /// zurück auf „Alle".
    private var scopeEmptyHint: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(sidebarScope == .active ? "Keine aktiven Chats" : "Keine Chats im Zeitraum")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AgentTheme.textSecondary)
            Text("Laufende, offene und gepinnte Chats erscheinen hier. Ältere findest du unter „Alle“.")
                .font(.system(size: 11))
                .foregroundStyle(AgentTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                sidebarScope = .all
            } label: {
                Text("Alle Chats zeigen")
                    .font(.system(size: 11, weight: .medium))
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

    func createDefaultSession() {
        let target = AppPreferences.shared.defaultAgentLaunchTarget
        createSession(provider: target.provider, kind: target.kind)
    }

    private var sidebarCommandRows: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                newChatSplitButton

                sidebarIconButton(icon: "arrow.clockwise", help: "Sessions neu einlesen (⌘R)") {
                    AgentScanCoordinator.shared.requestScan(reason: .manual)
                }
                .keyboardShortcut("r", modifiers: .command)
            }
            .padding(.horizontal, 8)

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AgentTheme.textTertiary)
                TextField("Filter…", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
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
    }

    /// Kompakter 30×30 Icon-Button für sekundäre Sidebar-Aktionen
    /// (Aktualisieren) neben dem primären „Neuer Chat".
    @ViewBuilder
    private func sidebarIconButton(icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(AgentTheme.textSecondary)
                .frame(width: 30, height: 30)
                .background(AgentTheme.hover, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// „Neuer Chat" als Split-Button: links startet sofort im aktuellen
    /// Zielprojekt (Badge sichtbar → man sieht, wo der Chat landet), der
    /// ▾-Teil rechts öffnet ein durchsuchbares Dropdown zum Wählen eines
    /// anderen Projekts oder zum Hinzufügen eines neuen.
    private var newChatSplitButton: some View {
        HStack(spacing: 0) {
            Button {
                createDefaultSession()
            } label: {
                HStack(spacing: 7) {
                    if let project = selectedProject {
                        ProjectAvatar(project: project, size: 15)
                    } else {
                        Image(systemName: "square.stack.3d.up")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    Text("Neuer Chat")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(AgentTheme.textPrimary)
                .opacity(selectedProject == nil ? 0.5 : 1)
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(selectedProject == nil)
            .help(selectedProject.map { "Neuer Chat in \($0.name)" } ?? "Erst ein Projekt hinzufügen")

            Divider().frame(height: 16)

            Button {
                showNewChatProjectPicker.toggle()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(AgentTheme.textSecondary)
                    .frame(width: 28, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Projekt für neuen Chat wählen oder hinzufügen")
            .popover(isPresented: $showNewChatProjectPicker, arrowEdge: .bottom) {
                newChatProjectPicker
            }
        }
        .background(AgentTheme.control, in: RoundedRectangle(cornerRadius: 8))
        .frame(maxWidth: .infinity)
    }

    /// Durchsuchbares Dropdown des Split-Buttons: alle Projekte (Badge + Name +
    /// Branch), das aktuelle Ziel markiert, plus „Projekt hinzufügen…".
    private var newChatProjectPicker: some View {
        let query = newChatProjectQuery.trimmingCharacters(in: .whitespaces)
        let projects = query.isEmpty
            ? manualProjects
            : manualProjects.filter { $0.name.localizedCaseInsensitiveContains(query) }
        return VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(AgentTheme.textTertiary)
                TextField("Projekt suchen…", text: $newChatProjectQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 11)
            .frame(height: 36)

            Divider()

            ScrollView {
                VStack(spacing: 1) {
                    ForEach(projects) { project in
                        Button {
                            startNewChat(in: project)
                        } label: {
                            HStack(spacing: 8) {
                                ProjectAvatar(project: project, size: 16)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(project.name)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(AgentTheme.textPrimary)
                                        .lineLimit(1)
                                    Text(project.lastBranch ?? project.path)
                                        .font(.system(size: 9.5))
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
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PopoverRowButtonStyle())
                    }
                    if projects.isEmpty {
                        Text(query.isEmpty ? "Noch keine Projekte" : "Kein Projekt gefunden")
                            .font(.system(size: 11))
                            .foregroundStyle(AgentTheme.textTertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 260)

            Divider()

            Button {
                showNewChatProjectPicker = false
                if let project = addProject() {
                    startNewChat(in: project)
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 12))
                        .frame(width: 16)
                    Text("Projekt hinzufügen…")
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
    }

    /// Effektiver Scope: die Suche überstimmt den Scope-Filter — tippt der
    /// User etwas, wird IMMER über alle Chats gesucht, egal welcher Filter
    /// gewählt ist (sonst „warum finde ich meinen Chat nicht").
    private var effectiveScope: SidebarScope {
        searchText.trimmingCharacters(in: .whitespaces).isEmpty ? sidebarScope : .all
    }

    /// Baut den auswertbaren Filter aus dem effektiven Scope + Live-Inputs.
    private func makeScopeFilter(openTabIDs: Set<UUID>, runningSessionIDs: Set<UUID>) -> SidebarScopeFilter {
        SidebarScopeFilter(
            scope: effectiveScope,
            runningSessionIDs: runningSessionIDs,
            openTabIDs: openTabIDs,
            now: Date(),
            recentWindow: SidebarScopeFilter.defaultRecentWindow
        )
    }

    /// Berechnet die „toten Zeiger" (Transkript fehlt auf der Platte) off-main
    /// und schreibt sie in `missingTranscriptIDs`. Debounced (300 ms), damit
    /// Workspace-Reload-Bursts keinen FS-Scan-Spam auslösen. Snapshot der
    /// Inputs läuft auf Main, der FS-Scan im Hintergrund.
    private func refreshMissingTranscripts() {
        let sessions = workspace.sessions
        let projectPathByID = Dictionary(
            workspace.projects.map { ($0.id, $0.path) },
            uniquingKeysWith: { first, _ in first }
        )
        let runningIDs = terminalRegistry.activeSessionIDs
        missingTranscriptTask?.cancel()
        missingTranscriptTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let missing = AgentTranscriptPresence.missingTranscriptSessionIDs(
                sessions: sessions,
                projectPathByID: projectPathByID,
                runningSessionIDs: runningIDs
            )
            guard !Task.isCancelled else { return }
            await MainActor.run { missingTranscriptIDs = missing }
        }
    }

    /// Scope-Umschalter (Aktiv·Zuletzt·Alle) + Layout-Toggle (gruppiert·flach)
    /// + „N von M sichtbar"-Hinweis. Fest verankert über der Chat-Liste,
    /// scrollt also nicht mit.
    private var sidebarScopeBar: some View {
        let counts = AgentSidebarModelBuilder.scopeCounts(
            workspaceSessions: workspace.sessions,
            pinnedSessionIDs: Set(pinnedSessionIDs),
            runningSessionIDs: terminalRegistry.activeSessionIDs,
            openTabIDs: Set(openTabIDs),
            now: Date()
        )
        let visibleCount: Int = {
            switch sidebarScope {
            case .active: return counts.active
            case .recent: return counts.recent
            case .all: return counts.all
            }
        }()
        let searching = !searchText.trimmingCharacters(in: .whitespaces).isEmpty
        return VStack(spacing: 5) {
            HStack(spacing: 6) {
                // Eigener Segmented-Control: der native Picker(.segmented)
                // expandiert auf macOS NICHT auf volle Breite — das darunter
                // liegende NSSegmentedControl behält seine intrinsische Größe,
                // `.frame(maxWidth:.infinity)` wird ignoriert. Eigene Buttons
                // mit maxWidth füllen die Breite zuverlässig (wie im Entwurf,
                // wo `.seg button { flex: 1 }` galt).
                HStack(spacing: 2) {
                    ForEach(SidebarScope.allCases) { scope in
                        let isOn = sidebarScope == scope
                        Button { sidebarScope = scope } label: {
                            Text(scope.label)
                                .font(.system(size: 11, weight: isOn ? .semibold : .medium))
                                .foregroundStyle(isOn ? AgentTheme.textPrimary : AgentTheme.textSecondary)
                                .frame(maxWidth: .infinity, minHeight: 22)
                                .background {
                                    if isOn {
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(AgentTheme.segmentActive)
                                            .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
                                    }
                                }
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(2)
                .frame(maxWidth: .infinity)
                .background(AgentTheme.control, in: RoundedRectangle(cornerRadius: 8))
                .disabled(searching)
                .opacity(searching ? 0.55 : 1)
                .help(searching ? "Suche zeigt alle Chats" : "Welche Chats die Liste zeigt")

                Button {
                    sidebarLayout = (sidebarLayout == .grouped ? .flat : .grouped)
                } label: {
                    Image(systemName: sidebarLayout.toggleIcon)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(AgentTheme.textSecondary)
                        .frame(width: 30, height: 26)
                        .background(AgentTheme.control, in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(sidebarLayout == .grouped
                    ? "Flach anzeigen (nach Aktivität sortiert)"
                    : "Nach Projekt gruppieren")
            }

            if searching {
                captionRow(text: "Suche zeigt alle Chats", action: nil, actionLabel: nil)
            } else if sidebarScope != .all {
                captionRow(
                    text: "\(visibleCount) von \(counts.all) Chats",
                    action: { sidebarScope = .all },
                    actionLabel: "Alle zeigen"
                )
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private func captionRow(text: String, action: (() -> Void)?, actionLabel: String?) -> some View {
        HStack(spacing: 4) {
            Text(text)
                .font(.system(size: 10))
                .foregroundStyle(AgentTheme.textTertiary)
            Spacer(minLength: 0)
            if let action, let actionLabel {
                Button(action: action) {
                    Text(actionLabel)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(AgentTheme.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Filter aufheben — alle Chats zeigen")
            }
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
            // Tabs sitzen in der Titelzone (oberste ~28px), browserähnlich neben
            // den Ampel-Buttons. Window-Drag wird hover-gesteuert ausgeschaltet,
            // sobald die Maus über dem Tab-Strip schwebt (siehe
            // `.onChange(of: isHoveringTabStrip)` am Body) — so zieht ein Klick/
            // Drag auf einem Tab nie das Fenster, während freie Flächen (links/
            // Lücken) das Fenster weiterhin verschieben.
            HStack(spacing: 6) {
                if !isSidebarVisible {
                    // Platz für die Ampel-Buttons, wenn die Sidebar aus ist.
                    Spacer().frame(width: 70)
                }

                TitlebarIconButton(systemImage: "sidebar.left", help: isSidebarVisible ? "Sidebar ausblenden" : "Sidebar einblenden", isActive: isSidebarVisible) {
                    isSidebarVisible.toggle()
                }

                if !headerTabs.isEmpty {
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal, showsIndicators: false) {
                            let runningSessionIDs = terminalRegistry.activeSessionIDs
                            HStack(spacing: 4) {
                                ForEach(headerTabs) { session in
                                    ChatTabButton(
                                        session: session,
                                        project: workspace.projects.first { $0.id == session.projectID },
                                        isSelected: session.id == selectedSession?.id,
                                        isMultiSelected: multiSelection.contains(session.id),
                                        isRunning: runningSessionIDs.contains(session.id),
                                        statusStore: runtimeStatusStore,
                                        isAwaitingInput: awaitingInputSessionIDs.contains(session.id),
                                        onSelect: {
                                            handleTabClick(session.id)
                                        },
                                        onClose: {
                                            closeTab(session)
                                        }
                                    )
                                    // Mittelklick (Mausrad) schließt den Tab — wie im Browser.
                                    .onMiddleClick { closeTab(session) }
                                    .draggable(DraggableSession(
                                        sessionID: session.id,
                                        sourceProjectID: session.projectID,
                                        sourceWindowID: windowID
                                    )) {
                                        TabDragPreview(title: session.title)
                                    }
                                    .simultaneousGesture(
                                        DragGesture(minimumDistance: 20)
                                            .onEnded { value in
                                                // Drag vorbei (Drop, Cancel ODER außerhalb der
                                                // Drop-Zone losgelassen). dropExited/performDrop
                                                // feuern dabei NICHT zuverlässig (SwiftUI-Bug) →
                                                // die Einfügelinie hier sicher zurücksetzen.
                                                tabInsertionIndex = nil
                                                if shouldDetachTab(for: value) {
                                                    moveTabToNewWindow(session)
                                                }
                                            }
                                    )
                                    .contextMenu {
                                        sessionManagementMenu(session)
                                    }
                                    // Tab-Frame im Inhalts-Space messen → Einfüge-Linie.
                                    .background(
                                        GeometryReader { geo in
                                            Color.clear.preference(
                                                key: TabFramePreferenceKey.self,
                                                value: [session.id: geo.frame(in: .named(Self.tabStripContentSpace))]
                                            )
                                        }
                                    )
                                }
                            }
                            .coordinateSpace(.named(Self.tabStripContentSpace))
                            .onPreferenceChange(TabFramePreferenceKey.self) { tabFrames = $0 }
                            // Stale IDs aus der Multi-Auswahl entfernen, wenn sich die offenen Tabs ändern.
                            .onChange(of: headerTabs.map(\.id)) { _, ids in
                                multiSelection.formIntersection(Set(ids))
                            }
                            // Einfüge-Linie an der Drop-Position (zwischen den Tabs).
                            .overlay(alignment: .leading) {
                                if let index = tabInsertionIndex,
                                   let x = TabReorderGeometry.insertionX(
                                    forIndex: index,
                                    orderedIDs: headerTabs.map(\.id),
                                    frames: tabFrames,
                                    spacing: 4
                                   ) {
                                    TabInsertionIndicator()
                                        .offset(x: x - 1.25)
                                        .allowsHitTesting(false)
                                }
                            }
                            .animation(.easeOut(duration: 0.1), value: tabInsertionIndex)
                            .background(WindowDragExclusionView())
                            // Reorder/Move + Cross-Window: EIN DropDelegate für die
                            // ganze Leiste → kontinuierliche Einfüge-Position (Linie)
                            // und Move-Semantik (kein Copy-„+"). Cross-Window/Sidebar-
                            // Open laufen weiter über windowStore.moveTab in dropTab.
                            .onDrop(of: [.agentChatSession], delegate: TabReorderDropDelegate(
                                orderedIDs: headerTabs.map(\.id),
                                frames: tabFrames,
                                insertionIndex: $tabInsertionIndex,
                                onMove: { dropped, beforeID in
                                    // Multi-Drag: ist das gezogene Tab Teil der Auswahl, wird die
                                    // ganze Gruppe (in Anzeige-Reihenfolge) als Block einsortiert —
                                    // vorerst nur same-window (Cross-Window-Gruppe = Folgeschritt).
                                    let group = multiSelection.contains(dropped.sessionID)
                                        ? openTabIDs.filter { multiSelection.contains($0) }
                                        : []
                                    let sameWindow = (dropped.sourceWindowID ?? windowID) == windowID
                                    if sameWindow, group.count > 1 {
                                        let newOrder = TabGroupReorder.newOrder(openTabIDs, moving: Set(group), before: beforeID)
                                        windowStore.setOpenTabIDs(newOrder, in: windowID)
                                    } else if let beforeID {
                                        dropTab(dropped, before: beforeID)
                                    } else {
                                        dropTabAtEnd(dropped)
                                    }
                                }
                            ))
                            // Gesamtbreite des Inhalts → Überlauf-Erkennung fürs Chevron.
                            .background(
                                GeometryReader { geo in
                                    Color.clear.preference(key: TabStripContentWidthKey.self, value: geo.size.width)
                                }
                            )
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
                        // Sichtbare Frame des Strips → Viewport-Breite (Überlauf)
                        // + X-Spanne (window-relativ) fürs Hit-Test-Gating des
                        // Mausrad-Monitors.
                        .background(
                            GeometryReader { geo in
                                Color.clear.preference(
                                    key: TabStripFrameKey.self,
                                    value: geo.frame(in: .named(Self.windowCoordinateSpaceName))
                                )
                            }
                        )
                        .onPreferenceChange(TabStripContentWidthKey.self) { stripContentWidth = $0 }
                        .onPreferenceChange(TabStripFrameKey.self) { frame in
                            stripFrameInWindow = frame
                            stripViewportWidth = frame.width
                        }
                        // Hover-Gating für den Mausrad-Monitor — robust in
                        // Fenster- UND Vollbildmodus (kein Koordinaten-Hit-Test).
                        .onHover { isHoveringTabStrip = $0 }
                        // Bei Tab-Wechsel (⌘⌥←/→, ⌘1–⌘9, Sidebar) den aktiven Tab
                        // in Sicht scrollen, falls die Bar überläuft. Hält außerdem
                        // den Mausrad-Anker an der Selektion, damit das Rad danach
                        // von dort weiterläuft.
                        .onChange(of: selectedSessionID) { _, id in
                            guard let id else { return }
                            stripWheelAnchorID = id
                            withAnimation(.easeInOut(duration: 0.15)) {
                                proxy.scrollTo(id, anchor: .center)
                            }
                        }
                        // Mausrad-Scroll (siehe handleTabStripScroll): tab-weise
                        // horizontal scrollen (scrollTo auf eine nicht mehr
                        // vorhandene ID ist ein No-Op → robust gegen Tab-Close).
                        .onChange(of: stripWheelTick) { _, _ in
                            guard let id = stripWheelAnchorID else { return }
                            withAnimation(.easeInOut(duration: 0.12)) {
                                proxy.scrollTo(id, anchor: .leading)
                            }
                        }
                    }
                }

                // Overflow-Menü: erscheint nur bei Tab-Überlauf (Fenstermodus).
                // Listet ALLE offenen Tabs; Klick selektiert → bestehender
                // onChange scrollt den Tab in Sicht. Im Fullscreen unsichtbar.
                if hasTabOverflow {
                    Menu {
                        ForEach(headerTabs) { session in
                            Button {
                                selectedSessionID = session.id
                            } label: {
                                if session.id == selectedSession?.id {
                                    Label(session.title, systemImage: "checkmark")
                                } else {
                                    Text(session.title)
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(AgentTheme.textSecondary)
                            .frame(width: 22, height: 22)
                            .background(AgentTheme.control.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Alle Tabs")
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
    func forceAutoNameUntitledSessions() {
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
            Button("In neues Fenster verschieben", systemImage: "macwindow.badge.plus") {
                moveTabToNewWindow(session)
            }
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
