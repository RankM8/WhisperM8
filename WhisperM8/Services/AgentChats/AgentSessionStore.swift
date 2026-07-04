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
        state.migrateToV2IfNeeded(workspace: workspace)
        state.prune(workspace: workspace)
        if needsPersist {
            try? saveUIState(state)
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

    func upsertProject(path: String, name: String? = nil, color: String? = nil, createdManually: Bool = false) throws -> AgentProject {
        let standardizedPath = Self.canonicalProjectPath(path)
        // Git-Lookup VOR der Mutation — die Closure läuft unter dem
        // prozessweiten Store-Lock, dort darf kein Subprozess laufen.
        let branch = Self.currentGitBranch(at: standardizedPath)
        return try mutateWorkspace { workspace in
            if let index = workspace.projects.firstIndex(where: { $0.path == standardizedPath }) {
                workspace.projects[index].updatedAt = Date()
                workspace.projects[index].lastBranch = branch
                if createdManually {
                    workspace.projects[index].createdManually = true
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
            update(&workspace.sessions[index])
            workspace.sessions[index].lastActivityAt = Date()
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
    }

    /// Entfernt ein Projekt samt all seiner Sessions aus dem Workspace.
    /// Bewusst NUR der WhisperM8-Workspace-Eintrag — das Repo auf der
    /// Festplatte und die externen Claude/Codex-Transcripts (`~/.claude`,
    /// `~/.codex`) bleiben unangetastet. Re-Importe durch spätere Scans
    /// landen als auto-importierte (nicht-manuelle) Sessions und tauchen
    /// daher nicht wieder in der Sidebar auf.
    func deleteProject(id: UUID) throws {
        try mutateWorkspaceIfChanged { workspace in
            let hasProject = workspace.projects.contains { $0.id == id }
            let hasSessions = workspace.sessions.contains { $0.projectID == id }
            guard hasProject || hasSessions else { return false }
            workspace.sessions.removeAll { $0.projectID == id }
            workspace.projects.removeAll { $0.id == id }
            return true
        }
    }

    func markStaleRunningSessionsClosed(excluding activeSessionIDs: Set<UUID> = []) throws {
        try mutateWorkspace { workspace in
            for index in workspace.sessions.indices where workspace.sessions[index].status == .running {
                guard workspace.sessions[index].shouldLaunchOnOpen != true else { continue }
                guard !activeSessionIDs.contains(workspace.sessions[index].id) else { continue }
                workspace.sessions[index].status = .closed
            }
        }
    }

    @discardableResult
    func createSession(
        provider: AgentProvider,
        projectPath: String,
        title: String,
        model: String = AppPreferences.shared.codexPostProcessingModelRaw,
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
        forkSourceSessionID: String? = nil
    ) throws -> AgentChatSession {
        let project = try upsertProject(path: projectPath, createdManually: createdManually)
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
            forkSourceSessionID: forkSourceSessionID
        )
        let stored = try upsertSession(session)
        // Crash-safe: strukturelle Erstellung SOFORT persistieren statt auf den
        // 0,5-s-Debounce zu warten — sonst Verlust bei Crash/Force-Quit/kill im
        // Zeitfenster. Siehe docs/agent-chats-redesign/01-chat-persistenz-datenverlust.md
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
    }

    @discardableResult
    func bindLatestIndexedSession(
        localSessionID: UUID,
        provider: AgentProvider,
        projectPath: String,
        indexedSessions: [IndexedAgentSession]
    ) throws -> AgentChatSession? {
        guard !Self.isClaudeWorktreePath(projectPath) else { return nil }
        return try mutateWorkspace { workspace in
            guard let index = workspace.sessions.firstIndex(where: { $0.id == localSessionID }) else {
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

            workspace.sessions[index].externalSessionID = nil
            workspace.sessions[index].hasLaunchedInitialPrompt = false
            workspace.sessions[index].status = .closed
            workspace.sessions[index].shouldLaunchOnOpen = false
            workspace.sessions[index].lastActivityAt = now
            return AgentResumeRepairResult(
                session: workspace.sessions[index],
                outcome: .resetInvalid(currentExternalID)
            )
        }
    }

    func mergeIndexedSessions(_ indexedSessions: [IndexedAgentSession]) throws {
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

        try mutateWorkspace { workspace in
            Self.removeClaudeWorktreeProjectsAndSessions(from: &workspace)
            Self.removeUnresumableClaudeSessions(from: &workspace)
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
            for indexed in indexedSessions {
                guard !Self.isClaudeWorktreePath(indexed.cwd) else { continue }
                guard !subagentThreadIDs.contains(indexed.externalSessionID) else { continue }
                let projectPath = Self.canonicalProjectPath(indexed.cwd)
                let project: AgentProject
                if let existingProject = workspace.projects.first(where: { $0.path == projectPath }) {
                    project = existingProject
                } else {
                    project = AgentProject(
                        name: URL(fileURLWithPath: projectPath).lastPathComponent,
                        path: projectPath,
                        color: AgentProjectColor.palette[workspace.projects.count % AgentProjectColor.palette.count],
                        lastBranch: branchByPath[projectPath] ?? nil
                    )
                    workspace.projects.append(project)
                }

                if let index = workspace.sessions.firstIndex(where: { $0.provider == indexed.provider && $0.externalSessionID == indexed.externalSessionID }) {
                    workspace.sessions[index].projectID = project.id
                    workspace.sessions[index].lastActivityAt = indexed.lastActivityAt
                    if workspace.sessions[index].title.isEmpty {
                        workspace.sessions[index].title = indexed.title
                    }
                } else if let index = workspace.sessions.firstIndex(where: {
                    $0.provider == indexed.provider
                        && $0.externalSessionID == nil
                        && $0.projectID == project.id
                        && $0.hasLaunchedInitialPrompt
                        && $0.createdAt <= indexed.createdAt.addingTimeInterval(5)
                        && indexed.createdAt >= $0.createdAt.addingTimeInterval(-5)
                }) {
                    workspace.sessions[index].externalSessionID = indexed.externalSessionID
                    workspace.sessions[index].lastActivityAt = max(indexed.lastActivityAt, workspace.sessions[index].lastActivityAt)
                    if workspace.sessions[index].title.hasSuffix(" Chat") || workspace.sessions[index].title.isEmpty {
                        workspace.sessions[index].title = indexed.title
                    }
                } else {
                    workspace.sessions.append(
                        AgentChatSession(
                            provider: indexed.provider,
                            projectID: project.id,
                            externalSessionID: indexed.externalSessionID,
                            title: indexed.title,
                            model: indexed.model ?? AppPreferences.shared.codexPostProcessingModelRaw,
                            reasoningEffort: indexed.reasoningEffort ?? AppPreferences.shared.codexReasoningEffortRaw,
                            status: .closed,
                            hasLaunchedInitialPrompt: true,
                            createdAt: indexed.createdAt,
                            lastActivityAt: indexed.lastActivityAt
                        )
                    )
                }
            }
            Self.removeClaudeWorktreeProjectsAndSessions(from: &workspace)
            Self.removeUnresumableClaudeSessions(from: &workspace)
        }
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
    func mergeSubagentJobs(
        _ jobs: [AgentJobState],
        activityBumpShortIds: Set<String> = []
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
                if let index = workspace.sessions.firstIndex(where: { $0.subagentJobShortID == job.shortId }) {
                    // Bekannter Job → nur ECHTE Änderungen schreiben.
                    if workspace.sessions[index].externalSessionID == nil,
                       let threadID = job.codexThreadID {
                        workspace.sessions[index].externalSessionID = threadID
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
                    if let parentExtID = job.parentSessionID,
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
                            subagentParentSessionID: job.parentSessionID,
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

    private static func currentGitBranch(at path: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", path, "branch", "--show-current"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let branch = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return branch?.isEmpty == false ? branch : nil
        } catch {
            return nil
        }
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
        workspace.sessions.removeAll { session in
            session.provider == .claude
                && session.hasLaunchedInitialPrompt
                && session.externalSessionID == nil
                && session.initialPrompt == nil
                && session.createdManually != true
                && session.shouldLaunchOnOpen != true
                && session.status != .running
                && session.status != .pending
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

    /// Internal (statt private), weil die `AgentWorkspaceStoreRegistry` die
    /// Migration in den Initial-Load des Kerns injiziert.
    static func migratedWorkspace(_ workspace: AgentWorkspace) -> AgentWorkspace {
        var migrated = workspace
        let beforeCount = migrated.sessions.count
        migrated.schemaVersion = AgentWorkspace.currentSchemaVersion
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

        return candidates.sorted { lhs, rhs in
            let lhsDistance = abs(lhs.createdAt.timeIntervalSince(session.createdAt))
            let rhsDistance = abs(rhs.createdAt.timeIntervalSince(session.createdAt))
            if lhsDistance != rhsDistance {
                return lhsDistance < rhsDistance
            }
            return lhs.lastActivityAt > rhs.lastActivityAt
        }.first
    }

    /// P1: Beide Primitive laufen über den serialisierten In-Memory-Kern.
    /// Persistiert wird Equatable-diff-gated — das frühere `changed`-Flag
    /// von `mutateWorkspaceIfChanged` ist damit nur noch advisory.
    private func mutateWorkspace<Result>(_ mutate: (inout AgentWorkspace) throws -> Result) throws -> Result {
        try PerfBudgets.storeMutate.withInterval {
            try workspaceStore.mutate(mutate)
        }
    }

    private func mutateWorkspaceIfChanged(_ mutate: (inout AgentWorkspace) throws -> Bool) throws {
        try PerfBudgets.storeMutate.withInterval {
            _ = try workspaceStore.mutate(mutate)
        }
    }
}

enum AgentSessionMoveDirection {
    case up
    case down
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
