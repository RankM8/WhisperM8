import Foundation

struct AgentSessionStore {
    /// Geteilter In-Memory-Kern (P1): Alle Facade-Kopien mit derselben
    /// fileURL teilen sich über die Registry dieselbe Store-Instanz —
    /// Mutationen sind damit prozessweit serialisiert, Reads kommen aus dem
    /// Speicher.
    private let workspaceStore: AgentWorkspaceStore
    private let uiStateFileURL: URL

    init(fileURL: URL? = nil, uiStateFileURL: URL? = nil) {
        self.workspaceStore = AgentWorkspaceStoreRegistry.store(
            for: fileURL ?? AgentWorkspaceRepository.defaultFileURL()
        )
        self.uiStateFileURL = uiStateFileURL ?? Self.defaultUIStateFileURL()
    }

    /// Liest den aktuellen Stand aus dem Speicher — seit P1 KEIN Disk-Read
    /// mehr. Externe Manipulation der JSON nach dem ersten Zugriff ist damit
    /// unsichtbar (gewollt; es gibt keine externen Schreiber).
    func loadWorkspace() -> AgentWorkspace {
        workspaceStore.read { $0 }
    }

    func saveWorkspace(_ workspace: AgentWorkspace) throws {
        try workspaceStore.replace(workspace)
    }

    // MARK: - UI-State (Tab-Persistenz, Selection, Disclosure)

    /// Pfad fuer das UI-State-Sidecar — neben der Workspace-JSON in
    /// Application Support. Standalone-File damit Workspace-Schema-Aenderungen
    /// + UI-State-Aenderungen unabhaengig versioniert werden koennen.
    static func defaultUIStateFileURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WhisperM8", isDirectory: true)
            .appendingPathComponent("agent-ui-state.json")
    }

    /// Liest den UI-State von Disk. Bei fehlendem File: First-Load-Migration
    /// aus dem aktuellen Workspace, damit die Sidebar nach Deployment nicht
    /// ploetzlich leer ist. v1-Dateien werden auf das globale v2-Tab-Schema
    /// migriert. Garbage-Collection laeuft immer, auch bei vorhandenem
    /// File — entfernt stale UUIDs.
    func loadUIState() -> AgentUIState {
        // Workspace nur EINMAL lesen: migrate + prune brauchen denselben
        // Stand. (loadWorkspace() ist seit P1 In-Memory, aber kopiert den
        // Workspace-Struct unter Lock — 3x war unnötig.)
        let workspace = loadWorkspace()
        var state: AgentUIState
        var needsPersist = false
        if FileManager.default.fileExists(atPath: uiStateFileURL.path) {
            do {
                let data = try Data(contentsOf: uiStateFileURL)
                state = try JSONDecoder().decode(AgentUIState.self, from: data)
            } catch {
                Logger.debug("AgentUIState load failed: \(error.localizedDescription) — falling back to first-load migration")
                state = AgentUIState.initialMigration(from: workspace)
                needsPersist = true
            }
        } else {
            state = AgentUIState.initialMigration(from: workspace)
            needsPersist = true
        }
        // Eine noch nicht migrierte Datei (bzw. ein fehlender Sidecar) erzeugt
        // bei JEDEM Decode eine frische primaryWindowID. Würde das nicht sofort
        // persistiert, sähe jeder weitere loadUIState()-Aufruf eine andere
        // Primaerfenster-ID → divergierende Fenster-Identitaeten. Daher die
        // Migration einmalig festschreiben.
        if state.schemaVersion < AgentUIState.currentSchemaVersion {
            needsPersist = true
        }
        // v3→v4 übernimmt die bisherigen globalen @AppStorage-Splits in die
        // migrierten Workspace-Entities (0 = Key existiert nicht → Default).
        let legacyColumn = UserDefaults.standard.double(forKey: "agentGridColumnFraction")
        let legacyRow = UserDefaults.standard.double(forKey: "agentGridRowFraction")
        state.migrateIfNeeded(
            workspace: workspace,
            legacySplits: (
                column: legacyColumn > 0 ? legacyColumn : 0.5,
                row: legacyRow > 0 ? legacyRow : 0.5
            )
        )
        state.prune(workspace: workspace)
        // Jede tatsächliche Reparatur sofort festschreiben — Vergleich gegen
        // die KANONISCHE Re-Encodierung der Datei-Bytes (deterministisch:
        // wir schreiben selbst prettyPrinted+sortedKeys): Das erfasst auch
        // Decoder-Reparaturen, die einem `state != decoded`-Vergleich
        // entgingen, weil `init(from:)` bereits normalisiert (z. B. eine
        // fehlende Entity-ID, die sonst bei JEDEM Start neu erzeugt würde —
        // Review-Finding). Sonst würde dieselbe Normalisierung bei jedem
        // Start erneut erzeugt (und eine frische primaryWindowID pro Load
        // divergieren).
        let diskData = try? Data(contentsOf: uiStateFileURL)
        let canonical: Data? = {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return try? encoder.encode(state)
        }()
        if needsPersist || diskData == nil || canonical == nil || diskData != canonical {
            do {
                try saveUIState(state)
            } catch {
                // Nicht verschlucken (Review-Finding): loggen — der Store
                // persistiert bei der nächsten Mutation erneut; bis dahin
                // lebt der reparierte State im Speicher.
                Logger.debug("AgentUIState repair-save failed: \(error.localizedDescription)")
            }
        }
        return state
    }

    /// Atomisches Schreiben des UI-States. Wird vom AgentChatsView nach
    /// jeder State-Aenderung (debounced) aufgerufen.
    func saveUIState(_ state: AgentUIState) throws {
        try PerfBudgets.saveUIState.withInterval {
            try FileManager.default.createDirectory(
                at: uiStateFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(state)
            try data.write(to: uiStateFileURL, options: .atomic)
        }
    }

    func upsertProject(
        path: String,
        name: String? = nil,
        color: String? = nil,
        createdManually: Bool = false,
        touchUpdatedAt: Bool = false
    ) throws -> AgentProject {
        let standardizedPath = Self.canonicalProjectPath(path)
        // Git-Lookup VOR der Mutation — die Closure läuft unter dem
        // prozessweiten Store-Lock, dort darf kein Subprozess laufen.
        let branch = Self.currentGitBranch(at: standardizedPath)
        return try mutateWorkspace { workspace in
            if let index = workspace.projects.firstIndex(where: { $0.path == standardizedPath }) {
                var updated = workspace.projects[index]
                var changed = false
                if updated.lastBranch != branch {
                    updated.lastBranch = branch
                    changed = true
                }
                if createdManually, updated.createdManually != true {
                    updated.createdManually = true
                    changed = true
                }
                // Nur echte Chat-Erstellungen ziehen ein bestehendes Projekt
                // in der Recency-Sortierung nach oben. Indexer-/Merge-Treffer
                // bleiben dagegen vollständig idempotent.
                if changed || touchUpdatedAt {
                    updated.updatedAt = Date()
                    workspace.projects[index] = updated
                }
                return workspace.projects[index]
            }

            let project = AgentProject(
                name: name ?? URL(fileURLWithPath: standardizedPath).lastPathComponent,
                path: standardizedPath,
                color: color ?? AgentProjectColor.palette[workspace.projects.count % AgentProjectColor.palette.count],
                lastBranch: branch,
                createdManually: createdManually ? true : nil
            )
            workspace.projects.append(project)
            return project
        }
    }

    // MARK: - Project metadata mutators

    /// Generic Mutator analog zu `updateSession` — bewusst nicht `inout`-Closure
    /// Capture, damit der Aufrufer den Update als `(inout AgentProject) -> Void`
    /// reichen kann.
    func updateProject(id: UUID, _ update: (inout AgentProject) -> Void) throws {
        try mutateWorkspaceIfChanged { workspace in
            guard let index = workspace.projects.firstIndex(where: { $0.id == id }) else { return false }
            update(&workspace.projects[index])
            workspace.projects[index].updatedAt = Date()
            return true
        }
    }

    func renameProject(id: UUID, name: String) throws {
        try updateProject(id: id) { project in
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            project.name = trimmed
        }
    }

    func setProjectColor(id: UUID, color: String) throws {
        try updateProject(id: id) { project in
            let trimmed = color.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            project.color = trimmed
        }
    }

    /// Default-Context-Profil des Projekts (`nil` = kein Overlay). Nur die
    /// Referenz — die Profil-Definition lebt im `ClaudeContextProfileStore`.
    func setProjectContextProfile(id: UUID, profileID: UUID?) throws {
        try updateProject(id: id) { project in
            project.contextProfileID = profileID
        }
    }

    /// Vom User explizit ausgewähltes Icon (File-Picker auf ein Bild beliebiger
    /// Lage). Hat Vorrang vor `iconRelativePath`.
    func setProjectCustomIcon(id: UUID, absolutePath: String?) throws {
        try updateProject(id: id) { project in
            let trimmed = absolutePath?.trimmingCharacters(in: .whitespacesAndNewlines)
            project.customIconAbsolutePath = (trimmed?.isEmpty == false) ? trimmed : nil
        }
    }

    /// Vom Auto-Resolver gefundenes Icon im Projekt-Repo. `relativePath = nil`
    /// markiert nur, dass der Lookup gelaufen ist, aber nichts gefunden wurde —
    /// damit der nächste Workspace-Reload nicht erneut scannt.
    func applyAutoResolvedProjectIcon(id: UUID, relativePath: String?) throws {
        try updateProject(id: id) { project in
            project.iconRelativePath = relativePath
            project.iconAutoLookupAttempted = true
        }
    }

    /// Setzt den Lookup-Status zurück und entfernt beide Icon-Slots — Trigger
    /// für "Auto-Icon erneut erkennen".
    func clearProjectIcon(id: UUID) throws {
        try updateProject(id: id) { project in
            project.iconRelativePath = nil
            project.customIconAbsolutePath = nil
            project.iconAutoLookupAttempted = nil
        }
    }

    func upsertSession(_ session: AgentChatSession) throws -> AgentChatSession {
        try mutateWorkspace { workspace in
            if let index = workspace.sessions.firstIndex(where: { $0.id == session.id }) {
                workspace.sessions[index] = session
            } else {
                workspace.sessions.append(session)
            }
            return session
        }
    }

    func updateSession(id: UUID, _ update: (inout AgentChatSession) -> Void) throws {
        try mutateWorkspaceIfChanged { workspace in
            guard let index = workspace.sessions.firstIndex(where: { $0.id == id }) else { return false }
            let original = workspace.sessions[index]
            var updated = original
            update(&updated)
            guard updated != original else { return false }
            // Ein vom Aufrufer fachlich gesetzter Aktivitätszeitpunkt (etwa
            // aus Transcript-mtime) gewinnt gegenüber dem Komfort-Bump.
            if updated.lastActivityAt == original.lastActivityAt {
                updated.lastActivityAt = Date()
            }
            workspace.sessions[index] = updated
            return true
        }
    }

    /// Manuelle Umbenennung durch den Nutzer. Setzt `titleIsAutoGenerated = false`,
    /// damit der Auto-Namer den Namen nie wieder überschreibt.
    func renameSession(id: UUID, title: String) throws {
        try updateSession(id: id) { session in
            session.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            session.titleIsAutoGenerated = false
        }
    }

    /// Archiviert eine Session (User-Aktion „Archivieren"). Der Zeitstempel ist
    /// der primäre Sortier-Key des Archiv-Sheets — `lastActivityAt` taugt dafür
    /// nicht, weil `mergeIndexedSessions` es bei Re-Scans weiter bumpt.
    func archiveSession(id: UUID) throws {
        try updateSession(id: id) { session in
            session.status = .archived
            session.archivedAt = Date()
        }
    }

    /// Holt eine archivierte Session zurück: Status wird `.closed` (resumebar),
    /// der Archiv-Zeitstempel entfernt. `createdManually` bleibt unangetastet.
    /// Der automatische `lastActivityAt`-Bump von `updateSession` ist hier
    /// erwünscht — die Session soll sofort im „Zuletzt"-Scope auftauchen.
    func restoreSession(id: UUID) throws {
        try updateSession(id: id) { session in
            session.status = .closed
            session.archivedAt = nil
        }
    }

    /// Automatische Umbenennung durch den Auto-Namer. Wird nur ausgeführt, wenn
    /// die Session laut `canAutoRenameTitle` für Auto-Rename freigegeben ist —
    /// sonst no-op. Setzt `titleIsAutoGenerated = true`.
    func applyAutoGeneratedTitle(id: UUID, title: String) throws {
        try updateSession(id: id) { session in
            guard session.canAutoRenameTitle else { return }
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            session.title = trimmed
            session.titleIsAutoGenerated = true
        }
    }

    /// Persistiert eine (neu) generierte Session-Zusammenfassung — vom
    /// `AgentSessionSummarizer` (LLM) bzw. Report-Mapping (Subagents).
    func applySummary(id: UUID, summary: AgentSessionSummary) throws {
        try updateSession(id: id) { session in
            session.summary = summary
        }
    }

    /// Vom Runtime-Watcher beim Erkennen eines abgeschlossenen Agent-Turns gesetzt.
    /// Dient dem Auto-Namer als Vorbedingung („mindestens ein Turn ist gelaufen").
    func recordTurnEnded(id: UUID, at date: Date = Date()) throws {
        try updateSession(id: id) { session in
            session.lastTurnAt = date
        }
    }

    func setSessionGroup(id: UUID, groupName: String?) throws {
        try updateSession(id: id) { session in
            let normalized = groupName?.trimmingCharacters(in: .whitespacesAndNewlines)
            session.groupName = normalized?.isEmpty == false ? normalized : nil
        }
    }

    func setSessionColor(id: UUID, color: String?) throws {
        try updateSession(id: id) { session in
            let normalized = color?.trimmingCharacters(in: .whitespacesAndNewlines)
            session.color = normalized?.isEmpty == false ? normalized : nil
        }
    }

    /// Stempelt eine Session auf ein anderes Claude-Account-Profil um
    /// („Move to account"). NUR die Metadaten — das Transcript muss der
    /// Caller vorher via `ClaudeAccountProfiles.moveTranscript` verschieben,
    /// sonst zeigt der Stempel auf einen Root ohne Datei.
    func setClaudeSessionProfile(id: UUID, profileName: String?) throws {
        try updateSession(id: id) { session in
            session.claudeProfileName = profileName
        }
    }

    /// Zieht nach einem Profil-Rename die Stempel ALLER betroffenen Sessions
    /// nach — die Transcripts sind mit dem Verzeichnis bereits umgezogen,
    /// nur die Metadaten zeigen noch auf den alten Namen.
    func renameClaudeSessionProfiles(from oldName: String, to newName: String) throws {
        try mutateWorkspaceIfChanged { workspace in
            var changed = false
            for index in workspace.sessions.indices
            where workspace.sessions[index].claudeProfileName == oldName {
                workspace.sessions[index].claudeProfileName = newName
                changed = true
            }
            return changed
        }
    }

    // MARK: - Drag-and-Drop reordering

    /// Schreibt fortlaufende `sortIndex`-Werte (0…n-1) anhand der gegebenen
    /// Reihenfolge ALLER sichtbaren Projekte. Aufruf erfolgt nach einem
    /// Drag-and-Drop in der Sidebar — der UI-Layer übergibt die neue
    /// komplette Reihenfolge.
    func reorderProjects(orderedIDs: [UUID]) throws {
        try mutateWorkspace { workspace in
            for (newIndex, projectID) in orderedIDs.enumerated() {
                guard let idx = workspace.projects.firstIndex(where: { $0.id == projectID }) else { continue }
                guard workspace.projects[idx].sortIndex != newIndex else { continue }
                workspace.projects[idx].sortIndex = newIndex
                workspace.projects[idx].updatedAt = Date()
            }
        }
    }

    /// Schreibt fortlaufende `sortIndex`-Werte für die Sessions in einem
    /// Projekt anhand der gegebenen Reihenfolge. Andere Projekte bleiben
    /// unangetastet.
    func reorderSessions(in projectID: UUID, orderedIDs: [UUID]) throws {
        try mutateWorkspace { workspace in
            for (newIndex, sessionID) in orderedIDs.enumerated() {
                guard let idx = workspace.sessions.firstIndex(where: { $0.id == sessionID }),
                      workspace.sessions[idx].projectID == projectID else {
                    continue
                }
                guard workspace.sessions[idx].sortIndex != newIndex else { continue }
                workspace.sessions[idx].sortIndex = newIndex
                workspace.sessions[idx].lastActivityAt = Date()
            }
        }
    }

    /// Verschiebt eine Session in ein anderes Projekt und ordnet sie an der
    /// angegebenen Ziel-Position ein. Wenn `targetIndex == nil`, wird die
    /// Session ans Ende des Ziel-Projekts gehängt.
    func moveSessionToProject(
        sessionID: UUID,
        newProjectID: UUID,
        targetIndex: Int? = nil
    ) throws {
        try mutateWorkspace { workspace in
            guard let sessionIdx = workspace.sessions.firstIndex(where: { $0.id == sessionID }),
                  workspace.projects.contains(where: { $0.id == newProjectID }) else {
                return
            }

            workspace.sessions[sessionIdx].projectID = newProjectID
            workspace.sessions[sessionIdx].lastActivityAt = Date()

            // Neue Sortier-Reihenfolge im Ziel-Projekt aufbauen.
            let targetSessions = Self.sortedSessions(
                workspace.sessions.filter { $0.projectID == newProjectID && $0.status != .archived }
            )
            var ordered = targetSessions.filter { $0.id != sessionID }
            let clampedIndex = max(0, min(targetIndex ?? ordered.count, ordered.count))
            ordered.insert(workspace.sessions[sessionIdx], at: clampedIndex)

            for (newIndex, session) in ordered.enumerated() {
                if let idx = workspace.sessions.firstIndex(where: { $0.id == session.id }) {
                    workspace.sessions[idx].sortIndex = newIndex
                }
            }
        }
    }

    func moveSession(id: UUID, direction: AgentSessionMoveDirection) throws {
        try mutateWorkspace { workspace in
            guard let current = workspace.sessions.first(where: { $0.id == id }) else { return }
            let sorted = Self.sortedSessions(
                workspace.sessions.filter { $0.projectID == current.projectID && $0.status != .archived }
            )
            guard let currentSortedIndex = sorted.firstIndex(where: { $0.id == id }) else { return }

            let targetSortedIndex: Int
            switch direction {
            case .up:
                targetSortedIndex = max(0, currentSortedIndex - 1)
            case .down:
                targetSortedIndex = min(sorted.count - 1, currentSortedIndex + 1)
            }
            guard targetSortedIndex != currentSortedIndex else { return }

            var reordered = sorted
            reordered.swapAt(currentSortedIndex, targetSortedIndex)
            for (index, session) in reordered.enumerated() {
                if let workspaceIndex = workspace.sessions.firstIndex(where: { $0.id == session.id }) {
                    workspace.sessions[workspaceIndex].sortIndex = index
                    workspace.sessions[workspaceIndex].lastActivityAt = Date()
                }
            }
        }
    }

    /// Loescht eine Session aus dem Workspace. Idempotent — wenn die Session
    /// nicht existiert, passiert nichts. Wird z. B. aufgerufen wenn ein
    /// Background-Spawn fehlschlaegt: die Stub-Session ist ohne Short-ID
    /// nicht attachbar, also weg damit, statt einen "Session noch nicht
    /// gestartet"-Geist liegen zu lassen.
    func deleteSession(id: UUID) throws {
        try mutateWorkspaceIfChanged { workspace in
            guard let index = workspace.sessions.firstIndex(where: { $0.id == id }) else {
                return false
            }
            workspace.sessions.remove(at: index)
            return true
        }
        // Crash-safe: strukturelle Loeschung sofort persistieren (Review-
        // Befund 2026-07-13: Doku versprach das, der Code tat es nicht).
        workspaceStore.flush(reason: "delete-session")
        // Terminal-Snapshot-Sidecar mit entsorgen (I/O bewusst NACH der
        // Mutation, nie in der Closure).
        DispatchQueue.global(qos: .utility).async {
            TerminalSnapshotStore.shared.delete(sessionID: id)
        }
    }

    /// Entfernt ein Projekt samt all seiner Sessions aus dem Workspace.
    /// Bewusst NUR der WhisperM8-Workspace-Eintrag — das Repo auf der
    /// Festplatte und die externen Claude/Codex-Transcripts (`~/.claude`,
    /// `~/.codex`) bleiben unangetastet. Re-Importe durch spätere Scans
    /// landen als auto-importierte (nicht-manuelle) Sessions und tauchen
    /// daher nicht wieder in der Sidebar auf.
    func deleteProject(id: UUID) throws {
        // IDs VOR der Mutation einsammeln (reines Lesen), Snapshot-I/O danach.
        var removedSessionIDs: [UUID] = []
        try mutateWorkspaceIfChanged { workspace in
            let hasProject = workspace.projects.contains { $0.id == id }
            let hasSessions = workspace.sessions.contains { $0.projectID == id }
            guard hasProject || hasSessions else { return false }
            removedSessionIDs = workspace.sessions.filter { $0.projectID == id }.map(\.id)
            workspace.sessions.removeAll { $0.projectID == id }
            workspace.projects.removeAll { $0.id == id }
            return true
        }
        workspaceStore.flush(reason: "delete-project")
        if !removedSessionIDs.isEmpty {
            let ids = removedSessionIDs
            DispatchQueue.global(qos: .utility).async {
                TerminalSnapshotStore.shared.delete(sessionIDs: ids)
            }
        }
    }

    func markStaleRunningSessionsClosed(excluding activeSessionIDs: Set<UUID> = []) throws {
        try mutateWorkspaceIfChanged { workspace in
            var changed = false
            for index in workspace.sessions.indices where workspace.sessions[index].status == .running {
                guard workspace.sessions[index].shouldLaunchOnOpen != true else { continue }
                guard !activeSessionIDs.contains(workspace.sessions[index].id) else { continue }
                workspace.sessions[index].status = .closed
                changed = true
            }
            return changed
        }
    }

    @discardableResult
    func createSession(
        provider: AgentProvider,
        projectPath: String,
        title: String,
        // Aufgelöster Default ("auto" → konkreter Frontier-Slug): Sessions
        // persistieren immer ein konkretes Modell, historische Chats bleiben
        // auf ihrem damaligen Stand.
        model: String = AppPreferences.shared.resolvedCodexDefaultModelRaw(),
        reasoningEffort: String = AppPreferences.shared.codexReasoningEffortRaw,
        externalSessionID: String? = nil,
        initialPrompt: String? = nil,
        imagePaths: [String] = [],
        shouldLaunchOnOpen: Bool = false,
        createdManually: Bool = true,
        kind: AgentSessionKind? = nil,
        backgroundShortID: String? = nil,
        backgroundSubAgent: String? = nil,
        backgroundPermissionMode: String? = nil,
        forkSourceSessionID: String? = nil,
        claudeProfileName: String? = nil,
        claudeBackendModel: String? = nil,
        contextProfileID: UUID? = nil
    ) throws -> AgentChatSession {
        let project = try upsertProject(
            path: projectPath,
            createdManually: createdManually,
            touchUpdatedAt: true
        )
        let session = AgentChatSession(
            provider: provider,
            projectID: project.id,
            externalSessionID: externalSessionID,
            title: title,
            model: model,
            reasoningEffort: reasoningEffort,
            initialPrompt: initialPrompt,
            imagePaths: imagePaths,
            shouldLaunchOnOpen: shouldLaunchOnOpen,
            createdManually: createdManually ? true : nil,
            kind: kind,
            backgroundShortID: backgroundShortID,
            backgroundSubAgent: backgroundSubAgent,
            backgroundPermissionMode: backgroundPermissionMode,
            forkSourceSessionID: forkSourceSessionID,
            claudeProfileName: claudeProfileName,
            claudeBackendModel: claudeBackendModel,
            contextProfileID: contextProfileID
        )
        let stored = try upsertSession(session)
        // Crash-safe: strukturelle Erstellung SOFORT persistieren statt auf den
        // 0,5-s-Debounce zu warten — sonst Verlust bei Crash/Force-Quit/kill im
        // Zeitfenster. Siehe docs/archive/agent-chats-redesign/01-chat-persistenz-datenverlust.md
        Logger.agentStore.notice("session_created id=\(stored.id.uuidString, privacy: .public) provider=\(provider.rawValue, privacy: .public)")
        workspaceStore.flush(reason: "create")
        return stored
    }

    /// Setzt die vom Supervisor zurueckgegebene Short-ID nachtraeglich auf
    /// eine `.backgroundChat`-Session. Wird vom Spawn-Flow benutzt, sobald
    /// `BackgroundAgentSpawner.spawn(...)` zurueckkehrt — vorher existiert
    /// die ID nicht.
    func setBackgroundShortID(localSessionID: UUID, shortID: String) throws {
        try mutateWorkspaceIfChanged { workspace in
            guard let index = workspace.sessions.firstIndex(where: { $0.id == localSessionID }) else {
                return false
            }
            let trimmed = shortID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return false }
            if workspace.sessions[index].backgroundShortID == trimmed {
                return false
            }
            workspace.sessions[index].backgroundShortID = trimmed
            workspace.sessions[index].lastActivityAt = Date()
            return true
        }
        // Crash-safe: ohne persistierte Short-ID ist der Background-Agent
        // nach einem App-Tod nicht mehr attachbar — sofort sichern.
        workspaceStore.flush(reason: "background-short-id")
    }

    /// Erzwingt einen sofortigen Persist (Debounce-Bypass) — fuer Mutationen,
    /// deren Verlust bei Crash strukturell schadet (Binding, Launch-Flag).
    /// No-op, wenn nichts dirty ist.
    func flushNow(reason: String) {
        workspaceStore.flush(reason: reason)
    }

    @discardableResult
    func bindLatestIndexedSession(
        localSessionID: UUID,
        provider: AgentProvider,
        projectPath: String,
        indexedSessions: [IndexedAgentSession]
    ) throws -> AgentChatSession? {
        guard !Self.isClaudeWorktreePath(projectPath) else { return nil }
        let bound: AgentChatSession? = try mutateWorkspace { workspace in
            guard let index = workspace.sessions.firstIndex(where: { $0.id == localSessionID }) else {
                return nil
            }

            // Terminals binden NIE eine externe Session — ihr Provider ist
            // nur Schema-Platzhalter; das Matching unten (Provider + cwd +
            // ±5s) würde sonst eine fremde Claude-/Codex-Session kapern.
            guard !workspace.sessions[index].isTerminal else {
                return nil
            }

            guard workspace.sessions[index].externalSessionID == nil else {
                return workspace.sessions[index]
            }

            let standardizedPath = Self.canonicalProjectPath(projectPath)
            let createdAt = workspace.sessions[index].createdAt
            guard let indexed = indexedSessions
                .filter({
                    $0.provider == provider
                        && !Self.isClaudeWorktreePath($0.cwd)
                        && Self.canonicalProjectPath($0.cwd) == standardizedPath
                        && $0.createdAt >= createdAt.addingTimeInterval(-5)
                })
                .sorted(by: { $0.lastActivityAt > $1.lastActivityAt })
                .first
            else {
                return nil
            }

            workspace.sessions[index].externalSessionID = indexed.externalSessionID
            workspace.sessions[index].lastActivityAt = max(indexed.lastActivityAt, workspace.sessions[index].lastActivityAt)
            if workspace.sessions[index].title.hasSuffix(" Chat") || workspace.sessions[index].title.isEmpty {
                workspace.sessions[index].title = indexed.title
            }
            return workspace.sessions[index]
        }
        // Crash-safe: frisch gebundene externe ID sofort persistieren.
        if bound?.externalSessionID != nil {
            workspaceStore.flush(reason: "binding")
        }
        return bound
    }

    @discardableResult
    func repairResumeStateBeforeLaunch(
        localSessionID: UUID,
        projectPath: String,
        indexedSessions: [IndexedAgentSession],
        now: Date = Date()
    ) throws -> AgentResumeRepairResult? {
        try mutateWorkspace { workspace in
            guard let index = workspace.sessions.firstIndex(where: { $0.id == localSessionID }) else {
                return nil
            }

            let session = workspace.sessions[index]
            guard session.provider == .claude,
                  session.hasLaunchedInitialPrompt,
                  let currentExternalID = session.externalSessionID,
                  !currentExternalID.isEmpty else {
                return AgentResumeRepairResult(session: session, outcome: .unchanged)
            }

            let canonicalProjectPath = Self.canonicalProjectPath(projectPath)
            let indexedForProject = indexedSessions.filter { indexed in
                indexed.provider == session.provider
                    && !Self.isClaudeWorktreePath(indexed.cwd)
                    && Self.canonicalProjectPath(indexed.cwd) == canonicalProjectPath
            }

            if indexedForProject.contains(where: { $0.externalSessionID == currentExternalID }) {
                return AgentResumeRepairResult(session: session, outcome: .unchanged)
            }

            if let replacement = Self.bestResumeReplacement(
                for: session,
                currentExternalID: currentExternalID,
                indexedSessions: indexedForProject,
                now: now
            ) {
                workspace.sessions[index].externalSessionID = replacement.externalSessionID
                workspace.sessions[index].lastActivityAt = max(
                    replacement.lastActivityAt,
                    workspace.sessions[index].lastActivityAt
                )
                if workspace.sessions[index].title.hasSuffix(" Chat") || workspace.sessions[index].title.isEmpty {
                    workspace.sessions[index].title = replacement.title
                }
                return AgentResumeRepairResult(
                    session: workspace.sessions[index],
                    outcome: .rebound(from: currentExternalID, to: replacement.externalSessionID)
                )
            }

            // KEIN destruktiver Reset mehr (Review-Befund 2026-07-13): Negative
            // Evidenz (Transcript gerade nicht auffindbar — kann auch ein
            // transienter I/O-/Mount-/Rechte-Fehler sein) darf die Bindung
            // NICHT löschen. externalSessionID/hasLaunchedInitialPrompt bleiben
            // erhalten; nur Auto-Launch wird entschärft. Der Caller stoppt den
            // Launch mit sichtbarer Meldung — taucht das Transcript wieder auf,
            // resumed der nächste Start ganz normal.
            workspace.sessions[index].shouldLaunchOnOpen = false
            return AgentResumeRepairResult(
                session: workspace.sessions[index],
                outcome: .resetInvalid(currentExternalID)
            )
        }
    }

    private struct ExternalSessionKey: Hashable {
        var provider: AgentProvider
        var externalSessionID: String
    }

    private struct AdoptionKey: Hashable {
        var provider: AgentProvider
        var projectID: UUID
    }

    /// Pro Provider/Projekt sortierter Pool ungebundener Starts. Ein Fenwick-
    /// Baum hält die noch verfügbaren Zeitstempel; Vorgänger/Nachfolger und
    /// Verbrauch kosten damit O(log n), auch wenn viele parallele Starts im
    /// selben Projekt liegen.
    private final class AdoptionCandidatePool {
        private let timestamps: [TimeInterval]
        private let indicesByTimestamp: [[Int]]
        private var consumedByTimestamp: [Int]
        private var remainingTree: [Int]

        init(candidates: [(index: Int, createdAt: Date)]) {
            var grouped: [TimeInterval: [Int]] = [:]
            for candidate in candidates {
                grouped[candidate.createdAt.timeIntervalSinceReferenceDate, default: []]
                    .append(candidate.index)
            }
            timestamps = grouped.keys.sorted()
            indicesByTimestamp = timestamps.map { grouped[$0] ?? [] }
            consumedByTimestamp = Array(repeating: 0, count: timestamps.count)
            remainingTree = Array(repeating: 0, count: timestamps.count + 1)
            for (position, indices) in indicesByTimestamp.enumerated() {
                addRemaining(indices.count, at: position)
            }
        }

        func takeNearest(to createdAt: Date) -> Int? {
            guard !timestamps.isEmpty else { return nil }
            let target = createdAt.timeIntervalSinceReferenceDate
            let insertion = lowerBound(for: target)
            let beforeCount = remainingCount(before: insertion)
            let total = remainingCount(before: timestamps.count)
            let previousPosition = beforeCount > 0
                ? position(ofRemainingOrder: beforeCount)
                : nil
            let nextPosition = beforeCount < total
                ? position(ofRemainingOrder: beforeCount + 1)
                : nil

            let validPositions = [previousPosition, nextPosition]
                .compactMap { $0 }
                .filter { abs(timestamps[$0] - target) <= 5 }
            guard let selectedPosition = validPositions.min(by: { lhs, rhs in
                let leftDistance = abs(timestamps[lhs] - target)
                let rightDistance = abs(timestamps[rhs] - target)
                if leftDistance != rightDistance {
                    return leftDistance < rightDistance
                }
                return currentIndex(at: lhs) < currentIndex(at: rhs)
            }) else {
                return nil
            }

            let selectedIndex = currentIndex(at: selectedPosition)
            consumedByTimestamp[selectedPosition] += 1
            addRemaining(-1, at: selectedPosition)
            return selectedIndex
        }

        private func currentIndex(at position: Int) -> Int {
            indicesByTimestamp[position][consumedByTimestamp[position]]
        }

        private func lowerBound(for value: TimeInterval) -> Int {
            var lower = 0
            var upper = timestamps.count
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                if timestamps[middle] < value {
                    lower = middle + 1
                } else {
                    upper = middle
                }
            }
            return lower
        }

        private func remainingCount(before end: Int) -> Int {
            var index = end
            var result = 0
            while index > 0 {
                result += remainingTree[index]
                index -= index & -index
            }
            return result
        }

        private func position(ofRemainingOrder order: Int) -> Int {
            var treeIndex = 0
            var accumulated = 0
            var step = 1
            while step < remainingTree.count {
                step <<= 1
            }
            while step > 0 {
                let next = treeIndex + step
                if next < remainingTree.count,
                   accumulated + remainingTree[next] < order {
                    treeIndex = next
                    accumulated += remainingTree[next]
                }
                step >>= 1
            }
            return treeIndex
        }

        private func addRemaining(_ delta: Int, at position: Int) {
            var index = position + 1
            while index < remainingTree.count {
                remainingTree[index] += delta
                index += index & -index
            }
        }
    }

    private static func takeAdoptionCandidate(
        for key: AdoptionKey,
        createdAt: Date,
        pools: [AdoptionKey: AdoptionCandidatePool]
    ) -> Int? {
        pools[key]?.takeNearest(to: createdAt)
    }

    func mergeIndexedSessions(_ indexedSessions: [IndexedAgentSession]) throws {
        _ = try mergeIndexedSessions(indexedSessions, closingStaleExcluding: nil)
    }

    /// Atomarer Scan-Commit: Statuskorrektur und Index-Merge teilen dieselbe
    /// Store-Mutation. Dadurch entstehen höchstens eine Workspace-Publikation
    /// und ein Persist-Debounce-Burst.
    @discardableResult
    func applyIndexedScan(
        _ indexedSessions: [IndexedAgentSession],
        activeSessionIDs: Set<UUID>
    ) throws -> AgentSessionMergeStats {
        try mergeIndexedSessions(
            indexedSessions,
            closingStaleExcluding: activeSessionIDs
        )
    }

    private func mergeIndexedSessions(
        _ indexedSessions: [IndexedAgentSession],
        closingStaleExcluding activeSessionIDs: Set<UUID>?
    ) throws -> AgentSessionMergeStats {
        // Git-Lookups VOR der Mutation (kein Subprozess unter dem Store-Lock):
        // Branches nur für Pfade berechnen, zu denen noch kein Projekt
        // existiert. TOCTOU ist harmlos — taucht das Projekt zwischenzeitlich
        // auf, bleibt der vorberechnete Branch einfach ungenutzt.
        let knownPaths = Set(loadWorkspace().projects.map(\.path))
        var branchByPath: [String: String?] = [:]
        for indexed in indexedSessions where !Self.isClaudeWorktreePath(indexed.cwd) {
            let path = Self.canonicalProjectPath(indexed.cwd)
            if !knownPaths.contains(path), branchByPath.index(forKey: path) == nil {
                branchByPath[path] = Self.currentGitBranch(at: path)
            }
        }

        // Vor der Mutation auflösen ("auto" → Katalog-Datei-Stat/-Parse):
        // Mutation-Closures laufen unter dem Store-Lock und dürfen kein
        // blockierendes I/O machen — gleiches Hoisting wie branchByPath oben.
        let fallbackModelRaw = AppPreferences.shared.resolvedCodexDefaultModelRaw()
        let fallbackEffortRaw = AppPreferences.shared.codexReasoningEffortRaw
        var stats = AgentSessionMergeStats()

        try PerfBudgets.indexMerge.withInterval {
            try mutateWorkspaceIfChanged { workspace in
                let projectCountBeforeMaintenance = workspace.projects.count
                let sessionCountBeforeMaintenance = workspace.sessions.count
                Self.removeClaudeWorktreeProjectsAndSessions(from: &workspace)
                Self.removeUnresumableClaudeSessions(from: &workspace)
                var didChange = workspace.projects.count != projectCountBeforeMaintenance
                    || workspace.sessions.count != sessionCountBeforeMaintenance
                if let activeSessionIDs {
                    for index in workspace.sessions.indices
                    where workspace.sessions[index].status == .running {
                        guard workspace.sessions[index].shouldLaunchOnOpen != true else { continue }
                        guard !activeSessionIDs.contains(workspace.sessions[index].id) else { continue }
                        workspace.sessions[index].status = .closed
                        stats.closedStaleSessions += 1
                        didChange = true
                    }
                }

                // Alle globalen Lookups einmalig aufbauen. Bei beschädigten
                // Duplikaten bleibt jeweils der erste Workspace-Eintrag maßgeblich
                // — exakt wie zuvor bei `first(where:)`/`firstIndex(where:)`.
                var projectIndexByPath: [String: Int] = [:]
                for index in workspace.projects.indices {
                    let path = workspace.projects[index].path
                    if projectIndexByPath[path] == nil {
                        projectIndexByPath[path] = index
                    }
                }
                var sessionIndexByExternalKey: [ExternalSessionKey: Int] = [:]
                var adoptionCandidatesByKey: [AdoptionKey: [(index: Int, createdAt: Date)]] = [:]
                for index in workspace.sessions.indices {
                    let session = workspace.sessions[index]
                    if let externalSessionID = session.externalSessionID {
                        let key = ExternalSessionKey(
                            provider: session.provider,
                            externalSessionID: externalSessionID
                        )
                        if sessionIndexByExternalKey[key] == nil {
                            sessionIndexByExternalKey[key] = index
                        }
                    } else if session.effectiveKind != .terminal,
                              session.hasLaunchedInitialPrompt {
                        let key = AdoptionKey(
                            provider: session.provider,
                            projectID: session.projectID
                        )
                        adoptionCandidatesByKey[key, default: []].append(
                            (index: index, createdAt: session.createdAt)
                        )
                    }
                }
                let adoptionPoolsByKey = adoptionCandidatesByKey.mapValues {
                    AdoptionCandidatePool(candidates: $0)
                }

                // Subagent-Jobs besitzen ihre Codex-Session exklusiv: der Scan
                // findet deren Rollout-JSONL auch in ~/.codex/sessions und würde
                // sie sonst duplizieren oder aufs Job-cwd-Projekt umhängen.
                // Bewusst ALLE .subagentJob-Sessions (nicht nur aktive) — auch
                // nach Übernahme/rm-Zwischenzuständen bleibt die Zuordnung.
                let subagentThreadIDs = Set(
                    workspace.sessions
                        .filter { $0.isSubagentJob }
                        .compactMap(\.externalSessionID)
                )
                // Duplikat-Schutz (Review-Befund 2026-07-13): dieselbe
                // externalSessionID kann in MEHREREN Roots liegen (extern
                // kopierte Transcripts). Ohne Dedup ueberschriebe der Merge
                // denselben Datensatz in Scan-Reihenfolge mehrfach — Stempel-
                // Flip-Flop und Dauer-Persistenz. Bevorzugt wird der Kandidat,
                // dessen Root zum vorhandenen Stempel passt (Stabilitaet),
                // sonst die juengste Aktivitaet.
                var chosenByKey: [ExternalSessionKey: IndexedAgentSession] = [:]
                var duplicateKeys = Set<ExternalSessionKey>()
                for indexed in indexedSessions {
                    let key = ExternalSessionKey(
                        provider: indexed.provider,
                        externalSessionID: indexed.externalSessionID
                    )
                    guard let existing = chosenByKey[key] else {
                        chosenByKey[key] = indexed
                        continue
                    }
                    duplicateKeys.insert(key)
                    let stamp = sessionIndexByExternalKey[key].flatMap {
                        workspace.sessions[$0].claudeProfileName
                    }
                    if existing.claudeProfileName == stamp, indexed.claudeProfileName != stamp {
                        // existing behalten
                    } else if indexed.claudeProfileName == stamp, existing.claudeProfileName != stamp {
                        chosenByKey[key] = indexed
                    } else if indexed.lastActivityAt > existing.lastActivityAt {
                        chosenByKey[key] = indexed
                    }
                }
                stats.duplicateKeys = duplicateKeys.count
                for key in duplicateKeys {
                    let description = "\(key.provider.rawValue)|\(key.externalSessionID)"
                    Logger.agentStore.warning("agent_index_duplicate_session key=\(description, privacy: .public) — Transcript liegt in mehreren Roots, Merge nutzt einen stabilen Kandidaten")
                }
                var emittedKeys = Set<ExternalSessionKey>()
                let dedupedSessions = indexedSessions.compactMap { indexed -> IndexedAgentSession? in
                    let key = ExternalSessionKey(
                        provider: indexed.provider,
                        externalSessionID: indexed.externalSessionID
                    )
                    guard chosenByKey[key] == indexed, emittedKeys.insert(key).inserted else { return nil }
                    return indexed
                }
                for indexed in dedupedSessions {
                    guard !Self.isClaudeWorktreePath(indexed.cwd) else { continue }
                    guard !subagentThreadIDs.contains(indexed.externalSessionID) else { continue }
                    let projectPath = Self.canonicalProjectPath(indexed.cwd)
                    let project: AgentProject
                    if let projectIndex = projectIndexByPath[projectPath] {
                        project = workspace.projects[projectIndex]
                    } else {
                        project = AgentProject(
                            name: URL(fileURLWithPath: projectPath).lastPathComponent,
                            path: projectPath,
                            color: AgentProjectColor.palette[workspace.projects.count % AgentProjectColor.palette.count],
                            lastBranch: branchByPath[projectPath] ?? nil
                        )
                        workspace.projects.append(project)
                        projectIndexByPath[projectPath] = workspace.projects.count - 1
                        didChange = true
                    }

                    let externalKey = ExternalSessionKey(
                        provider: indexed.provider,
                        externalSessionID: indexed.externalSessionID
                    )
                    if let index = sessionIndexByExternalKey[externalKey] {
                        stats.updates += 1
                        if workspace.sessions[index].projectID != project.id {
                            workspace.sessions[index].projectID = project.id
                            didChange = true
                        }
                        if workspace.sessions[index].lastActivityAt != indexed.lastActivityAt {
                            workspace.sessions[index].lastActivityAt = indexed.lastActivityAt
                            didChange = true
                        }
                        if workspace.sessions[index].title.isEmpty,
                           workspace.sessions[index].title != indexed.title {
                            workspace.sessions[index].title = indexed.title
                            didChange = true
                        }
                        // Stempel-Selbstheilung: der Indexer kennt den REALEN
                        // Ablageort des Transcripts (main- vs. Profil-Root).
                        // Weicht der gespeicherte Account-Stempel davon ab, liefe
                        // ein Resume unterm falschen CLAUDE_CONFIG_DIR („No
                        // conversation found") — die Platte gewinnt.
                        if indexed.provider == .claude,
                           workspace.sessions[index].claudeProfileName != indexed.claudeProfileName {
                            workspace.sessions[index].claudeProfileName = indexed.claudeProfileName
                            didChange = true
                        }
                    } else if let index = Self.takeAdoptionCandidate(
                        for: AdoptionKey(
                            provider: indexed.provider,
                            projectID: project.id
                        ),
                        createdAt: indexed.createdAt,
                        pools: adoptionPoolsByKey
                    ) {
                        stats.adoptions += 1
                        didChange = true
                        if workspace.sessions[index].externalSessionID != indexed.externalSessionID {
                            workspace.sessions[index].externalSessionID = indexed.externalSessionID
                        }
                        sessionIndexByExternalKey[externalKey] = index
                        let mergedLastActivityAt = max(
                            indexed.lastActivityAt,
                            workspace.sessions[index].lastActivityAt
                        )
                        if workspace.sessions[index].lastActivityAt != mergedLastActivityAt {
                            workspace.sessions[index].lastActivityAt = mergedLastActivityAt
                        }
                        if (workspace.sessions[index].title.hasSuffix(" Chat") || workspace.sessions[index].title.isEmpty),
                           workspace.sessions[index].title != indexed.title {
                            workspace.sessions[index].title = indexed.title
                        }
                        // Profil nachtragen, falls das Transcript unter einem
                        // Profil-Root liegt und die Session noch keins traegt —
                        // sonst wuerde ein Resume unterm falschen Config-Dir laufen.
                        if workspace.sessions[index].claudeProfileName == nil,
                           let profile = indexed.claudeProfileName {
                            workspace.sessions[index].claudeProfileName = profile
                        }
                    } else {
                        stats.appends += 1
                        didChange = true
                        workspace.sessions.append(
                            AgentChatSession(
                                provider: indexed.provider,
                                projectID: project.id,
                                externalSessionID: indexed.externalSessionID,
                                title: indexed.title,
                                model: indexed.model ?? fallbackModelRaw,
                                reasoningEffort: indexed.reasoningEffort ?? fallbackEffortRaw,
                                status: .closed,
                                hasLaunchedInitialPrompt: true,
                                createdAt: indexed.createdAt,
                                lastActivityAt: indexed.lastActivityAt,
                                claudeProfileName: indexed.claudeProfileName
                            )
                        )
                        sessionIndexByExternalKey[externalKey] = workspace.sessions.count - 1
                    }
                }
                return didChange
            }
        }
        let updates = stats.updates
        let adoptions = stats.adoptions
        let appends = stats.appends
        let stale = stats.closedStaleSessions
        let duplicates = stats.duplicateKeys
        Logger.agentPerformance.info("agent_index_merge updates=\(updates) adoptions=\(adoptions) appends=\(appends) staleClosed=\(stale) duplicateKeys=\(duplicates)")
        return stats
    }

    /// Spiegelt die Subagent-Jobs (state.json-Snapshots aus `agent-jobs/`) in
    /// den Workspace — Gegenstück zu `mergeIndexedSessions`, gerufen vom
    /// `AgentJobWorkspaceSync`. Muss IDEMPOTENT sein: der Sync läuft bei jedem
    /// FSEvent; ein Lauf ohne echte Änderung darf den Workspace nicht anfassen
    /// (sonst persisted der Debounce dauernd und die Sidebar re-rendert).
    ///
    /// - `activityBumpShortIds`: Jobs mit Phasen-Übergang seit dem letzten
    ///   Sync — NUR für die wird `lastActivityAt` gebumpt (deterministisch auf
    ///   `job.updatedAt`, kein `Date()` pro Tick).
    /// - `resolvedParentExternalByShortId`: vom Sync per PID-Abstammung
    ///   aufgelöste Parents (Claude-externalSessionID) für Jobs OHNE
    ///   explizites `--parent` — wird beim Anlegen genutzt und bei bekannten
    ///   Sessions nachgetragen, solange dort noch kein Parent steht.
    /// - `codexConfigDefaults`: die globalen ~/.codex/config.toml-Defaults —
    ///   das nutzt `codex exec` real, wenn der Job ohne `--model`/`--effort`
    ///   lief. Default-Argument (at call site evaluiert = außerhalb des
    ///   Store-Locks, Datei-I/O!); Tests injizieren feste Werte.
    func mergeSubagentJobs(
        _ jobs: [AgentJobState],
        activityBumpShortIds: Set<String> = [],
        resolvedParentExternalByShortId: [String: String] = [:],
        codexConfigDefaults: CodexGlobalConfigDefaults = CodexGlobalConfigReader.shared.defaults(),
        fallbackModelRaw: String = AppPreferences.shared.resolvedCodexDefaultModelRaw()
    ) throws {
        // Branch-Lookups VOR der Mutation (kein Subprozess unter dem
        // Store-Lock) — nur für Fallback-Projekte, die es noch nicht gibt.
        let knownPaths = Set(loadWorkspace().projects.map(\.path))
        var branchByPath: [String: String?] = [:]
        for job in jobs {
            let path = Self.canonicalProjectPath(job.cwd)
            if !knownPaths.contains(path), branchByPath.index(forKey: path) == nil {
                branchByPath[path] = Self.currentGitBranch(at: path)
            }
        }

        try mutateWorkspace { workspace in
            let jobShortIds = Set(jobs.map(\.shortId))

            // 1. Verschwundene Job-Verzeichnisse (`agent rm`): Short-ID nilen,
            //    die Session bleibt — der Indexer darf die Codex-Session
            //    danach normal adoptieren (Dedupe-Set greift nicht mehr).
            for index in workspace.sessions.indices {
                guard workspace.sessions[index].isSubagentJob,
                      let shortId = workspace.sessions[index].subagentJobShortID,
                      !jobShortIds.contains(shortId) else { continue }
                workspace.sessions[index].subagentJobShortID = nil
            }

            for job in jobs {
                let effectiveCwd = job.worktree?.path ?? job.cwd
                // Explizites --parent gewinnt; sonst die PID-Auflösung.
                let parentExternalID = job.parentSessionID
                    ?? resolvedParentExternalByShortId[job.shortId]
                // Was der Job WIRKLICH nutzt: explizites --model/--effort aus
                // dem Job-State, sonst der globale config.toml-Default (den
                // zieht codex bei jedem Turn). nil = unbekannt → nicht raten.
                let jobModel = job.model ?? codexConfigDefaults.model
                let jobEffort = job.effort ?? codexConfigDefaults.effort
                if let index = workspace.sessions.firstIndex(where: { $0.subagentJobShortID == job.shortId }) {
                    // Bekannter Job → nur ECHTE Änderungen schreiben.
                    if workspace.sessions[index].externalSessionID == nil,
                       let threadID = job.codexThreadID {
                        workspace.sessions[index].externalSessionID = threadID
                    }
                    // Frühere Versionen legten Job-Sessions mit den App-
                    // Defaults an (zeigte z.B. gpt-5.5 statt des echten
                    // gpt-5.6-sol) — hier einmalig geradeziehen; idempotent,
                    // schreibt nur bei echter Abweichung.
                    if let jobModel, workspace.sessions[index].model != jobModel {
                        workspace.sessions[index].model = jobModel
                    }
                    if let jobEffort, workspace.sessions[index].reasoningEffort != jobEffort {
                        workspace.sessions[index].reasoningEffort = jobEffort
                    }
                    // Nachträgliche Parent-Zuordnung (Job lief schon, bevor
                    // die PID aufgelöst werden konnte) — nie überschreiben.
                    if workspace.sessions[index].subagentParentSessionID == nil,
                       let parentExternalID {
                        workspace.sessions[index].subagentParentSessionID = parentExternalID
                    }
                    if workspace.sessions[index].subagentCwd != effectiveCwd {
                        workspace.sessions[index].subagentCwd = effectiveCwd
                    }
                    if workspace.sessions[index].title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        workspace.sessions[index].title = Self.subagentSessionTitle(from: job.intent)
                    }
                    if activityBumpShortIds.contains(job.shortId) {
                        workspace.sessions[index].lastActivityAt = max(
                            job.updatedAt,
                            workspace.sessions[index].lastActivityAt
                        )
                    }
                } else {
                    // Unbekannter Job → Session anlegen. Projekt-Zuordnung:
                    // Parent-Session (Claude-externalSessionID) → deren
                    // Projekt; Fallback: Projekt fürs Job-cwd (find-or-create,
                    // Muster mergeIndexedSessions — upsertProject wäre unterm
                    // Lock ein Deadlock).
                    let projectID: UUID
                    if let parentExtID = parentExternalID,
                       let parent = workspace.sessions.first(where: {
                           !$0.isSubagentJob && $0.externalSessionID == parentExtID
                       }) {
                        projectID = parent.projectID
                    } else {
                        let path = Self.canonicalProjectPath(job.cwd)
                        if let existing = workspace.projects.first(where: { $0.path == path }) {
                            projectID = existing.id
                        } else {
                            let project = AgentProject(
                                name: URL(fileURLWithPath: path).lastPathComponent,
                                path: path,
                                color: AgentProjectColor.palette[workspace.projects.count % AgentProjectColor.palette.count],
                                lastBranch: branchByPath[path] ?? nil
                            )
                            workspace.projects.append(project)
                            projectID = project.id
                        }
                    }
                    workspace.sessions.append(
                        AgentChatSession(
                            provider: .codex,
                            projectID: projectID,
                            externalSessionID: job.codexThreadID,
                            title: Self.subagentSessionTitle(from: job.intent),
                            // Echte Job-Parameter statt App-Defaults; nur wenn
                            // beides unbekannt ist, greift der aufgelöste
                            // App-Default (auto → Frontier-Modell) — nie der
                            // starre Legacy-Wert gpt-5.5.
                            model: jobModel ?? fallbackModelRaw,
                            reasoningEffort: jobEffort ?? CodexReasoningEffort.defaultEffort.rawValue,
                            status: .closed,
                            // Resume-Pfad ohne Sonderfall (Übernahme):
                            hasLaunchedInitialPrompt: true,
                            createdAt: job.createdAt,
                            lastActivityAt: job.updatedAt,
                            // SONST UNSICHTBAR — die Sidebar filtert auf
                            // isManuallyCreated:
                            createdManually: true,
                            kind: .subagentJob,
                            subagentJobShortID: job.shortId,
                            subagentParentSessionID: parentExternalID,
                            subagentCwd: effectiveCwd
                        )
                    )
                }
            }
        }
    }

    /// Sidebar-Titel aus dem Job-Intent: erste Zeile, auf 60 Zeichen gekürzt.
    /// Pure + testbar (Muster `backgroundSessionTitle`).
    static func subagentSessionTitle(from intent: String) -> String {
        let trimmed = intent.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = trimmed.split(whereSeparator: { $0.isNewline }).first.map(String.init) ?? trimmed
        let cap = 60
        let snippet = firstLine.count > cap ? String(firstLine.prefix(cap - 1)) + "…" : firstLine
        return snippet.isEmpty ? "Subagent-Job" : snippet
    }

    static func sortedSessions(_ sessions: [AgentChatSession]) -> [AgentChatSession] {
        sessions.sorted { lhs, rhs in
            switch (lhs.sortIndex, rhs.sortIndex) {
            case let (left?, right?) where left != right:
                return left < right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return lhs.lastActivityAt > rhs.lastActivityAt
            }
        }
    }

    /// Identische Sortier-Semantik wie `sortedSessions`: explicit `sortIndex`
    /// wins, sonst `updatedAt` als Tiebreaker (jüngste zuerst).
    static func sortedProjects(_ projects: [AgentProject]) -> [AgentProject] {
        projects.sorted { lhs, rhs in
            switch (lhs.sortIndex, rhs.sortIndex) {
            case let (left?, right?) where left != right:
                return left < right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return lhs.updatedAt > rhs.updatedAt
            }
        }
    }

    /// Direkter `.git/HEAD`-Read statt `git branch --show-current`-Spawn —
    /// läuft u. a. bei jedem `createSession` synchron auf dem Main Thread,
    /// ein Subprozess mit `waitUntilExit()` fror dort die UI sichtbar ein.
    private static func currentGitBranch(at path: String) -> String? {
        GitBranchReader.currentBranch(at: path)
    }

    // Forwarder auf AgentProjectPath (Logik dort) — haelt bestehende
    // Aufrufstellen `AgentSessionStore.canonicalProjectPath(...)` stabil.
    static func canonicalProjectPath(_ path: String) -> String {
        AgentProjectPath.canonicalProjectPath(path)
    }

    static func isClaudeWorktreePath(_ path: String) -> Bool {
        AgentProjectPath.isClaudeWorktreePath(path)
    }

    private static func removeClaudeWorktreeProjectsAndSessions(from workspace: inout AgentWorkspace) {
        let worktreeProjectIDs = Set(
            workspace.projects
                .filter { isClaudeWorktreePath($0.path) }
                .map(\.id)
        )
        guard !worktreeProjectIDs.isEmpty else {
            return
        }

        workspace.sessions.removeAll { worktreeProjectIDs.contains($0.projectID) }
        workspace.projects.removeAll { worktreeProjectIDs.contains($0.id) }
    }

    private static func removeUnresumableClaudeSessions(from workspace: inout AgentWorkspace) {
        // Altersgrenze (Review-Befund 2026-07-13): frisch gestartete Sessions
        // sind oft transient ungebunden (SessionStart-Hook/Indexer-Adoption
        // noch unterwegs) — der Prune darf nur echte Alt-Leichen räumen,
        // nie eine Session, deren Transcript gleich adoptiert würde.
        let cutoff = Date().addingTimeInterval(-3600)
        workspace.sessions.removeAll { session in
            session.provider == .claude
                && session.hasLaunchedInitialPrompt
                && session.externalSessionID == nil
                && session.initialPrompt == nil
                && session.createdManually != true
                && session.shouldLaunchOnOpen != true
                && session.status != .running
                && session.status != .pending
                && session.createdAt < cutoff
        }
    }

    /// Background-Sessions, deren Spawn nie erfolgreich abgeschlossen wurde
    /// (kein `backgroundShortID` persistiert) und die mittlerweile beendet
    /// sind (`closed`/`archived`), sind nicht mehr nutzbar — `claude attach`
    /// braucht zwingend eine Short-ID. Wir raeumen sie still beim
    /// Workspace-Load weg.
    ///
    /// Bewusst NICHT raeumen, wenn `status == .pending`/`.running`:
    /// theoretisch koennte ein Spawn gerade laufen (oder die App ist mitten
    /// im Spawn abgestuerzt). In dem Fall lassen wir die Session da — der
    /// User kann selbst entscheiden.
    static func removeOrphanBackgroundSessions(from workspace: inout AgentWorkspace) {
        workspace.sessions.removeAll { session in
            session.kind == .backgroundChat
                && (session.backgroundShortID?.isEmpty != false)
                && (session.status == .closed || session.status == .archived)
        }
    }

    /// Einmal-Migration: in einer frueheren Build-Variante (Phase 6) hat
    /// WhisperM8 jeden vom Claude-Supervisor gehosteten Background-Worker
    /// automatisch aus `~/.claude/daemon/roster.json` als
    /// `.backgroundChat`-Session importiert (mit `createdManually=false`).
    /// Das hat in der Praxis nicht gut funktioniert und wurde wieder
    /// zurueckgenommen. Diese Migration entfernt die Geist-Tabs aus dem
    /// Workspace, damit die Sidebar nicht weiterhin von uns importierte
    /// Sessions zeigt. Vom User selbst gespawnte BG-Agents
    /// (`createdManually=true`) bleiben unberuehrt.
    static func removeImportedBackgroundSessions(from workspace: inout AgentWorkspace) {
        workspace.sessions.removeAll { session in
            session.kind == .backgroundChat
                && session.createdManually != true
        }
    }

    /// R4-AS-11: Doppelte lokale Session-IDs (defekter oder duplizierter
    /// Bestand) deterministisch auf die jeweils ERSTE Row reduzieren — alle
    /// Konsumenten suchen per `first(where:)`, die erste Row ist also die
    /// ohnehin sichtbare. Ohne kontrollierten Dedup erreicht ein Duplikat
    /// trap-faehige Vorbedingungen (z. B. `Dictionary(uniqueKeysWithValues:)`
    /// im Summary-Startup-Planer).
    static func dedupeDuplicateSessionIDs(from workspace: inout AgentWorkspace) {
        var seen = Set<UUID>()
        var duplicates = 0
        workspace.sessions.removeAll { session in
            if seen.insert(session.id).inserted { return false }
            duplicates += 1
            return true
        }
        if duplicates > 0 {
            Logger.agentStore.notice("agent_store_duplicate_session_ids removed=\(duplicates)")
        }
    }

    /// Internal (statt private), weil die `AgentWorkspaceStoreRegistry` die
    /// Migration in den Initial-Load des Kerns injiziert.
    static func migratedWorkspace(_ workspace: AgentWorkspace) -> AgentWorkspace {
        var migrated = workspace
        let beforeCount = migrated.sessions.count
        migrated.schemaVersion = AgentWorkspace.currentSchemaVersion
        dedupeDuplicateSessionIDs(from: &migrated)
        removeClaudeWorktreeProjectsAndSessions(from: &migrated)
        removeUnresumableClaudeSessions(from: &migrated)
        removeOrphanBackgroundSessions(from: &migrated)
        removeImportedBackgroundSessions(from: &migrated)
        // Datenverlust-Diagnose: jedes Entfernen sichtbar machen. Läuft als
        // `normalize` bei jeder Mutation — loggt nur, wenn wirklich etwas wegfällt.
        let removed = beforeCount - migrated.sessions.count
        if removed > 0 {
            Logger.agentStore.notice("agent_store_pruned removed=\(removed) before=\(beforeCount) after=\(migrated.sessions.count)")
        }
        return migrated
    }

    private static func bestResumeReplacement(
        for session: AgentChatSession,
        currentExternalID: String,
        indexedSessions: [IndexedAgentSession],
        now: Date
    ) -> IndexedAgentSession? {
        let maxCreationDistance = max(
            30 * 60,
            session.lastActivityAt.timeIntervalSince(session.createdAt) + 5 * 60
        )
        let candidates = indexedSessions.filter { indexed in
            indexed.externalSessionID != currentExternalID
                && indexed.createdAt >= session.createdAt.addingTimeInterval(-10)
                && indexed.createdAt <= now.addingTimeInterval(60)
                && abs(indexed.createdAt.timeIntervalSince(session.createdAt)) <= maxCreationDistance
        }

        // Auto-Rebind NUR bei genau EINEM Kandidaten (Review-Befund
        // 2026-07-13): Die Heuristik kennt weder Profil noch Inhalt — bei
        // mehreren zeitlich plausiblen Sessions desselben Projekts könnte sie
        // einen FREMDEN Chat kapern, dessen existierendes Transcript dann auch
        // den finalen Launch-Guard passiert und den echten Verlauf verdeckt.
        // Mehrdeutigkeit → kein Rebind; der Caller stoppt sichtbar.
        guard candidates.count == 1 else {
            if candidates.count > 1 {
                Logger.agentStore.warning("resume_rebind_ambiguous session=\(currentExternalID, privacy: .public) candidates=\(candidates.count)")
            }
            return nil
        }
        return candidates[0]
    }

    /// P1: Beide Primitive laufen über den serialisierten In-Memory-Kern.
    /// Persistiert wird Equatable-diff-gated — das frühere `changed`-Flag
    /// von `mutateWorkspaceIfChanged` ist damit nur noch advisory.
    private func mutateWorkspace<Result>(_ mutate: (inout AgentWorkspace) throws -> Result) throws -> Result {
        try PerfBudgets.storeMutate.withInterval {
            try workspaceStore.mutate(mutate)
        }
    }

    /// Boolescher Änderungsvertrag für fachlich präzise Mutatoren: `false`
    /// beendet den Store-Pfad vor Vollnormalisierung und Deep-Equatable.
    private func mutateWorkspaceIfChanged(_ mutate: (inout AgentWorkspace) throws -> Bool) throws {
        try PerfBudgets.storeMutate.withInterval {
            try workspaceStore.mutateIfChanged(mutate)
        }
    }
}

enum AgentSessionMoveDirection {
    case up
    case down
}

struct AgentSessionMergeStats: Equatable {
    var updates = 0
    var adoptions = 0
    var appends = 0
    var closedStaleSessions = 0
    var duplicateKeys = 0
}

struct IndexedAgentSession: Codable, Equatable {
    var provider: AgentProvider
    var externalSessionID: String
    var cwd: String
    var title: String
    var model: String?
    var reasoningEffort: String?
    var createdAt: Date
    var lastActivityAt: Date
    /// Claude-Account-Profil, unter dessen Root das Transcript liegt
    /// (`~/.claude-profiles/<name>/projects/...`). `nil` = main. Optional,
    /// damit alte `agent-index-cache.json`-Staende weiter dekodieren.
    var claudeProfileName: String?
}

struct AgentResumeRepairResult: Equatable {
    var session: AgentChatSession
    var outcome: AgentResumeRepairOutcome
}

enum AgentResumeRepairOutcome: Equatable {
    case unchanged
    case rebound(from: String, to: String)
    case resetInvalid(String)
}
