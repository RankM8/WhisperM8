import Foundation

// MARK: - Methoden der Feature-Erweiterungen

/// Board, Debug, Ansagen, Zwischenablage und Tickets haben je eine eigene Datei
/// (`AgentControlRequestHandler+…`). Ihre Methoden-Sets landen hier, damit der
/// zentrale Switch nicht mit jedem Feature wächst. `handle(_:)` fragt
/// `featureRoute` VOR dem zentralen Switch — so kann dort kein Fall eine
/// Feature-Methode verdecken, und die Zuordnung ist pur testbar.
extension AgentControlRequestHandler {
    enum FeatureRoute: Equatable, CaseIterable {
        case board
        case debug
        case speech
        case clipboard
        case gptRouter
        case handover
        case order
        case submit
        case tickets

        var methods: Set<String> {
            switch self {
            case .board: return AgentControlRequestHandler.boardMethods
            case .debug: return AgentControlRequestHandler.debugMethods
            case .speech: return AgentControlRequestHandler.speechMethods
            case .clipboard: return AgentControlRequestHandler.clipboardMethods
            case .gptRouter: return [AgentControlRequestHandler.gptRouterStartProfileMethod]
            case .handover: return [AgentControlRequestHandler.appHandoverMethod]
            case .order: return [AgentControlRequestHandler.sessionOrderMethod, AgentControlRequestHandler.tabOrderMethod]
            case .submit: return [AgentControlRequestHandler.sessionSubmitMethod]
            case .tickets: return [AgentControlRequestHandler.ticketsOpenMethod]
            }
        }
    }

    /// Welche Feature-Datei bedient die Methode? `nil` = keine (zentraler Switch
    /// oder unbekannt).
    static func featureRoute(for method: String) -> FeatureRoute? {
        FeatureRoute.allCases.first { $0.methods.contains(method) }
    }

    func featureRequest(_ request: ChatsControlRequest, route: FeatureRoute) async -> ChatsControlResponse {
        switch route {
        case .board: return await boardMutation(request)
        case .debug: return await debugRequest(request)
        case .speech: return await speechRequest(request)
        case .clipboard: return await clipboardRequest(request)
        case .gptRouter: return gptRouterStartProfile(request)
        case .handover: return await appHandover(request)
        case .order:
            return request.method == Self.tabOrderMethod ? await tabOrder(request) : await sessionOrder(request)
        case .submit: return await sessionSubmit(request)
        case .tickets: return await ticketsOpen(request)
        }
    }
}
