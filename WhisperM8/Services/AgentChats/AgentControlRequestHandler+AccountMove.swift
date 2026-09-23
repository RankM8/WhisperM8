import Darwin
import Foundation

// MARK: - session.moveAccount (`whisperm8 chats move-account`)

/// Konto-Umzug bestehender Chats ueber die CLI. Dieselbe Kette wie das
/// Kontextmenue „Zu Account verschieben": `AccountMoveFacts` sammelt die
/// Fakten, `AccountMovePlanner` entscheidet (identische Skip-Regeln),
/// `AccountMoveService` bewegt Transcript + Stempel und schreibt das Journal —
/// „Letzten Kontowechsel rückgängig machen" in der App nimmt einen CLI-Umzug
/// deshalb genauso zurueck.
///
/// `stopAndResume` erweitert NUR die Regel „läuft gerade": ein solcher Chat
/// wird angehalten (graceful wie `close --stop`), erst nach dem nachweislichen
/// Prozessende umgezogen und danach zum Neustart vorgemerkt. Geschuetzt
/// bleiben arbeitende Chats und Chats mit vermutlich ungesendetem Entwurf
/// (beide nur mit `force`) sowie die aufrufende Session (nie).
extension AgentControlRequestHandler {
    /// Ergebnis je angefragter Session — wird 1:1 zur JSON-Zeile.
    struct MoveAccountItem {
        var id: UUID
        var title: String?
        var project: String?
        var fromProfile: String?
        /// moved | wouldMove | skipped | failed | notFound
        var outcome: String
        /// Skip-Grund des Planers (`AccountMovePlanner.SkipReason.rawValue`)
        /// oder Fehlerart (`stopTimeout`, `moveFailed`, `projectPathMissing`).
        var reason: String?
        var reasonLabel: String?
        /// Wird (bzw. wuerde) angehalten, umgezogen und neu gestartet.
        var stopAndResume = false
        /// Nur „läuft gerade" steht im Weg — mit `--stop-and-resume` ginge es.
        var stopAndResumePossible = false
        /// Warum `--stop-and-resume` diesen laufenden Chat nicht anfasst.
        var stopBlocked: String?
        var movedTranscript: Bool?
        /// Neustart vorgemerkt (`shouldLaunchOnOpen`).
        var resumeScheduled = false

        var dictionary: [String: Any] {
            var dict: [String: Any] = [
                "id": id.uuidString,
                "outcome": outcome,
                "fromProfile": fromProfile ?? ClaudeAccountProfiles.mainProfileName,
                "stopAndResume": stopAndResume,
                "stopAndResumePossible": stopAndResumePossible,
                "resumeScheduled": resumeScheduled,
            ]
            if let title { dict["title"] = title }
            if let project { dict["project"] = project }
            if let reason { dict["reason"] = reason }
            if let reasonLabel { dict["reasonLabel"] = reasonLabel }
            if let stopBlocked { dict["stopBlocked"] = stopBlocked }
            if let movedTranscript { dict["movedTranscript"] = movedTranscript }
            return dict
        }
    }

    /// Zustand zwischen Planung (MainActor), Warten aufs Prozessende (off-main)
    /// und Ausfuehrung (MainActor).
    private struct MoveAccountPreparation {
        var targetName: String
        var target: String?
        var targetIsLoggedIn: Bool
        var requestedIDs: [UUID]
        /// Vorlaeufiges Ergebnis je ID — die Ausfuehrung ueberschreibt die
        /// Eintraege, die sie tatsaechlich anfasst.
        var items: [UUID: MoveAccountItem]
        /// Aus der Planung umziehbar (ohne Stop).
        var movableIDs: [UUID]
        /// Angehalten, mit PID fuer das Warten aufs Prozessende.
        var stopped: [(id: UUID, pid: pid_t?)]
    }

    private enum MoveAccountPhase {
        case fail(ChatsControlErrorCode, String)
        case ready(MoveAccountPreparation)
    }

    func sessionMoveAccount(_ request: ChatsControlRequest) async -> ChatsControlResponse {
        let rawIDs = request.params["targetSessionIDs"]?.arrayValue?.compactMap { $0.stringValue } ?? []
        let parsedIDs = rawIDs.compactMap(UUID.init(uuidString:))
        guard !rawIDs.isEmpty, parsedIDs.count == rawIDs.count else {
            return .failure(requestID: request.requestID, code: .invalid,
                            message: "targetSessionIDs fehlt/ungültig (Array von Session-UUIDs)")
        }
        guard let targetName = request.params["toProfile"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines), !targetName.isEmpty else {
            return .failure(requestID: request.requestID, code: .invalid, message: "toProfile fehlt")
        }
        let dryRun = request.params["dryRun"]?.boolValue ?? false
        let stopAndResume = request.params["stopAndResume"]?.boolValue ?? false
        let force = request.params["force"]?.boolValue ?? false
        guard !force || stopAndResume else {
            return .failure(requestID: request.requestID, code: .invalid,
                            message: "force nur zusammen mit stopAndResume")
        }
        var deduped: [UUID] = []
        for id in parsedIDs where !deduped.contains(id) { deduped.append(id) }
        let requestedIDs = deduped
        let actorID = request.actor.sessionID.flatMap(UUID.init(uuidString:))

        // Phase 1 — planen und (nur bei echter Ausfuehrung) anhalten. EIN
        // MainActor-Block: Laufzustand, Status und Stop sehen denselben Stand.
        let phase: MoveAccountPhase = await MainActor.run {
            let profiles = ClaudeAccountProfiles()
            let known = profiles.profiles().map(\.name)
            guard known.contains(targetName) else {
                return .fail(.notFound,
                             "Unbekanntes Claude-Konto „\(targetName)“ — vorhanden: \(known.joined(separator: ", "))")
            }
            let target = AccountMovePlanner.normalize(targetName)
            let targetIsLoggedIn = target == nil || profiles.profile(named: targetName).isLoggedIn

            let workspace = AgentWorkspaceUIModel.shared.workspace
            let registry = AgentTerminalRegistry.shared
            let statusStore = AgentSessionStatusCoordinator.shared.statusStore
            let projectNames = Dictionary(
                workspace.projects.map { ($0.id, $0.name) },
                uniquingKeysWith: { first, _ in first }
            )

            var items: [UUID: MoveAccountItem] = [:]
            var sessions: [AgentChatSession] = []
            for id in requestedIDs {
                guard let session = workspace.sessions.first(where: { $0.id == id }),
                      session.status != .archived else {
                    items[id] = MoveAccountItem(id: id, outcome: "notFound",
                                                reasonLabel: "Session nicht gefunden oder archiviert")
                    continue
                }
                sessions.append(session)
                items[id] = MoveAccountItem(
                    id: id, title: session.title, project: projectNames[session.projectID],
                    fromProfile: session.claudeProfileName, outcome: "skipped")
            }

            let plan = AccountMovePlanner.plan(
                candidates: AccountMoveFacts.candidates(
                    for: sessions, projects: workspace.projects, target: target,
                    profiles: profiles,
                    isRunning: { registry.controller(for: $0)?.isRunning == true }),
                targetProfile: target,
                targetIsLoggedIn: targetIsLoggedIn
            )
            // Auch ohne Flag auswerten: so kann die Vorschau sagen, welche
            // laufenden Chats `--stop-and-resume` mitnehmen wuerde.
            let selection = AccountMoveStopResumePlanner.select(
                plan: plan,
                force: stopAndResume && force,
                isCaller: { $0 == actorID },
                isWorking: { statusStore.status(for: $0) == .working },
                mayHaveUnsentInput: {
                    registry.controller(for: $0)?.composerDraft.mayHaveUnsentInput == true
                }
            )
            let stoppableIDs = Set(selection.toStop.map(\.sessionID))
            let blockedByID = Dictionary(
                selection.blocked.map { ($0.candidate.sessionID, $0.reason) },
                uniquingKeysWith: { first, _ in first }
            )

            for candidate in plan.movable {
                items[candidate.sessionID]?.outcome = "wouldMove"
            }
            for skip in plan.skipped {
                let id = skip.candidate.sessionID
                items[id]?.reason = skip.reason.rawValue
                items[id]?.reasonLabel = skip.reason.label
                if stopAndResume, stoppableIDs.contains(id) {
                    items[id]?.outcome = "wouldMove"
                    items[id]?.reason = nil
                    items[id]?.reasonLabel = nil
                    items[id]?.stopAndResume = true
                } else if stoppableIDs.contains(id) {
                    items[id]?.stopAndResumePossible = true
                } else if let blocked = blockedByID[id] {
                    items[id]?.stopBlocked = blocked.rawValue
                    if stopAndResume {
                        items[id]?.reasonLabel = "\(skip.reason.label) — \(blocked.label)"
                    }
                }
            }

            var stopped: [(id: UUID, pid: pid_t?)] = []
            if stopAndResume, !dryRun {
                let store = AgentSessionStore()
                for candidate in selection.toStop {
                    let id = candidate.sessionID
                    let pid = registry.controller(for: id)?.processID
                    // Graceful wie `close --stop`: 2× Ctrl+C, letzter Flush,
                    // dann SIGTERM. Der Tab bleibt offen.
                    registry.terminate(sessionID: id)
                    try? store.updateSession(id: id) { updated in
                        if updated.status == .running { updated.status = .closed }
                    }
                    stopped.append((id, pid))
                }
            }

            return .ready(MoveAccountPreparation(
                targetName: targetName, target: target, targetIsLoggedIn: targetIsLoggedIn,
                requestedIDs: requestedIDs, items: items,
                movableIDs: plan.movable.map(\.sessionID), stopped: stopped))
        }

        var preparation: MoveAccountPreparation
        switch phase {
        case .fail(let code, let message):
            await audit(request.actor, method: "move-account", target: targetName,
                        outcome: code.rawValue, prompt: nil)
            return .failure(requestID: request.requestID, code: code, message: message)
        case .ready(let ready):
            preparation = ready
        }

        if dryRun {
            return moveAccountResponse(request, preparation: preparation, dryRun: true)
        }

        // Phase 2 — aufs Prozessende warten (off-main). Erst ein beendeter
        // Prozess schreibt garantiert nicht mehr in die alte Datei.
        let exitedIDs: Set<UUID> = await withTaskGroup(of: UUID?.self) { group in
            for entry in preparation.stopped {
                group.addTask {
                    guard let pid = entry.pid else { return nil }
                    return await ProcessExitWaiter.waitForExit(pid: pid) ? entry.id : nil
                }
            }
            var exited: Set<UUID> = []
            for await id in group {
                if let id { exited.insert(id) }
            }
            return exited
        }
        for entry in preparation.stopped where !exitedIDs.contains(entry.id) {
            preparation.items[entry.id]?.outcome = "failed"
            preparation.items[entry.id]?.reason = "stopTimeout"
            preparation.items[entry.id]?.reasonLabel =
                "angehalten, aber der Prozess hat sich nicht beendet — nicht umgezogen, nicht neu gestartet; "
                + "bitte in der App prüfen"
        }

        // Phase 3 — frisch planen und ausfuehren. Frisch, weil zwischen
        // Phase 1 und hier Zeit vergangen ist (ein Chat kann wieder laufen,
        // im Ziel kann eine Datei aufgetaucht sein); der Service prueft die
        // Kollision beim Bewegen ohnehin noch einmal.
        let attemptIDs = preparation.movableIDs
            + preparation.stopped.map(\.id).filter { exitedIDs.contains($0) }
        let prepared = preparation
        let executed: [UUID: MoveAccountItem] = await MainActor.run {
            let workspace = AgentWorkspaceUIModel.shared.workspace
            let registry = AgentTerminalRegistry.shared
            let profiles = ClaudeAccountProfiles()
            let sessions = workspace.sessions.filter { attemptIDs.contains($0.id) }
            let targetIsLoggedIn = prepared.target == nil
                || profiles.profile(named: prepared.targetName).isLoggedIn
            let plan = AccountMovePlanner.plan(
                candidates: AccountMoveFacts.candidates(
                    for: sessions, projects: workspace.projects, target: prepared.target,
                    profiles: profiles,
                    isRunning: { registry.controller(for: $0)?.isRunning == true }),
                targetProfile: prepared.target,
                targetIsLoggedIn: targetIsLoggedIn
            )
            var results: [UUID: MoveAccountItem] = [:]
            for id in attemptIDs {
                guard var item = prepared.items[id] else { continue }
                if !sessions.contains(where: { $0.id == id }) {
                    item.outcome = "notFound"
                    item.reasonLabel = "Session während des Umzugs verschwunden"
                }
                results[id] = item
            }
            for skip in plan.skipped {
                results[skip.candidate.sessionID]?.outcome = "skipped"
                results[skip.candidate.sessionID]?.reason = skip.reason.rawValue
                results[skip.candidate.sessionID]?.reasonLabel = skip.reason.label
            }

            let built = AccountMoveFacts.moves(for: plan, sessions: sessions, projects: workspace.projects)
            for candidate in built.unresolved {
                results[candidate.sessionID]?.outcome = "failed"
                results[candidate.sessionID]?.reason = "projectPathMissing"
                results[candidate.sessionID]?.reasonLabel = "Projektpfad unbekannt"
            }
            let outcome = AccountMoveService().perform(built.moves)
            let movedByID = Dictionary(
                outcome.moved.map { ($0.sessionID, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            // `perform` arbeitet die Moves in Reihenfolge ab und haengt je
            // Fehlschlag genau einen Eintrag an — die Fehlschlaege sind also
            // die nicht bewegten Moves, in derselben Reihenfolge.
            let failedMoves = built.moves.filter { movedByID[$0.sessionID] == nil }
            for (move, failure) in zip(failedMoves, outcome.failed) {
                results[move.sessionID]?.outcome = "failed"
                results[move.sessionID]?.reason = "moveFailed"
                results[move.sessionID]?.reasonLabel = failure.message
            }
            for entry in outcome.moved {
                results[entry.sessionID]?.outcome = "moved"
                results[entry.sessionID]?.reason = nil
                results[entry.sessionID]?.reasonLabel = nil
                results[entry.sessionID]?.movedTranscript = entry.movedTranscript
            }

            // Neustart fuer ALLE angehaltenen und beendeten Chats — auch fuer
            // die, deren Umzug scheiterte: dann im bisherigen Konto, denn
            // gelaufen sind sie vorher auch. Mechanik wie `chats resume` bzw.
            // die Absturz-Wiederaufnahme: Start beim Anzeigen des Tabs.
            let store = AgentSessionStore()
            let windowStore = AgentWindowStore.shared
            for entry in prepared.stopped where exitedIDs.contains(entry.id) {
                let id = entry.id
                guard sessions.contains(where: { $0.id == id }),
                      registry.controller(for: id)?.isRunning != true else { continue }
                do {
                    try store.updateSession(id: id) { $0.shouldLaunchOnOpen = true }
                    if windowStore.windowID(containingTab: id) == nil {
                        windowStore.openTab(id, in: windowStore.primaryWindowID, select: false)
                    }
                    results[id]?.resumeScheduled = true
                } catch {
                    Logger.agentStore.warning(
                        "move_account_resume_flag_failed session=\(id.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                }
            }
            return results
        }
        for (id, item) in executed {
            preparation.items[id] = item
        }

        for id in preparation.requestedIDs {
            guard let item = preparation.items[id], item.outcome == "moved" else { continue }
            let label = [item.project, item.title].compactMap { $0 }.joined(separator: "/")
            let method = item.stopAndResume
                ? (force ? "move-account --stop-and-resume --force" : "move-account --stop-and-resume")
                : "move-account"
            await audit(request.actor, method: method,
                        target: "\(label) → \(preparation.targetName)", outcome: "ok", prompt: nil)
        }
        return moveAccountResponse(request, preparation: preparation, dryRun: false)
    }

    private func moveAccountResponse(
        _ request: ChatsControlRequest,
        preparation: MoveAccountPreparation,
        dryRun: Bool
    ) -> ChatsControlResponse {
        let items = preparation.requestedIDs.compactMap { preparation.items[$0] }
        func count(_ outcome: String) -> Int { items.filter { $0.outcome == outcome }.count }
        return .success(requestID: request.requestID, result: .object([
            "ok": true,
            "dryRun": dryRun,
            "toProfile": preparation.targetName,
            "targetLoggedIn": preparation.targetIsLoggedIn,
            "movedCount": count("moved"),
            "wouldMoveCount": count("wouldMove"),
            "skippedCount": count("skipped"),
            "failedCount": count("failed"),
            "journal": AccountMoveJournal.defaultFileURL().path,
            "results": items.map(\.dictionary),
        ]))
    }
}
