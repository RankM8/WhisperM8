import SwiftUI

/// Hintergrund-Agenten der AgentChatsView: Dispatch (claude --bg), Sub-Agent-
/// Bibliothek, Logs, Lifecycle (stop/respawn/forget) und Startup-Healthcheck.
/// Aus AgentChatsView.swift ausgelagert (Phase-2-Split); genutzte View-Member
/// sind dort auf internal gehoben.
extension AgentChatsView {
    // MARK: - Background Agents (Phase 2)

    /// Oeffnet die Read-Only-Sub-Agent-Bibliothek als Sheet. Listet alle
    /// Sub-Agents aus `~/.claude/agents/` (User) + `.claude/agents/`
    /// (Projekt), grupiert nach Scope. Zweck: Discovery — der User sieht,
    /// was er dem `--agent`-Flag im Dispatch-Modal mitgeben kann.
    func presentSubAgentLibrary() {
        let projectPath = selectedProject?.path
        let agents = SubAgentDiscovery.discover(projectPath: projectPath)
        subAgentLibrarySheet = SubAgentLibraryPresentation(
            projectName: selectedProject?.name,
            agents: agents
        )
    }

    /// Oeffnet das Background-Dispatch-Modal fuer das aktuell selektierte
    /// Projekt. Sub-Agent-Discovery laeuft synchron — die Listen sind klein
    /// und es ist FS-cached.
    func presentBackgroundDispatchModal() {
        guard let project = selectedProject else { return }
        let subAgents = SubAgentDiscovery.discover(projectPath: project.path)
        pendingBackgroundDispatch = PendingBackgroundDispatch(
            project: project,
            subAgents: subAgents
        )
    }

    /// Spawnt einen neuen Background-Agent via `claude --bg`, persistiert die
    /// Short-ID auf die neu angelegte Session und triggert dann `claude attach`
    /// als PTY-Tab. Drei Stufen:
    ///
    /// 1. Persistieren — Tab erscheint sofort in der Sidebar (mit Pending-State).
    /// 2. Spawn — Subprocess-Aufruf, parsed Short-ID. Bei Fehler: errorMessage.
    /// 3. Attach — Short-ID auf Session schreiben + sessionActionRequest senden.
    @MainActor
    func dispatchBackgroundAgent(in project: AgentProject, request: BackgroundDispatchRequest) async {
        // 1. Stub-Session anlegen (ohne Short-ID), Tab oeffnen. Das Context-
        //    Profil des Projekts wird auf die Session gestempelt — der
        //    Supervisor brennt die Spawn-Settings ein, Profil-Aenderungen
        //    wirken bei Background-Agents erst ab Respawn.
        let contextProfile = ClaudeContextProfileStore.shared.profile(id: project.contextProfileID)
        let session: AgentChatSession
        do {
            session = try store.createSession(
                provider: .claude,
                projectPath: project.path,
                title: backgroundSessionTitle(for: request),
                model: AppPreferences.shared.resolvedCodexDefaultModelRaw(),
                reasoningEffort: AppPreferences.shared.codexReasoningEffortRaw,
                externalSessionID: nil,
                initialPrompt: request.prompt,
                shouldLaunchOnOpen: false,
                kind: .backgroundChat,
                backgroundSubAgent: request.subAgent,
                backgroundPermissionMode: request.permissionMode,
                contextProfileID: contextProfile?.id
            )
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        spawningBackgroundSessions.insert(session.id)
        openTab(session.id)
        selectedSessionID = session.id

        // 2. GPT-Router vor dem Spawn off-main absichern. Toggle und Ports
        //    werden nach dem Readiness-Check erneut gelesen; kippt der Guard,
        //    startet der Agent sichtbar geloggt im Claude-Direktbetrieb. Bei
        //    Erfolg wird derselbe vollstaendige Snapshot an Dispatcher UND
        //    session-scoped Worker-Settings weitergereicht.
        let routerEnvironment = await Task.detached(priority: .userInitiated) {
            var ensureError: ClaudeCodeProxyError?
            return BackgroundRouterLaunchGuard.resolveEnvironment(
                isEnabled: { AppPreferences.shared.claudeGPTBackendEnabled },
                port: { AppPreferences.shared.claudeGPTBackendPort },
                ensureRunning: { port in
                    switch ClaudeCodeProxyManager.shared.ensureRunning(port: port) {
                    case .success:
                        return true
                    case .failure(let error):
                        ensureError = error
                        return false
                    }
                },
                makeEnvironment: { guardedPort in
                    var builder = AgentCommandBuilder()
                    // Der nach dem Guard fixierte Port gehoert zum Snapshot;
                    // ein weiterer Preference-Read hier koennte sonst einen
                    // noch nicht geprueften Port in die Worker-Datei schreiben.
                    builder.gptRouterPortResolver = { guardedPort }
                    return builder.gptRouterCoreEnvironment()
                },
                onUnavailable: {
                    Logger.claudeGPTRouter.error(
                        "background_launch_guard_unavailable error=\(ensureError?.localizedDescription ?? "unbekannt", privacy: .public)"
                    )
                }
            )
        }.value

        // 3. Settings vorbereiten (Hook-Bridge + Context-Profil + Worker-Env) —
        //    die Background-Session erbt die Settings vom Supervisor, also
        //    muessen wir `--settings <path>` schon beim Spawn-Subprocess
        //    setzen, nicht erst beim spaeteren `claude attach`. Ohne aktives
        //    Routing bleibt ein IO-Fehler fail-open; mit Router-Snapshot ist die
        //    Datei Pflicht, weil sonst der Worker andere Invarianten als der
        //    Dispatcher erhielte.
        let launchPreparation = AgentSessionStatusCoordinator.shared.prepareLaunchSettings(
            localSessionID: session.id,
            contextProfile: contextProfile,
            includeGPTModelCatalog: routerEnvironment != nil,
            workerEnvironment: routerEnvironment
        )
        let settingsPath = launchPreparation.settingsFilePath
        if BackgroundRouterLaunchGuard.blocksSpawnAfterSettingsPreparation(
            routerEnvironment: routerEnvironment,
            settingsFilePath: settingsPath
        ) {
            spawningBackgroundSessions.remove(session.id)
            try? store.deleteSession(id: session.id)
            openTabIDs.removeAll { $0 == session.id }
            if selectedSessionID == session.id {
                selectedSessionID = openTabIDs.first
            }
            errorMessage = "Hintergrund-Agent konnte nicht gestartet werden: Worker-Settings mit GPT-Router-Environment konnten nicht geschrieben werden."
            return
        }

        // 4. Spawn via BackgroundAgentSpawner.
        let extraArgs = AgentCommandBuilder.parseArguments(AppPreferences.shared.claudeExtraArguments)
        do {
            let result = try await BackgroundAgentSpawner.spawn(
                initialPrompt: request.prompt,
                projectPath: project.path,
                settingsFilePath: settingsPath,
                subAgent: request.subAgent,
                permissionMode: request.permissionMode,
                extraArguments: extraArgs,
                environmentOverrides: routerEnvironment ?? [:]
            )
            // 4. Short-ID persistieren + Hook-Tracking starten + Attach triggern.
            try store.setBackgroundShortID(localSessionID: session.id, shortID: result.shortID)
            try store.updateSession(id: session.id) { updated in
                updated.hasLaunchedInitialPrompt = true
            }
            spawningBackgroundSessions.remove(session.id)
            // hooksActive statt `settingsPath != nil`: seit Context-Profilen
            // kann die Settings-Datei auch ohne Hook-Keys existieren — dann
            // darf kein Event-Tracking starten (Event-File existiert nicht).
            if launchPreparation.hooksActive {
                AgentSessionStatusCoordinator.shared.hookLaunchDidStart(sessionID: session.id)
            }
            sessionActionRequest = AgentSessionActionRequest(sessionID: session.id, kind: .start)
        } catch {
            spawningBackgroundSessions.remove(session.id)
            // Mehrdeutige Fehler (Timeout, Short-ID nicht geparst): der
            // Supervisor kann den Agenten TROTZDEM angelegt haben — die
            // Stub-Session bleibt dann als sichtbarer Fehlerzustand erhalten,
            // statt die Zuordnung zu einem real laufenden Agenten zu löschen
            // (Review-Befund 2026-07-13). Nur bei definitivem Nicht-Start
            // (Projekt fehlt, claude fehlt, Exit != 0) wird aufgeräumt.
            let spawnDefinitelyFailed: Bool
            switch error as? BackgroundAgentSpawner.SpawnError {
            case .timedOut?, .shortIDNotFound?:
                spawnDefinitelyFailed = false
            default:
                spawnDefinitelyFailed = true
            }
            if spawnDefinitelyFailed {
                try? store.deleteSession(id: session.id)
                openTabIDs.removeAll { $0 == session.id }
                if selectedSessionID == session.id {
                    selectedSessionID = openTabIDs.first
                }
            } else {
                try? store.updateSession(id: session.id) { updated in
                    updated.status = .closed
                }
            }
            errorMessage = "Hintergrund-Agent konnte nicht gestartet werden: \(error.localizedDescription)"
        }
    }

    // MARK: - Background Agents · Phase 3 (Lifecycle)

    /// Oeffnet das Logs-Sheet fuer eine Background-Session. Ruft `claude
    /// logs <id>` asynchron auf und reicht das Ergebnis ins Sheet weiter —
    /// das Sheet selbst zeigt einen Spinner, solange wir laden.
    @MainActor
    func showBackgroundLogs(for session: AgentChatSession) {
        guard let shortID = session.backgroundShortID, !shortID.isEmpty else { return }
        let presentation = BackgroundLogsPresentation(
            sessionID: session.id,
            shortID: shortID,
            title: session.title,
            state: .loading
        )
        pendingBackgroundLogs = presentation
        pendingLifecycleSessions.insert(session.id)
        Task { @MainActor in
            defer { pendingLifecycleSessions.remove(session.id) }
            do {
                let result = try await BackgroundAgentLifecycle.logs(shortID: shortID)
                // Nur uebernehmen, wenn das Sheet noch fuer dieselbe Short-ID offen ist —
                // sonst hat der User das Sheet schon geschlossen oder gewechselt.
                guard pendingBackgroundLogs?.id == presentation.id else { return }
                let combined = result.stdout + (result.stderr.isEmpty ? "" : "\n[stderr]\n" + result.stderr)
                pendingBackgroundLogs = presentation.with(state: .loaded(combined))
            } catch {
                guard pendingBackgroundLogs?.id == presentation.id else { return }
                pendingBackgroundLogs = presentation.with(state: .failed(error.localizedDescription))
            }
        }
    }

    /// Fuehrt eine Lifecycle-Aktion auf einer Background-Session aus. Bei
    /// `.rm` raeumen wir nach Erfolg auch den lokalen State auf (Tab
    /// schliessen + Session archivieren), bei den anderen Aktionen
    /// belassen wir die Session in der UI.
    @MainActor
    func performBackgroundLifecycle(
        _ action: BackgroundAgentLifecycle.Action,
        on session: AgentChatSession
    ) {
        guard let shortID = session.backgroundShortID, !shortID.isEmpty else { return }
        pendingLifecycleSessions.insert(session.id)
        Task { @MainActor in
            defer { pendingLifecycleSessions.remove(session.id) }
            do {
                switch action {
                case .logs:
                    _ = try await BackgroundAgentLifecycle.logs(shortID: shortID)
                case .stop:
                    _ = try await BackgroundAgentLifecycle.stop(shortID: shortID)
                case .respawn:
                    _ = try await BackgroundAgentLifecycle.respawn(shortID: shortID)
                case .rm:
                    _ = try await BackgroundAgentLifecycle.remove(shortID: shortID)
                    forgetBackgroundSession(session.id)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Lokales Cleanup, wenn der User die Session vom Supervisor entfernt
    /// hat (oder der Health-Check sie als verwaist klassifiziert).
    /// Terminiert ggf. das PTY, archiviert die Session, schliesst den Tab.
    @MainActor
    func forgetBackgroundSession(_ id: UUID) {
        if terminalRegistry.controller(for: id)?.isRunning == true {
            terminalRegistry.terminate(sessionID: id)
        }
        try? store.updateSession(id: id) { session in
            session.status = .archived
            session.archivedAt = Date()
            // Short-ID bewusst BEHALTEN (Review-Befund 2026-07-13): mit
            // genullter ID griffe `removeOrphanBackgroundSessions` und
            // löschte die archivierte Session komplett — ein fehlklassifizierter
            // Health-Check würde so einen echten Chat abkoppeln. Mit ID bleibt
            // sie als Archiv-Eintrag erhalten; ein Attach-Versuch scheitert
            // dann ehrlich statt still.
        }
        openTabIDs.removeAll { $0 == id }
        pinnedSessionIDs.removeAll { $0 == id }
        if selectedSessionID == id {
            selectedSessionID = openTabIDs.first
        }
    }

    /// Beim Window-Open: pro Short-ID einmal Health-Check fahren. Sessions,
    /// die der Supervisor nicht mehr kennt, werden lokal archiviert — sonst
    /// liessen sie sich nicht mehr attachen und blieben als Zombies in der
    /// Sidebar. Idempotent: laeuft pro Window-Lifetime nur einmal.
    func runBackgroundAgentStartupHealthCheckIfNeeded() {
        guard !hasRunStartupHealthCheck else { return }
        hasRunStartupHealthCheck = true
        let candidates: [(UUID, String)] = workspace.sessions.compactMap { session in
            guard session.isBackgroundChat,
                  session.status != .archived,
                  let id = session.backgroundShortID,
                  !id.isEmpty
            else { return nil }
            return (session.id, id)
        }
        guard !candidates.isEmpty else { return }
        Task.detached(priority: .utility) {
            for (sessionID, shortID) in candidates {
                let outcome = await BackgroundAgentLifecycle.healthCheck(shortID: shortID)
                guard outcome == .unknown else { continue }
                await MainActor.run {
                    forgetBackgroundSession(sessionID)
                }
            }
        }
    }

    /// Kurzer Titel-Fallback, bis der AutoNamer einen besseren Namen aus dem
    /// Transcript ableitet. Zeigt direkt den Prompt-Anfang an.
    func backgroundSessionTitle(for request: BackgroundDispatchRequest) -> String {
        let trimmed = request.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = trimmed.split(whereSeparator: { $0.isNewline }).first.map(String.init) ?? trimmed
        let cap = 60
        let snippet = firstLine.count > cap ? String(firstLine.prefix(cap - 1)) + "…" : firstLine
        return snippet.isEmpty ? "Hintergrund-Agent" : snippet
    }
}
