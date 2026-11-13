import Foundation

/// Hintergrund-Agents und ihre Kopien im Index-Merge (Befunde 11.11.2026).
///
/// Claudes Daemon startet einen Hintergrund-Agent bei Bedarf als Abzweig neu
/// (`dispatch.source = "respawn"`, `launch.fork = true`): Die Unterhaltung läuft
/// unter einer NEUEN Session-ID weiter, deren Verlauf eine vollständige Kopie
/// mit den alten Zeitstempeln ist. Der Merge legte dafür bisher einen zweiten
/// Chat an (Jarvis 64306879 → Kopie 84ca7666 als eigener Sidebar-Eintrag).
///
/// Außerdem entstand ein Doppel, wenn der Scan einen neuen Verlauf fand, bevor
/// der von Hand angelegte Chat seine ID gebunden hatte (Fin: Verlauf 29 s nach
/// dem Tab, Adoptionsfenster 5 s → zweiter Chat mit derselben ID).
extension AgentSessionStore {
    /// Liefert neue Session-ID → Ursprung für alle lebenden Daemon-Abzweige
    /// aller Konten. Im Test überschreibbar (sonst läse der Merge das echte
    /// Roster).
    nonisolated(unsafe) static var respawnForkOriginsProvider: () -> [String: String] = {
        let profiles = ClaudeAccountProfiles()
        return SupervisorRosterReader.liveForkOrigins(
            configDirs: profiles.profileNames().map { profiles.configDir(forProfile: $0) }
        )
    }

    /// Sessions, deren Tab nur an einen Hintergrund-Agent angedockt ist. Sie
    /// wandern bei einem Respawn mit — sonst verlöre der Chat @self und Board.
    nonisolated(unsafe) static var attachedSessionIDsProvider: () -> Set<UUID> = {
        AgentSessionTokenRegistry.shared.attachSessionIDs()
    }

    /// Wie lange ein gestarteter, noch ungebundener Chat neue Verläufe im
    /// selben Projekt für sich reserviert, bevor der Scan sie als eigene
    /// Chats anlegt.
    static let unboundLaunchReservation: TimeInterval = 10 * 60

    /// Läuft unter dem Store-Lock VOR dem eigentlichen Merge: bindet Chats auf
    /// Daemon-Abzweige um und nennt die Verläufe, die der Merge diesmal NICHT
    /// als Chat anlegen oder adoptieren darf.
    ///
    /// - Abgelöste IDs (`supersededExternalSessionIDs`) → überspringen.
    /// - Abzweig eines gebundenen Chats, dessen Prozess nicht in einem Tab
    ///   läuft → Chat wandert auf die neue ID. Läuft der Ursprung noch im Tab,
    ///   ist die Kopie ein zweiter Agent: kein Chat, nur ein Log-Eintrag.
    /// - Neuer Verlauf, während im selben Projekt ein gestarteter Chat noch
    ///   auf seine ID wartet → zurückstellen, bis der Hook gebunden hat.
    static func applyRespawnForksAndReservations(
        to workspace: inout AgentWorkspace,
        indexedSessions: [IndexedAgentSession],
        forkOrigins: [String: String],
        activeSessionIDs: Set<UUID>?,
        didChange: inout Bool,
        now: Date = Date()
    ) -> Set<String> {
        var skipped = Set<String>()
        let attached = attachedSessionIDsProvider()
        var boundIndexByID: [String: Int] = [:]
        for index in workspace.sessions.indices where workspace.sessions[index].provider == .claude {
            if let id = workspace.sessions[index].externalSessionID?.lowercased() {
                if boundIndexByID[id] == nil { boundIndexByID[id] = index }
            }
            for old in workspace.sessions[index].supersededExternalSessionIDs ?? [] {
                skipped.insert(old.lowercased())
            }
        }

        for indexed in indexedSessions where indexed.provider == .claude {
            let id = indexed.externalSessionID.lowercased()
            guard boundIndexByID[id] == nil, !skipped.contains(id) else { continue }

            if let origin = forkOrigins[id], let index = boundIndexByID[origin] {
                let session = workspace.sessions[index]
                // Ein Tab, der nur angedockt ist, führt keine eigene Unterhaltung.
                let runsInTab = !attached.contains(session.id)
                    && (activeSessionIDs?.contains(session.id) ?? (session.status == .running))
                if runsInTab {
                    Logger.claudeBinding.notice(
                        "respawn_fork_copy_skipped localID=\(session.id.uuidString, privacy: .public) origin=\(origin, privacy: .public) copy=\(id, privacy: .public) — Ursprung läuft im Tab"
                    )
                } else {
                    rebindToRespawnFork(&workspace.sessions[index], newID: indexed.externalSessionID)
                    boundIndexByID[origin] = nil
                    boundIndexByID[id] = index
                    // Der alte Verlauf ist ab jetzt abgelöst — auch in diesem Lauf.
                    skipped.insert(origin)
                    didChange = true
                    Logger.claudeBinding.notice(
                        "respawn_fork_rebound localID=\(session.id.uuidString, privacy: .public) from=\(origin, privacy: .public) to=\(id, privacy: .public) source=index"
                    )
                }
                skipped.insert(id)
                continue
            }

            if hasReservingUnboundLaunch(for: indexed, in: workspace, now: now) {
                skipped.insert(id)
            }
        }
        // Gebundene IDs aktualisiert der Merge ganz normal.
        return skipped.subtracting(boundIndexByID.keys)
    }

    /// Chat auf den Abzweig umbinden und die alte ID als abgelöst merken.
    static func rebindToRespawnFork(_ session: inout AgentChatSession, newID: String) {
        guard let old = session.externalSessionID,
              old.caseInsensitiveCompare(newID) != .orderedSame else { return }
        var superseded = session.supersededExternalSessionIDs ?? []
        if !superseded.contains(where: { $0.caseInsensitiveCompare(old) == .orderedSame }) {
            superseded.append(old)
        }
        session.supersededExternalSessionIDs = superseded
        session.externalSessionID = newID
    }

    /// Store-Weg für die Detailansicht (Attach an einen Abzweig).
    func rebindToRespawnFork(localSessionID: UUID, newID: String) throws {
        try mutateWorkspace { workspace in
            guard let index = workspace.sessions.firstIndex(where: { $0.id == localSessionID }) else { return }
            Self.rebindToRespawnFork(&workspace.sessions[index], newID: newID)
        }
    }

    /// Wartet im selben Projekt ein gestarteter Claude-Chat, der vor diesem
    /// Verlauf angelegt wurde, noch auf seine ID? Dann gehört der Verlauf sehr
    /// wahrscheinlich ihm; der SessionStart-Hook bindet ihn gleich.
    static func hasReservingUnboundLaunch(
        for indexed: IndexedAgentSession,
        in workspace: AgentWorkspace,
        now: Date
    ) -> Bool {
        let path = canonicalProjectPath(indexed.cwd)
        guard let project = workspace.projects.first(where: { $0.path == path }) else { return false }
        return workspace.sessions.contains { session in
            session.provider == .claude
                && session.projectID == project.id
                && session.effectiveKind != .terminal
                && session.externalSessionID == nil
                && session.hasLaunchedInitialPrompt
                && session.status == .running
                && session.createdAt <= indexed.createdAt.addingTimeInterval(5)
                && now.timeIntervalSince(session.createdAt) < unboundLaunchReservation
        }
    }

    /// Bevorzugter Halter einer externen ID, wenn mehrere Chats sie tragen:
    /// der von Hand angelegte vor dem automatisch eingelesenen.
    static func prefersAsExternalHolder(_ candidate: AgentChatSession, over current: AgentChatSession) -> Bool {
        candidate.isManuallyCreated && !current.isManuallyCreated
    }
}

/// Doppel: mehrere Chats mit derselben externen Sitzung. Nur zur Anzeige als
/// Vorschlag — archiviert oder gelöscht wird nichts automatisch.
struct AgentSessionDuplicateGroup: Equatable {
    var externalSessionID: String
    /// Der Chat, der die Sitzung führt (von Hand angelegt, sonst der älteste).
    var keeper: AgentChatSession
    /// Kandidaten zum Archivieren.
    var duplicates: [AgentChatSession]

    static func groups(in workspace: AgentWorkspace) -> [AgentSessionDuplicateGroup] {
        var byKey: [String: [AgentChatSession]] = [:]
        for session in workspace.sessions where session.status != .archived {
            guard let id = session.externalSessionID, !id.isEmpty else { continue }
            byKey["\(session.provider.rawValue)|\(id.lowercased())", default: []].append(session)
        }
        return byKey.values.compactMap { sessions -> AgentSessionDuplicateGroup? in
            guard sessions.count > 1 else { return nil }
            let sorted = sessions.sorted(by: keeperPrecedes)
            return AgentSessionDuplicateGroup(
                externalSessionID: sorted[0].externalSessionID ?? "",
                keeper: sorted[0],
                duplicates: Array(sorted.dropFirst())
            )
        }
        .sorted { $0.keeper.createdAt < $1.keeper.createdAt }
    }

    /// Wer von mehreren Chats derselben Sitzung sie führt: der von Hand
    /// angelegte, sonst der älteste (eine Fehlbindung trifft den später
    /// angelegten: Fork auf Quelle, Rückfall auf ein fremdes Transcript),
    /// bei Gleichstand fest nach UUID. Gilt auch für Sammel-Starts
    /// (`AgentCollectiveStartPlanner`).
    static func keeperPrecedes(_ lhs: AgentChatSession, _ rhs: AgentChatSession) -> Bool {
        if lhs.isManuallyCreated != rhs.isManuallyCreated { return lhs.isManuallyCreated }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
