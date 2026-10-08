import Foundation

// MARK: - board.* (`whisperm8 chats board set|remove|clear|activate|deactivate`)

/// Jarvis-Board: Die App ist der einzige Schreiber (wie beim Workspace), die
/// CLI liest direkt von Disk. Owner ist IMMER der aufrufende Chat — und zwar
/// nur mit gültigem Session-Token. Die nackte `WHISPERM8_SESSION_ID` wäre
/// spoofbar und schriebe sonst auf das Board eines fremden Jarvis.
extension AgentControlRequestHandler {
    static let boardMethods: Set<String> = [
        "board.set", "board.remove", "board.clear", "board.activate", "board.deactivate",
    ]

    /// Zustand des Zielchats aus Sicht der App (für `set`).
    enum BoardTargetState: Equatable {
        case missing
        case archived
        case available
    }

    func boardMutation(_ request: ChatsControlRequest) async -> ChatsControlResponse {
        let verifiedOwner: UUID? = request.actor.sessionID
            .flatMap(UUID.init(uuidString:))
            .flatMap { id in
                AgentSessionTokenRegistry.shared.verify(sessionID: id, token: request.actor.token) ? id : nil
            }
        let targetID = request.params["targetSessionID"]?.stringValue.flatMap(UUID.init(uuidString:))
        let targetState: BoardTargetState = await MainActor.run {
            guard let targetID,
                  let session = AgentWorkspaceUIModel.shared.workspace.sessions.first(where: { $0.id == targetID })
            else { return .missing }
            return session.status == .archived ? .archived : .available
        }

        let response = Self.performBoardMutation(
            request, store: .shared, enabled: AppPreferences.shared.isJarvisBoardEnabled,
            verifiedOwner: verifiedOwner, targetState: { _ in targetState })

        let short = String(request.method.dropFirst("board.".count))
        var label: String?
        if let targetID { label = await sessionLabel(targetID) }
        await audit(request.actor, method: "board-\(short)", target: label,
                    outcome: response.ok ? "ok" : (response.error?.code ?? "error"), prompt: nil)
        return response
    }

    /// Pure Entscheidung + Store-Mutation, ohne App-Singletons — testbar mit
    /// temporärem Store und injiziertem Zielzustand.
    static func performBoardMutation(
        _ request: ChatsControlRequest,
        store: JarvisBoardStore,
        enabled: Bool,
        verifiedOwner: UUID?,
        targetState: (UUID) -> BoardTargetState,
        now: Date = Date()
    ) -> ChatsControlResponse {
        func fail(_ code: ChatsControlErrorCode, _ message: String) -> ChatsControlResponse {
            .failure(requestID: request.requestID, code: code, message: message)
        }
        guard enabled else { return fail(.unsupported, JarvisBoardSettings.disabledMessage) }
        guard let op = JarvisBoardOp(rawValue: String(request.method.dropFirst("board.".count))),
              boardMethods.contains(request.method) else {
            return fail(.unsupported, "Unbekannte Board-Methode: \(request.method)")
        }
        guard let owner = verifiedOwner else {
            return fail(.invalid, "Board-Befehle gehen nur aus einer WhisperM8-Session mit gültigem Token "
                        + "(WHISPERM8_SESSION_ID/WHISPERM8_SESSION_TOKEN) — das Board gehört dem aufrufenden Chat.")
        }

        // Ziel nur für set/remove.
        var targetID: UUID?
        if op == .set || op == .remove {
            guard let raw = request.params["targetSessionID"]?.stringValue, let id = UUID(uuidString: raw) else {
                return fail(.invalid, "targetSessionID fehlt/ungültig")
            }
            guard id != owner else {
                return fail(.selfSend, "Der eigene Chat kann nicht auf das eigene Board.")
            }
            targetID = id
        }

        var patch = JarvisBoardPatch()
        if op == .set {
            switch targetState(targetID!) {
            case .missing: return fail(.notFound, "Session nicht gefunden")
            case .archived: return fail(.notFound, "Session ist archiviert — archivierte Chats kommen nicht aufs Board")
            case .available: break
            }
            if let raw = request.params["light"]?.stringValue {
                guard let light = JarvisBoardLight(rawValue: raw) else {
                    return fail(.invalid, "light '\(raw)' ungültig. Erlaubt: \(JarvisBoardLight.allowedList)")
                }
                patch.light = light
            }
            patch.mission = request.params["mission"]?.stringValue
            patch.needs = request.params["needs"]?.stringValue
            patch.next = request.params["next"]?.stringValue
        }

        let change: JarvisBoardChange
        do {
            change = try store.mutate(now: now) { file, now in
                switch op {
                case .set: return JarvisBoardLogic.set(&file, owner: owner, sessionID: targetID!, patch: patch, now: now)
                case .remove: return JarvisBoardLogic.remove(&file, owner: owner, sessionID: targetID!, now: now)
                case .clear: return JarvisBoardLogic.clear(&file, owner: owner, now: now)
                case .activate: return JarvisBoardLogic.setActive(&file, owner: owner, active: true, now: now)
                case .deactivate: return JarvisBoardLogic.setActive(&file, owner: owner, active: false, now: now)
                }
            }
        } catch {
            return fail(.internalError, error.localizedDescription)
        }
        return .success(requestID: request.requestID, result: .object(boardChangeResult(change)))
    }

    static func boardChangeResult(_ change: JarvisBoardChange) -> [String: Any] {
        var result: [String: Any] = [
            "op": change.op.rawValue,
            "changed": change.changed,
            "owner": change.owner.uuidString,
            "ownerRef": ChatsOutput.shortID(change.owner),
            "isActive": change.board?.isActive ?? false,
            "entryCount": change.board?.entries.count ?? 0,
        ]
        if let sessionID = change.sessionID {
            result["sessionID"] = sessionID.uuidString
            result["ref"] = ChatsOutput.shortID(sessionID)
        }
        if let light = change.light { result["light"] = light.rawValue }
        if change.op == .set, let entry = change.entry {
            result["entry"] = [
                "light": entry.light.rawValue, "mission": entry.mission, "needs": entry.needs,
                "next": entry.next, "updatedAt": ChatsOutput.iso(entry.updatedAt),
            ]
        }
        if change.op == .remove || change.op == .clear { result["removedCount"] = change.removedCount }
        return result
    }
}
