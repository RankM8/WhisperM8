import AppKit
import SwiftUI

// MARK: - Was die Ticket-Ansicht von der App braucht

/// Zuordnung und Zugang eines Projektordners.
enum TicketBoardResolution: Equatable {
    /// Der Ordner gehört zu keinem Team, oder das Team zu keinem Workspace.
    case notMapped
    case noKey(workspace: String)
    case ready(team: String, workspace: String, projectPath: String)
}

/// Alles von außen als Closures: Tests und Snapshots ersetzen Datei,
/// Schlüsselbund, Netz und die Chats der App.
struct TicketBoardEnvironment {
    /// Liest Zuordnung und Schlüsselbund. Läuft abseits des Main Threads.
    var resolve: @Sendable (_ projectPath: String) async -> TicketBoardResolution
    var makeStore: @MainActor (_ workspace: String) -> TicketBoardStore
    /// Chats dieser Installation, ohne Zustand (den liefern die Status-Punkte).
    var chats: @MainActor () -> [TicketChat]

    @MainActor static let live = TicketBoardEnvironment(
        resolve: { projectPath in
            await TicketBlockingWork.run {
                let config = TicketConfigStore.live.load()
                guard let team = config.team(forDirectory: projectPath),
                      let root = config.projectPath(forDirectory: projectPath),
                      let workspace = config.workspace(forTeam: team) else { return .notMapped }
                let hasKey = TicketCredentialCache.shared.value(for: workspace) { TicketCredentialStore.live.read(workspace) } != nil
                return hasKey ? .ready(team: team, workspace: workspace, projectPath: root) : .noKey(workspace: workspace)
            }
        },
        makeStore: { workspace in TicketBoardStore(source: LinearTicketSource(client: .live(workspace: workspace))) },
        chats: {
            let workspace = AgentWorkspaceUIModel.shared.workspace
            let projects = Dictionary(workspace.projects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            return workspace.sessions.compactMap { session in
                guard session.status != .archived, let project = projects[session.projectID] else { return nil }
                return TicketChat(
                    id: session.id, title: session.title, projectName: project.name,
                    projectPath: TicketConfig.normalized(project.path), state: nil,
                    isRunning: AgentTerminalRegistry.shared.controller(for: session.id)?.isRunning == true)
            }
        }
    )
}

// MARK: - Ablauf

/// Was die Ansicht gerade zeigt.
enum TicketBoardPhase: Equatable {
    case noProject
    case notMapped
    case noKey(workspace: String)
    case loading
    /// Der erste Abruf ist gescheitert; es gibt noch keinen Stand zum Zeigen.
    case unreachable(String)
    case ready
}

/// Verbindet die Ansicht mit Zuordnung, Abruf und den Chats der App. Liest
/// nur: Es gibt hier keinen Aufruf, der im Ticket-Werkzeug etwas ändert.
///
/// Abgerufen wird nur, solange die Ansicht sichtbar ist (`show`/`hide`). Der
/// Abgleich „wer sitzt woran“ läuft abseits des Main Threads.
@MainActor
@Observable
final class TicketBoardController {
    private(set) var phase: TicketBoardPhase = .noProject
    private(set) var title = ""
    let viewModel = TicketBoardViewModel()
    let load = TicketBoardLoad()

    @ObservationIgnored private let environment: TicketBoardEnvironment
    @ObservationIgnored private var stores: [String: TicketBoardStore] = [:]
    @ObservationIgnored private var active: (store: TicketBoardStore, team: String, projectPath: String)?
    @ObservationIgnored private var shownProject: String?
    /// Zählt Wechsel von Projekt und Sichtbarkeit; eine überholte Auflösung
    /// der Zuordnung trägt nichts ein.
    @ObservationIgnored private var generation = 0
    /// Für welchen Abzug zuletzt abgeglichen wurde.
    @ObservationIgnored private var builtFor: Date?
    /// Nur der zuletzt begonnene Abgleich trägt sein Ergebnis ein. Verdecken
    /// zählt hier nicht: Ein Abgleich, der dabei noch läuft, soll ankommen.
    @ObservationIgnored private var buildSequence = 0
    /// Steht im `viewModel` schon ein Abgleich dieses Projekts?
    @ObservationIgnored private var hasModel = false
    @ObservationIgnored private var isVisible = false

    init(environment: TicketBoardEnvironment) {
        self.environment = environment
    }

    /// Die Ansicht ist sichtbar, oder das Projekt hat gewechselt.
    func show(projectPath: String?, projectName: String) async {
        generation += 1
        let generation = generation
        isVisible = true
        title = projectName
        guard let projectPath else {
            leaveProject()
            shownProject = nil
            phase = .noProject
            return
        }
        if shownProject != projectPath {
            // Filter, Auswahl und Stand gehören zum alten Projekt.
            leaveProject()
            shownProject = projectPath
            phase = .loading
        }
        let resolution = await environment.resolve(projectPath)
        guard generation == self.generation else { return }
        switch resolution {
        case .notMapped:
            leaveProject()
            phase = .notMapped
        case .noKey(let workspace):
            leaveProject()
            phase = .noKey(workspace: workspace)
        case .ready(let team, let workspace, let root):
            let store = stores[workspace] ?? environment.makeStore(workspace)
            stores[workspace] = store
            if let active, active.store !== store || active.team != team || active.projectPath != root {
                // Anderer Workspace, anderes Team oder andere Wurzel: Der Stand gehört nicht hierher.
                leaveProject()
                phase = .loading
            }
            active = (store, team, root)
            store.onChange = { [weak self, weak store] in
                guard let self, let store else { return }
                self.storeChanged(store)
            }
            store.activate(team: team)
            storeChanged(store)
        }
    }

    /// Verdeckt, andere Ansicht oder Schalter aus: kein Abruf mehr. Der letzte
    /// Stand bleibt für das nächste Zeigen stehen.
    func hide() {
        generation += 1
        isVisible = false
        active?.store.deactivate()
    }

    func refresh() {
        guard isVisible, let store = active?.store else { return }
        Task { await store.refresh() }
    }

    private func leaveProject() {
        active?.store.deactivate()
        active = nil
        builtFor = nil
        buildSequence += 1
        hasModel = false
        viewModel.reset()
        load.reset()
    }

    private func storeChanged(_ store: TicketBoardStore) {
        guard let active, active.store === store, store.team == active.team else { return }
        if load.isLoading != store.isLoading { load.isLoading = store.isLoading }
        let problem = store.lastError?.userText
        if load.problem != problem { load.problem = problem }
        guard let snapshot = store.snapshot else {
            phase = store.lastError.map { .unreachable($0.userText) } ?? .loading
            return
        }
        if load.fetchedAt != snapshot.fetchedAt { load.fetchedAt = snapshot.fetchedAt }
        if hasModel, phase != .ready { phase = .ready }
        guard builtFor != snapshot.fetchedAt else { return }
        builtFor = snapshot.fetchedAt
        // Die Liste der Chats wird mit jedem Abzug neu gelesen (alle 30 Sekunden);
        // ihren Zustand liefern die Status-Punkte selbst, ohne Abgleich.
        let chats = environment.chats()
        let projectPath = active.projectPath
        buildSequence += 1
        let sequence = buildSequence
        Task { [weak self] in
            // Abgleich abseits des Main Threads: bis zu 500 Tickets gegen alle Chats.
            let model = await Task.detached(priority: .userInitiated) {
                PerfBudgets.ticketsBuild.withInterval {
                    TicketBoardBuilder.build(snapshot: snapshot, chats: chats, projectPath: projectPath)
                }
            }.value
            guard let self, sequence == self.buildSequence else { return }
            self.viewModel.update(model)
            self.hasModel = true
            if self.phase != .ready { self.phase = .ready }
        }
    }
}

// MARK: - Ansicht

/// Die Ticket-Ansicht samt ihren Leerzuständen, so wie sie im Agent-Chats-
/// Fenster steht. Ruft nur ab, solange sie sichtbar und der Schalter an ist.
struct TicketBoardScreen: View {
    /// Projekt, dessen Tickets gezeigt werden; `nil` ohne gewähltes Projekt.
    let projectPath: String?
    let projectName: String
    /// Der Schalter ging aus, während die Ansicht offen war: Das Fenster
    /// kehrt zu den Chats zurück.
    var onDisabled: (() -> Void)?
    /// Entsteht erst beim Erscheinen: Das Fenster baut diese Ansicht bei jeder
    /// Neuauswertung neu zusammen, und dabei soll nichts angelegt werden.
    @State private var controller: TicketBoardController?
    @State private var windowVisible = true
    /// Zählt, wie oft das Fenster aktiv wurde: Danach wird die Zuordnung neu
    /// gelesen, etwa nach dem Einrichten in den Einstellungen.
    @State private var windowActivations = 0
    @AppStorage(PreferenceKeys.ticketBoardEnabled) private var enabled = false

    /// Ohne Angaben gelten die Wege der App; Tests und Bilder setzen eigene ein.
    var environment: TicketBoardEnvironment?
    var source: TicketChatStatusSource?
    var actions: TicketBoardActions?

    var body: some View {
        Group {
            if !enabled {
                TicketBoardEmptyState(kind: .disabled, actions: screenActions)
            } else if let controller {
                switch controller.phase {
                case .ready:
                    TicketBoardView(title: String(localized: "Tickets · \(controller.title)"), model: controller.viewModel,
                                    load: controller.load, source: source ?? .live, actions: screenActions)
                case .noProject:
                    TicketBoardEmptyState(kind: .noProject, actions: screenActions)
                case .notMapped:
                    TicketBoardEmptyState(kind: .notMapped(project: controller.title), actions: screenActions)
                case .noKey(let workspace):
                    TicketBoardEmptyState(kind: .noKey(workspace: workspace), actions: screenActions)
                case .loading:
                    TicketBoardEmptyState(kind: .loading, actions: screenActions)
                case .unreachable(let problem):
                    TicketBoardEmptyState(kind: .unreachable(problem), actions: screenActions)
                }
            } else {
                TicketBoardEmptyState(kind: .loading, actions: screenActions)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AgentTheme.background)
        .background(TicketBoardWindowVisibility(isVisible: $windowVisible, activations: $windowActivations))
        // Ein Schlüssel für alles, was den Abruf an- oder abschaltet.
        .task(id: Activation(enabled: enabled, visible: windowVisible, project: projectPath, activations: windowActivations)) {
            if enabled, windowVisible {
                let controller = controller ?? TicketBoardController(environment: environment ?? .live)
                if self.controller == nil { self.controller = controller }
                await controller.show(projectPath: projectPath, projectName: projectName)
            } else {
                controller?.hide()
                if !enabled { onDisabled?() }
            }
        }
        .onDisappear { controller?.hide() }
    }

    private struct Activation: Equatable {
        var enabled: Bool
        var visible: Bool
        var project: String?
        var activations: Int
    }

    private var screenActions: TicketBoardActions {
        var actions = actions ?? .live
        actions.refresh = { [controller] in controller?.refresh() }
        return actions
    }
}

extension TicketBoardActions {
    /// Wege der App: Chat in den Vordergrund, Adresse im Browser, Einstellungen.
    @MainActor static let live = TicketBoardActions(
        refresh: {},
        openChat: { WindowRequestCenter.shared.requestSessionFocus(sessionID: $0) },
        openURL: { NSWorkspace.shared.open($0) },
        openSettings: { WindowRequestCenter.shared.requestSettings(routeID: SettingsPage.tickets.rawValue) }
    )
}

// MARK: - Leerzustände

struct TicketBoardEmptyState: View {
    enum Kind: Equatable {
        case disabled
        case noProject
        case notMapped(project: String)
        case noKey(workspace: String)
        case loading
        case unreachable(String)
    }

    let kind: Kind
    let actions: TicketBoardActions

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(AgentTheme.textTertiary)
            title
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AgentTheme.textPrimary)
            detail
                .font(.system(size: 12))
                .foregroundStyle(AgentTheme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            button
                .padding(.top, 4)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var symbol: String {
        switch kind {
        case .disabled: return "ticket"
        case .noProject: return "folder"
        case .notMapped: return "link"
        case .noKey: return "key"
        case .loading: return "arrow.clockwise"
        case .unreachable: return "exclamationmark.triangle"
        }
    }

    @ViewBuilder
    private var title: some View {
        switch kind {
        case .disabled: Text("Tickets are turned off")
        case .noProject: Text("Choose a project")
        case .notMapped: Text("This project is not linked to a team")
        case .noKey: Text("No Linear key for this workspace")
        case .loading: Text("Loading tickets…")
        case .unreachable: Text("Tickets could not be loaded")
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch kind {
        case .disabled:
            Text("Turn on “Show tickets in Agent Chats” in Settings › Tickets. Until then WhisperM8 reads nothing from Linear.")
        case .noProject:
            Text("Tickets are shown per project. Select a chat or a project in the sidebar.")
        case .notMapped(let project):
            Text("Link the folder of \(project) to a team in Settings › Tickets.")
        case .noKey(let workspace):
            Text("Save a key for linear.app/\(workspace) in Settings › Tickets.")
        case .loading:
            Text("Fetching the board from Linear.")
        case .unreachable(let problem):
            Text(verbatim: problem)
        }
    }

    @ViewBuilder
    private var button: some View {
        switch kind {
        case .disabled, .notMapped, .noKey:
            Button("Open Ticket Settings") { actions.openSettings() }
                .buttonStyle(SettingsButtonStyle.primary)
        case .unreachable:
            Button("Try Again") { actions.refresh() }
                .buttonStyle(SettingsButtonStyle.primary)
        case .noProject, .loading:
            EmptyView()
        }
    }
}

// MARK: - Sichtbarkeit des Fensters

/// Meldet, ob das Fenster der Ansicht sichtbar ist. Verdeckt oder
/// minimiert heißt: kein Abruf.
private struct TicketBoardWindowVisibility: NSViewRepresentable {
    @Binding var isVisible: Bool
    @Binding var activations: Int

    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        probe.onChange = { visible in
            if isVisible != visible { isVisible = visible }
        }
        probe.onActivate = { activations += 1 }
        return probe
    }

    func updateNSView(_ nsView: Probe, context: Context) {}

    final class Probe: NSView {
        var onChange: ((Bool) -> Void)?
        var onActivate: (() -> Void)?
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            observers.append(NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.report() }
            })
            observers.append(NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.onActivate?() }
            })
            report()
        }

        private func report() {
            onChange?(window?.occlusionState.contains(.visible) ?? false)
        }

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }
    }
}
