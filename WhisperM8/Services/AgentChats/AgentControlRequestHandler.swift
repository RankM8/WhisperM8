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
    /// Audit-Ziel (Tests injizieren eine Temp-Datei).
    var auditLog: ChatsAuditLog = .shared
    private let idempotencyLock = NSLock()
    private var recentRequests: [String: IdempotencyState] = [:]
    private let idempotencyWindow: TimeInterval = 60

    /// Reine Lese-Methoden: brauchen keine verifizierte Identität.
    static let readOnlyMethods: Set<String> = ["ping", "sessions.live", "window.list", "gridWorkspace.list"]

    /// Behauptet ein mutierender Aufruf eine Session-Identität (`sessionID`),
    /// beweist aber kein gültiges Token (falsch, nie ausgegeben oder mit dem
    /// PTY-Ende widerrufen), wird er abgelehnt statt als „unverified"
    /// ausgeführt (LR-CLI-005). Aufrufe ganz ohne `sessionID` (User im Terminal,
    /// Skripte) bleiben wie bisher erlaubt und erscheinen als „external".
    static func rejectsUnverifiedActor(_ request: ChatsControlRequest) -> Bool {
        guard !readOnlyMethods.contains(request.method),
              let idString = request.actor.sessionID else { return false }
        guard let id = UUID(uuidString: idString) else { return true }
        return !AgentSessionTokenRegistry.shared.verify(sessionID: id, token: request.actor.token)
    }

    func handle(_ request: ChatsControlRequest) async -> ChatsControlResponse {
        if Self.rejectsUnverifiedActor(request) {
            return .failure(requestID: request.requestID, code: .invalid,
                            message: "Session-Identität nicht belegt (Token fehlt, falsch oder widerrufen) — Befehl aus der laufenden Chat-Session der App ausführen.")
        }
        // Feature-Methoden zuerst: kein Fall unten kann sie verdecken (+Routing).
        if let route = Self.featureRoute(for: request.method) {
            return await featureRequest(request, route: route)
        }
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
        case "session.reopen":
            return await sessionReopen(request)
        case "session.pin":
            return await sessionPin(request)
        case "session.move":
            return await sessionMove(request)
        case "window.list":
            return await windowList(request)
        case "gridWorkspace.add", "gridWorkspace.remove":
            return await gridWorkspaceMembership(request)
        case "session.resume":
            return await sessionResume(request)
        case "session.new":
            return await sessionNew(request)
        case "workspace.rename", "workspace.group", "workspace.archive":
            return await workspaceMutation(request)
        case "workspace.unarchive":
            return await workspaceUnarchive(request)
        case "gridWorkspace.list":
            return await gridWorkspaceList(request)
        case "gridWorkspace.create":
            return await gridWorkspaceCreate(request)
        case "gridWorkspace.delete":
            return await gridWorkspaceDelete(request)
        case "gridWorkspace.rename":
            return await gridWorkspaceRename(request)
        case "gridWorkspace.open":
            return await gridWorkspaceOpen(request)
        case "queue.enqueue", "queue.cancel":
            return await queueMutation(request)
        case "audit.note":
            return await auditNote(request)
        case "session.moveAccount":
            return await sessionMoveAccount(request)
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

    /// Autoritative Runtime-Daten für die Lese-Befehle: die App kennt PTY-Existenz
    /// und den hook-getrackten Status, die der CLI-Schätzer nicht sieht.
    /// `onlyActive` (neue CLI): nur Sessions mit PTY, bekanntem Status oder schon
    /// gestartetem Prozess; die übrigen ergänzt die CLI selbst.
    private func sessionsLive(_ request: ChatsControlRequest) async -> ChatsControlResponse {
        let onlyActive = request.params["onlyActive"]?.boolValue ?? false
        let live = await MainActor.run { () -> [[String: Any]] in
            let statusStore = AgentSessionStatusCoordinator.shared.statusStore
            let registry = AgentTerminalRegistry.shared
            let workspace = AgentWorkspaceUIModel.shared.workspace
            return workspace.sessions.compactMap { session in
                let controller = registry.controller(for: session.id)
                let isRunning = controller?.isRunning ?? false
                let runtime = statusStore.status(for: session.id)
                if onlyActive, !isRunning, runtime == nil, controller?.hasStarted != true { return nil }
                return ChatsSendReadinessGuard.liveEntry(session: session, isRunning: isRunning, runtime: runtime,
                    hasStarted: controller?.hasStarted == true, pid: isRunning ? controller?.processID : nil)
            }
        }
        return .success(requestID: request.requestID,
                        result: .object(["sessions": live, "omittedDetached": onlyActive]))
    }

    // MARK: session.interrupt

    private func sessionInterrupt(_ request: ChatsControlRequest) async -> ChatsControlResponse {
        guard let targetString = request.params["targetSessionID"]?.stringValue,
              let targetID = UUID(uuidString: targetString) else {
            return .failure(requestID: request.requestID, code: .invalid, message: "targetSessionID fehlt/ungültig")
        }
        let actorID = request.actor.sessionID.flatMap(UUID.init(uuidString:))

        let clearInput = request.params["clearInput"]?.boolValue ?? false
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
            controller.noteInterruptSent(status: runtime)
            // Abort-Verdacht anmelden: Der Stop-Hook feuert bei
            // ESC-Interrupts nicht — ohne die Verifikation bliebe die
            // Session im working-Stau (QA-Befund 2026-08-17). Der
            // Coordinator bestätigt nur, wenn der Turn binnen 5 s weder
            // Hook- noch Transcript-Aktivität zeigt.
            AgentSessionStatusCoordinator.shared.suspectTurnAborted(targetID)
            // `--clear-input` (opt-in, löscht auch einen User-Entwurf): leert
            // den zurückgelegten Prompt verzögert, aber nur, wenn bis dahin
            // nichts anderes ins Feld geschrieben hat (Review R1).
            if clearInput { controller.clearComposerAfterInterrupt() }
            return .success(session)
        }

        switch outcome {
        case .failure(let code, let message):
            await audit(request.actor, method: "interrupt", target: nil, outcome: code.rawValue, prompt: nil)
            return .failure(requestID: request.requestID, code: code, message: message)
        case .success(let session):
            let targetLabel = await sessionLabel(targetID)
            await audit(request.actor, method: "interrupt", target: targetLabel, outcome: "ok", prompt: nil)
            var payload: [String: Any] = [
                "ack": "interrupted",
                "target": ["id": session.id.uuidString, "title": session.title],
            ]
            if clearInput { payload["clearInput"] = true }
            return .success(requestID: request.requestID, result: .object(payload))
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
            WindowRequestCenter.shared.requestSessionFocus(sessionID: targetID, fromControlChannel: true)
            AppActivation.activate()
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

    /// Schließt offene UI-Tabs — und ohne `stop` NUR die. Bewusst kein
    /// Gegenstück zu `workspace.archive`: die Session bleibt im Workspace, ein
    /// laufendes PTY läuft weiter (Registry ist sessionID-basiert, erneutes
    /// Öffnen attached an denselben Controller inkl. Scrollback), der Pin
    /// bleibt. Wie jedes Tab-Schließen verlässt der Chat offene Workspaces
    /// (siehe `AgentWindowStore+GridTabClose`). Deshalb kein Status-Guard:
    /// Schließen ist nie destruktiv, egal ob das Ziel working oder
    /// awaitingInput ist.
    ///
    /// `stop == true` ist die einzige Ausnahme: dann wird zusätzlich der
    /// laufende Agent beendet (graceful: 2× Ctrl+C, Terminal-Snapshot, dann
    /// Kill) und der Session-Status von `.running` auf `.closed` gesetzt.
    /// Nicht archiviert, nichts gelöscht, Pin bleibt — die Session ist danach
    /// per `resume` wieder hochfahrbar.
    ///
    /// Schutz arbeitender Agenten: ist auch nur EIN Ziel gerade `working`,
    /// scheitert der GESAMTE Request mit `conflict`, bevor irgendein Tab
    /// schließt oder ein Prozess stirbt — kein Teilzustand, in dem die Hälfte
    /// der Tabs weg ist. Nur `force` hebt das auf.
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
        let mode = request.params["mode"]?.stringValue ?? "explicit"
        guard mode == "explicit" || mode == "others" || mode == "right" else {
            return .failure(requestID: request.requestID, code: .invalid,
                            message: "mode muss explicit|others|right sein")
        }
        let stop = request.params["stop"]?.boolValue ?? false
        let force = request.params["force"]?.boolValue ?? false
        guard mode == "explicit" || parsedIDs.count == 1 else {
            return .failure(requestID: request.requestID, code: .invalid,
                            message: "mode \(mode) verlangt genau EINEN Anker-Tab")
        }
        // Duplikate raus, Reihenfolge erhalten — ein doppelt gelistetes Ziel
        // würde sonst beim zweiten Mal fälschlich "alreadyClosed" melden.
        var deduped: [UUID] = []
        for id in parsedIDs where !deduped.contains(id) { deduped.append(id) }
        let requestedIDs = deduped

        enum CloseComputation {
            case items([CloseOutcomeItem])
            case failure(ChatsControlErrorCode, String)
        }
        // Auch die Opfer-Bestimmung von others/right lebt im selben
        // MainActor-Block wie das Schließen — der Anker kann zwischen
        // Berechnung und Mutation nicht das Fenster wechseln.
        let computation: CloseComputation = await MainActor.run {
            let workspace = AgentWorkspaceUIModel.shared.workspace
            let windowStore = AgentWindowStore.shared
            let registry = AgentTerminalRegistry.shared
            let statusStore = AgentSessionStatusCoordinator.shared.statusStore
            let projectNames = Dictionary(uniqueKeysWithValues: workspace.projects.map { ($0.id, $0.name) })

            let targetIDs: [UUID]
            switch mode {
            case "others", "right":
                let anchor = requestedIDs[0]
                guard let host = windowStore.windowID(containingTab: anchor) else {
                    return .failure(.conflict, "Anker-Tab ist in keinem Fenster offen")
                }
                let tabs = windowStore.openTabIDs(in: host)
                if mode == "others" {
                    targetIDs = tabs.filter { $0 != anchor }
                } else {
                    let anchorIndex = tabs.firstIndex(of: anchor) ?? tabs.count
                    targetIDs = Array(tabs.dropFirst(anchorIndex + 1))
                }
            default:
                targetIDs = requestedIDs
            }

            // Schutz arbeitender Agenten — VOR jeder Mutation und über ALLE
            // Ziele. Ein Stop mitten im Turn verwirft die laufende Arbeit;
            // das darf nie beiläufig aus einer Aufräum-Runde passieren.
            if stop {
                let blocking = ChatsCloseStopGuard.blockingTargets(
                    targetIDs: targetIDs,
                    force: force,
                    isWorking: { id in
                        // Archivierte/unbekannte Ziele blockieren nie — sie
                        // landen ohnehin als `notFound` im Ergebnis.
                        guard workspace.sessions.contains(where: { $0.id == id && $0.status != .archived })
                        else { return false }
                        return statusStore.status(for: id) == .working
                    },
                    label: { id in
                        guard let session = workspace.sessions.first(where: { $0.id == id }) else { return nil }
                        return [projectNames[session.projectID], session.title]
                            .compactMap { $0 }.joined(separator: "/")
                    }
                )
                if !blocking.isEmpty {
                    return .failure(.conflict, ChatsCloseStopGuard.conflictMessage(blocking: blocking))
                }
            }

            let sessionStore = stop ? AgentSessionStore() : nil

            return .items(targetIDs.map { id in
                guard let session = workspace.sessions.first(where: { $0.id == id }),
                      session.status != .archived else {
                    return CloseOutcomeItem(id: id, outcome: "notFound")
                }
                let wasRunning = registry.controller(for: id)?.isRunning ?? false
                let hostWindow = windowStore.closeTabInHostingWindow(id)

                var didStop = false
                if stop, wasRunning {
                    // Graceful: 2× Ctrl+C, Terminal-Snapshot, dann Kill —
                    // dieselbe Routine wie beim Archivieren, damit der letzte
                    // JSONL-Flush und der `--resume`-Hinweis erhalten bleiben.
                    registry.terminate(sessionID: id)
                    didStop = true
                }

                // Hintergrund-Agenten leben im Claude-Supervisor-Daemon; das
                // PTY ist nur ein `claude attach`. Es zu killen trennt die
                // ANZEIGE, der Agent arbeitet weiter. Der echte Stop läuft
                // über `claude stop <short-id>` — asynchron, also außerhalb
                // dieses MainActor-Blocks.
                let backgroundShortID: String? = {
                    guard stop, session.effectiveKind == .backgroundChat,
                          let shortID = session.backgroundShortID, !shortID.isEmpty else { return nil }
                    return shortID
                }()

                if stop {
                    // Status nur herunterstufen, nie archivieren. Idempotent —
                    // der Terminierungs-Callback der UI setzt dasselbe.
                    try? sessionStore?.updateSession(id: id) { updated in
                        if updated.status == .running { updated.status = .closed }
                    }
                }

                return CloseOutcomeItem(
                    id: id,
                    title: session.title,
                    project: projectNames[session.projectID],
                    outcome: hostWindow == nil ? "alreadyClosed" : "closed",
                    // Nach einem Stop läuft nichts mehr — sonst würde die
                    // Ausgabe „läuft weiter" behaupten, obwohl gerade beendet.
                    ptyRunning: didStop ? false : wasRunning,
                    runtimeStatus: statusStore.status(for: id)?.rawValue,
                    isPinned: windowStore.pinnedSessionIDs.contains(id),
                    // Für Hintergrund-Agenten erst nach dem Daemon-Stop wahr —
                    // sonst meldete die CLI „Agent gestoppt", während er läuft.
                    stopped: backgroundShortID == nil ? didStop : false,
                    backgroundShortID: backgroundShortID)
            })
        }
        var items: [CloseOutcomeItem]
        switch computation {
        case .failure(let code, let message):
            await audit(request.actor, method: "close", target: nil, outcome: code.rawValue, prompt: nil)
            return .failure(requestID: request.requestID, code: code, message: message)
        case .items(let computed):
            items = computed
        }

        // Zweite Phase: Hintergrund-Agenten im Supervisor-Daemon beenden. Läuft
        // bewusst NACH dem MainActor-Block — `claude stop` ist ein Subprozess
        // und hätte den MainActor sonst über die gesamte Laufzeit blockiert.
        for index in items.indices {
            guard let shortID = items[index].backgroundShortID else { continue }
            do {
                _ = try await BackgroundAgentLifecycle.stop(shortID: shortID)
                items[index].stopped = true
            } catch {
                // Tab ist bereits zu, der Daemon-Job läuft aber weiter — das
                // muss sichtbar sein, sonst hält der Aufrufer ihn für beendet.
                items[index].stopFailed = true
                Logger.agentStore.warning(
                    "close_stop_background_failed short=\(shortID, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            }
        }

        // Audit pro tatsächlich geschlossenem Tab — genau die Mutationen sind
        // nachvollziehbar, No-ops und notFound spammen das Log nicht. Ein Stop
        // wird als eigene Methode geführt: er beendet einen Prozess und muss
        // im Audit vom rein visuellen Schließen unterscheidbar sein.
        for item in items where item.outcome == "closed" || item.stopped {
            let label = [item.project, item.title].compactMap { $0 }.joined(separator: "/")
            let method = item.stopped ? (force ? "close --stop --force" : "close --stop") : "close"
            await audit(request.actor, method: method, target: label, outcome: "ok", prompt: nil)
        }

        return .success(requestID: request.requestID, result: .object([
            "ok": true,
            "closedCount": items.filter { $0.outcome == "closed" }.count,
            "stoppedCount": items.filter(\.stopped).count,
            "results": items.map { item -> [String: Any] in
                var dict: [String: Any] = [
                    "id": item.id.uuidString,
                    "outcome": item.outcome,
                    "ptyRunning": item.ptyRunning,
                    "isPinned": item.isPinned,
                    "stopped": item.stopped,
                    "stopFailed": item.stopFailed,
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
        /// `--stop` hat hier einen laufenden Agenten beendet.
        var stopped = false
        /// Gesetzt, solange der Supervisor-Job noch zu stoppen ist (zweite
        /// Phase außerhalb des MainActor-Blocks).
        var backgroundShortID: String?
        /// Der Daemon-Stop schlug fehl — der Agent läuft trotz `--stop` weiter.
        var stopFailed = false
    }

    // MARK: session.reopen

    /// Stellt den zuletzt geschlossenen Tab wieder her (LIFO, ephemer —
    /// App-Neustart leert die Liste). Gegenstück zum close-Fehlgriff:
    /// nicht destruktiv, kein Guard. Sessions, die inzwischen archiviert
    /// oder gelöscht wurden, überspringt die Store-Logik.
    private func sessionReopen(_ request: ChatsControlRequest) async -> ChatsControlResponse {
        let outcome: SendOutcome = await MainActor.run {
            guard let session = ClosedChatReopener.reopen() else {
                return .failure(.notFound, "Keine zuletzt geschlossenen Tabs (die Liste ist ephemer und nach App-Neustart leer)")
            }
            return .success(session)
        }
        switch outcome {
        case .failure(let code, let message):
            return .failure(requestID: request.requestID, code: code, message: message)
        case .success(let session):
            let label = await sessionLabel(session.id)
            await audit(request.actor, method: "reopen", target: label, outcome: "ok", prompt: nil)
            return .success(requestID: request.requestID, result: .object([
                "ok": true, "target": ["id": session.id.uuidString, "title": session.title],
            ]))
        }
    }

    // MARK: session.pin

    /// Pin/Unpin (Sidebar-Sektion „Gepinnt") — Batch wie close, idempotent:
    /// ein bereits passender Zustand ist "unchanged", kein Fehler.
    private func sessionPin(_ request: ChatsControlRequest) async -> ChatsControlResponse {
        let rawIDs = request.params["targetSessionIDs"]?.arrayValue?.compactMap { $0.stringValue } ?? []
        let parsedIDs = rawIDs.compactMap(UUID.init(uuidString:))
        guard !rawIDs.isEmpty, parsedIDs.count == rawIDs.count else {
            return .failure(requestID: request.requestID, code: .invalid,
                            message: "targetSessionIDs fehlt/ungültig (Array von Session-UUIDs)")
        }
        guard let pinned = request.params["pinned"]?.boolValue else {
            return .failure(requestID: request.requestID, code: .invalid, message: "pinned fehlt (true|false)")
        }
        var deduped: [UUID] = []
        for id in parsedIDs where !deduped.contains(id) { deduped.append(id) }
        let targetIDs = deduped

        let items: [CloseOutcomeItem] = await MainActor.run {
            let workspace = AgentWorkspaceUIModel.shared.workspace
            let windowStore = AgentWindowStore.shared
            let projectNames = Dictionary(uniqueKeysWithValues: workspace.projects.map { ($0.id, $0.name) })
            return targetIDs.map { id in
                guard let session = workspace.sessions.first(where: { $0.id == id }),
                      session.status != .archived else {
                    return CloseOutcomeItem(id: id, outcome: "notFound")
                }
                let changed = windowStore.setPinned(id, pinned: pinned)
                return CloseOutcomeItem(
                    id: id, title: session.title, project: projectNames[session.projectID],
                    outcome: changed ? (pinned ? "pinned" : "unpinned") : "unchanged",
                    isPinned: pinned)
            }
        }
        for item in items where item.outcome == "pinned" || item.outcome == "unpinned" {
            let label = [item.project, item.title].compactMap { $0 }.joined(separator: "/")
            await audit(request.actor, method: item.outcome, target: label, outcome: "ok", prompt: nil)
        }
        return .success(requestID: request.requestID, result: .object([
            "ok": true,
            "changedCount": items.filter { $0.outcome != "unchanged" && $0.outcome != "notFound" }.count,
            "results": items.map { item -> [String: Any] in
                var dict: [String: Any] = ["id": item.id.uuidString, "outcome": item.outcome]
                if let title = item.title { dict["title"] = title }
                if let project = item.project { dict["project"] = project }
                return dict
            },
        ]))
    }

    // MARK: session.move

    /// Verschiebt einen Tab in ein anderes, EXISTIERENDES Fenster (neue
    /// Fenster kann nur die App-UI öffnen — die Scene gehört SwiftUI).
    /// Nicht-offene Tabs werden im Ziel geöffnet (`moveTab`-Semantik).
    private func sessionMove(_ request: ChatsControlRequest) async -> ChatsControlResponse {
        guard let targetString = request.params["targetSessionID"]?.stringValue,
              let targetID = UUID(uuidString: targetString) else {
            return .failure(requestID: request.requestID, code: .invalid, message: "targetSessionID fehlt/ungültig")
        }
        guard let windowRef = request.params["windowRef"]?.stringValue, !windowRef.isEmpty else {
            return .failure(requestID: request.requestID, code: .invalid, message: "windowRef fehlt (primary | Fenster-ID/Präfix)")
        }
        enum MoveOutcome { case ok(AgentChatSession, UUID); case fail(ChatsControlErrorCode, String) }
        let outcome: MoveOutcome = await MainActor.run {
            let workspace = AgentWorkspaceUIModel.shared.workspace
            let windowStore = AgentWindowStore.shared
            guard let session = workspace.sessions.first(where: { $0.id == targetID }),
                  session.status != .archived else {
                return .fail(.notFound, "Session nicht gefunden oder archiviert")
            }
            guard let destination = Self.resolveWindowRef(windowRef, store: windowStore) else {
                return .fail(.notFound, "Kein Fenster gefunden für: \(windowRef) — `chats window list` zeigt die IDs")
            }
            let source = windowStore.windowID(containingTab: targetID) ?? destination
            if source == destination, windowStore.openTabIDs(in: destination).contains(targetID) {
                return .fail(.conflict, "Tab ist bereits in diesem Fenster")
            }
            windowStore.moveTab(targetID, from: source, to: destination, before: nil)
            WindowRequestCenter.shared.requestWindowFocus(windowID: destination)
            return .ok(session, destination)
        }
        switch outcome {
        case .fail(let code, let message):
            return .failure(requestID: request.requestID, code: code, message: message)
        case .ok(let session, let destination):
            let label = await sessionLabel(targetID)
            await audit(request.actor, method: "move", target: label, outcome: "ok", prompt: nil)
            return .success(requestID: request.requestID, result: .object([
                "ok": true,
                "target": ["id": session.id.uuidString, "title": session.title],
                "windowID": destination.uuidString,
            ]))
        }
    }

    /// Fenster-Referenz: `primary` oder UUID/-Präfix (≥ 8 Hex-Zeichen,
    /// eindeutig) über die Fenster im UI-State.
    @MainActor
    static func resolveWindowRef(_ ref: String, store: AgentWindowStore) -> UUID? {
        if ref.lowercased() == "primary" { return store.primaryWindowID }
        let allIDs = [store.primaryWindowID] + store.secondaryWindowIDs
        if let uuid = UUID(uuidString: ref) {
            return allIDs.first { $0 == uuid }
        }
        let normalized = ref.replacingOccurrences(of: "-", with: "").lowercased()
        guard normalized.count >= 8 else { return nil }
        let matches = allIDs.filter {
            $0.uuidString.replacingOccurrences(of: "-", with: "").lowercased().hasPrefix(normalized)
        }
        return matches.count == 1 ? matches[0] : nil
    }

    // MARK: window.list

    /// Fenster-Inventar für `chats window list` — Basis der `move`-Ziele.
    private func windowList(_ request: ChatsControlRequest) async -> ChatsControlResponse {
        let windows = await MainActor.run { () -> [[String: Any]] in
            let store = AgentWindowStore.shared
            let workspace = AgentWorkspaceUIModel.shared.workspace
            let titles = Dictionary(uniqueKeysWithValues: workspace.sessions.map { ($0.id, $0.title) })
            let ids = [store.primaryWindowID] + store.secondaryWindowIDs
            return ids.map { id in
                let tabs = store.openTabIDs(in: id)
                var dict: [String: Any] = [
                    "id": id.uuidString,
                    "isPrimary": id == store.primaryWindowID,
                    "tabCount": tabs.count,
                    "tabTitles": tabs.map { titles[$0] ?? "?" },
                    "tabs": tabs.enumerated().map { ["position": $0.offset + 1, "id": $0.element.uuidString, "title": titles[$0.element] ?? "?"] },
                    "selectedTitle": store.selectedSession(in: id).flatMap { titles[$0] } ?? "",
                    // Grid oder Einzelansicht? Ohne dieses Feld ist ein
                    // gesetzter `activeWorkspaceID` nicht interpretierbar —
                    // er bleibt auch in der Einzelansicht stehen.
                    "showsGrid": store.showsGrid(in: id),
                ]
                let active = store.activeGridWorkspace(in: id)
                // Projekt-Views sind für die CLI keine Workspaces — ihre
                // Entity-ID bleibt verborgen (sonst wäre sie über
                // gridWorkspace.*-Refs doch adressierbar); stattdessen als
                // Projekt-Ansicht gekennzeichnet.
                let isProjectView = active?.sourceProjectID != nil
                dict["activeWorkspaceID"] = (isProjectView ? nil : active?.id.uuidString) ?? NSNull()
                // Name mitliefern, damit ein Agent für die Aussage nicht
                // zusätzlich `workspace list` aufrufen muss.
                dict["activeWorkspaceName"] = (isProjectView ? nil : active?.name) ?? NSNull()
                dict["activeProjectViewName"] = (isProjectView ? active?.name : nil) ?? NSNull()
                return dict
            }
        }
        return .success(requestID: request.requestID, result: .object(["windows": windows]))
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
            guard let session = workspace.sessions.first(where: { $0.id == targetID }) else {
                return .failure(.notFound, "Session nicht gefunden")
            }
            // Strikte Aktions-Trennung: resume startet NIE eine archivierte
            // Session — der explizite Compound dafür ist `unarchive --resume`.
            guard session.status != .archived else {
                return .failure(.conflict, "Session ist archiviert — `chats unarchive <ref> --resume` nutzen")
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
            // Fortsetzen holt die App nicht nach vorn (LR-CLI-004).
            WindowRequestCenter.shared.requestSessionFocus(
                sessionID: targetID,
                activate: ControlActivationPolicy.shouldActivate(method: request.method, wantsOpen: false), fromControlChannel: true)
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

    // session.new: AgentControlRequestHandler+SessionNew.swift

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
                case "workspace.rename" where request.params["reset"]?.boolValue == true:
                    // Benennung aufheben → zurück zum nativen Titel des CLI.
                    let before = session.title
                    try store.resetSessionTitle(id: targetID)
                    if let project = workspace.projects.first(where: { $0.id == session.projectID }),
                       var reset = store.loadWorkspace().sessions.first(where: { $0.id == targetID }) {
                        reset.titleIsAutoGenerated = true
                        AgentSessionStatusCoordinator.shared.autoNamer
                            .forceGenerateTitle(session: reset, cwd: project.path)
                    }
                    return .success(before: before, after: "(nativer Titel)")
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

    // MARK: workspace.unarchive

    /// Entfernt NUR die Archiv-Markierung (`restoreSession`: Status →
    /// `.closed`, `archivedAt` weg) — kein Tab, kein Start, kein Fokus.
    /// Die strikte Aktions-Trennung (close ≠ archive ≠ unarchive ≠ resume)
    /// wird nur über die EXPLIZITEN Flags `resume`/`open` kombiniert:
    /// `resume` = danach Auto-Launch + Fokus (Semantik von `session.resume`),
    /// `open` = danach nur Tab fokussieren. Alles-oder-nichts: ist `resume`
    /// für die Session-Art nicht möglich (Terminal/agentView), passiert
    /// GAR NICHTS — auch kein Unarchive (kein halber Compound).
    ///
    /// Nicht archivierte Ziele sind idempotenter Erfolg (`alreadyActive`) —
    /// ein angefordertes `resume`/`open` läuft dann trotzdem (jede Aktion
    /// tut genau ihr eigenes Ding). Datenverlust ist ausgeschlossen:
    /// beide Pfade ändern ausschließlich Status/Zeitstempel/UI-Fokus.
    private func workspaceUnarchive(_ request: ChatsControlRequest) async -> ChatsControlResponse {
        guard let targetString = request.params["targetSessionID"]?.stringValue,
              let targetID = UUID(uuidString: targetString) else {
            return .failure(requestID: request.requestID, code: .invalid, message: "targetSessionID fehlt/ungültig")
        }
        let wantsResume = request.params["resume"]?.boolValue ?? false
        let wantsOpen = request.params["open"]?.boolValue ?? false
        guard !(wantsResume && wantsOpen) else {
            return .failure(requestID: request.requestID, code: .invalid, message: "resume und open schließen sich aus")
        }

        enum UnarchiveOutcome {
            case ok(AgentChatSession, outcome: String, resumed: Bool, opened: Bool)
            case fail(ChatsControlErrorCode, String)
        }
        let result: UnarchiveOutcome = await MainActor.run {
            let workspace = AgentWorkspaceUIModel.shared.workspace
            guard let session = workspace.sessions.first(where: { $0.id == targetID }) else {
                return .fail(.notFound, "Session nicht gefunden")
            }
            // Vorab-Guard VOR jeder Mutation: ein nicht-resumebarer Kind-Typ
            // bricht den ganzen Compound ab, bevor irgendetwas passiert.
            if wantsResume,
               session.effectiveKind == .terminal || session.effectiveKind == .agentView {
                return .fail(.unsupported, "Session-Art \(session.effectiveKind.displayName) ist nicht resumebar — `unarchive` ohne --resume nutzen")
            }
            let wasArchived = session.status == .archived
            if wasArchived {
                do {
                    try AgentSessionStore().restoreSession(id: targetID)
                } catch {
                    return .fail(.internalError, "Entarchivieren fehlgeschlagen: \(error.localizedDescription)")
                }
            }
            var resumed = false
            var opened = false
            if wantsResume {
                let isRunning = AgentTerminalRegistry.shared.controller(for: targetID)?.isRunning ?? false
                if !isRunning {
                    do {
                        try AgentSessionStore().updateSession(id: targetID) { $0.shouldLaunchOnOpen = true }
                    } catch {
                        // Unarchive ist bereits passiert und bleibt gültig
                        // (kein Rollback einer gewollten Markierung) — nur der
                        // Startteil wird als Fehler gemeldet.
                        return .fail(.internalError, "Entarchiviert, aber Resume-Flag fehlgeschlagen: \(error.localizedDescription)")
                    }
                }
                // Fortsetzen holt die App nicht nach vorn (LR-CLI-004).
                WindowRequestCenter.shared.requestSessionFocus(
                    sessionID: targetID,
                    activate: ControlActivationPolicy.shouldActivate(method: request.method, wantsOpen: wantsOpen), fromControlChannel: true)
                resumed = true
            } else if wantsOpen {
                WindowRequestCenter.shared.requestSessionFocus(sessionID: targetID, fromControlChannel: true)
                AppActivation.activate()
                opened = true
            }
            return .ok(session, outcome: wasArchived ? "unarchived" : "alreadyActive",
                       resumed: resumed, opened: opened)
        }

        switch result {
        case .fail(let code, let message):
            await audit(request.actor, method: "unarchive", target: nil, outcome: code.rawValue, prompt: nil)
            return .failure(requestID: request.requestID, code: code, message: message)
        case .ok(let session, let outcome, let resumed, let opened):
            let label = await sessionLabel(targetID)
            let auditMethod = resumed ? "unarchive+resume" : opened ? "unarchive+open" : "unarchive"
            await audit(request.actor, method: auditMethod, target: label, outcome: outcome, prompt: nil)
            return .success(requestID: request.requestID, result: .object([
                "ok": true,
                "outcome": outcome,
                "resumed": resumed,
                "opened": opened,
                "target": ["id": session.id.uuidString, "title": session.title],
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
    func reserveIdempotency(_ requestID: String) -> IdempotencyReservation {
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

    func completeIdempotency(_ requestID: String) {
        idempotencyLock.lock()
        recentRequests[requestID] = .completed(Date())
        idempotencyLock.unlock()
    }

    /// Gibt eine Reservierung frei, wenn die Ausführung NICHT zum Paste führte
    /// (Guard-Fehler) — sonst würde ein legitimer Retry nach behobenem Konflikt
    /// fälschlich als Duplikat abgewiesen.
    func releaseIdempotency(_ requestID: String) {
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

    func auditActorLabel(_ actor: ChatsControlActor) async -> String {
        guard let idString = actor.sessionID, let id = UUID(uuidString: idString) else {
            return "extern"
        }
        let verified = AgentSessionTokenRegistry.shared.verify(sessionID: id, token: actor.token)
        guard verified else { return "unverified" }
        return await sessionLabel(id)
    }

    func sessionLabel(_ id: UUID) async -> String {
        await MainActor.run {
            let workspace = AgentWorkspaceUIModel.shared.workspace
            guard let session = workspace.sessions.first(where: { $0.id == id }) else { return id.uuidString }
            let project = workspace.projects.first(where: { $0.id == session.projectID })?.name ?? "?"
            return "\(project)/\(session.title)"
        }
    }

    func audit(_ actor: ChatsControlActor, method: String, target: String?, outcome: String, prompt: String?) async {
        let verified: Bool
        let label: String
        if let idString = actor.sessionID, let id = UUID(uuidString: idString) {
            verified = AgentSessionTokenRegistry.shared.verify(sessionID: id, token: actor.token)
            label = verified ? await sessionLabel(id) : "unverified"
        } else {
            verified = false
            label = "external"
        }
        auditLog.append(ChatsAuditEntry(
            at: Date(), actor: label, verified: verified, method: method, target: target,
            outcome: outcome, promptChars: prompt?.count,
            promptHead: prompt.map(ChatsAuditLog.promptHead)))
    }

    // MARK: - Outcome-Typen

    enum SendOutcome {
        case success(AgentChatSession)
        case failure(ChatsControlErrorCode, String)
    }

    private enum MutationOutcome {
        case success(before: String, after: String)
        case failure(ChatsControlErrorCode, String)
    }
}
