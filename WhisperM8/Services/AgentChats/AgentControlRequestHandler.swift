import Foundation
import AppKit

// MARK: - Control-Request-Handler (App-Logik)

/// Übersetzt Control-Requests der `whisperm8 chats`-CLI in App-Aktionen. Läuft
/// die eigentliche Arbeit auf dem MainActor (Registry, Store, Fokus), aber das
/// Protokoll ist `nonisolated`, damit der Socket-Server (Utility-Queue) es
/// aufrufen kann; jede Methode hoppt selbst auf den MainActor.
///
/// Die Send-/Interrupt-Guards laufen bewusst in EINEM synchronen MainActor-
/// Block (kein `await` zwischen Prüfung und Injektion) — das schließt das
/// TOCTOU-Fenster zwischen „Status ok" und „Prompt gepastet" (GPT-Review).
final class AgentControlRequestHandler: AgentControlRequestHandling, @unchecked Sendable {
    /// Idempotenz-Cache: requestID → Zustand. Ein Timeout-Retry mit gleicher
    /// ID pastet nie doppelt — auch nicht bei NEBENLÄUFIGEN Duplikaten (die
    /// Verbindungen laufen concurrent). Reservierung + Abschluss unter EINEM
    /// Lock (GPT-Review G).
    private enum IdempotencyState {
        /// Reserviert-seit-Zeitpunkt — damit eine verwaiste Reservierung (Task
        /// starb, bevor complete/release lief) nach dem Fenster geprunt wird
        /// statt unbegrenzt zu leaken.
        case inFlight(Date)
        case completed(Date)
    }
    private let idempotencyLock = NSLock()
    private var recentRequests: [String: IdempotencyState] = [:]
    private let idempotencyWindow: TimeInterval = 60

    func handle(_ request: ChatsControlRequest) async -> ChatsControlResponse {
        switch request.method {
        case "ping":
            return await pingResponse(request)
        case "sessions.live":
            return await sessionsLive(request)
        case "session.send":
            return await sessionSend(request)
        case "session.interrupt":
            return await sessionInterrupt(request)
        case "session.open":
            return await sessionOpen(request)
        case "session.close":
            return await sessionClose(request)
        case "session.resume":
            return await sessionResume(request)
        case "session.new":
            return await sessionNew(request)
        case "workspace.rename", "workspace.group", "workspace.archive":
            return await workspaceMutation(request)
        case "gridWorkspace.list":
            return await gridWorkspaceList(request)
        case "gridWorkspace.rename":
            return await gridWorkspaceRename(request)
        default:
            return .failure(requestID: request.requestID, code: .unsupported,
                            message: "Unbekannte Methode: \(request.method)")
        }
    }

    // MARK: ping

    private func pingResponse(_ request: ChatsControlRequest) async -> ChatsControlResponse {
        let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "?"
        return .success(requestID: request.requestID, result: .object([
            "appVersion": version,
            "protocolVersion": ChatsControlProtocol.version,
            "pid": Int(ProcessInfo.processInfo.processIdentifier),
        ]))
    }

    // MARK: sessions.live

    /// Autoritative Runtime-Daten für die Lese-Befehle: die App kennt
    /// PTY-Existenz und den hook-getrackten Status, die der CLI-Schätzer nicht
    /// sieht.
    private func sessionsLive(_ request: ChatsControlRequest) async -> ChatsControlResponse {
        let live = await MainActor.run { () -> [[String: Any]] in
            let statusStore = AgentSessionStatusCoordinator.shared.statusStore
            let registry = AgentTerminalRegistry.shared
            let workspace = AgentWorkspaceUIModel.shared.workspace
            return workspace.sessions.map { session in
                let controller = registry.controller(for: session.id)
                let isRunning = controller?.isRunning ?? false
                let runtime = statusStore.status(for: session.id)
                return [
                    "sessionID": session.id.uuidString,
                    "runtimeStatus": runtime?.rawValue ?? "unknown",
                    "isAttachedPTY": isRunning,
                    "canSend": isRunning,
                    "canInterrupt": isRunning && runtime == .working,
                ]
            }
        }
        return .success(requestID: request.requestID, result: .object(["sessions": live]))
    }

    // MARK: session.send

    private func sessionSend(_ request: ChatsControlRequest) async -> ChatsControlResponse {
        guard let targetString = request.params["targetSessionID"]?.stringValue,
              let targetID = UUID(uuidString: targetString) else {
            return .failure(requestID: request.requestID, code: .invalid, message: "targetSessionID fehlt/ungültig")
        }
        guard let prompt = request.params["prompt"]?.stringValue, !prompt.isEmpty else {
            return .failure(requestID: request.requestID, code: .invalid, message: "prompt fehlt/leer")
        }
        let submit = request.params["submit"]?.boolValue ?? true
        let ifStatus = request.params["ifStatus"]?.arrayValue?.compactMap { $0.stringValue } ?? ["awaitingInput", "idle"]

        // Idempotenz — atomar reservieren VOR der Ausführung. Ein bekanntes
        // Duplikat pastet nie erneut; ein noch LAUFENDES Original meldet
        // „inFlight" (Ausgang offen) statt eines falschen Erfolgs.
        switch reserveIdempotency(request.requestID) {
        case .fresh:
            break
        case .completedEarlier(let date):
            return .success(requestID: request.requestID, result: .object([
                "ack": "duplicate", "target": ["id": targetString],
                "at": ISO8601DateFormatter().string(from: date),
            ]))
        case .stillInFlight:
            return .failure(requestID: request.requestID, code: .conflict,
                            message: "Anfrage mit dieser requestID läuft noch — Ausgang per `chats audit` prüfen")
        }

        let actorID = request.actor.sessionID.flatMap(UUID.init(uuidString:))
        let markerActor = await auditActorLabel(request.actor)

        // ATOMARER MainActor-Block: Guards + Paste ohne await dazwischen.
        let outcome: SendOutcome = await MainActor.run {
            let registry = AgentTerminalRegistry.shared
            let workspace = AgentWorkspaceUIModel.shared.workspace
            guard let session = workspace.sessions.first(where: { $0.id == targetID }),
                  session.status != .archived else {
                return .failure(.notFound, "Session nicht gefunden oder archiviert")
            }
            // Selbst-Send-Schutz — nie, auch nicht mit force.
            if let actorID, actorID == targetID {
                return .failure(.selfSend, "An sich selbst senden ist nicht erlaubt (Endlosschleife)")
            }
            guard let controller = registry.controller(for: targetID), controller.isRunning else {
                return .failure(.noPty, "Keine laufende PTY — Tab mit `chats open` starten")
            }
            // Status-Guard (--if-status). --force überstimmt ihn (nie den
            // Selbst-Send-Schutz).
            let force = request.params["force"]?.boolValue ?? false
            let runtime = AgentSessionStatusCoordinator.shared.statusStore.status(for: targetID)
            if !force, let runtime, !ifStatus.contains(runtime.rawValue) {
                return .failure(.conflict, "Ziel ist \(runtime.rawValue) (erlaubt: \(ifStatus.joined(separator: ",")))")
            }
            // Marker-Zeile voranstellen (Kennzeichnung + Ein-Hop, entschieden).
            let marked = Self.markedPrompt(prompt, actor: markerActor)
            controller.sendPrompt(marked, submit: submit)
            return .success(session)
        }

        switch outcome {
        case .failure(let code, let message):
            // Kein Paste passiert → Reservierung freigeben, damit ein Retry
            // nach behobenem Konflikt (z. B. Ziel wird idle) nicht als Duplikat
            // abgewiesen wird.
            releaseIdempotency(request.requestID)
            await audit(request.actor, method: "send", target: nil, outcome: code.rawValue,
                        prompt: prompt)
            return .failure(requestID: request.requestID, code: code, message: message,
                            detail: sendConflictDetail(targetID: targetID))
        case .success(let session):
            completeIdempotency(request.requestID)
            let targetLabel = await sessionLabel(targetID)
            await audit(request.actor, method: "send", target: targetLabel, outcome: "ok", prompt: prompt)
            return .success(requestID: request.requestID, result: .object([
                "ack": "delivered",
                "target": ["id": session.id.uuidString, "title": session.title],
                "promptChars": prompt.count,
                "requestID": request.requestID,
            ]))
        }
    }

    private func sendConflictDetail(targetID: UUID) -> ChatsControlJSON? {
        // best-effort — kann nil sein
        nil
    }

    // MARK: session.interrupt

    private func sessionInterrupt(_ request: ChatsControlRequest) async -> ChatsControlResponse {
        guard let targetString = request.params["targetSessionID"]?.stringValue,
              let targetID = UUID(uuidString: targetString) else {
            return .failure(requestID: request.requestID, code: .invalid, message: "targetSessionID fehlt/ungültig")
        }
        let actorID = request.actor.sessionID.flatMap(UUID.init(uuidString:))

        let outcome: SendOutcome = await MainActor.run {
            let registry = AgentTerminalRegistry.shared
            let workspace = AgentWorkspaceUIModel.shared.workspace
            guard let session = workspace.sessions.first(where: { $0.id == targetID }),
                  session.status != .archived else {
                return .failure(.notFound, "Session nicht gefunden oder archiviert")
            }
            if let actorID, actorID == targetID {
                return .failure(.selfSend, "Sich selbst zu unterbrechen ist nicht erlaubt")
            }
            guard let controller = registry.controller(for: targetID), controller.isRunning else {
                return .failure(.noPty, "Keine laufende PTY")
            }
            // Guard: nur working-Ziele interrupten (sonst sinnlos).
            let ifStatus = request.params["ifStatus"]?.arrayValue?.compactMap { $0.stringValue } ?? ["working"]
            let force = request.params["force"]?.boolValue ?? false
            let runtime = AgentSessionStatusCoordinator.shared.statusStore.status(for: targetID)
            if !force, let runtime, !ifStatus.contains(runtime.rawValue) {
                return .failure(.conflict, "Ziel ist \(runtime.rawValue), nicht working")
            }
            controller.sendInterrupt()
            return .success(session)
        }

        switch outcome {
        case .failure(let code, let message):
            await audit(request.actor, method: "interrupt", target: nil, outcome: code.rawValue, prompt: nil)
            return .failure(requestID: request.requestID, code: code, message: message)
        case .success(let session):
            let targetLabel = await sessionLabel(targetID)
            await audit(request.actor, method: "interrupt", target: targetLabel, outcome: "ok", prompt: nil)
            return .success(requestID: request.requestID, result: .object([
                "ack": "interrupted",
                "target": ["id": session.id.uuidString, "title": session.title],
            ]))
        }
    }

    // MARK: session.open

    private func sessionOpen(_ request: ChatsControlRequest) async -> ChatsControlResponse {
        guard let targetString = request.params["targetSessionID"]?.stringValue,
              let targetID = UUID(uuidString: targetString) else {
            return .failure(requestID: request.requestID, code: .invalid, message: "targetSessionID fehlt/ungültig")
        }
        let outcome: SendOutcome = await MainActor.run {
            let workspace = AgentWorkspaceUIModel.shared.workspace
            guard let session = workspace.sessions.first(where: { $0.id == targetID }),
                  session.status != .archived else {
                return .failure(.notFound, "Session nicht gefunden oder archiviert")
            }
            WindowRequestCenter.shared.requestSessionFocus(sessionID: targetID)
            NSApp.activate(ignoringOtherApps: true)
            return .success(session)
        }
        switch outcome {
        case .failure(let code, let message):
            return .failure(requestID: request.requestID, code: code, message: message)
        case .success(let session):
            let label = await sessionLabel(targetID)
            await audit(request.actor, method: "open", target: label, outcome: "ok", prompt: nil)
            return .success(requestID: request.requestID, result: .object([
                "ok": true, "target": ["id": session.id.uuidString, "title": session.title],
            ]))
        }
    }

    // MARK: session.close

    /// Schließt offene UI-Tabs — und NUR die. Bewusst kein Gegenstück zu
    /// `workspace.archive`: die Session bleibt im Workspace, ein laufendes PTY
    /// läuft weiter (Registry ist sessionID-basiert, erneutes Öffnen attached
    /// an denselben Controller inkl. Scrollback), Pin und Grid-Mitgliedschaft
    /// bleiben. Deshalb auch kein Status-Guard und kein `--force`: Schließen
    /// ist nie destruktiv, egal ob das Ziel working oder awaitingInput ist.
    ///
    /// Batch-fähig (`targetSessionIDs`): alle Ziele werden in EINEM synchronen
    /// MainActor-Block verarbeitet — ein konsistenter Snapshot, kein
    /// Cross-Window-Race zwischen Prüfung und Mutation (analog Send-Pipeline).
    /// Pro Ziel ein Outcome: `closed`, `alreadyClosed` (idempotent, kein
    /// Fehler) oder `notFound` — die CLI leitet daraus den Exit-Code ab.
    private func sessionClose(_ request: ChatsControlRequest) async -> ChatsControlResponse {
        let rawIDs = request.params["targetSessionIDs"]?.arrayValue?.compactMap { $0.stringValue } ?? []
        let parsedIDs = rawIDs.compactMap(UUID.init(uuidString:))
        guard !rawIDs.isEmpty, parsedIDs.count == rawIDs.count else {
            return .failure(requestID: request.requestID, code: .invalid,
                            message: "targetSessionIDs fehlt/ungültig (Array von Session-UUIDs)")
        }
        // Duplikate raus, Reihenfolge erhalten — ein doppelt gelistetes Ziel
        // würde sonst beim zweiten Mal fälschlich "alreadyClosed" melden.
        var deduped: [UUID] = []
        for id in parsedIDs where !deduped.contains(id) { deduped.append(id) }
        let targetIDs = deduped

        let items: [CloseOutcomeItem] = await MainActor.run {
            let workspace = AgentWorkspaceUIModel.shared.workspace
            let windowStore = AgentWindowStore.shared
            let registry = AgentTerminalRegistry.shared
            let statusStore = AgentSessionStatusCoordinator.shared.statusStore
            let projectNames = Dictionary(uniqueKeysWithValues: workspace.projects.map { ($0.id, $0.name) })
            return targetIDs.map { id in
                guard let session = workspace.sessions.first(where: { $0.id == id }),
                      session.status != .archived else {
                    return CloseOutcomeItem(id: id, outcome: "notFound")
                }
                let hostWindow = windowStore.closeTabInHostingWindow(id)
                return CloseOutcomeItem(
                    id: id,
                    title: session.title,
                    project: projectNames[session.projectID],
                    outcome: hostWindow == nil ? "alreadyClosed" : "closed",
                    ptyRunning: registry.controller(for: id)?.isRunning ?? false,
                    runtimeStatus: statusStore.status(for: id)?.rawValue,
                    isPinned: windowStore.pinnedSessionIDs.contains(id))
            }
        }

        // Audit pro tatsächlich geschlossenem Tab — genau die Mutationen sind
        // nachvollziehbar, No-ops und notFound spammen das Log nicht.
        for item in items where item.outcome == "closed" {
            let label = [item.project, item.title].compactMap { $0 }.joined(separator: "/")
            await audit(request.actor, method: "close", target: label, outcome: "ok", prompt: nil)
        }

        return .success(requestID: request.requestID, result: .object([
            "ok": true,
            "closedCount": items.filter { $0.outcome == "closed" }.count,
            "results": items.map { item -> [String: Any] in
                var dict: [String: Any] = [
                    "id": item.id.uuidString,
                    "outcome": item.outcome,
                    "ptyRunning": item.ptyRunning,
                    "isPinned": item.isPinned,
                ]
                if let title = item.title { dict["title"] = title }
                if let project = item.project { dict["project"] = project }
                if let status = item.runtimeStatus { dict["runtimeStatus"] = status }
                return dict
            },
        ]))
    }

    /// Outcome eines einzelnen close-Ziels (Server-Seite).
    private struct CloseOutcomeItem {
        var id: UUID
        var title: String?
        var project: String?
        var outcome: String
        var ptyRunning = false
        var runtimeStatus: String?
        var isPinned = false
    }

    // MARK: session.resume

    /// Revived einen geschlossenen Chat: setzt `shouldLaunchOnOpen = true` und
    /// fokussiert die Session — der `AgentSessionDetailView` startet die PTY
    /// dann mit dem Resume-Kommando (`claude resume <id>` / `codex resume`).
    /// Läuft die Session schon, ist es ein reines `open`.
    private func sessionResume(_ request: ChatsControlRequest) async -> ChatsControlResponse {
        guard let targetString = request.params["targetSessionID"]?.stringValue,
              let targetID = UUID(uuidString: targetString) else {
            return .failure(requestID: request.requestID, code: .invalid, message: "targetSessionID fehlt/ungültig")
        }
        let outcome: SendOutcome = await MainActor.run {
            let workspace = AgentWorkspaceUIModel.shared.workspace
            guard let session = workspace.sessions.first(where: { $0.id == targetID }),
                  session.status != .archived else {
                return .failure(.notFound, "Session nicht gefunden oder archiviert (Archiv erst wiederherstellen)")
            }
            // Terminal-Sessions (reine Shell) und agentView haben kein Resume.
            if session.effectiveKind == .terminal || session.effectiveKind == .agentView {
                return .failure(.unsupported, "Session-Art \(session.effectiveKind.displayName) ist nicht resumebar")
            }
            let isRunning = AgentTerminalRegistry.shared.controller(for: targetID)?.isRunning ?? false
            if !isRunning {
                // shouldLaunchOnOpen setzen, damit der DetailView launcht
                // (onAppear, Session-Wechsel ODER der onChange-Trigger für
                // bereits offene Tabs). Fehler propagieren statt Erfolg zu
                // behaupten (GPT-Review: try? verschluckte den Store-Fehler).
                do {
                    try AgentSessionStore().updateSession(id: targetID) { $0.shouldLaunchOnOpen = true }
                } catch {
                    return .failure(.internalError, "Resume-Flag konnte nicht gesetzt werden: \(error.localizedDescription)")
                }
            }
            WindowRequestCenter.shared.requestSessionFocus(sessionID: targetID)
            NSApp.activate(ignoringOtherApps: true)
            return .success(session)
        }
        switch outcome {
        case .failure(let code, let message):
            return .failure(requestID: request.requestID, code: code, message: message)
        case .success(let session):
            let label = await sessionLabel(targetID)
            await audit(request.actor, method: "resume", target: label, outcome: "ok", prompt: nil)
            return .success(requestID: request.requestID, result: .object([
                "ok": true, "target": ["id": session.id.uuidString, "title": session.title],
            ]))
        }
    }

    // MARK: session.new

    private func sessionNew(_ request: ChatsControlRequest) async -> ChatsControlResponse {
        guard let projectRef = request.params["project"]?.stringValue, !projectRef.isEmpty else {
            return .failure(requestID: request.requestID, code: .invalid, message: "project fehlt")
        }
        let providerRaw = request.params["provider"]?.stringValue ?? "claude"
        guard let provider = AgentProvider(rawValue: providerRaw) else {
            return .failure(requestID: request.requestID, code: .invalid, message: "provider muss claude|codex sein")
        }
        let title = request.params["title"]?.stringValue
        let prompt = request.params["prompt"]?.stringValue

        let result = await MainActor.run {
            AgentChatLaunchService().openChatViaControl(
                provider: provider, projectRef: projectRef, title: title, prompt: prompt)
        }
        switch result {
        case .failure(let error):
            return .failure(requestID: request.requestID, code: .notFound, message: error.message)
        case .success(let launch):
            await audit(request.actor, method: "new", target: "\(launch.projectName)/\(launch.title)", outcome: "ok", prompt: prompt)
            return .success(requestID: request.requestID, result: .object([
                "ok": true,
                "session": ["id": launch.id.uuidString, "title": launch.title, "project": launch.projectName],
            ]))
        }
    }

    // MARK: workspace.rename / .group / .archive

    private func workspaceMutation(_ request: ChatsControlRequest) async -> ChatsControlResponse {
        guard let targetString = request.params["targetSessionID"]?.stringValue,
              let targetID = UUID(uuidString: targetString) else {
            return .failure(requestID: request.requestID, code: .invalid, message: "targetSessionID fehlt/ungültig")
        }
        let force = request.params["force"]?.boolValue ?? false

        let result: MutationOutcome = await MainActor.run {
            let store = AgentSessionStore()
            let workspace = AgentWorkspaceUIModel.shared.workspace
            guard let session = workspace.sessions.first(where: { $0.id == targetID }),
                  session.status != .archived else {
                return .failure(.notFound, "Session nicht gefunden oder archiviert")
            }
            let registry = AgentTerminalRegistry.shared
            let isRunningPTY = registry.controller(for: targetID)?.isRunning ?? false
            let runtime = AgentSessionStatusCoordinator.shared.statusStore.status(for: targetID)

            do {
                switch request.method {
                case "workspace.rename":
                    // Vor dem Guard trimmen — ein Whitespace-only-Titel würde
                    // sonst zu einem leeren Titel getrimmt (GPT-Review).
                    guard let title = request.params["title"]?.stringValue?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                        !title.isEmpty else {
                        return .failure(.invalid, "title fehlt/leer")
                    }
                    // KEIN Schutz für manuelle Titel mehr: Ein CLI-Rename ist
                    // eine explizite User-Anweisung (der Skill bestätigt sie
                    // ohnehin). `renameSession` setzt `titleIsAutoGenerated =
                    // false`, damit der Auto-Namer den neuen Namen nicht später
                    // überschreibt — das reicht als Schutz.
                    let before = session.title
                    try store.renameSession(id: targetID, title: title)
                    return .success(before: before, after: title)
                case "workspace.group":
                    let clear = request.params["clear"]?.boolValue ?? false
                    let group = clear ? nil : request.params["group"]?.stringValue
                    let before = session.groupName ?? ""
                    try store.setSessionGroup(id: targetID, groupName: group)
                    return .success(before: before, after: group ?? "")
                case "workspace.archive":
                    if runtime == .working || isRunningPTY, !force {
                        return .failure(.conflict, "Session arbeitet oder hat eine laufende PTY — nicht archivierbar")
                    }
                    try store.archiveSession(id: targetID)
                    return .success(before: session.status.rawValue, after: "archived")
                default:
                    return .failure(.unsupported, "Unbekannte Mutation")
                }
            } catch {
                return .failure(.internalError, error.localizedDescription)
            }
        }

        let methodShort = String(request.method.dropFirst("workspace.".count))
        switch result {
        case .failure(let code, let message):
            await audit(request.actor, method: methodShort, target: nil, outcome: code.rawValue, prompt: nil)
            return .failure(requestID: request.requestID, code: code, message: message)
        case .success(let before, let after):
            let label = await sessionLabel(targetID)
            await audit(request.actor, method: methodShort, target: label, outcome: "ok", prompt: nil)
            return .success(requestID: request.requestID, result: .object([
                "ok": true, "before": before, "after": after,
                "target": ["id": targetString],
            ]))
        }
    }

    // MARK: gridWorkspace.list / .rename

    /// Grid-Workspaces (die „WORKSPACES"-Sektion der Sidebar). Read-über-Socket,
    /// weil die Namen im UI-State liegen (nicht in AgentSessions.json) und die
    /// App der Single Writer dafür ist.
    private func gridWorkspaceList(_ request: ChatsControlRequest) async -> ChatsControlResponse {
        let workspaces = await MainActor.run { () -> [[String: Any]] in
            AgentWindowStore.shared.gridWorkspaces.map { ws in
                ["id": ws.id.uuidString, "name": ws.name, "capacity": ws.capacity]
            }
        }
        return .success(requestID: request.requestID, result: .object(["workspaces": workspaces]))
    }

    private func gridWorkspaceRename(_ request: ChatsControlRequest) async -> ChatsControlResponse {
        guard let ref = request.params["ref"]?.stringValue, !ref.isEmpty else {
            return .failure(requestID: request.requestID, code: .invalid, message: "ref fehlt")
        }
        guard let newName = request.params["name"]?.stringValue, !newName.isEmpty else {
            return .failure(requestID: request.requestID, code: .invalid, message: "name fehlt")
        }
        enum GridOutcome { case ok(before: String, after: String); case fail(ChatsControlErrorCode, String) }
        let outcome: GridOutcome = await MainActor.run {
            let all = AgentWindowStore.shared.gridWorkspaces
            // Auflösung: exakte ID, sonst eindeutiger Name (case-insensitiv,
            // normalisiert). Mehrdeutig → Fehler (nie raten).
            let byID = UUID(uuidString: ref).flatMap { id in all.first { $0.id == id } }
            let target: AgentGridWorkspace?
            if let byID {
                target = byID
            } else {
                let norm = SessionRefResolver.normalize(ref)
                // Exakter (normalisierter) Match gewinnt VOR Substring —
                // sonst wäre „Workspace" gegen „Workspace" + „Workspace 2"
                // fälschlich mehrdeutig (GPT-Review).
                let exact = all.filter { SessionRefResolver.normalize($0.name) == norm }
                if exact.count == 1 {
                    target = exact[0]
                } else if exact.count > 1 {
                    return .fail(.notFound, "Workspace-Name \(ref) ist mehrdeutig (\(exact.count) exakte Treffer) — ID nutzen")
                } else {
                    let matches = all.filter { SessionRefResolver.normalize($0.name).contains(norm) }
                    if matches.count > 1 {
                        return .fail(.notFound, "Workspace-Name \(ref) ist mehrdeutig (\(matches.count) Treffer) — genauer angeben oder ID nutzen")
                    }
                    target = matches.first
                }
            }
            guard let workspace = target else {
                return .fail(.notFound, "Kein Grid-Workspace gefunden für: \(ref)")
            }
            let before = workspace.name
            guard AgentWindowStore.shared.renameGridWorkspace(workspace.id, to: newName) else {
                return .fail(.conflict, "Umbenennung abgelehnt (leerer/gleicher Name?)")
            }
            return .ok(before: before, after: newName)
        }
        switch outcome {
        case .fail(let code, let message):
            return .failure(requestID: request.requestID, code: code, message: message)
        case .ok(let before, let after):
            await audit(request.actor, method: "workspace-rename", target: after, outcome: "ok", prompt: nil)
            return .success(requestID: request.requestID, result: .object([
                "ok": true, "before": before, "after": after,
            ]))
        }
    }

    // MARK: - Idempotenz

    /// Ergebnis der atomaren Reservierung.
    enum IdempotencyReservation {
        /// Frisch reserviert — Aufrufer darf ausführen.
        case fresh
        /// Bereits erfolgreich ausgeführt (Zeitpunkt des Paste).
        case completedEarlier(Date)
        /// Original läuft noch — Ausgang offen, NICHT als Erfolg werten
        /// (GPT-Review: ein inFlight-Duplikat darf keinen falschen Erfolg
        /// melden, das Original kann noch scheitern).
        case stillInFlight
    }

    /// Reserviert die requestID atomar unter einem Lock.
    private func reserveIdempotency(_ requestID: String) -> IdempotencyReservation {
        idempotencyLock.lock()
        defer { idempotencyLock.unlock() }
        pruneIdempotency()
        if let existing = recentRequests[requestID] {
            switch existing {
            case .completed(let date): return .completedEarlier(date)
            case .inFlight: return .stillInFlight
            }
        }
        recentRequests[requestID] = .inFlight(Date())
        return .fresh
    }

    private func completeIdempotency(_ requestID: String) {
        idempotencyLock.lock()
        recentRequests[requestID] = .completed(Date())
        idempotencyLock.unlock()
    }

    /// Gibt eine Reservierung frei, wenn die Ausführung NICHT zum Paste führte
    /// (Guard-Fehler) — sonst würde ein legitimer Retry nach behobenem Konflikt
    /// fälschlich als Duplikat abgewiesen.
    private func releaseIdempotency(_ requestID: String) {
        idempotencyLock.lock()
        if case .inFlight = recentRequests[requestID] {
            recentRequests.removeValue(forKey: requestID)
        }
        idempotencyLock.unlock()
    }

    private func pruneIdempotency() {
        let cutoff = Date().addingTimeInterval(-idempotencyWindow)
        recentRequests = recentRequests.filter {
            switch $0.value {
            case .completed(let date): return date > cutoff
            // Verwaiste inFlight-Reservierung (Task starb vor complete/release)
            // nach dem Fenster fallenlassen — sonst Leak. Ein echter Paste ist
            // in < 60 s durch, danach steht der Eintrag ohnehin auf completed.
            case .inFlight(let date): return date > cutoff
            }
        }
    }

    // Test-Zugänge zur Idempotenz-Logik.
    func reserveIdempotencyForTest(_ requestID: String) -> IdempotencyReservation { reserveIdempotency(requestID) }
    func completeIdempotencyForTest(_ requestID: String) { completeIdempotency(requestID) }
    func releaseIdempotencyForTest(_ requestID: String) { releaseIdempotency(requestID) }

    // MARK: - Audit + Marker

    /// Marker-Zeile für gesendete Prompts (Kennzeichnung + Ein-Hop-Regel).
    static func markedPrompt(_ prompt: String, actor: String) -> String {
        let time = markerTimeFormatter.string(from: Date())
        return "[via whisperm8 chats · von \(actor) · \(time)]\n\(prompt)"
    }

    private func auditActorLabel(_ actor: ChatsControlActor) async -> String {
        guard let idString = actor.sessionID, let id = UUID(uuidString: idString) else {
            return "extern"
        }
        let verified = AgentSessionTokenRegistry.shared.verify(sessionID: id, token: actor.token)
        guard verified else { return "unverified" }
        return await sessionLabel(id)
    }

    private func sessionLabel(_ id: UUID) async -> String {
        await MainActor.run {
            let workspace = AgentWorkspaceUIModel.shared.workspace
            guard let session = workspace.sessions.first(where: { $0.id == id }) else { return id.uuidString }
            let project = workspace.projects.first(where: { $0.id == session.projectID })?.name ?? "?"
            return "\(project)/\(session.title)"
        }
    }

    private func audit(_ actor: ChatsControlActor, method: String, target: String?, outcome: String, prompt: String?) async {
        let verified: Bool
        let label: String
        if let idString = actor.sessionID, let id = UUID(uuidString: idString) {
            verified = AgentSessionTokenRegistry.shared.verify(sessionID: id, token: actor.token)
            label = verified ? await sessionLabel(id) : "unverified"
        } else {
            verified = false
            label = "external"
        }
        ChatsAuditLog.shared.append(ChatsAuditEntry(
            at: Date(), actor: label, verified: verified, method: method, target: target,
            outcome: outcome, promptChars: prompt?.count,
            promptHead: prompt.map(ChatsAuditLog.promptHead)))
    }

    private static let markerTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    // MARK: - Outcome-Typen

    private enum SendOutcome {
        case success(AgentChatSession)
        case failure(ChatsControlErrorCode, String)
    }

    private enum MutationOutcome {
        case success(before: String, after: String)
        case failure(ChatsControlErrorCode, String)
    }
}
