import AppKit
import Foundation

// MARK: - Ticket von außen öffnen (WM8-131)

/// `whisperm8 tickets open <Ticket>` in der App: erst prüfen, dann zeigen.
///
/// Reihenfolge, damit nichts halb offen bleibt: Ticket-Ansicht an? Nummer
/// lesbar? Team eingerichtet und mit Projekt in der App? Ticket in Linear
/// ladbar? Erst danach wird ein Fenster nach vorn geholt und auf das Board
/// geschaltet. Liest Linear nur (ein Ticket), schreibt nirgends hin und schickt
/// nichts in einen Chat.
///
/// Alles von außen als Closures; Tests ersetzen Einrichtung, Linear und Fenster.
struct TicketOpenService {
    enum Outcome: Equatable {
        case opened(board: TicketOpenTarget.Board, ticket: Ticket)
        case failed(ChatsControlErrorCode, String)
    }

    var isEnabled: @MainActor () -> Bool
    /// Projekte der App (Main Thread, nur der Speicher, kein Disk).
    var projects: @MainActor () -> [TicketTeamDirectory.Project]
    /// Einrichtung aus `tickets.json`; läuft abseits des Main Threads.
    var loadConfig: @Sendable () -> TicketConfig
    var fetch: @Sendable (_ workspace: String, _ key: String) async throws -> TicketContext
    /// Fenster nach vorn, Board des Projekts, Ticket in die Triage.
    var present: @MainActor (_ board: TicketOpenTarget.Board, _ ticket: Ticket) async -> Result<Void, TicketOpenPresenter.Failure>

    static let disabledMessage =
        "Die Ticket-Ansicht ist aus. Einschalten: Einstellungen › Tickets › „Show tickets in Agent Chats“ (Labs)."

    func open(input: String) async -> Outcome {
        guard let key = TicketOpenTarget.key(fromInput: input) else {
            return .failed(.invalid, TicketOpenTarget.Failure.invalidKey(input).message)
        }
        guard await isEnabled() else { return .failed(.unsupported, Self.disabledMessage) }
        let projects = await projects()
        let load = loadConfig
        let resolved = await TicketBlockingWork.run { TicketOpenTarget.resolve(key: key, config: load(), projects: projects) }
        let board: TicketOpenTarget.Board
        switch resolved {
        case .success(let found): board = found
        case .failure(let failure): return .failed(.notFound, failure.message)
        }
        let context: TicketContext
        do {
            context = try await fetch(board.workspace, key)
        } catch let error as TicketSourceError {
            if case .notFound = error { return .failed(.notFound, error.message) }
            return .failed(.conflict, "\(key) lässt sich nicht laden: \(error.message)")
        } catch {
            return .failed(.conflict, "\(key) lässt sich nicht laden: \(TicketSourceError.network("Netzfehler").message)")
        }
        // Linear leitet eine alte Nummer nach einem Umbenennen des Teams weiter:
        // Dann gehört das Ticket zu einem anderen Board als dem aus der Nummer.
        guard context.team.isEmpty || context.team.caseInsensitiveCompare(board.team) == .orderedSame else {
            return .failed(.notFound, "\(key) gehört in Linear zu Team \(context.team), nicht zu \(board.team). "
                + "Mit der neuen Nummer öffnen: whisperm8 tickets open \(context.ticket.key)")
        }
        switch await present(board, context.ticket) {
        case .success:
            return .opened(board: board, ticket: context.ticket)
        case .failure(let failure):
            return .failed(.internalError, failure.message)
        }
    }

    @MainActor static var live: TicketOpenService {
        TicketOpenService(
            isEnabled: { UserDefaults.standard.bool(forKey: PreferenceKeys.ticketBoardEnabled) },
            projects: {
                AgentWorkspaceUIModel.shared.workspace.projects.map {
                    TicketTeamDirectory.Project(id: $0.id, path: $0.path, name: $0.name, colorHex: $0.color)
                }
            },
            loadConfig: { TicketConfigStore.live.load() },
            fetch: { workspace, key in try await LinearTicketSource(client: .live(workspace: workspace)).ticket(key: key) },
            present: { board, ticket in await TicketOpenPresenter.live.present(board: board, ticket: ticket) }
        )
    }
}

// MARK: - Fenster und Board

/// Holt ein Agent-Chats-Fenster nach vorn und zeigt dort das Board mit dem
/// Ticket. Welches Fenster: das zuletzt aktive (das vorderste, solange die App
/// vorne ist; sonst das, in dem der Nutzer zuletzt war), sonst das
/// Primärfenster, das dafür auch geöffnet wird.
@MainActor
struct TicketOpenPresenter {
    enum Failure: Error, Equatable {
        case noWindow
        case boardNotShown

        var message: String {
            switch self {
            case .noWindow: return "Das Agent-Chats-Fenster ließ sich nicht öffnen."
            case .boardNotShown: return "Das Ticket-Board ließ sich im Fenster nicht zeigen."
            }
        }
    }

    /// So lange darf das Board brauchen, bis es steht; danach verfällt der Wunsch.
    static let openTimeout: TimeInterval = 30

    var lastActiveWindowID: () -> UUID?
    var primaryWindowID: () -> UUID
    var isRegistered: (UUID) -> Bool
    var openPrimary: () -> Void
    /// Wartet, bis das Fenster sich angemeldet hat; `false` nach Ablauf der Frist.
    var waitForWindow: (UUID) async -> Bool
    var showBoard: (_ projectID: UUID, _ windowID: UUID) -> Void
    var isShowingBoard: (_ projectID: UUID, _ windowID: UUID) -> Bool
    var controller: (UUID) -> TicketBoardController
    var bringToFront: (UUID) -> Void
    var now: () -> Date = Date.init

    /// Zielfenster und ob es erst geöffnet werden muss.
    static func targetWindow(lastActive: UUID?, primary: UUID, isRegistered: (UUID) -> Bool) -> (id: UUID, mustOpen: Bool) {
        if let lastActive, isRegistered(lastActive) { return (lastActive, false) }
        return (primary, !isRegistered(primary))
    }

    func present(board: TicketOpenTarget.Board, ticket: Ticket) async -> Result<Void, Failure> {
        let target = Self.targetWindow(lastActive: lastActiveWindowID(), primary: primaryWindowID(), isRegistered: isRegistered)
        if target.mustOpen {
            openPrimary()
            guard await waitForWindow(target.id) else { return .failure(.noWindow) }
        }
        let controller = controller(target.id)
        // Erst der Wunsch, dann das Board: Wechselt das Projekt, räumt das Board
        // seinen alten Stand und zeigt das Ticket nach dem Abruf.
        controller.open(TicketOpenRequest(ticket: ticket, projectPath: board.projectPath,
                                          expires: now().addingTimeInterval(Self.openTimeout)))
        showBoard(board.projectID, target.id)
        guard isShowingBoard(board.projectID, target.id) else {
            controller.cancelPendingOpen()
            return .failure(.boardNotShown)
        }
        bringToFront(target.id)
        return .success(())
    }

    static var live: TicketOpenPresenter {
        let center = AgentChatsCommandCenter.shared
        let store = AgentWindowStore.shared
        return TicketOpenPresenter(
            lastActiveWindowID: { store.dictationWindowID },
            primaryWindowID: { store.primaryWindowID },
            isRegistered: { center.isRegistered($0) },
            openPrimary: { WindowRequestCenter.shared.request(.agentChats) },
            waitForWindow: { id in
                for _ in 0..<60 where !center.isRegistered(id) { try? await Task.sleep(for: .milliseconds(50)) }
                return center.isRegistered(id)
            },
            showBoard: { projectID, windowID in _ = center.perform(.showTickets(projectID: projectID), in: windowID) },
            isShowingBoard: { projectID, windowID in
                store.isTicketsMode(in: windowID) && store.selectedProject(in: windowID) == projectID
            },
            controller: { TicketBoardControllers.shared.controller(for: $0) },
            bringToFront: { id in
                ControllerWakeFocus(
                    targetWindowID: { id },
                    makeKey: { target in
                        guard center.perform(.makeKeyWindow, in: target) else { return false }
                        // Die Tastatur gehört danach dem Board, nicht dem Terminal
                        // des Board-Chats: Wer gerade woanders tippte, soll nicht in
                        // einen Chat schreiben. Ein zweites Mal, falls die Spalte
                        // beim Aufbau den Fokus nimmt.
                        BoardChatFocusRule.releaseTerminalFocus(in: NSApp.keyWindow)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                            MainActor.assumeIsolated { BoardChatFocusRule.releaseTerminalFocus(in: NSApp.keyWindow) }
                        }
                        return true
                    },
                    openPrimary: { WindowRequestCenter.shared.request(.agentChats) },
                    activate: { AppActivation.activate() },
                    whenActive: ControllerWakeFocus.runWhenAppActive
                ).bringToFront()
            }
        )
    }
}
