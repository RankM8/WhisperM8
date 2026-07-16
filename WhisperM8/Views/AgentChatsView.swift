import AppKit
import SwiftUI

/// Liefert die nächste/vorherige Tab-ID mit Wrap-around (Browser-Verhalten).
/// `direction`: -1 = vorheriger, +1 = nächster Tab; der Ctrl+Tab-Switcher
/// springt mit ±Spaltenzahl auch ganze Grid-Reihen. Gibt `nil` zurück, wenn
/// keine Tabs offen sind. Ist `current` nicht (mehr) in der Liste, wird auf den
/// ersten Tab gesprungen. Window-frei → unit-testbar.
func adjacentTabID(in order: [UUID], current: UUID?, direction: Int) -> UUID? {
    guard !order.isEmpty else { return nil }
    guard let current, let idx = order.firstIndex(of: current) else { return order.first }
    // Echtes positives Modulo: Swifts `%` behält das Vorzeichen — bei
    // Mehrfach-Schritten (|direction| > count, z. B. stale Spaltenzahl nach
    // externem Tab-Close) wäre der Index sonst negativ.
    let raw = (idx + direction) % order.count
    return order[(raw + order.count) % order.count]
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
    /// Festbreite des rechten Inspectors (ProjectDetailPanel) — geht auch in
    /// die Sidebar-Max-Breite ein (`SidebarWidthResolver.maxWidth`).
    private static let inspectorPanelWidth: CGFloat = 292

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
        nonmutating set {
            // Quellenunabhängige Klickregel (Plan-Abschnitt 03) — zentral im
            // Store (`navigateToSession`): Chat im sichtbaren Workspace →
            // Pane-Fokus, sonst Einzelansicht; Slots bleiben IMMER
            // unverändert (Klick navigiert, Drop kuratiert).
            guard let newValue else {
                windowStore.setSelectedSession(nil, in: windowID)
                return
            }
            // Lebt der Chat als Tab in einem ANDEREN Fenster, wird DORT
            // navigiert und das Fenster nach vorn geholt — ein lokales
            // Öffnen würde den Tab über die globale Deduplizierung still
            // stehlen (Review-Finding; Chrome-Semantik wie Notification-Klick).
            if let host = windowStore.windowID(containingTab: newValue), host != windowID {
                WindowRequestCenter.shared.requestSessionFocus(sessionID: newValue)
                return
            }
            windowStore.navigateToSession(newValue, in: windowID)
        }
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
    /// Live-Status-Store für die Sidebar-Indikatoren — die app-weite Instanz
    /// des `AgentSessionStatusCoordinator` (alle Fenster sehen denselben
    /// Status; Tracking überlebt Fenster-Schließen).
    ///
    /// P4, WICHTIG: bewusst KEIN `@StateObject` — Status-Ticks dürfen NICHT
    /// den gesamten Body invalidieren; die Rows subscriben per-Item via
    /// `statusPublisher(for:)`. Der Body darf `.statuses` deshalb NIE direkt
    /// lesen (sonst stale UI ohne Invalidation).
    var runtimeStatusStore: AgentSessionRuntimeStatusStore {
        AgentSessionStatusCoordinator.shared.statusStore
    }
    /// Referenz auf den app-weiten Auto-Namer (Koordinator) — lazy in
    /// `setupRuntimeServicesIfNeeded()` gesetzt.
    @State var autoNamer: AgentSessionAutoNamer?
    /// Laufzeit-Projektion der Subagent-Jobs (Snapshots, Zähler, Übernahmen).
    /// @State-Bridge auf das Singleton, damit Observation-Tracking greift
    /// (Muster `windowStore`). internal, da +Subagents es nutzt.
    @State var jobRuntimeModel = AgentJobRuntimeModel.shared

    /// Etappe-0 Tab-Drag: gemessene Tab-Frames (Inhalts-Space) + aktueller
    /// Einfüge-Index während eines Drags (ephemer, nicht persistiert).
    @State private var tabFrames: [UUID: CGRect] = [:]
    /// Gepinnt-Sektion ein-/ausgeklappt (persistiert) — damit Pins nicht
    /// dauerhaft oben Platz belegen.
    @AppStorage("agentPinnedSectionCollapsed") private var pinnedSectionCollapsed = false
    /// Chats-Sektion (alle Projekt-Gruppen bzw. die flache Liste) ein-/
    /// ausgeklappt — Muster GEPINNT; eine aktive Suche überstimmt.
    @AppStorage("agentChatsSectionCollapsed") private var chatsSectionCollapsed = false
    /// Workspaces-Sektion ein-/ausgeklappt (persistiert, Muster GEPINNT).
    /// internal, da die Sektion in +Workspaces lebt.
    @AppStorage("agentWorkspacesSectionCollapsed") var workspacesSectionCollapsed = false
    /// Umbenennen-Sheet für Workspace-Gruppen (analog renameTargetID).
    @State var renameWorkspaceTargetID: UUID?
    @State var renameWorkspaceDraft = ""
    /// Löschen-Bestätigung für Workspace-Gruppen (analog projectPendingDeletion).
    @State var workspacePendingDeletion: AgentGridWorkspace?
    /// Tear-off: die Detach-Drop-Zone (Content) ist gerade Drop-Ziel.
    @State private var detachZoneTargeted = false
    /// Grid-Ansicht: Pane, über der die Maus gerade schwebt — Klick-Routing
    /// für den Fokus-Wechsel (Muster `isHoveringTabStrip`, kein Koordinaten-
    /// Hit-Test). internal, da Monitor (+Shortcuts) und +Grid es nutzen.
    @State var hoveredGridPaneID: UUID?
    /// Ein Session-Drag schwebt über dem Grid — steuert die Growzone
    /// („voll + Drop = wächst", Plan F8). internal für +Grid.
    @State var gridDropTargeted = false
    /// Anzahl gerade getargeteter Slot-Drop-Zonen: solange der Cursor über
    /// einer Pane hängt, erscheint KEINE Growzone (deren safeAreaInset
    /// würde die Slots unter dem Cursor wegschieben — Review-Finding).
    @State var gridSlotDropTargetCount = 0
    /// Aktuell gedrosselte Panes (F11) — Diff-Registry, damit entfernte/
    /// ersetzte Sessions und Workspace-Wechsel nie gedrosselt zurückbleiben.
    @State var throttledGridPaneIDs: Set<UUID> = []
    /// Ausstehende Verkleinerung (Kapazitäts-Picker): erst die Vorschau
    /// bestätigen, dann wird mit exakt dieser Eviction-Liste angewendet.
    @State var gridShrinkRequest: GridShrinkRequest?
    /// Gemessene Grid-Fläche — der Kapazitäts-Picker sitzt seit dem Umzug in
    /// die Header-Zeile außerhalb des Grids und braucht die Fläche weiterhin,
    /// um nicht passende Stufen auszublenden.
    @State var gridAreaSize: CGSize = .zero
    /// Stufe 2 der Subagent-Expansion in der WORKSPACE-Sektion (Fertige
    /// hinter der Welle-Zeile) — lokaler View-State wie das Pendant
    /// `finishedExpandedParentIDs` in `ProjectChatGroup`; Stufe 1 teilt sich
    /// beide Sektionen über `windowStore.expandedSubagentParentIDs`.
    @State var workspaceFinishedSubagentParentIDs: Set<UUID> = []
    /// Stufe 2 der Subagent-Expansion für GEPINNT + flache Listenansicht
    /// (ein Set reicht: `flatSessions` schließt gepinnte Rows aus, ein
    /// Parent erscheint also nie in beiden Sektionen gleichzeitig).
    @State var listFinishedSubagentParentIDs: Set<UUID> = []
    // Die Grid-Split-Verhältnisse leben seit Schema v4 am Workspace-Entity
    // (AgentGridWorkspace.columnFractions/rowFractions); die alten globalen
    // @AppStorage-Keys agentGridColumnFraction/agentGridRowFraction liest
    // nur noch die v3→v4-Migration (AgentSessionStore.loadUIState).
    /// internal, da der `leftMouseUp`-Monitor (in +Shortcuts) ihn zurücksetzt.
    @State var tabInsertionIndex: Int?

    /// Multi-Select pro Fenster — Bridge in den AgentWindowStore (ephemer, nicht
    /// persistiert), damit ein Cross-Window-Drop die Quell-Auswahl live sieht und
    /// danach leeren kann. internal, da Extensions (+Tabs/+BulkActions) es nutzen.
    var multiSelection: Set<UUID> {
        get { windowStore.multiSelection(in: windowID) }
        nonmutating set { windowStore.setMultiSelection(newValue, in: windowID) }
    }
    /// Mirror der `autoNamer.inFlight`-Set — wird via NotificationCenter
    /// aktualisiert, damit SwiftUI Re-Renders triggert. Wir koennen das nicht
    /// ueber @Observable machen weil autoNamer lazy-init in einem optionalen
    /// State lebt.
    @State private var autoRenamingSessionIDs: Set<UUID> = []
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
    /// Persistierter "Wunschwert" der Sidebar-Breite — global ueber alle
    /// Fenster (wie Scope/Layout), bewusst NICHT @SceneStorage: dessen
    /// Persistenz haengt an der macOS-State-Restoration, die wir mit
    /// `isRestorable = false` abgeschaltet haben. Angewendet wird nie der
    /// Rohwert, sondern `SidebarWidthResolver.effectiveWidth` gegen die
    /// aktuelle Fensterbreite — ein alter grosser Wert kann kleine Fenster
    /// daher nicht kaputt layouten.
    @AppStorage("agentSidebarWidth") private var storedSidebarWidth: Double = Double(SidebarWidthResolver.defaultWidth)
    /// Effektive Breite beim Drag-Beginn — Basis, auf die die kumulative
    /// Gesten-Translation addiert wird. `nil` ausserhalb eines Drags.
    @State private var sidebarDragBaseWidth: CGFloat?
    /// Live-Breite waehrend eines aktiven Handle-Drags (ephemer, nicht
    /// persistiert — Commit erst beim Loslassen in `commitSidebarDrag`).
    @State private var sidebarLiveWidth: CGFloat?
    /// IDs abgeschlossener Sessions, deren Transkript nicht mehr auf der Platte
    /// liegt („tote Zeiger"). Off-main berechnet (`refreshMissingTranscripts`),
    /// driftet die Sidebar zum Ausgrauen + Hinweis. Ephemeral, nicht persistiert.
    // internal, da die Workspace-Sektion (+Workspaces) die Rows ebenfalls
    // mit dem Missing-Transcript-Zustand rendert.
    @State var missingTranscriptIDs: Set<UUID> = []
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
    /// Ctrl+Tab-Switcher: pure Durchlauf-Maschine (nil = inaktiv). Ephemer und
    /// fensterlokal — bewusst `@State` statt AgentWindowStore: der Zustand lebt
    /// und stirbt mit einer einzigen Key-Interaktion in DIESEM Fenster.
    /// internal, da die Handler in +Shortcuts ihn steuern.
    @State var tabSwitcher: TabSwitcherModel?
    /// Spaltenzahl des gerade gerenderten Switcher-Grids — vom Overlay
    /// gemeldet (`onColumnsChange`), von `+Shortcuts` als ↑/↓-Schrittweite
    /// benutzt (eine Reihe = `tabSwitcherColumns` Schritte).
    @State var tabSwitcherColumns: Int = 1
    /// Lokaler `.flagsChanged`-Monitor: Loslassen von Control bei aktivem
    /// Switcher committet den hervorgehobenen Tab. `keyDown` sieht Modifier-
    /// Änderungen nicht — dafür braucht es diesen zweiten Monitor.
    @State var tabSwitcherFlagsMonitor: Any?
    /// Zustand der Zwei-Finger-Swipe-Erkennung (Tab links/rechts, Safari-
    /// Stil) — pure State-Machine über eine Gesten-Lebensdauer, gefüttert vom
    /// `scrollWheel`-Monitor (siehe `handleTabSwipeScroll` in +Shortcuts).
    /// Ephemer, fensterlokal.
    @State var tabScrollSwipeRecognizer = TabScrollSwipeRecognizer()
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
    /// Sessions, für die gerade der Archivieren-Bestätigungsdialog offen ist
    /// (nur gesetzt, wenn mindestens ein Terminal der Gruppe läuft).
    @State var sessionsPendingArchive: [AgentChatSession]?
    /// `true` solange die Sidebar den Archiv-Modus zeigt (Footer-Button) —
    /// gleiche Listen-UI, aber archivierte Chats mit „Wiederherstellen".
    @State var archiveModeActive = false
    /// Eigenes Suchfeld des Archiv-Modus (bewusst nicht `searchText`, damit
    /// der normale Sidebar-Filter nicht ins Archiv leakt und umgekehrt).
    @State var archiveSearchText = ""
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
    /// Popover des „Neuer Chat"-Split-Buttons (▾): Ziel-Projekt wählen/suchen.
    @State var showNewChatProjectPicker = false
    @State var newChatProjectQuery = ""
    /// Per Tastatur hervorgehobenes Ergebnis im „Neuer Chat"-Picker (aktive
    /// Auswahl). `nil` = kein Highlight (leere Ergebnisliste → `Enter` = No-op).
    @State var newChatHighlightedProjectID: UUID?
    /// Fokus des Suchfelds im „Neuer Chat"-Picker — für Autofokus beim Öffnen.
    @FocusState private var newChatSearchFocused: Bool
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

    /// Archivierte, manuell erstellte Sessions — geteilte Datengrundlage für
    /// Footer-Badge UND Archiv-Modus (sonst driftet der Tooltip-Count).
    /// BG-Sessions ohne Short-ID sind nicht wiederherstellbar (attach
    /// unmöglich) und werden ausgeblendet.
    var archivedSidebarSessions: [AgentChatSession] {
        workspace.sessions.filter {
            $0.status == .archived
                && $0.isManuallyCreated
                && !($0.isBackgroundChat && ($0.backgroundShortID?.isEmpty != false))
        }
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
                rootProcessID: terminalRegistry.controller(for: session.id)?.processID,
                kind: session.kind
            )
        }
    }

    var body: some View {
        let _ = PerfSignposts.sidebar.emitEvent("sidebar.bodyEval.chats")
        // GeometryReader liefert die Fensterbreite fuers Sidebar-Clamping —
        // er nimmt exakt die Flaeche ein, die vorher der HStack fuellte
        // (greedy), alle nachfolgenden Modifier verhalten sich unveraendert.
        GeometryReader { geo in
            HStack(spacing: 0) {
                if isSidebarVisible {
                    hashboardSidebar
                        .frame(width: currentSidebarWidth(windowWidth: geo.size.width))
                        .overlay(alignment: .trailing) {
                            SidebarResizeHandle(
                                onDragChanged: { translation in
                                    handleSidebarDrag(translation: translation, windowWidth: geo.size.width)
                                },
                                onDragEnded: commitSidebarDrag,
                                onDoubleClick: resetSidebarWidth,
                                // Fenster-Drag waehrend des Hovers aus — wie
                                // beim Tab-Strip (`isHoveringTabStrip`), sonst
                                // zieht ein Drag im Titelzonen-Band das Fenster.
                                onHoverChanged: { hovering in hostWindow?.isMovable = !hovering }
                            )
                            // Haelftig ueber den Content ragen (9pt-Zone, 4.5
                            // je Seite), ohne das Layout zu verschieben.
                            .offset(x: 4.5)
                        }
                        // Der Overlay-Ueberhang muss Hits VOR mainWorkspace
                        // bekommen — spaetere HStack-Geschwister laegen sonst
                        // im Hit-Test darueber.
                        .zIndex(1)
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
                    .frame(width: Self.inspectorPanelWidth)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Bewusst KEINE feste Mindestgröße mehr — der User soll das Fenster
        // so klein ziehen können, wie er will. Die einzige Untergrenze ist
        // jetzt der natürliche Platzbedarf des Inhalts (Sidebar/Inspector
        // lassen sich per Toggle ausblenden, um noch kleiner zu werden).
        .background(AgentTheme.background)
        .background(AgentChatsWindowAccessor(
            onResolve: { hostWindow = $0 },
            // User schliesst das Fenster (rotes X, Fenstermenue, ⌘W ohne
            // Tabs) → Fenster + Tabs aus dem Store, sonst stellt der
            // Launch-Restore es beim naechsten Start wieder her. Quit/
            // Profilwechsel sind via suspendCloseTracking ausgenommen.
            onWillClose: { windowStore.handleWindowWillClose(windowID) },
            // Dictation routet ausschliesslich ueber das Key-Fenster —
            // Selektionen in Nicht-Key-Fenstern aendern das Ziel nie
            // (Multi-Window-Politik, Plan-Abschnitt 03).
            onBecomeKey: {
                windowStore.windowDidBecomeKey(windowID)
                syncActiveAgentChat()
            },
            onResignKey: { windowStore.windowDidResignKey(windowID) }
        ))
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
        .sheet(isPresented: Binding(
            get: { renameWorkspaceTargetID != nil },
            set: { if !$0 { renameWorkspaceTargetID = nil } }
        )) {
            renameWorkspaceSheet
        }
        .confirmationDialog(
            "Workspace verkleinern?",
            isPresented: Binding(
                get: { gridShrinkRequest != nil },
                set: { if !$0 { gridShrinkRequest = nil } }
            ),
            presenting: gridShrinkRequest
        ) { request in
            Button("Verkleinern — \(request.evictedTitles.count) \(request.evictedTitles.count == 1 ? "Chat verlässt" : "Chats verlassen") den Workspace", role: .destructive) {
                commitGridShrink(request)
            }
            Button("Abbrechen", role: .cancel) {}
        } message: { request in
            Text("Es verlassen: \(request.evictedTitles.joined(separator: ", ")). Tabs und Prozesse bleiben erhalten — nur die Slots werden entfernt.")
        }
        // Benannte Ablehnungen (volles 3×3, blockierte Aktivierung,
        // PhpStorm-/Restore-Fehler) sichtbar machen — errorMessage hatte
        // zuvor keinen Leser (Review-Finding).
        .alert(
            "Hinweis",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .confirmationDialog(
            "Workspace löschen?",
            isPresented: Binding(
                get: { workspacePendingDeletion != nil },
                set: { if !$0 { workspacePendingDeletion = nil } }
            ),
            presenting: workspacePendingDeletion
        ) { entity in
            Button("Löschen: \(entity.name)", role: .destructive) {
                windowStore.deleteGridWorkspace(entity.id)
            }
            Button("Abbrechen", role: .cancel) {}
        } message: { entity in
            let count = entity.occupiedSessionIDs.count
            Text("Entfernt nur die Gruppe „\(entity.name)“ — ihre \(count) \(count == 1 ? "Chat bleibt" : "Chats bleiben") samt Tabs und laufenden Prozessen erhalten.")
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
        .confirmationDialog(
            "Chat archivieren?",
            isPresented: Binding(
                get: { sessionsPendingArchive != nil },
                set: { if !$0 { sessionsPendingArchive = nil } }
            ),
            presenting: sessionsPendingArchive
        ) { sessions in
            Button(sessions.count == 1 ? "Archivieren" : "\(sessions.count) Chats archivieren") {
                commitArchive(sessions)
                sessionsPendingArchive = nil
            }
            Button("Abbrechen", role: .cancel) {}
        } message: { sessions in
            let running = sessions.filter {
                terminalRegistry.controller(for: $0.id)?.isRunning == true
            }.count
            Text(sessions.count == 1
                ? "Der Chat läuft noch — beim Archivieren wird das Terminal beendet. Der Chat bleibt im Archiv erhalten und lässt sich wiederherstellen."
                : "\(running) von \(sessions.count) Chats laufen noch — beim Archivieren werden die Terminals beendet. Alle Chats bleiben im Archiv erhalten und lassen sich wiederherstellen.")
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
            installTabSwitcherFlagsMonitorIfNeeded()
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
            removeTabSwitcherFlagsMonitor()
            // Window zu → Routing nur räumen, wenn ES das Ziel besass: das
            // Verschwinden eines NICHT-besitzenden Fensters darf das
            // Dictation-Ziel des aktiv genutzten Fensters nicht löschen
            // (Multi-Window-Politik). Stale Refs auf Chats, die nirgends
            // mehr offen sind, werden ebenfalls geräumt.
            if windowStore.dictationWindowID == windowID {
                windowStore.windowDidCloseForDictation(windowID)
                AppState.shared.activeAgentChat = nil
            } else if let ref = AppState.shared.activeAgentChat,
                      windowStore.windowID(containingTab: ref.sessionID) == nil {
                AppState.shared.activeAgentChat = nil
            }
        }
        .onChange(of: selectedSessionID) { _, newValue in
            // Externe Selektion (Sidebar-Row, Tab-Klick, ⌘1–⌘9) mitten im
            // Ctrl+Tab-Durchlauf bricht den Switcher ab — sonst würde das
            // spätere Ctrl-Loslassen die frische Wahl wieder überstimmen.
            // Der eigene Commit räumt den Switcher VOR dem Selektieren
            // (siehe commitTabSwitcher) und ist hier deshalb ein No-op.
            if tabSwitcher != nil { tabSwitcher = nil }
            syncActiveAgentChat()
            // Kontext-Projekt folgt der Selektion — Tabs sind global, das
            // Projekt ist nur noch Ziel für „Neuer Chat" und den Inspector.
            // (Persistenz erledigt der Store automatisch bei jeder Mutation.)
            if let sessionID = newValue,
               let session = workspace.sessions.first(where: { $0.id == sessionID }) {
                selectedProjectID = session.projectID
            }
            // Subagent-Ergebnis gilt mit der Selektion als gelesen (No-op
            // für alles, was nicht als unread markiert ist).
            if let sessionID = newValue {
                windowStore.clearSubagentUnread(sessionID)
            }
            updateActiveBackgroundTrackerIfNeeded()
        }
        .onChange(of: selectedProjectID) { _, _ in
            syncActiveAgentChat()
        }
        .onChange(of: workspace) { _, _ in
            syncActiveAgentChat()
            // Globale GC gegen den frischen Workspace: tote Session-IDs auch
            // aus Fenstern raeumen, die gerade NICHT gerendert sind (per X
            // geschlossene Fenster haben keinen reconcileSelection-Lauf mehr).
            // Diff-gated — ohne effektive Aenderung kein Save/Re-Render.
            windowStore.prune(workspace: workspace)
            // P1 S6: Selektion darf nach Mutationen (z. B. deleteSession aus
            // dem Spawn-Fehlerpfad) nie auf Gelöschtes zeigen.
            reconcileSelection()
        }
        .onChange(of: openTabIDs) { _, _ in
            closeWindowIfEmptyAndSecondary()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { note in
            // Fenster verliert den Key-Status mitten im Ctrl+Tab-Durchlauf
            // (Cmd+Tab zu anderer App, Klick in anderes Fenster) → Abbruch.
            // Das Ctrl-Loslassen passiert dann außerhalb unseres Fensters und
            // der `.flagsChanged`-Monitor würde sonst nie committen — das
            // Overlay bliebe hängen.
            guard tabSwitcher != nil,
                  let window = note.object as? NSWindow,
                  window === hostWindow else { return }
            cancelTabSwitcher()
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
    ///
    /// Der Store-Eintrag kann hier bereits fehlen (Laufzeit-`prune` oder
    /// willClose-Removal haben ihn entfernt) — das leere NSWindow muss
    /// trotzdem zu. `removeWindowIfEmpty` ist dann ein No-op; der
    /// `isVisible`-Guard verhindert ein Doppel-Close, wenn wir aus dem
    /// willClose-Teardown heraus getriggert wurden (Fenster schliesst bereits).
    private func closeWindowIfEmptyAndSecondary() {
        guard windowID != windowStore.primaryWindowID,
              openTabIDs.isEmpty else { return }
        windowStore.removeWindowIfEmpty(windowID)
        DispatchQueue.main.async {
            guard let hostWindow, hostWindow.isVisible else { return }
            hostWindow.performClose(nil)
        }
    }

    // MARK: - Sidebar-Breite (Drag-Resize)

    /// Inspector-Anteil, der in die Sidebar-Obergrenze eingeht — nur wenn er
    /// gerade sichtbar ist.
    private var activeInspectorWidth: CGFloat {
        isInspectorVisible ? Self.inspectorPanelWidth : 0
    }

    /// Die zu layoutende Sidebar-Breite: waehrend eines Drags der Live-Wert,
    /// sonst der persistierte Wunschwert — beide immer frisch gegen die
    /// aktuelle Fensterbreite geclampt (Resize/Fullscreen/kleine Fenster
    /// brauchen so kein Event-Handling).
    private func currentSidebarWidth(windowWidth: CGFloat) -> CGFloat {
        if let live = sidebarLiveWidth { return live }
        return SidebarWidthResolver.effectiveWidth(
            stored: CGFloat(storedSidebarWidth),
            windowWidth: windowWidth,
            inspectorWidth: activeInspectorWidth
        )
    }

    /// Drag-Tick vom Handle: beim ersten Tick die Basis (aktuelle effektive
    /// Breite) einfrieren, dann Basis + kumulative Translation clampen.
    private func handleSidebarDrag(translation: CGFloat, windowWidth: CGFloat) {
        if sidebarDragBaseWidth == nil {
            sidebarDragBaseWidth = currentSidebarWidth(windowWidth: windowWidth)
        }
        guard let base = sidebarDragBaseWidth else { return }
        sidebarLiveWidth = SidebarWidthResolver.widthDuringDrag(
            startWidth: base,
            translation: translation,
            windowWidth: windowWidth,
            inspectorWidth: activeInspectorWidth
        )
    }

    /// Drag-Ende: den (bereits geclampten) Endwert EINMAL persistieren —
    /// kein Write pro Tick.
    private func commitSidebarDrag() {
        if let final = sidebarLiveWidth {
            storedSidebarWidth = Double(final)
        }
        sidebarDragBaseWidth = nil
        sidebarLiveWidth = nil
    }

    /// Doppelklick aufs Handle: zurueck auf die Standardbreite.
    private func resetSidebarWidth() {
        storedSidebarWidth = Double(SidebarWidthResolver.defaultWidth)
        sidebarDragBaseWidth = nil
        sidebarLiveWidth = nil
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
        // Key-Window-Routing: Das globale Dictation-Ziel besitzt das ZULETZT
        // key gewesene Agent-Fenster (`dictationWindowID` — bleibt beim
        // App-Wechsel gesetzt: der User diktiert oft per globalem Hotkey aus
        // einer anderen App in seinen letzten Chat). Andere Fenster dürfen
        // es NIE überschreiben — auch nicht, wenn gerade kein Agent-Fenster
        // key ist (Review-Finding: Hintergrund-Mutationen kaperten sonst
        // das Ziel).
        if let route = windowStore.dictationWindowID, route != windowID { return }
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

            if archiveModeActive {
                // Archiv-Modus: gleiche Listen-UI (Ordner + Rows), aber
                // archivierte Chats mit „Wiederherstellen" — ersetzt Befehle,
                // Scope-Bar und Chat-Liste; der Footer bleibt.
                archiveSidebarContent
            } else {

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
                // sind @Published und triggern den). Nur noch für den
                // Scope-Filter („Aktiv") — der Row-Status kommt vollständig
                // aus dem Status-Koordinator.
                // Subagent-Kinder: unter Parent-Rows gruppiert; laufende Jobs
                // halten ihre Parent-Row in jedem Scope sichtbar (sonst
                // verschwände ein arbeitender Subagent im „Aktiv"-Filter).
                let subagentChildren = AgentSidebarModelBuilder.subagentChildren(
                    workspaceSessions: workspace.sessions
                )
                let subagentChildIDs = Set(
                    subagentChildren.byParentLocalID.values.flatMap { $0 }.map(\.id)
                )
                // Variante-D-Mengen für den Kinder-Split: laufend = aktiv
                // (spawning/running) ∪ übernommen mit lebender PTY; fehl-
                // geschlagen = state == .failed.
                let workingSubagentIDs = jobRuntimeModel.activeSubagentSessionIDs
                    .union(jobRuntimeModel.snapshotsBySessionID
                        .filter { $0.value.state == .takenOver && terminalRegistry.activeSessionIDs.contains($0.key) }
                        .keys)
                let erroredSubagentIDs = Set(jobRuntimeModel.snapshotsBySessionID
                    .filter { $0.value.state == .failed }
                    .keys)
                let runningSessionIDs = terminalRegistry.activeSessionIDs
                    .union(jobRuntimeModel.runningCountByParentSessionID.filter { $0.value > 0 }.keys)
                    .union(jobRuntimeModel.activeSubagentSessionIDs)
                let scopeFilter = makeScopeFilter(
                    openTabIDs: openTabIDSet,
                    runningSessionIDs: runningSessionIDs
                )
                let sessionsByProject = AgentSidebarModelBuilder.sessionsByProject(
                    workspaceSessions: workspace.sessions,
                    pinnedSessionIDs: Set(pinnedSessionIDs),
                    scope: scopeFilter,
                    subagentChildIDs: subagentChildIDs
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
                    scope: scopeFilter,
                    subagentChildIDs: subagentChildIDs
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
                        pinnedSectionHeader(count: visiblePinned.count)
                        if !pinnedSectionCollapsed {
                            ForEach(visiblePinned) { session in
                                // Subagent-Kinder wie in der Chat-Liste: Split
                                // EINMAL pro Parent, Chip an der Row, Kinder
                                // über die geteilte Komponente darunter.
                                let children = subagentChildren.byParentLocalID[session.id] ?? []
                                let split = children.isEmpty ? nil : AgentSidebarModelBuilder.subagentChildSplit(
                                    children: children,
                                    erroredIDs: erroredSubagentIDs,
                                    workingIDs: workingSubagentIDs,
                                    unreadIDs: windowStore.unreadSubagentSessionIDs,
                                    selectedID: selectedSessionID
                                )
                                pinnedRow(session, order: visiblePinned.map(\.id), split: split)
                                if let split {
                                    subagentChildrenRows(
                                        parent: session,
                                        children: children,
                                        split: split,
                                        isFinishedExpanded: listFinishedSubagentParentIDs.contains(session.id),
                                        onToggleFinished: { toggleListFinishedSubagents(session.id) }
                                    )
                                }
                            }
                        }
                    }

                    // WORKSPACES: unter GEPINNT, über den Projekten —
                    // unsichtbar bei null Workspaces (siehe +Workspaces).
                    // Bekommt dieselben Subagent-Mengen wie die Chat-Liste,
                    // damit Workspace-Rows Chip + Kind-Zeilen zeigen.
                    workspacesSidebarSection(
                        subagentChildrenByParent: subagentChildren.byParentLocalID,
                        workingSubagentIDs: workingSubagentIDs,
                        erroredSubagentIDs: erroredSubagentIDs
                    )

                    // CHATS als klappbare Sektion (Muster GEPINNT). Eine
                    // aktive Suche überstimmt den Collapse — sonst wären
                    // Treffer unsichtbar.
                    let chatCount = sidebarLayout == .flat
                        ? flatSessions.count
                        : visibleProjects.reduce(0) { $0 + (sessionsByProject[$1.id]?.count ?? 0) }
                    let showChatList = !chatsSectionCollapsed || !trimmedQuery.isEmpty
                    if !chatListIsEmpty {
                        chatsSectionHeader(count: chatCount)
                    }

                    if showChatList, sidebarLayout == .flat {
                        ForEach(flatSessions) { session in
                            // Subagent-Kinder auch in der flachen Ansicht —
                            // `flatSessions` filtert sie aus der Hauptliste,
                            // gerendert werden sie unter ihrem Parent (sonst
                            // wären sie hier komplett unsichtbar).
                            let children = subagentChildren.byParentLocalID[session.id] ?? []
                            let split = children.isEmpty ? nil : AgentSidebarModelBuilder.subagentChildSplit(
                                children: children,
                                erroredIDs: erroredSubagentIDs,
                                workingIDs: workingSubagentIDs,
                                unreadIDs: windowStore.unreadSubagentSessionIDs,
                                selectedID: selectedSessionID
                            )
                            flatRow(session, order: flatSessions.map(\.id), split: split)
                            if let split {
                                subagentChildrenRows(
                                    parent: session,
                                    children: children,
                                    split: split,
                                    isFinishedExpanded: listFinishedSubagentParentIDs.contains(session.id),
                                    onToggleFinished: { toggleListFinishedSubagents(session.id) }
                                )
                            }
                        }
                    } else if showChatList {
                    ForEach(visibleProjects) { project in
                        ProjectChatGroup(
                            project: project,
                            sessions: sessionsByProject[project.id] ?? [],
                            isExpanded: expandedProjectIDs.contains(project.id) || !searchText.isEmpty,
                            selectedSessionID: selectedSessionID,
                            multiSelection: multiSelection,
                            openTabIDs: openTabIDSet,
                            onSelectProject: {
                                selectProject(project.id)
                            },
                            onToggleExpanded: {
                                toggleProject(project.id)
                            },
                            onSelectSession: { sessionID in
                                handleSidebarSessionClick(
                                    sessionID,
                                    project: project,
                                    orderedSessionIDs: (sessionsByProject[project.id] ?? []).map(\.id)
                                )
                            },
                            onNewChat: {
                                selectedProjectID = project.id
                                expandedProjectIDs.insert(project.id)
                                createDefaultSession()
                            },
                            onCloseSession: { archiveSelection(forID: $0.id) },
                            onRename: renameSession,
                            sessionMenu: { AnyView(sessionContextMenu($0, context: .sidebarRow)) },
                            subagentChildMenu: { AnyView(sessionContextMenu($0, context: .subagentChild)) },
                            statusStore: runtimeStatusStore,
                            autoRenamingSessionIDs: autoRenamingSessionIDs,
                            missingTranscriptSessionIDs: missingTranscriptIDs,
                            subagentChildrenByParent: subagentChildren.byParentLocalID,
                            workingSubagentSessionIDs: workingSubagentIDs,
                            erroredSubagentSessionIDs: erroredSubagentIDs,
                            unreadSubagentSessionIDs: windowStore.unreadSubagentSessionIDs,
                            expandedSubagentParentIDs: windowStore.expandedSubagentParentIDs,
                            onToggleSubagentChildren: { windowStore.toggleSubagentChildren($0) },
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
                // Mit angeschlossener Maus rendert macOS sonst einen 15 pt
                // breiten Legacy-Scroller mit hellem Track in die dunkle
                // Sidebar — Overlay-Stil erzwingen (Views/OverlayScrollers).
                .overlayScrollers()
            }
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

    /// Klappbarer „Chats"-Header (Chevron + Anzahl) — blendet die komplette
    /// Projekt-/Flachliste ein/aus (Muster Gepinnt-Header). Zustand via
    /// @AppStorage persistiert; die Suche überstimmt den Collapse.
    private func chatsSectionHeader(count: Int) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { chatsSectionCollapsed.toggle() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .rotationEffect(.degrees(chatsSectionCollapsed ? 0 : 90))
                Text("CHATS")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.6)
                if chatsSectionCollapsed {
                    Text("\(count)")
                        .font(.system(size: 9, weight: .bold).monospacedDigit())
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(AgentTheme.textTertiary)
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(chatsSectionCollapsed ? "Chats einblenden" : "Chats ausblenden")
        .accessibilityLabel(chatsSectionCollapsed ? "Chat-Liste einblenden" : "Chat-Liste ausblenden")
    }

    /// Klappbarer „Gepinnt"-Header (Chevron + Anzahl) — blendet die gepinnten
    /// Zeilen ein/aus, damit sie nicht dauerhaft oben Platz belegen. Zustand
    /// via @AppStorage persistiert.
    private func pinnedSectionHeader(count: Int) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { pinnedSectionCollapsed.toggle() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .rotationEffect(.degrees(pinnedSectionCollapsed ? 0 : 90))
                Image(systemName: "pin")
                    .font(.system(size: 8, weight: .bold))
                Text("GEPINNT")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.6)
                if pinnedSectionCollapsed {
                    Text("\(count)")
                        .font(.system(size: 9, weight: .bold).monospacedDigit())
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(AgentTheme.textTertiary)
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(pinnedSectionCollapsed ? "Gepinnte einblenden" : "Gepinnte ausblenden")
    }

    /// Zeile der Gepinnt-Sektion inkl. Kontextmenü (Loslösen, Umbenennen,
    /// Auto-Titel, Farbe, Archivieren). Gepinnte Chats sind projektübergreifend —
    /// das Repo-Badge stellt die Zuordnung her.
    @ViewBuilder
    private func pinnedRow(
        _ session: AgentChatSession,
        order: [UUID],
        split: SubagentChildSplit? = nil
    ) -> some View {
        PinnedSessionRow(
            session: session,
            project: workspace.projects.first { $0.id == session.projectID },
            isSelected: selectedSessionID == session.id,
            isMultiSelected: multiSelection.contains(session.id),
            statusStore: runtimeStatusStore,
            isMissingTranscript: missingTranscriptIDs.contains(session.id),
            runningChildCount: split?.workingCount ?? 0,
            erroredChildCount: split?.erroredCount ?? 0,
            unreadChildCount: split?.hiddenUnreadCount ?? 0,
            childCount: split?.totalCount ?? 0,
            isChildrenExpanded: windowStore.expandedSubagentParentIDs.contains(session.id),
            onToggleChildren: { windowStore.toggleSubagentChildren(session.id) },
            onSelect: {
                handleSidebarRowClick(session.id, order: order) {
                    selectedSessionID = session.id
                }
            },
            onClose: { requestArchive([session]) }
        )
        // Sidebar-Quelle für Grid-/Workspace-Drops (Add/Place-Semantik).
        .draggable(DraggableSession(
            sessionID: session.id,
            sourceProjectID: session.projectID,
            sourceWindowID: windowID
        ))
        .contextMenu {
            sessionContextMenu(session, context: .sidebarRow)
        }
    }

    /// Stufe-2-Toggle (Fertige hinter der Fußzeile) für GEPINNT + flache
    /// Liste — Pendant zu `toggleWorkspaceFinishedSubagents`.
    func toggleListFinishedSubagents(_ parentID: UUID) {
        if listFinishedSubagentParentIDs.contains(parentID) {
            listFinishedSubagentParentIDs.remove(parentID)
        } else {
            listFinishedSubagentParentIDs.insert(parentID)
        }
    }

    /// Zeile der flachen (ungruppierten) Ansicht: Repo-Badge + Titel + Status
    /// (`PinnedSessionRow` wiederverwendet, da projektübergreifend). Kontextmenü
    /// wie eine normale Chat-Zeile, nur „Anpinnen" statt „Loslösen".
    @ViewBuilder
    private func flatRow(
        _ session: AgentChatSession,
        order: [UUID],
        split: SubagentChildSplit? = nil
    ) -> some View {
        PinnedSessionRow(
            session: session,
            project: workspace.projects.first { $0.id == session.projectID },
            isSelected: selectedSessionID == session.id,
            isMultiSelected: multiSelection.contains(session.id),
            statusStore: runtimeStatusStore,
            isMissingTranscript: missingTranscriptIDs.contains(session.id),
            runningChildCount: split?.workingCount ?? 0,
            erroredChildCount: split?.erroredCount ?? 0,
            unreadChildCount: split?.hiddenUnreadCount ?? 0,
            childCount: split?.totalCount ?? 0,
            isChildrenExpanded: windowStore.expandedSubagentParentIDs.contains(session.id),
            onToggleChildren: { windowStore.toggleSubagentChildren(session.id) },
            onSelect: {
                handleSidebarRowClick(session.id, order: order) {
                    selectedProjectID = session.projectID
                    selectedSessionID = session.id
                }
            },
            onClose: { requestArchive([session]) }
        )
        // Sidebar-Quelle für Grid-/Workspace-Drops (Add/Place-Semantik).
        .draggable(DraggableSession(
            sessionID: session.id,
            sourceProjectID: session.projectID,
            sourceWindowID: windowID
        ))
        .contextMenu {
            sessionContextMenu(session, context: .sidebarRow)
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
        // Kein eigenes horizontales Padding links: `SidebarRowButtonStyle`
        // bringt die 8 pt Außenkante bereits mit — das frühere Doppel-Padding
        // (8 außen + 8 Style + 10 innen) schob die Settings-Pill 8–10 pt
        // rechts vom Raster der oberen Sidebar-Elemente (Projekt-Header und
        // Filter-Feld starten bei 8 pt, Inhalt bei 16–17 pt).
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
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(SidebarRowButtonStyle())
            .help("Einstellungen öffnen")

            SidebarUpdateBadge()

            Button {
                if archiveModeActive {
                    exitArchiveMode()
                } else {
                    archiveModeActive = true
                }
            } label: {
                Image(systemName: archiveModeActive ? "archivebox.fill" : "archivebox")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(archiveModeActive ? AgentTheme.accent : AgentTheme.textSecondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(archiveModeActive ? "Archiv verlassen" : "Archiv (\(archivedSidebarSessions.count))")

            // Usage-Limits der verbundenen Claude-/ChatGPT-Accounts
            SidebarUsageButtons()

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
        .padding(.trailing, 8)
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
                // Dezenter Keycap-Hinweis: ⌘N öffnet den durchsuchbaren Picker.
                // Als Trailing-Overlay, damit „Neuer Chat" zentriert bleibt.
                .overlay(alignment: .trailing) {
                    Text("⌘N")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(AgentTheme.textTertiary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1.5)
                        .background(AgentTheme.hover, in: RoundedRectangle(cornerRadius: 4))
                        .opacity(selectedProject == nil ? 0.5 : 1)
                        .padding(.trailing, 8)
                        .allowsHitTesting(false)
                }
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
            .help("Projekt für neuen Chat wählen oder hinzufügen (⌘N)")
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
        let projectIDs = projects.map(\.id)
        return VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(AgentTheme.textTertiary)
                TextField("Projekt suchen…", text: $newChatProjectQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($newChatSearchFocused)
                    .accessibilityLabel("Projekt suchen")
                    .onSubmit { confirmHighlightedNewChatProject(projects) }
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
                            .background(project.id == newChatHighlightedProjectID ? AgentTheme.hover : Color.clear)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PopoverRowButtonStyle())
                        .accessibilityAddTraits(project.id == newChatHighlightedProjectID ? .isSelected : [])
                        .onHover { if $0 { newChatHighlightedProjectID = project.id } }
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
        // Pfeiltasten bubblen aus dem fokussierten (einzeiligen) Suchfeld hoch:
        // Up/Down navigieren die Ergebnisse, Left/Right bleiben Cursor im Feld.
        .onKeyPress(.downArrow) {
            newChatHighlightedProjectID = ProjectPickerKeyboard.move(from: newChatHighlightedProjectID, in: projectIDs, direction: 1)
            return .handled
        }
        .onKeyPress(.upArrow) {
            newChatHighlightedProjectID = ProjectPickerKeyboard.move(from: newChatHighlightedProjectID, in: projectIDs, direction: -1)
            return .handled
        }
        .onKeyPress(.escape) {
            showNewChatProjectPicker = false
            return .handled
        }
        // Filterwechsel: Highlight auf gültige Auswahl bzw. erstes Ergebnis setzen.
        .onChange(of: newChatProjectQuery) {
            newChatHighlightedProjectID = ProjectPickerKeyboard.normalize(newChatHighlightedProjectID, in: projectIDs)
        }
        .onAppear {
            newChatSearchFocused = true
            newChatHighlightedProjectID = projectIDs.first
        }
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

            if isGridActive {
                // Split-Grid: alle offenen Tabs als bündige Panes — ersetzt
                // nur den Detail-Bereich; Sidebar/Tab-Strip bleiben
                // unverändert. Siehe AgentChatsView+Grid.swift.
                gridWorkspace
                    // Ctrl+Tab-Switcher auch im Grid: der keyDown-Monitor
                    // aktiviert ihn layoutunabhängig — ohne Overlay wäre er
                    // unsichtbar und würde trotzdem alle Tasten konsumieren.
                    .overlay {
                        if tabSwitcher != nil { tabSwitcherOverlay }
                    }
                    .animation(.easeOut(duration: 0.1), value: tabSwitcher != nil)
            } else if let selectedSession, let project = selectedSessionProject {
                // Detail-Pfad (Subagent-Job vs. PTY) geteilt mit den
                // Grid-Panes — siehe sessionDetailContent in +Grid.
                sessionDetailContent(for: selectedSession, project: project)
                .id(selectedSession.id)
                .padding(.top, 14)
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
                .background(AgentTheme.background)
                // Tear-off: Tab/Gruppe in den Content ziehen → neues Fenster.
                // Eigene Drop-Zone (nur Content, NICHT der Strip → kein Konflikt
                // mit Reorder), zuverlässig über das Drop-System + Indikator.
                .dropDestination(for: DraggableSession.self) { items, _ in
                    guard let dropped = items.first else { return false }
                    detachDroppedToNewWindow(dropped)
                    return true
                } isTargeted: { detachZoneTargeted = $0 }
                .overlay {
                    if detachZoneTargeted { detachDropBanner }
                }
                .animation(.easeOut(duration: 0.12), value: detachZoneTargeted)
                // Ctrl+Tab-Switcher: liegt bewusst NUR über dem Terminal-
                // Content — Sidebar und Tab-Strip bleiben sichtbar/bedienbar.
                .overlay {
                    if tabSwitcher != nil { tabSwitcherOverlay }
                }
                .animation(.easeOut(duration: 0.1), value: tabSwitcher != nil)
            } else {
                ContentUnavailableView("Kein Agent Chat", systemImage: "terminal")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(AgentTheme.background)
    }

    /// Ctrl+Tab-Switcher-Overlay über dem Terminal-Content. Die Tastatur-
    /// Steuerung (Tab/Shift+Tab/Esc/Return, Ctrl-Release-Commit) läuft über
    /// die Monitore in +Shortcuts — hier nur Rendering + Maus-Callbacks.
    @ViewBuilder
    private var tabSwitcherOverlay: some View {
        if let tabSwitcher {
            AgentTabSwitcherOverlay(
                sessions: headerTabs,
                highlightedID: tabSwitcher.highlightedID,
                projectsByID: Dictionary(
                    workspace.projects.map { ($0.id, $0) },
                    uniquingKeysWith: { a, _ in a }
                ),
                statusStore: runtimeStatusStore,
                onCommit: { commitTabSwitcher(to: $0) },
                onCancel: { cancelTabSwitcher() },
                onColumnsChange: { tabSwitcherColumns = $0 }
            )
        }
    }

    /// Banner-Indikator, der während eines Tab-Drags über dem Content erscheint
    /// („Loslassen → neues Fenster").
    private var detachDropBanner: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(AgentTheme.accent.opacity(0.12))
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(AgentTheme.accent.opacity(0.7), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            Label("Loslassen für neues Fenster", systemImage: "macwindow.badge.plus")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AgentTheme.accent)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(AgentTheme.background, in: Capsule())
                .overlay(Capsule().strokeBorder(AgentTheme.border, lineWidth: 1))
        }
        .padding(14)
        .allowsHitTesting(false)
        .transition(.opacity)
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
                            HStack(spacing: 4) {
                                ForEach(headerTabs) { session in
                                    ChatTabButton(
                                        session: session,
                                        project: workspace.projects.first { $0.id == session.projectID },
                                        isSelected: session.id == selectedSession?.id,
                                        isMultiSelected: multiSelection.contains(session.id),
                                        statusStore: runtimeStatusStore,
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
                                        TabDragPreview(
                                            title: session.title,
                                            extraCount: max(0, tabDragGroup(for: session).count - 1)
                                        )
                                    }
                                    .contextMenu {
                                        sessionContextMenu(session, context: .tab)
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
                            .onChange(of: headerTabs.map(\.id)) { _, _ in
                                // Gegen ALLE Sessions prunen (nicht nur offene Tabs) — die
                                // Multi-Auswahl gilt auch für Sidebar-Sessions ohne offenen Tab.
                                multiSelection.formIntersection(Set(workspace.sessions.map(\.id)))
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
                                    let source = dropped.sourceWindowID ?? windowID
                                    // Gruppe aus der LIVE-Auswahl des QUELL-Fensters (robust, ohne
                                    // Payload-Round-Trip) — fixt cross-window.
                                    let sourceSel = windowStore.multiSelection(in: source)
                                    let group = (sourceSel.count > 1 && sourceSel.contains(dropped.sessionID))
                                        ? windowStore.openTabIDs(in: source).filter { sourceSel.contains($0) }
                                        : [dropped.sessionID]
                                    if source == windowID {
                                        // Same-window: Gruppe als Block reordern bzw. Einzel.
                                        if group.count > 1 {
                                            let newOrder = TabGroupReorder.newOrder(openTabIDs, moving: Set(group), before: beforeID)
                                            windowStore.setOpenTabIDs(newOrder, in: windowID)
                                        } else if let beforeID {
                                            dropTab(dropped, before: beforeID)
                                        } else {
                                            dropTabAtEnd(dropped)
                                        }
                                    } else {
                                        // Cross-window: ganze Gruppe (Reihenfolge erhalten) hierher holen.
                                        for id in group {
                                            windowStore.moveTab(id, from: source, to: windowID, before: beforeID)
                                        }
                                        windowStore.setMultiSelection([], in: source)  // Quell-Auswahl aufräumen
                                    }
                                    // Einzel-Drag (kein Gruppen-Tab) verwirft die Auswahl (Chrome/Finder).
                                    if group.count <= 1 { multiSelection = [] }
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
                    // Kein Agent: normale Login-Shell im Projektverzeichnis.
                    // Der Provider ist nur Schema-Platzhalter (siehe
                    // AgentSessionKind.terminal).
                    Button("Neues Terminal") { createSession(provider: .claude, kind: .terminal) }
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

            // Im sichtbaren Grid ersetzt die Workspace-Zeile (Name + Belegung
            // + Kapazitäts-Picker) den Chat-Header — die Pane-Header tragen
            // die Session-Infos bereits, und der Picker verdeckt so keine
            // Pane mehr (vorher Overlay über der rechten oberen Pane).
            if isGridActive, let entity = activeGridWorkspaceEntity {
                gridWorkspaceStatusRow(entity: entity)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
            } else {
                activeChatStatusRow
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
            }
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

                // Zurück ins Grid: stellt den referenzierten Workspace exakt
                // wieder her (Gegenstück zum ⤢ im Pane-Header).
                returnToWorkspaceButton
            }
            .fixedSize()
        }
    }

    // `internal` statt `private`: auch die Grid-Pane-Header (+Grid,
    // Repo-öffnen-Button) nutzen Ziel + Öffnen-Aktion.
    var projectOpenTarget: ProjectOpenTarget {
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
    /// orange bei Needs-Input (Status-Koordinator), grau wenn keine Session da.
    @ViewBuilder
    private var statusDot: some View {
        if let selectedSession {
            SessionLiveStatusDot(
                sessionID: selectedSession.id,
                isProcessRunning: terminalRegistry.controller(for: selectedSession.id)?.isRunning == true,
                statusStore: runtimeStatusStore
            )
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
                } else if selectedSession.isTerminal {
                    kindBadge("TERM", color: .teal)
                        .help("Normales Terminal · Login-Shell im Projektverzeichnis, kein Agent")
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
                sessionContextMenu(session, context: .headerMenu)
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
    // `internal`: wird vom vereinheitlichten Kontextmenü (+SessionMenus) gerufen.
    func forceAutoNameSession(_ session: AgentChatSession) {
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

    // Das Session-Kontextmenü (früher `sessionManagementMenu` +
    // `backgroundLifecycleMenuItems` hier) lebt jetzt vereinheitlicht in
    // AgentChatsView+SessionMenus.swift (`sessionContextMenu(_:context:)`).

    // `internal` statt `private`: auch die Workspace-Sektion (+Workspaces,
    // Subagent-Kind-Kontextmenü) startet das Umbenennen.
    func beginRename(_ session: AgentChatSession) {
        renameTargetID = session.id
        renameDraft = session.title
    }

    /// Wird vom Inspector-Button („PHPStorm öffnen") genutzt.
    private func openSelectedProjectInPHPStorm() {
        guard let selectedProject else { return }
        openProject(selectedProject, in: .phpStorm)
    }

    /// Öffnet das Projektverzeichnis im gewählten Ziel. `internal` statt
    /// `private`: auch die Grid-Pane-Header (+Grid) öffnen darüber.
    func openProject(_ project: AgentProject, in target: ProjectOpenTarget) {
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
