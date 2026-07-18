import SwiftUI

/// Session-Lifecycle der AgentChatsView: neuen Chat starten, erstellen,
/// forken, umbenennen/gruppieren/faerben, Status (mark/relaunch) und Pinning,
/// plus die session-nahen Menue-Helfer. Aus AgentChatsView.swift ausgelagert
/// (Phase-2-Split).
extension AgentChatsView {
    /// Startet einen neuen Chat in einem explizit gewählten Projekt (aus dem
    /// „Neuer Chat"-Dropdown): macht es zum aktuellen Ziel und öffnet den Chat.
    func startNewChat(in project: AgentProject) {
        showNewChatProjectPicker = false
        newChatProjectQuery = ""
        selectedProjectID = project.id
        expandedProjectIDs.insert(project.id)
        AppPreferences.shared.agentDefaultProjectPath = project.path
        createDefaultSession()
    }

    /// Enter im „Neuer Chat"-Suchfeld: öffnet den aktuell per Tastatur
    /// hervorgehobenen Ordner. No-op bei leerer Ergebnisliste (kein falsches
    /// Verhalten). `startNewChat` schließt Popover + setzt den Chat-Kontext.
    func confirmHighlightedNewChatProject(_ projects: [AgentProject]) {
        guard let id = newChatHighlightedProjectID,
              let project = projects.first(where: { $0.id == id }) else { return }
        startNewChat(in: project)
    }

    func createSession(provider: AgentProvider, kind: AgentSessionKind? = nil) {
        guard let selectedProject else { return }
        do {
            // Agent View hat keine externe Session-ID (es ist ein Dashboard
            // ueber viele Sessions). Auch der Titel ist anders. Terminals
            // heissen schlicht "Terminal" — der Live-Titel aus der Shell
            // (OSC 0/2) uebernimmt danach, solange der User nicht umbenennt.
            let title: String
            switch kind {
            case .agentView: title = "Agent View"
            case .terminal: title = "Terminal"
            default: title = "\(provider.displayName) Chat"
            }
            // Weg B (Superset-Prinzip): KEINE Vorab-Session-ID mehr. Claude
            // vergibt die ID selbst — wie Codex/Agent View. Der SessionStart-Hook
            // + Indexer-Merge binden die REALE, von Claude geschriebene ID nach.
            // Ein erzwungenes `--session-id` war die Wurzel der „No conversation
            // found"-Fehler (Claude persistierte nicht zuverlässig darunter).
            let externalSessionID: String? = nil
            let backendDefault = AppPreferences.shared.claudeGPTBackendDefaultModel
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let claudeBackendModel = provider == .claude
                && AppPreferences.shared.claudeGPTBackendEnabled
                && !backendDefault.isEmpty
                ? backendDefault
                : nil
            let session = try store.createSession(
                provider: provider,
                projectPath: selectedProject.path,
                title: title,
                model: AppPreferences.shared.resolvedCodexDefaultModelRaw(),
                reasoningEffort: AppPreferences.shared.codexReasoningEffortRaw,
                externalSessionID: externalSessionID,
                shouldLaunchOnOpen: true,
                kind: kind,
                // Multi-Account: neue Claude-Sessions laufen unter dem in den
                // Settings gewaehlten aktiven Profil (nil = Haupt-Account).
                claudeProfileName: provider == .claude
                    ? ClaudeAccountProfiles().activeProfileNameOrNil()
                    : nil,
                claudeBackendModel: claudeBackendModel
            )
            openTab(session.id)
            selectedSessionID = session.id
            sessionActionRequest = AgentSessionActionRequest(sessionID: session.id, kind: .start)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Fork (Claude Code)

    /// Forkt einen Claude-Chat: legt einen neuen Tab an und startet ihn als
    /// `claude --resume <quelle> --fork-session` — übernimmt den kompletten
    /// Stand der Quelle, zweigt aber in eine eigene Session-ID ab. Das
    /// Original läuft unverändert weiter. Die neue Fork-Session-ID bindet
    /// der SessionStart-Hook automatisch (siehe handleClaudeHookEvent).
    func forkSession(_ source: AgentChatSession) {
        guard source.isForkable,
              let sourceExternalID = source.externalSessionID,
              let project = workspace.projects.first(where: { $0.id == source.projectID }) else {
            return
        }
        do {
            let forked = try store.createSession(
                provider: .claude,
                projectPath: project.path,
                title: forkTitle(for: source.title),
                externalSessionID: nil, // wird nach Launch via Hook gebunden
                shouldLaunchOnOpen: true,
                kind: .chat,
                forkSourceSessionID: sourceExternalID,
                // Fork erbt das Account-Profil der Quelle — `--resume` der
                // Quell-Session funktioniert nur unter deren Config-Dir.
                claudeProfileName: source.claudeProfileName,
                claudeBackendModel: source.claudeBackendModel
            )
            // Farbe der Quelle erben, damit Fork und Original visuell
            // zusammengehören.
            if let color = source.color, !color.isEmpty {
                try? store.setSessionColor(id: forked.id, color: color)
            }
            openTab(forked.id)
            selectedSessionID = forked.id
            sessionActionRequest = AgentSessionActionRequest(sessionID: forked.id, kind: .start)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// "Foo" → "Foo (Fork)", "Foo (Fork)" → "Foo (Fork 2)", … — fortlaufend.
    func forkTitle(for base: String) -> String {
        let trimmed = base.trimmingCharacters(in: .whitespaces)
        if let range = trimmed.range(of: #" \(Fork( \d+)?\)$"#, options: .regularExpression) {
            let stem = String(trimmed[..<range.lowerBound])
            let suffix = trimmed[range]
            let current = suffix.range(of: #"\d+"#, options: .regularExpression)
                .flatMap { Int(suffix[$0]) } ?? 1
            return "\(stem) (Fork \(current + 1))"
        }
        return "\(trimmed) (Fork)"
    }

    /// Gemeinsamer „Forken"-Menüeintrag — nur für forkbare Claude-Chats
    /// sichtbar (sonst leer). Wird in allen Chat-Kontextmenüs eingehängt.
    @ViewBuilder
    func forkMenuItem(_ session: AgentChatSession) -> some View {
        if session.isForkable {
            Button("Forken", systemImage: "arrow.triangle.branch") {
                forkSession(session)
            }
        }
    }

    // MARK: - Move to Account (Claude Multi-Account)

    /// `true` für Sessions, die zu einem anderen Claude-Account umziehen
    /// können: normale Claude-Chats (kein Background/AgentView/Terminal).
    /// Laufend-Check passiert erst beim Klick — das Menü bleibt sichtbar,
    /// damit der Zustand nicht versteckt wird.
    func canMoveToAccount(_ session: AgentChatSession) -> Bool {
        session.provider == .claude && session.effectiveKind == .chat
    }

    /// Untermenü „Zu Account verschieben": listet alle Profile außer dem
    /// aktuellen der Session. Disabled solange die Session läuft — unter
    /// einem laufenden Prozess das Transcript wegzuverschieben wäre
    /// Datenverlust-Roulette.
    @ViewBuilder
    func moveToAccountMenu(_ session: AgentChatSession) -> some View {
        if canMoveToAccount(session) {
            let currentProfile = session.claudeProfileName ?? ClaudeAccountProfiles.mainProfileName
            let isRunning = terminalRegistry.controller(for: session.id)?.isRunning == true
            Menu("Zu Account verschieben", systemImage: "person.crop.circle.badge.checkmark") {
                ForEach(ClaudeAccountProfiles().profiles()) { profile in
                    if profile.name != currentProfile {
                        Button(moveTargetLabel(profile)) {
                            moveSession(session, toProfileNamed: profile.name)
                        }
                        .disabled(!profile.isLoggedIn)
                    }
                }
                if isRunning {
                    Divider()
                    Text("Session läuft — zuerst stoppen")
                }
            }
            .disabled(isRunning)
        }
    }

    private func moveTargetLabel(_ profile: ClaudeAccountProfile) -> String {
        if let email = profile.emailAddress {
            return "\(profile.name) (\(email))"
        }
        return "\(profile.name) (nicht eingeloggt)"
    }

    /// Verschiebt einen Chat zu einem anderen Claude-Account: Transcript in
    /// den Ziel-Profil-Root bewegen (der Verlauf ist nicht account-gebunden,
    /// nur sein Ablageort zählt), dann den Profil-Stempel der Session
    /// aktualisieren. Ab dem nächsten Resume läuft der Chat unter dem
    /// Ziel-Account und verbraucht dessen Kontingent.
    func moveSession(_ session: AgentChatSession, toProfileNamed targetName: String) {
        guard canMoveToAccount(session) else { return }
        guard terminalRegistry.controller(for: session.id)?.isRunning != true else {
            errorMessage = "„\(session.title)“ läuft noch — bitte zuerst stoppen, dann verschieben."
            return
        }
        let profileName: String? = targetName == ClaudeAccountProfiles.mainProfileName ? nil : targetName
        do {
            // Ohne externalSessionID gibt es (noch) kein Transcript — dann
            // reicht der Stempel; der Chat startet direkt im Ziel-Account.
            if let externalID = session.externalSessionID, !externalID.isEmpty,
               let project = workspace.projects.first(where: { $0.id == session.projectID }) {
                try ClaudeAccountProfiles().moveTranscript(
                    externalSessionID: externalID,
                    cwd: session.subagentCwd ?? project.path,
                    toProfile: profileName
                )
            }
            try store.setClaudeSessionProfile(id: session.id, profileName: profileName)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func markSession(_ id: UUID, status: AgentChatStatus) {
        do {
            if status == .closed || status == .archived {
                terminalRegistry.terminate(sessionID: id)
            }
            try store.updateSession(id: id) { session in
                session.status = status
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func relaunch(_ id: UUID) {
        markSession(id, status: .pending)
        selectedSessionID = id
    }

    func renameSession(id: UUID, title: String) {
        if let error = viewModel.renameSession(id: id, title: title) { errorMessage = error }
    }

    func setSessionGroup(id: UUID, groupName: String?) {
        if let error = viewModel.setSessionGroup(id: id, groupName: groupName) { errorMessage = error }
    }

    func setSessionColor(id: UUID, color: String?) {
        if let error = viewModel.setSessionColor(id: id, color: color) { errorMessage = error }
    }

    /// Wiederverwendetes „Tab-Farbe"-Submenu (8er-Palette + Provider-Reset).
    /// `allowsBulk: false` (strikt-singuläre Kontexte, z. B. Einzelansicht)
    /// färbt nur DIESE Session — ohne „Farbe für N Tabs"-Überraschung.
    @ViewBuilder
    func tabColorMenu(for session: AgentChatSession, allowsBulk: Bool = true) -> some View {
        Menu(allowsBulk ? bulkLabel("Tab-Farbe", "Farbe für %d Tabs", for: session) : "Tab-Farbe") {
            ForEach(AgentChatColor.palette, id: \.self) { color in
                Button {
                    if allowsBulk {
                        setColorForSelection(session, color: color)
                    } else {
                        setSessionColor(id: session.id, color: color)
                    }
                } label: {
                    Label {
                        Text(AgentChatColorName.label(for: color))
                    } icon: {
                        Image(nsImage: colorSwatchImage(hex: color))
                    }
                }
            }
            Divider()
            Button("Provider-Farbe verwenden", systemImage: "arrow.uturn.backward") {
                if allowsBulk {
                    setColorForSelection(session, color: nil)
                } else {
                    setSessionColor(id: session.id, color: nil)
                }
            }
        }
    }

    // MARK: - Pinning

    func pinSession(_ id: UUID) {
        guard !pinnedSessionIDs.contains(id) else { return }
        pinnedSessionIDs.append(id)
    }

    func unpinSession(_ id: UUID) {
        pinnedSessionIDs.removeAll { $0 == id }
    }

    func togglePin(_ id: UUID) {
        pinnedSessionIDs.contains(id) ? unpinSession(id) : pinSession(id)
    }
}
