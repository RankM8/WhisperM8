import Foundation

// MARK: - tab.order (`whisperm8 chats order --tabs`)

extension AgentControlRequestHandler {
    static let tabOrderMethod = "tab.order"

    struct TabOrderPlan {
        var windowID: UUID
        var projectName: String
        var before: [UUID]
        var after: [UUID]
    }

    /// Prüft und plant die Tab-Folge eines Fensters (pure). Alle genannten
    /// Chats müssen als Tab offen sein, im selben Fenster und im selben
    /// Projekt. Die Tabs dieses Projekts werden wie bei `chats order` geordnet
    /// und rücken als Block an die Stelle des ersten; andere Tabs bleiben in
    /// ihrer Folge.
    static func planTabOrder(
        windows: [(id: UUID, tabs: [UUID])], workspace: AgentWorkspace, first: [UUID], last: [UUID]
    ) -> Result<TabOrderPlan, ChatsControlErrorKind> {
        let named = first + last
        guard !named.isEmpty else { return .failure(.init(.invalid, "Mindestens einen Chat nennen.")) }
        if let both = first.first(where: { last.contains($0) }) {
            return .failure(.init(.invalid, "Chat \(both.uuidString) steht zugleich vorn und bei --last."))
        }
        let byID = Dictionary(workspace.sessions.map { ($0.id, $0) }, uniquingKeysWith: { lhs, _ in lhs })
        var windowIDs = Set<UUID>()
        for id in named {
            guard let window = windows.first(where: { $0.tabs.contains(id) }) else {
                let title = byID[id]?.title ?? id.uuidString
                return .failure(.init(.notFound, "\(title) ist in keinem Fenster als Tab offen."))
            }
            windowIDs.insert(window.id)
        }
        guard windowIDs.count == 1, let windowID = windowIDs.first,
              let window = windows.first(where: { $0.id == windowID }) else {
            return .failure(.init(.invalid, "Die Tabs liegen in verschiedenen Fenstern; chats order --tabs ordnet nur innerhalb eines Fensters."))
        }
        let projectIDs = Set(named.compactMap { byID[$0]?.projectID })
        guard projectIDs.count == 1, let projectID = projectIDs.first else {
            return .failure(.init(.invalid, "Die Tabs gehören zu verschiedenen Projekten; chats order --tabs ordnet die Tabs eines Projekts."))
        }
        let projectTabs = window.tabs.filter { byID[$0]?.projectID == projectID }
        let block = ChatOrderPlanner.plannedOrder(current: projectTabs, first: first, last: last)
        return .success(TabOrderPlan(
            windowID: windowID,
            projectName: workspace.projects.first { $0.id == projectID }?.name ?? "?",
            before: window.tabs,
            after: ChatOrderPlanner.tabBlockOrder(window: window.tabs, block: block)))
    }

    func tabOrder(_ request: ChatsControlRequest) async -> ChatsControlResponse {
        func ids(_ key: String) -> [UUID]? {
            let raw = request.params[key]?.arrayValue?.compactMap { $0.stringValue } ?? []
            let parsed = raw.compactMap(UUID.init(uuidString:))
            return parsed.count == raw.count ? parsed : nil
        }
        guard let first = ids("firstSessionIDs"), let last = ids("lastSessionIDs") else {
            return .failure(requestID: request.requestID, code: .invalid,
                            message: "firstSessionIDs/lastSessionIDs ungültig (Arrays von Session-UUIDs)")
        }
        let dryRun = request.params["dryRun"]?.boolValue ?? false

        let outcome: Result<(TabOrderPlan, [UUID: String]), ChatsControlErrorKind> = await MainActor.run {
            let store = AgentWindowStore.shared
            let workspace = AgentSessionStore().loadWorkspace()
            let windows = ([store.primaryWindowID] + store.secondaryWindowIDs).map { (id: $0, tabs: store.openTabIDs(in: $0)) }
            switch Self.planTabOrder(windows: windows, workspace: workspace, first: first, last: last) {
            case .failure(let error):
                return .failure(error)
            case .success(let plan):
                if !dryRun, plan.after != plan.before {
                    guard store.setTabOrder(plan.after, in: plan.windowID) != nil else {
                        return .failure(.init(.conflict, "Die Tabs des Fensters haben sich gerade geändert; bitte erneut versuchen."))
                    }
                    store.flush()
                }
                let titles = Dictionary(workspace.sessions.map { ($0.id, $0.title) }, uniquingKeysWith: { lhs, _ in lhs })
                return .success((plan, titles))
            }
        }

        switch outcome {
        case .failure(let error):
            return .failure(requestID: request.requestID, code: error.code, message: error.message)
        case .success(let (plan, titles)):
            let changed = plan.after != plan.before
            if !dryRun, changed {
                await audit(request.actor, method: "order-tabs", target: plan.projectName, outcome: "ok", prompt: nil)
            }
            func list(_ ids: [UUID]) -> [[String: Any]] {
                ids.enumerated().map { index, id in
                    ["position": index + 1, "id": id.uuidString, "title": titles[id] ?? "?"]
                }
            }
            return .success(requestID: request.requestID, result: .object([
                "ok": true,
                "dryRun": dryRun,
                "changed": changed,
                "project": plan.projectName,
                "windowID": plan.windowID.uuidString,
                "before": list(plan.before),
                "after": list(plan.after),
            ]))
        }
    }
}
