import Foundation

// MARK: - session.order (`whisperm8 chats order`)

extension AgentControlRequestHandler {
    static let sessionOrderMethod = "session.order"

    /// Ergebnis der Prüfung und Planung, auf dem Main Thread gebaut.
    struct SessionOrderPlan {
        var projectID: UUID
        var projectName: String
        var before: [UUID]
        var after: [UUID]
        var titles: [UUID: String]
    }

    /// Chats eines Projekts, wie die Seitenleiste sie in der Projektgruppe
    /// zeigt: manuell angelegt, nicht archiviert, nicht gepinnt (eigene
    /// Sektion), kein Subagent-Kind unter seinem Parent. Gleiche Menge wie
    /// beim Umsortieren mit der Maus.
    static func sidebarSessions(
        workspace: AgentWorkspace, pinnedIDs: Set<UUID>
    ) -> [UUID: [AgentChatSession]] {
        let childIDs = Set(AgentSidebarModelBuilder.subagentChildren(workspaceSessions: workspace.sessions)
            .byParentLocalID.values.flatMap { $0.map(\.id) })
        return AgentSidebarModelBuilder.sessionsByProject(
            workspaceSessions: workspace.sessions, pinnedSessionIDs: pinnedIDs, subagentChildIDs: childIDs)
    }

    /// Prüft die Anfrage gegen den Workspace und plant die neue Folge (pure).
    /// Alle Chats müssen existieren, nicht archiviert sein, im selben Projekt
    /// liegen und in dessen Gruppe der Seitenleiste stehen; ein Chat darf
    /// nicht zugleich vorn und hinten stehen.
    static func planSessionOrder(
        workspace: AgentWorkspace, pinnedIDs: Set<UUID> = [], first: [UUID], last: [UUID]
    ) -> Result<SessionOrderPlan, ChatsControlErrorKind> {
        let named = first + last
        guard !named.isEmpty else { return .failure(.init(.invalid, "Mindestens einen Chat nennen.")) }
        if let both = first.first(where: { last.contains($0) }) {
            return .failure(.init(.invalid, "Chat \(both.uuidString) steht zugleich vorn und bei --last."))
        }
        let byID = Dictionary(workspace.sessions.map { ($0.id, $0) }, uniquingKeysWith: { lhs, _ in lhs })
        var projectIDs = Set<UUID>()
        for id in named {
            guard let session = byID[id], session.status != .archived else {
                return .failure(.init(.notFound, "Chat \(id.uuidString) nicht gefunden oder archiviert."))
            }
            projectIDs.insert(session.projectID)
        }
        guard projectIDs.count == 1, let projectID = projectIDs.first else {
            let names = projectIDs.compactMap { id in workspace.projects.first { $0.id == id }?.name }.sorted()
            return .failure(.init(.invalid, "Die Chats liegen in verschiedenen Projekten (\(names.joined(separator: ", "))); chats order ordnet nur innerhalb eines Projekts."))
        }
        let projectSessions = sidebarSessions(workspace: workspace, pinnedIDs: pinnedIDs)[projectID] ?? []
        let visible = Set(projectSessions.map(\.id))
        if let hidden = named.first(where: { !visible.contains($0) }), let session = byID[hidden] {
            let reason = pinnedIDs.contains(hidden)
                ? "ist gepinnt und steht in der Gepinnt-Sektion"
                : "steht nicht in der Projektgruppe der Seitenleiste (Subagent-Job oder nicht von Hand angelegt)"
            return .failure(.init(.invalid, "\(session.title) \(reason); chats order ordnet nur die Projektgruppe."))
        }
        let before = projectSessions.map(\.id)
        let after = ChatOrderPlanner.plannedOrder(current: before, first: first, last: last)
        return .success(SessionOrderPlan(
            projectID: projectID,
            projectName: workspace.projects.first { $0.id == projectID }?.name ?? "?",
            before: before, after: after,
            titles: Dictionary(projectSessions.map { ($0.id, $0.title) }, uniquingKeysWith: { lhs, _ in lhs })))
    }

    /// Fehlerart plus Text für `planSessionOrder`.
    struct ChatsControlErrorKind: Error, Equatable {
        var code: ChatsControlErrorCode
        var message: String
        init(_ code: ChatsControlErrorCode, _ message: String) {
            self.code = code
            self.message = message
        }
    }

    func sessionOrder(_ request: ChatsControlRequest) async -> ChatsControlResponse {
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

        let outcome: Result<(SessionOrderPlan, [ProjectViewOrderChange]), ChatsControlErrorKind> = await MainActor.run {
            // Aktueller Store-Stand (aus dem Speicher), nicht die UI-Kopie, die
            // nach Änderungen abseits des Main Threads kurz hinterherhinkt.
            let workspace = AgentSessionStore().loadWorkspace()
            let pinned = Set(AgentWindowStore.shared.pinnedSessionIDs)
            switch Self.planSessionOrder(workspace: workspace, pinnedIDs: pinned, first: first, last: last) {
            case .failure(let error):
                return .failure(error)
            case .success(let plan):
                if !dryRun, plan.after != plan.before {
                    do {
                        try AgentSessionStore().reorderSessions(in: plan.projectID, orderedIDs: plan.after)
                    } catch {
                        return .failure(.init(.internalError, "Reihenfolge nicht gespeichert: \(error.localizedDescription)"))
                    }
                }
                let views = AgentWindowStore.shared.reorderProjectViews(
                    projectID: plan.projectID, order: plan.after, dryRun: dryRun)
                // UI-Zustand (Projekt-Ansicht, Tabs) sofort schreiben: Die CLI
                // liest danach von Disk.
                if !dryRun, views.contains(where: { $0.before != $0.after }) {
                    AgentWindowStore.shared.flush()
                }
                return .success((plan, views))
            }
        }

        switch outcome {
        case .failure(let error):
            return .failure(requestID: request.requestID, code: error.code, message: error.message)
        case .success(let (plan, views)):
            let changed = plan.after != plan.before || views.contains { $0.before != $0.after }
            // Befund 13.11.2026: `chats list` las direkt danach noch die alte
            // Folge. Erst antworten, wenn der Workspace auf der Platte steht.
            var persisted = true
            if !dryRun, plan.after != plan.before {
                persisted = await AgentSessionStore().flushToDisk(reason: "order")
            }
            if !dryRun, changed {
                await audit(request.actor, method: "order", target: plan.projectName, outcome: "ok", prompt: nil)
            }
            func list(_ ids: [UUID]) -> [[String: Any]] {
                ids.enumerated().map { index, id in
                    ["position": index + 1, "id": id.uuidString, "title": plan.titles[id] ?? ""]
                }
            }
            func slots(_ slots: [UUID?]) -> [Any] { slots.map { $0?.uuidString ?? NSNull() } }
            return .success(requestID: request.requestID, result: .object([
                "ok": true,
                "dryRun": dryRun,
                "changed": changed,
                // false: Folge gesetzt, aber noch nicht auf der Platte; chats list
                // kann bis zum nächsten Schreibversuch die alte Folge lesen.
                "persisted": persisted,
                "project": plan.projectName,
                "projectID": plan.projectID.uuidString,
                "before": list(plan.before),
                "after": list(plan.after),
                "projectViews": views.map { view -> [String: Any] in
                    ["id": view.workspaceID.uuidString, "name": view.name,
                     "before": slots(view.before), "after": slots(view.after)]
                },
            ]))
        }
    }
}
