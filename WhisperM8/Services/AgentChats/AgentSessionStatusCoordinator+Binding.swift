import Foundation

// Bindung der externen Session-ID (Hook-SessionStart, Registry, übernommene
// Chats). Ausgelagert aus AgentSessionStatusCoordinator.swift, weil die Datei an
// die 1.500-Zeilen-Grenze kam (Vic, Gesamt-Review Teil 1, 13.11.2026); reine
// Verschiebung, verschobene Logik ist internal.
extension AgentSessionStatusCoordinator {
    // MARK: - Binding der externen Session-ID

    enum ExternalIDBindingDecision: Equatable {
        /// Neue ID sofort übernehmen.
        case bind
        /// Neue ID merken, erst beim ersten Turn-Event dieser ID übernehmen.
        case postpone
        /// Background-Fork einer bereits gebundenen Session — nie binden.
        case ignoreFork
        /// Nichts zu tun (ID schon gebunden).
        case unchanged
    }

    /// Pure Bindungs-Regel für `SessionStart`. Früher übernahm JEDES
    /// SessionStart blind die neue ID — Vorfall 2026-09-30 (Chat 06760440):
    /// Beim Umwandeln in einen Background-Agent meldet erst der bg-Fork
    /// (`source: fork`, eigene ID) und danach die frische, leere
    /// Vordergrund-Session der TUI (`source: startup`) ein SessionStart über
    /// dieselbe Settings-Datei. Die leere Session schreibt ohne Prompt nie
    /// ein Transcript — der Chat zeigte danach auf eine nicht existierende
    /// Datei und hatte seinen Verlauf „verloren".
    ///
    /// - Erstbindung (noch keine ID, auch WhisperM8-Forks) → sofort.
    /// - `fork` bei bereits gebundener ID kommt vom bg-Fork → ignorieren.
    ///   Früher „zurückstellen" — mit nur EINEM Pending-Platz überschrieb ein
    ///   nach der leeren Vordergrund-Session eintreffender Fork den Platz, und
    ///   sein erster Turn band den Chat an den Background-Agent (Review
    ///   2026-10-02: die Reihenfolge der beiden SessionStarts ist nicht
    ///   garantiert).
    /// - Bisherige ID ohne Transcript → nichts zu verlieren, sofort.
    /// - Neue ID mit Transcript (`/resume` in der TUI) → sofort.
    /// - Bisherige ID läuft laut Claudes Registry gerade in einem ANDEREN
    ///   Vordergrund-Prozess → sie war nie die eigene (Rückfall-Bindung an ein
    ///   fremdes Transcript, Befund 13.11.2026), sofort. Nur die Registry
    ///   entscheidet das, nicht eine zweite Bindung im Workspace: Alte
    ///   Doppel-Einträge gibt es dort viele, und beim echten Besitzer nach
    ///   `/background` muss die leere Session weiter zurückgestellt werden.
    /// - Sonst (`/clear`, leere Session nach `/background`) → zurückstellen,
    ///   bis die neue ID einen Turn zeigt.
    nonisolated static func externalIDBindingDecision(
        currentID: String?,
        newID: String,
        source: String?,
        newTranscriptExists: Bool,
        currentTranscriptExists: Bool,
        currentIDRunsInOtherProcess: Bool = false
    ) -> ExternalIDBindingDecision {
        guard let currentID, !currentID.isEmpty else { return .bind }
        if currentID == newID { return .unchanged }
        if source == "fork" { return .ignoreFork }
        if currentIDRunsInOtherProcess { return .bind }
        if !currentTranscriptExists { return .bind }
        if newTranscriptExists { return .bind }
        return .postpone
    }

    /// Führt ein lebender Vordergrund-Prozess außer dem eigenen die Sitzung?
    /// Hintergrund-Worker zählen nicht (`/background` gibt die Sitzung bewusst
    /// dorthin ab), ebenso Prozesse, die die App gerade beendet — wie in der
    /// Doppelstart-Sperre (`ClaudeSessionRunningGuard`). Ohne eigene PID lässt
    /// sich der eigene Prozess nicht ausnehmen — dann nie (der Registry-Cache
    /// kann den eigenen Prozess nach `/background` noch mit der alten ID führen).
    nonisolated static func runsInOtherForegroundProcess(
        sessionID: String,
        ownProcessID: Int32?,
        records: [ClaudeSessionRecord],
        isBeingTerminated: (Int32) -> Bool = { _ in false }
    ) -> Bool {
        guard !sessionID.isEmpty, let ownProcessID else { return false }
        return records.contains {
            !$0.isBackground && $0.pid != ownProcessID && !isBeingTerminated($0.pid)
                && $0.sessionID.caseInsensitiveCompare(sessionID) == .orderedSame
        }
    }

    // MARK: Bindung übernommener Chats (Bindungs-Befund, Punkt d)


    /// Gehört der Registry-Eintrag zum Prozess eines übernommenen Chats?
    func adoptedOwner(of record: ClaudeSessionRecord) -> UUID? {
        adoptedSessions.first { terminalProcessID($0) == record.pid }
    }

    /// Nach der Übernahme kennt Claudes Registry die Sitzung des Prozesses
    /// genau. Weicht die gespeicherte ID ab, gilt dieselbe Regel wie beim
    /// SessionStart: Läuft die gespeicherte ID in einem anderen
    /// Vordergrund-Prozess, war sie nie die eigene (Altlast der
    /// Rückfall-Bindung) und wird sofort ersetzt; sonst ist die neue ID wie nach
    /// `/clear` zurückgestellt und bindet mit dem ersten echten Turn. Eine
    /// Fork-ID bindet nie. `localID`, wenn der Eintrag jetzt zum Chat gehört.
    func reconcileAdoptedBinding(localID: UUID, record: ClaudeSessionRecord) -> UUID? {
        let currentID = store.loadWorkspace().sessions.first { $0.id == localID }?.externalSessionID
        if let currentID, currentID.caseInsensitiveCompare(record.sessionID) == .orderedSame { return localID }
        guard forkExternalIDs[localID]?.contains(record.sessionID) != true else { return nil }
        let runsElsewhere = currentID.map {
            Self.runsInOtherForegroundProcess(sessionID: $0, ownProcessID: record.pid,
                                              records: foregroundRecordsLookup($0),
                                              isBeingTerminated: { [isBeingTerminated] in isBeingTerminated($0, localID) })
        } ?? false
        if currentID?.isEmpty != false || runsElsewhere {
            pendingExternalIDs[localID] = nil
            Logger.claudeBinding.notice(
                "binding_adopted_corrected localID=\(localID.uuidString, privacy: .public) old=\(currentID ?? "nil", privacy: .public) new=\(record.sessionID, privacy: .public)")
            setExternalSessionID(localID: localID, newID: record.sessionID)
            return localID
        }
        pendingExternalIDs[localID] = record.sessionID
        return bindPendingExternalID(from: record) == nil ? nil : localID
    }

    /// Nimmt `id` aus der Fork-Merkliste des Chats (LR-AK-020).
    func releaseForkMark(localID: UUID, id: String) {
        guard forkExternalIDs[localID]?.contains(id) == true else { return }
        forkExternalIDs[localID]?.remove(id)
        if forkExternalIDs[localID]?.isEmpty == true { forkExternalIDs[localID] = nil }
    }

    func bindExternalSessionID(localID: UUID, event: ClaudeHookEvent) {
        guard let newID = event.sessionID, !newID.isEmpty else { return }
        let currentID = store.loadWorkspace().sessions
            .first(where: { $0.id == localID })?.externalSessionID
        let isReplacement = currentID.map { !$0.isEmpty && $0 != newID && event.source != "fork" } ?? false
        let runsElsewhere = isReplacement && Self.runsInOtherForegroundProcess(
            sessionID: currentID ?? "", ownProcessID: terminalProcessID(localID),
            records: foregroundRecordsLookup(currentID ?? ""),
            isBeingTerminated: { [isBeingTerminated] in isBeingTerminated($0, localID) })
        // Dateisystem nur befragen, wo die Regel es wirklich braucht.
        let needsFileCheck = isReplacement && !runsElsewhere
        let currentExists = needsFileCheck
            && transcriptExists(localID: localID, externalID: currentID ?? "", transcriptPath: nil)
        let newExists = currentExists
            && transcriptExists(localID: localID, externalID: newID, transcriptPath: event.transcriptPath)
        let decision = Self.externalIDBindingDecision(
            currentID: currentID,
            newID: newID,
            source: event.source,
            newTranscriptExists: newExists,
            currentTranscriptExists: currentExists,
            currentIDRunsInOtherProcess: runsElsewhere
        )
        if runsElsewhere, decision == .bind {
            Logger.claudeBinding.notice("binding_foreign_id_replaced localID=\(localID.uuidString, privacy: .public) foreign=\(currentID ?? "nil", privacy: .public) new=\(newID, privacy: .public)")
        }
        switch decision {
        case .unchanged:
            pendingExternalIDs[localID] = nil
        case .bind:
            pendingExternalIDs[localID] = nil
            setExternalSessionID(localID: localID, newID: newID)
        case .ignoreFork:
            forkExternalIDs[localID, default: []].insert(newID)
            if pendingExternalIDs[localID] == newID { pendingExternalIDs[localID] = nil }
            Logger.claudeBinding.notice("binding_fork_ignored localID=\(localID.uuidString, privacy: .public) fork=\(newID, privacy: .public)")
        case .postpone:
            guard forkExternalIDs[localID]?.contains(newID) != true else { return }
            pendingExternalIDs[localID] = newID
            Logger.claudeBinding.notice("binding_postponed localID=\(localID.uuidString, privacy: .public) current=\(currentID ?? "nil", privacy: .public) new=\(newID, privacy: .public) source=\(event.source ?? "nil", privacy: .public)")
        }
    }

    /// Zurückgestellte ID: übernehmen, sobald sie einen echten Turn zeigt
    /// (Prompt, Tool, Stop) — dann schreibt sie nachweislich ein Transcript.
    /// Endet sie vorher, wird sie verworfen.
    func resolvePendingBinding(localID: UUID, event: ClaudeHookEvent) {
        guard let pendingID = pendingExternalIDs[localID],
              event.sessionID == pendingID else { return }
        switch event.hookEventName {
        case .sessionEnd:
            pendingExternalIDs[localID] = nil
            forkExternalIDs[localID] = nil
            Logger.claudeBinding.info("binding_postponed_dropped localID=\(localID.uuidString, privacy: .public) id=\(pendingID, privacy: .public)")
        case .userPromptSubmit, .preToolUse, .postToolUse, .postToolUseFailure,
             .permissionRequest, .stop:
            pendingExternalIDs[localID] = nil
            setExternalSessionID(localID: localID, newID: pendingID)
        case .sessionStart, .notification, .other, .taskCreated, .taskCompleted:
            break
        }
    }

    func transcriptExists(localID: UUID, externalID: String, transcriptPath: String?) -> Bool {
        if let transcriptExistsOverride {
            return transcriptExistsOverride(localID, externalID, transcriptPath)
        }
        if let transcriptPath, FileManager.default.fileExists(atPath: transcriptPath) {
            return true
        }
        let workspace = store.loadWorkspace()
        guard let session = workspace.sessions.first(where: { $0.id == localID }),
              let project = workspace.projects.first(where: { $0.id == session.projectID }) else {
            return false
        }
        // Ohne Glob-Fallback: läuft auf dem MainActor, und der Glob listet
        // jeden Projekt-Ordner aller Profil-Roots (Review 2026-10-02). Stufe 1
        // deckt alle Profile ab; der Hook-Pfad oben den Rest.
        return AgentTranscriptLocator.locate(
            provider: .claude, externalSessionID: externalID, cwd: project.path,
            globFallback: false) != nil
    }

    func setExternalSessionID(localID: UUID, newID: String) {
        // Eine gebundene ID ist kein Fork mehr (LR-AK-020): bindet der Chat später
        // genau diese ID (`/resume` auf den Fork, Recovery), würden sonst alle ihre
        // Hooks verworfen.
        releaseForkMark(localID: localID, id: newID)
        do {
            var didChange = false
            try store.updateSession(id: localID) { session in
                let old = session.externalSessionID
                guard old != newID else { return }
                session.externalSessionID = newID
                didChange = true
                Logger.claudeBinding.info("binding_launch_id_set localID=\(localID.uuidString, privacy: .public) old=\(old ?? "nil", privacy: .public) new=\(newID, privacy: .public)")
            }
            if didChange {
                // Crash-safe: das Binding ist die wichtigste Einzelmutation —
                // geht es im Debounce-Fenster verloren, ist die Session nach
                // App-Tod eine unsichtbare Waise (Review-Befund 2026-07-13).
                store.flushNow(reason: "binding")
                terminalExternalIDUpdater(localID, newID)
                attachWatch(sessionID: localID)
                adoptRegistryRecord(sessionID: localID)
            }
        } catch {
            Logger.claudeBinding.warning("binding_launch_set_failed localID=\(localID.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }
}
