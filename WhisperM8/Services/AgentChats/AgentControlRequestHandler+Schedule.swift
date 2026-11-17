import Foundation

// MARK: - schedule.* (`whisperm8 schedule add|edit|remove|run|pause|resume`)

/// Geplante Aufgaben ändern (WM8-110). Die App ist einziger Schreiber von
/// `scheduled-tasks.json`; die CLI liest `list` und `show` selbst von Disk und
/// schickt nur Änderungen hierher. Auftragstexte stehen nie im Audit-Log.
extension AgentControlRequestHandler {
    static let scheduleMethods: Set<String> = [
        "schedule.add", "schedule.edit", "schedule.remove", "schedule.run", "schedule.pause", "schedule.resume",
    ]

    func scheduleRequest(_ request: ChatsControlRequest) async -> ChatsControlResponse {
        let scheduler = await MainActor.run { () -> ScheduledTaskScheduler? in
            let runtime = ScheduledTaskRuntime.shared
            guard AppPreferences.shared.isScheduledTasksEnabled else { return nil }
            // Per `defaults write` eingeschaltet, ohne die Einstellungsseite: jetzt starten.
            if !runtime.isRunning { runtime.start() }
            return runtime.scheduler
        }
        guard let scheduler else {
            return .failure(requestID: request.requestID, code: .unsupported,
                            message: ScheduledTaskScheduler.SchedulerError.disabled.localizedDescription)
        }
        let response = await Self.scheduleResponse(request, scheduler: scheduler)
        let target = request.params["id"]?.stringValue ?? "neu"
        await audit(request.actor, method: request.method, target: target,
                    outcome: response.ok ? "ok" : (response.error?.code ?? "error"), prompt: nil)
        if response.ok {
            await MainActor.run { ScheduledTaskRuntime.shared.tick(reason: "cli") }
        }
        return response
    }

    /// Ohne Laufzeit-Singletons, damit Tests einen Planer mit Attrappen geben.
    static func scheduleResponse(_ request: ChatsControlRequest, scheduler: ScheduledTaskScheduler) async -> ChatsControlResponse {
        let id = request.params["id"]?.stringValue.flatMap(UUID.init(uuidString:))
        do {
            switch request.method {
            case "schedule.add":
                let draft = try decodeDraft(request.params["draftJSON"]?.stringValue)
                return .success(requestID: request.requestID, result: taskResult(try await scheduler.add(draft)))
            case "schedule.edit":
                guard let id else { return missingID(request) }
                let draft = try decodeDraft(request.params["draftJSON"]?.stringValue)
                guard !draft.isEmpty else {
                    return .failure(requestID: request.requestID, code: .invalid, message: "Nichts zu ändern.")
                }
                return .success(requestID: request.requestID, result: taskResult(try await scheduler.edit(id: id, draft: draft)))
            case "schedule.remove":
                guard let id else { return missingID(request) }
                return .success(requestID: request.requestID, result: taskResult(try await scheduler.remove(id: id)))
            case "schedule.pause", "schedule.resume":
                guard let id else { return missingID(request) }
                let task = try await scheduler.setPaused(id: id, paused: request.method == "schedule.pause")
                return .success(requestID: request.requestID, result: taskResult(task))
            case "schedule.run":
                guard let id else { return missingID(request) }
                let record = try await scheduler.runNow(id: id)
                return .success(requestID: request.requestID, result: runResult(record))
            default:
                return .failure(requestID: request.requestID, code: .unsupported, message: "Unbekannte Methode: \(request.method)")
            }
        } catch let error as ScheduledTaskScheduler.SchedulerError {
            let code: ChatsControlErrorCode
            switch error {
            case .disabled, .notLeader: code = .unsupported
            case .notFound: code = .notFound
            case .invalid: code = .invalid
            case .conflict: code = .conflict
            case .storage: code = .internalError
            }
            return .failure(requestID: request.requestID, code: code, message: error.localizedDescription)
        } catch {
            return .failure(requestID: request.requestID, code: .invalid, message: error.localizedDescription)
        }
    }

    private static func missingID(_ request: ChatsControlRequest) -> ChatsControlResponse {
        .failure(requestID: request.requestID, code: .invalid, message: "id fehlt oder ist keine Aufgaben-ID.")
    }

    /// Der Entwurf kommt als JSON-Text: Über `ChatsControlJSON(any:)` würden
    /// Zahlen 0 und 1 (Minute, Wochentag) zu Wahrheitswerten.
    static func decodeDraft(_ text: String?) throws -> ScheduledTaskDraft {
        guard let text, !text.isEmpty else { return ScheduledTaskDraft() }
        return try ScheduledTaskStore.makeDecoder().decode(ScheduledTaskDraft.self, from: Data(text.utf8))
    }

    static func taskResult(_ task: ScheduledTask) -> ChatsControlJSON {
        .object([
            "id": task.id.uuidString.lowercased(),
            "shortID": task.shortID,
            "name": task.name,
            "schedule": task.schedule.text,
            "account": task.account,
            "directory": task.directory,
            "paused": task.paused,
        ])
    }

    static func runResult(_ record: ScheduledTaskRunRecord) -> ChatsControlJSON {
        var result: [String: Any] = [
            "runID": record.runID,
            "taskID": record.taskID.uuidString.lowercased(),
            "taskName": record.taskName,
            "started": record.notStarted == nil,
        ]
        if let sessionID = record.sessionID { result["sessionID"] = sessionID.uuidString.lowercased() }
        if let reason = record.notStarted { result["notStarted"] = reason.rawValue }
        if let message = record.message { result["message"] = message }
        return .object(result)
    }
}
