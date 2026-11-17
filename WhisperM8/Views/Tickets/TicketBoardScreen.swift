import AppKit
import SwiftUI

// MARK: - Was die Ticket-Ansicht von der App braucht

/// Zuordnung und Zugang eines Projektordners.
enum TicketBoardResolution: Equatable {
    /// Der Ordner gehört zu keinem Team, oder das Team zu keinem Workspace.
    case notMapped
    case noKey(workspace: String)
    /// `rule`: was die Status des Teams bedeuten (aus `tickets.json`).
    case ready(team: String, workspace: String, projectPath: String, rule: TicketTeamRule = TicketTeamRule())
}

/// Alles von außen als Closures: Tests und Snapshots ersetzen Datei,
/// Schlüsselbund, Netz und die Chats der App.
struct TicketBoardEnvironment {
    /// Liest Zuordnung und Schlüsselbund. Läuft abseits des Main Threads.
    var resolve: @Sendable (_ projectPath: String) async -> TicketBoardResolution
    var makeStore: @MainActor (_ workspace: String) -> TicketBoardStore
    /// Chats dieser Installation, ohne Zustand (den liefern die Status-Punkte).
    var chats: @MainActor () -> [TicketChat]
    /// Meldet sich einmal, sobald sich an den Chats etwas geändert haben
    /// kann. Danach meldet sich die Ansicht neu an.
    var whenChatsChange: @MainActor (_ notify: @escaping @MainActor () -> Void) -> Void = { _ in }
    /// Ruhezeit, bevor eine Änderung an den Chats abgeglichen wird: Der
    /// Workspace ändert sich in Schüben.
    var chatsSettle: @Sendable () async -> Void = { try? await Task.sleep(for: .seconds(2)) }
    /// Ruhe, bevor die Kommentare eines geöffneten Tickets geholt werden: Wer
    /// mit J/K durch zehn Tickets blättert, löst eine Anfrage aus, nicht zehn.
    var commentsSettle: @Sendable () async -> Void = { try? await Task.sleep(for: .milliseconds(300)) }
    /// Wie der Text der Triage gebaut wird; Bilder und Tests bauen sofort.
    var documents: TicketDocumentBuilding = .background

    @MainActor static let live = TicketBoardEnvironment(
        resolve: { projectPath in
            await TicketBlockingWork.run {
                let config = TicketConfigStore.live.load()
                guard let team = config.team(forDirectory: projectPath),
                      let root = config.projectPath(forDirectory: projectPath),
                      let workspace = config.workspace(forTeam: team) else { return .notMapped }
                let hasKey = TicketCredentialCache.shared.value(for: workspace) { TicketCredentialStore.live.read(workspace) } != nil
                return hasKey
                    ? .ready(team: team, workspace: workspace, projectPath: root, rule: config.rule(forTeam: team))
                    : .noKey(workspace: workspace)
            }
        },
        makeStore: { workspace in TicketBoardStore(source: LinearTicketSource(client: .live(workspace: workspace))) },
        chats: {
            let workspace = AgentWorkspaceUIModel.shared.workspace
            // Name und Pfad je Projekt einmal, nicht je Sitzung.
            let projects = Dictionary(
                workspace.projects.map { ($0.id, (name: $0.name, path: TicketConfig.normalized($0.path))) },
                uniquingKeysWith: { first, _ in first })
            // Arbeitsordner neben dem Projekt zählen zum Haupt-Projekt (WM8-102).
            let parents = AgentWorkspaceUIModel.shared.projectParents
            return workspace.sessions.compactMap { session in
                guard session.status != .archived,
                      let project = projects[AgentProjectDisplay.displayProjectID(session.projectID, parents: parents)]
                else { return nil }
                return TicketChat(
                    id: session.id, title: session.title, projectName: project.name,
                    projectPath: project.path, state: nil,
                    isRunning: AgentTerminalRegistry.shared.controller(for: session.id)?.isRunning == true)
            }
        },
        whenChatsChange: { notify in
            withObservationTracking {
                _ = AgentWorkspaceUIModel.shared.workspace
            } onChange: {
                Task { @MainActor in notify() }
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
    let viewModel: TicketBoardViewModel
    let load = TicketBoardLoad()

    @ObservationIgnored private let environment: TicketBoardEnvironment
    @ObservationIgnored private var stores: [String: TicketBoardStore] = [:]
    @ObservationIgnored private var active: (store: TicketBoardStore, team: String, projectPath: String, rule: TicketTeamRule)?
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
    /// Mit welchen Chats zuletzt abgeglichen wurde.
    @ObservationIgnored private var builtWith: [TicketChat]?
    /// Für welche Ansicht und welchen Abruf ihrer Tickets zuletzt abgeglichen wurde (WM8-125).
    @ObservationIgnored private var builtView: TicketBuiltView?
    @ObservationIgnored private var watchesChats = false
    @ObservationIgnored private var chatsTask: Task<Void, Never>?
    @ObservationIgnored private var isVisible = false
    @ObservationIgnored private var commentsTask: Task<Void, Never>?
    /// Ticket von außen, das die Triage zeigen soll, sobald das Board seines
    /// Projekts steht (WM8-131).
    @ObservationIgnored private var pendingOpen: TicketOpenRequest?
    /// Uhr für die Frist des Wunsches; Tests ersetzen sie.
    @ObservationIgnored var now: () -> Date = Date.init

    init(environment: TicketBoardEnvironment) {
        self.environment = environment
        viewModel = TicketBoardViewModel(documents: environment.documents)
        viewModel.onShowTicket = { [weak self] ticket in self?.showComments(for: ticket, fresh: false) }
        viewModel.onReloadComments = { [weak self] ticket in self?.showComments(for: ticket, fresh: true) }
        viewModel.onSelectView = { [weak self] id in
            guard let self, let store = self.active?.store else { return }
            // Der Store holt die Tickets, wenn sein Zwischenspeicher nicht frisch ist.
            store.viewID = id
            self.storeChanged(store)
        }
    }

    /// Kommentare des Tickets in der Triage: aus dem Zwischenspeicher sofort,
    /// sonst nach kurzer Ruhe genau eine Anfrage. Liest nur.
    private func showComments(for ticket: Ticket?, fresh: Bool) {
        commentsTask?.cancel()
        guard let ticket, let store = active?.store else { return }
        if fresh { store.forgetComments(ticketID: ticket.id) }
        if let cached = store.cachedComments(for: ticket) {
            viewModel.setComments(.loaded(cached), ticketID: ticket.id)
            return
        }
        let settle = environment.commentsSettle
        commentsTask = Task { [weak self, weak store] in
            await settle()
            guard !Task.isCancelled, let self, let store else { return }
            let load: TicketCommentsLoad
            do {
                load = .loaded(try await store.comments(for: ticket))
            } catch is CancellationError {
                return
            } catch let error as TicketSourceError {
                load = .failed(error.userText)
            } catch {
                load = .failed(TicketSourceError.network("Netzfehler").userText)
            }
            guard !Task.isCancelled else { return }
            self.viewModel.setComments(load, ticketID: ticket.id)
        }
    }

    // MARK: Ticket von außen (WM8-131)

    /// Zeigt das Ticket in der Triage, sobald das Board des Projekts steht:
    /// sofort, wenn es schon steht, sonst nach dem Abruf. Ein neuer Wunsch
    /// ersetzt den alten.
    func open(_ request: TicketOpenRequest) {
        pendingOpen = request
        applyPendingOpen()
    }

    /// Der Nutzer hat die Tickets verlassen, bevor das Board stand: Später soll
    /// nichts mehr aufspringen.
    func cancelPendingOpen() {
        pendingOpen = nil
    }

    var hasPendingOpen: Bool { pendingOpen != nil }

    private func applyPendingOpen() {
        guard let pending = pendingOpen else { return }
        guard pending.expires > now() else {
            pendingOpen = nil
            return
        }
        guard hasModel, phase == .ready, shownProject == pending.projectPath, let active else { return }
        pendingOpen = nil
        // Steht es im Abzug, gilt dieser Eintrag (mit den Chats des Abgleichs).
        let entry = viewModel.presentation.entry(key: pending.ticket.key)
            ?? TicketBoardBuilder.entry(for: pending.ticket, chats: builtWith ?? [], rule: active.rule,
                                        viewerID: active.store.snapshot?.viewerID)
        viewModel.openFromOutside(entry)
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
        case .ready(let team, let workspace, let root, let rule):
            let store = stores[workspace] ?? environment.makeStore(workspace)
            stores[workspace] = store
            if let active, active.store !== store || active.team != team || active.projectPath != root {
                // Anderer Workspace, anderes Team oder andere Wurzel: Der Stand gehört nicht hierher.
                leaveProject()
                phase = .loading
            }
            if let active, active.rule != rule {
                // Neue Regel (etwa nach `tickets setup --status`): neu abgleichen.
                builtFor = nil
            }
            active = (store, team, root, rule)
            store.onChange = { [weak self, weak store] in
                guard let self, let store else { return }
                self.storeChanged(store)
            }
            store.activate(team: team)
            storeChanged(store)
            watchChats()
        }
    }

    /// Verdeckt, andere Ansicht oder Schalter aus: kein Abruf mehr. Der letzte
    /// Stand bleibt für das nächste Zeigen stehen.
    func hide() {
        generation += 1
        isVisible = false
        active?.store.deactivate()
        chatsTask?.cancel()
        commentsTask?.cancel()
    }

    func refresh() {
        guard isVisible, let store = active?.store else { return }
        Task { await store.refresh() }
    }

    private func leaveProject() {
        active?.store.deactivate()
        active = nil
        builtFor = nil
        builtWith = nil
        builtView = nil
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
        let viewProblem = store.viewError.map { String(localized: "Views from Linear: \($0.userText)") }
        if load.viewProblem != viewProblem { load.viewProblem = viewProblem }
        guard let snapshot = store.snapshot else {
            phase = store.lastError.map { .unreachable($0.userText) } ?? .loading
            return
        }
        if load.fetchedAt != snapshot.fetchedAt { load.fetchedAt = snapshot.fetchedAt }
        if hasModel, phase != .ready { phase = .ready }
        let viewID = store.effectiveViewID
        // Ohne Stand und mit Fehler (etwa in Linear gelöscht) heißt es „nicht
        // verfügbar“, nicht „lädt“; beim nächsten Takt kommen die Reiter neu.
        let unavailable = viewID.map(store.isUnavailable) ?? false
        viewModel.setViews(store.catalog ?? .empty, active: viewID,
                           isLoading: !unavailable && viewID != nil && viewID.flatMap { store.viewTickets[$0] } == nil,
                           isUnavailable: unavailable)
        match(snapshot, projectPath: active.projectPath, rule: active.rule)
        applyPendingOpen()
    }

    /// Gleicht den Abzug mit den Chats ab, wenn einer von beiden neu ist. Den
    /// Zustand der Chats liefern die Status-Punkte selbst, ohne Abgleich.
    private func match(_ snapshot: TicketBoardSnapshot, projectPath: String, rule: TicketTeamRule) {
        let chats = PerfBudgets.ticketsChats.withInterval { environment.chats() }
        let store = active?.store
        let viewID = store?.effectiveViewID
        let view = store?.catalog?.views.first { $0.id == viewID }
        let viewTickets = viewID.flatMap { store?.viewTickets[$0] }
        let wanted = TicketBuiltView(viewID: viewID, fetchedAt: viewTickets?.fetchedAt)
        guard builtFor != snapshot.fetchedAt || builtWith != chats || builtView != wanted else { return }
        builtFor = snapshot.fetchedAt
        builtWith = chats
        builtView = wanted
        buildSequence += 1
        let sequence = buildSequence
        Task { [weak self] in
            // Abgleich abseits des Main Threads: bis zu 500 Tickets gegen alle Chats.
            let model = await Task.detached(priority: .userInitiated) {
                PerfBudgets.ticketsBuild.withInterval {
                    TicketBoardBuilder.build(snapshot: snapshot, chats: chats, projectPath: projectPath, rule: rule,
                                             view: view, viewTickets: viewTickets)
                }
            }.value
            guard let self, sequence == self.buildSequence else { return }
            self.viewModel.update(model)
            self.hasModel = true
            if self.phase != .ready { self.phase = .ready }
            self.applyPendingOpen()
        }
    }

    /// Ein neuer Chat, ein neuer Titel, ein beendeter Chat: Die Karten sollen
    /// das zeigen, ohne auf den nächsten Abruf bei Linear zu warten.
    private func watchChats() {
        guard !watchesChats else { return }
        watchesChats = true
        environment.whenChatsChange { [weak self] in
            guard let self else { return }
            self.watchesChats = false
            self.chatsMayHaveChanged()
        }
    }

    private func chatsMayHaveChanged() {
        // Verdeckt: nichts tun. Beim nächsten Zeigen meldet `show` neu an und gleicht ab.
        guard isVisible else { return }
        chatsTask?.cancel()
        let settle = environment.chatsSettle
        chatsTask = Task { [weak self] in
            await settle()
            guard let self, !Task.isCancelled, self.isVisible else { return }
            // Erst wieder anmelden, dann lesen: Was dazwischen geschieht, geht nicht verloren.
            self.watchChats()
            guard let active = self.active, let snapshot = active.store.snapshot else { return }
            self.match(snapshot, projectPath: active.projectPath, rule: active.rule)
        }
    }
}

/// Ticket von außen (`whisperm8 tickets open`, WM8-131), das die Triage zeigen
/// soll, sobald das Board seines Projekts steht.
struct TicketOpenRequest: Equatable {
    /// Wie Linear es eben geliefert hat; der Abzug des Boards hat Vorrang.
    var ticket: Ticket
    /// Projekt der App (Pfad, wie die Ansicht ihn bekommt).
    var projectPath: String
    /// Danach verfällt der Wunsch: Ein Board, das erst viel später steht, soll
    /// nicht unvermittelt ein Ticket aufschlagen.
    var expires: Date
}

/// Ansicht und Abruf, für die zuletzt abgeglichen wurde.
struct TicketBuiltView: Equatable {
    var viewID: String?
    var fetchedAt: Date?
}

/// Ein Controller je Fenster, außerhalb der View: Wer zwischen Chats und
/// Tickets wechselt, sieht beim Zurückkommen sofort den letzten Stand statt
/// „Loading“, und der frische Abruf läuft dahinter.
@MainActor
final class TicketBoardControllers {
    static let shared = TicketBoardControllers()
    private var byWindow: [UUID: TicketBoardController] = [:]

    private var mouseMonitor: Any?

    func controller(for windowID: UUID) -> TicketBoardController {
        if let known = byWindow[windowID] { return known }
        let fresh = TicketBoardController(environment: .live)
        fresh.viewModel.windowID = windowID
        byWindow[windowID] = fresh
        watchMouse()
        return fresh
    }

    /// Ein Mausklick räumt den Kopf (`leaveHeaders`), unabhängig von der
    /// Controller-Laufzeit: Auch die Tastatur wählt Knöpfe im Kopf (Paket 3c),
    /// und ein späteres Return nach einem Klick wirkte sonst auf den alten
    /// Knopf (WM8-91). Erst nach dem Klick geräumt, nicht beim Mausdruck: Ein
    /// Klick auf einen Eintrag der offenen Liste unter „Mehr“ wählt ihn
    /// (`chooseMoreViewByMouse`), statt dass die Liste vorher verschwindet und der
    /// Klick darunter landet. Einmal je App, sobald es ein Board gibt. Kosten je
    /// Klick: ein Blick je Fenster mit Board, nie je Taste.
    private func watchMouse() {
        guard mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { TicketBoardControllers.shared.leaveHeaders() }
            }
            return event
        }
    }

    /// Das Fenster gibt es nicht mehr: Takt beenden, Controller freigeben.
    func forget(_ windowID: UUID) {
        byWindow.removeValue(forKey: windowID)?.hide()
    }

    func hasController(for windowID: UUID) -> Bool { byWindow[windowID] != nil }

    /// Die Maus greift ein (WM8-91, Folgepunkt der Prüferin zu Paket 3d):
    /// Auswahl im Kopf und offene Liste der Bereiche weg, in jedem Fenster.
    /// Sonst blieben Ring und Liste stehen, und ein späteres Kreuz wirkte auf
    /// den alten Knopf, im ungünstigsten Fall „← Chats“. Kosten: ein Blick je
    /// Fenster (es gibt wenige).
    func leaveHeaders() {
        Self.leaveHeaders(byWindow.values.map(\.viewModel))
    }

    static func leaveHeaders(_ models: [TicketBoardViewModel]) {
        for model in models where model.headerFocus != nil || model.morePickerIndex != nil
            || model.columnFocus != nil || model.columnPickerIndex != nil {
            model.leaveHeader()
        }
    }
}

// MARK: - Ansicht

/// Die Ticket-Ansicht samt ihren Leerzuständen, so wie sie im Agent-Chats-
/// Fenster steht. Ruft nur ab, solange sie sichtbar und der Schalter an ist.
struct TicketBoardScreen: View, Equatable {
    /// Projekt, dessen Tickets gezeigt werden; `nil` ohne gewähltes Projekt.
    let projectPath: String?
    let projectName: String
    /// Daran hängen Einstellungen je Projekt, etwa die Breite der Liste in der Triage (WM8-125).
    var projectID: UUID? = nil
    let controller: TicketBoardController
    /// Der Schalter ging aus, während die Ansicht offen war: Das Fenster
    /// kehrt zu den Chats zurück.
    var onDisabled: (() -> Void)?
    @State private var windowVisible = true
    /// Zählt, wie oft das Fenster aktiv wurde: Danach wird die Zuordnung neu
    /// gelesen, etwa nach dem Einrichten in den Einstellungen.
    @State private var windowActivations = 0
    @AppStorage(PreferenceKeys.ticketBoardEnabled) private var enabled = false

    /// Ohne Angaben gelten die Wege der App; Tests und Bilder setzen eigene ein.
    var source: TicketChatStatusSource?
    var actions: TicketBoardActions?
    /// „← Chats · …“ im Kopf (WM8-124). Von der App gesetzt, weil nur sie
    /// weiß, wohin es zurückgeht.
    var back: TicketsBackLinkModel?

    /// Die Closures zählen nicht: Sie tun für dasselbe Fenster immer dasselbe.
    /// Vom Rückweg zählt nur, was auf dem Knopf steht.
    nonisolated static func == (lhs: TicketBoardScreen, rhs: TicketBoardScreen) -> Bool {
        lhs.projectPath == rhs.projectPath && lhs.projectName == rhs.projectName && lhs.projectID == rhs.projectID
            && lhs.controller === rhs.controller
            && lhs.back?.destination == rhs.back?.destination
    }

    var body: some View {
        Group {
            if !enabled {
                TicketBoardEmptyState(kind: .disabled, actions: screenActions)
            } else {
                switch controller.phase {
                case .ready:
                    TicketBoardView(title: String(localized: "Tickets · \(controller.title)"), model: controller.viewModel,
                                    load: controller.load, source: source ?? .live, actions: screenActions, projectID: projectID)
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
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AgentTheme.background)
        .background(TicketBoardWindowVisibility(isVisible: $windowVisible, activations: $windowActivations))
        // Ein Schlüssel für alles, was den Abruf an- oder abschaltet.
        .task(id: Activation(enabled: enabled, visible: windowVisible, project: projectPath, activations: windowActivations)) {
            if enabled, windowVisible {
                await controller.show(projectPath: projectPath, projectName: projectName)
            } else {
                controller.hide()
                if !enabled { onDisabled?() }
            }
        }
        .onDisappear { controller.hide() }
    }

    private struct Activation: Equatable {
        var enabled: Bool
        var visible: Bool
        var project: String?
        var activations: Int
    }

    private var screenActions: TicketBoardActions {
        var actions = actions ?? .live
        actions.refresh = { [controller] in controller.refresh() }
        if let back { actions.back = back }
        return actions
    }
}

extension TicketBoardActions {
    /// Wege der App: Chat in den Vordergrund, Linear-Adresse in die Linear-App
    /// (Einstellung „Browser“: im Browser, WM8-132), Einstellungen.
    @MainActor static let live = TicketBoardActions(
        refresh: {},
        openChat: { WindowRequestCenter.shared.requestSessionFocus(sessionID: $0) },
        openURL: { LinearLinkOpener.live.openInLinear($0) },
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
        .overlay(alignment: .topLeading) {
            // Auch ohne Board führt der Kopf zurück zu den Chats (WM8-124).
            if let back = actions.back { TicketsBackLinkButton(link: back).padding(14) }
        }
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
            // Nicht jetzt: Die Ansicht wird gerade eingehängt, und dabei darf
            // sie ihren Zustand nicht ändern.
            DispatchQueue.main.async { [weak self] in self?.report() }
        }

        private func report() {
            onChange?(window?.occlusionState.contains(.visible) ?? false)
        }

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }
    }
}
