import Foundation

/// Kontowechsel ohne Stoppen (Plan `docs/plans/claude-account-switch-ohne-stopp.md`,
/// Slice 2): entscheidet je Chat, WIE er ins Zielkonto kommt. Pur — die Fakten
/// (Laufzustand, Status, Entwurf, Trust) liefert der Aufrufer.
///
/// Grundlage bleibt der `AccountMovePlanner`; geändert wird nur, was mit
/// „läuft gerade" passiert. Statt übersprungen zu werden, wechselt ein
/// laufender Chat jetzt selbst: ein ruhender sofort (anhalten, umziehen, im Tab
/// neu starten), ein arbeitender nach seinem Turn.
enum AccountSwitchPlanner {
    /// Worauf ein vorgemerkter Chat wartet.
    enum WaitReason: String, Equatable {
        /// Ein Turn läuft — der Wechsel folgt, sobald er fertig ist.
        case turnRunning
        /// Claude wartet auf eine Antwort (z. B. Permission-Dialog) — erst
        /// beantworten, dann wechselt der Chat.
        case awaitingInput
        /// Im Eingabefeld steht vermutlich ungesendeter Text; ein Beenden der
        /// TUI verwürfe ihn. Abschicken oder leeren, dann wechselt der Chat.
        case unsentInput
        /// Turn fertig, aber Hintergrund-Tasks (Bash `run_in_background`,
        /// Subagents) laufen noch — sie stürben mit dem Prozess (E2E-Test
        /// 11.10.2026: ein `sleep 25` im Hintergrund wurde `killed`).
        case backgroundTasks

        var label: String {
            switch self {
            case .turnRunning: return String(localized: "Working — switches after the turn")
            case .awaitingInput: return String(localized: "Waiting for your answer — switches afterwards")
            case .unsentInput: return String(localized: "Text in the input field — switches after sending")
            case .backgroundTasks: return String(localized: "Background tasks still running — switches afterwards")
            }
        }
    }

    enum BlockReason: String, Equatable {
        /// Die eigene Session (CLI): sie würde ihren eigenen Prozess beenden.
        case ownSession
        /// Zielkonto hat den Ordner nie freigegeben: beim Neustart erschiene
        /// Claudes Trust-Dialog mit Vorauswahl „No, exit" (Prototyp P3). Ein
        /// unbeobachteter Wechsel nach dem Turn wäre eine Falle — nur ein
        /// ruhender Chat wechselt dann, weil der User gerade hinschaut.
        case trustMissing

        var label: String {
            switch self {
            case .ownSession: return String(localized: "own session — cannot stop itself")
            case .trustMissing: return String(localized: "folder not approved in the target account — switch again after the turn")
            }
        }
    }

    struct Decision: Equatable {
        var targetProfile: String?
        /// Läuft nicht — Transcript sofort umziehen.
        var moveNow: [AccountMovePlanner.Candidate] = []
        /// Läuft und ruht — anhalten, umziehen, im Tab neu starten.
        var switchNow: [AccountMovePlanner.Candidate] = []
        /// Läuft und ist beschäftigt — Vormerkung bis zum Turn-Ende.
        var waitForTurn: [(candidate: AccountMovePlanner.Candidate, reason: WaitReason)] = []
        var blocked: [(candidate: AccountMovePlanner.Candidate, reason: BlockReason)] = []
        /// Übrige Skip-Gründe des Planers (nie „läuft gerade").
        var skipped: [AccountMovePlanner.Skip] = []

        var actionableCount: Int { moveNow.count + switchNow.count + waitForTurn.count }

        static func == (lhs: Decision, rhs: Decision) -> Bool {
            lhs.targetProfile == rhs.targetProfile
                && lhs.moveNow == rhs.moveNow
                && lhs.switchNow == rhs.switchNow
                && lhs.waitForTurn.map(\.candidate) == rhs.waitForTurn.map(\.candidate)
                && lhs.waitForTurn.map(\.reason) == rhs.waitForTurn.map(\.reason)
                && lhs.blocked.map(\.candidate) == rhs.blocked.map(\.candidate)
                && lhs.blocked.map(\.reason) == rhs.blocked.map(\.reason)
                && lhs.skipped == rhs.skipped
        }
    }

    static func decide(
        plan: AccountMovePlanner.Plan,
        isCaller: (UUID) -> Bool = { _ in false },
        status: (UUID) -> AgentSessionRuntimeStatus?,
        mayHaveUnsentInput: (UUID) -> Bool,
        openBackgroundTasks: (UUID) -> Int = { _ in 0 },
        targetTrustsProject: (UUID) -> Bool
    ) -> Decision {
        var decision = Decision(targetProfile: plan.targetProfile, moveNow: plan.movable)
        decision.skipped = plan.skipped.filter { $0.reason != .running }
        let running = plan.skipped.filter { $0.reason == .running }.map(\.candidate)
        guard !running.isEmpty else { return decision }

        // Neu planen, als liefen sie nicht: so greifen die übrigen Regeln
        // (z. B. Kollision im Ziel) vor jedem Anhalten — ein Chat, der danach
        // doch nicht umziehen dürfte, wird gar nicht erst gestoppt.
        let replanned = AccountMovePlanner.plan(
            candidates: running.map { candidate in
                var stopped = candidate
                stopped.isRunning = false
                return stopped
            },
            targetProfile: plan.targetProfile,
            targetIsLoggedIn: true
        )
        decision.skipped.append(contentsOf: replanned.skipped)

        for candidate in replanned.movable {
            let id = candidate.sessionID
            if isCaller(id) {
                decision.blocked.append((candidate, .ownSession))
                continue
            }
            if let reason = waitReason(
                status: status(id),
                mayHaveUnsentInput: mayHaveUnsentInput(id),
                openBackgroundTasks: openBackgroundTasks(id)
            ) {
                if targetTrustsProject(id) {
                    decision.waitForTurn.append((candidate, reason))
                } else {
                    decision.blocked.append((candidate, .trustMissing))
                }
            } else {
                decision.switchNow.append(candidate)
            }
        }
        return decision
    }

    /// `nil` = darf jetzt wechseln. Unbekannter Status zählt als beschäftigt:
    /// lieber einen Moment warten als einen Turn abschießen.
    static func waitReason(
        status: AgentSessionRuntimeStatus?,
        mayHaveUnsentInput: Bool,
        openBackgroundTasks: @autoclosure () -> Int = 0
    ) -> WaitReason? {
        switch status {
        case .idle?, .stopped?, .errored?:
            if mayHaveUnsentInput { return .unsentInput }
            // Erst hier auswerten: der erste Scan liest das ganze Transcript
            // (Review 11.10.2026: ~0,3 s bei 29 MB) — für arbeitende Chats
            // oder solche mit Entwurf ist die Antwort ohnehin schon klar.
            return openBackgroundTasks() > 0 ? .backgroundTasks : nil
        case .awaitingInput?:
            return .awaitingInput
        case .working?, nil:
            return .turnRunning
        }
    }
}

/// Nur lesende Vorab-Prüfungen gegen die `.claude.json` des Zielkontos —
/// WhisperM8 schreibt dort nie (Leitplanke des Plans).
enum ClaudeAccountPreflight {
    /// Hat das Konto den Ordner (oder einen übergeordneten) im Trust-Dialog
    /// freigegeben? Fehlt die Datei oder ist sie unlesbar, gilt das als „nein".
    static func trustsProject(cwd: String, claudeJSON: URL) -> Bool {
        trustsProject(cwd: cwd, trustedPaths: trustedPaths(claudeJSON: claudeJSON))
    }

    /// Alle freigegebenen Pfade eines Kontos — einmal lesen, für viele Chats
    /// prüfen (die `.claude.json` von `main` ist schnell mehrere MB groß).
    static func trustedPaths(claudeJSON: URL) -> Set<String> {
        guard let projects = readJSON(claudeJSON)?["projects"] as? [String: Any] else { return [] }
        return Set(projects.compactMap { path, value in
            (value as? [String: Any])?["hasTrustDialogAccepted"] as? Bool == true ? path : nil
        })
    }

    static func trustsProject(cwd: String, trustedPaths: Set<String>) -> Bool {
        var path = ClaudeSharedMemoryPath.realPath(cwd)
        while true {
            if trustedPaths.contains(path) { return true }
            let parent = (path as NSString).deletingLastPathComponent
            if parent == path || parent.isEmpty { return false }
            path = parent
        }
    }

    /// Namen der User-MCP-Server (`mcpServers` auf oberster Ebene).
    static func userMCPServers(claudeJSON: URL) -> Set<String> {
        Set((readJSON(claudeJSON)?["mcpServers"] as? [String: Any])?.keys.map { $0 } ?? [])
    }

    /// Projektbezogene MCP-Server (Local-Scope, `projects[<pfad>].mcpServers`)
    /// für die genannten Arbeitsverzeichnisse — roh und als realpath, weil
    /// Claude den Schlüssel so ablegt, wie das Verzeichnis beim Anlegen hieß.
    static func localMCPServers(claudeJSON: URL, cwds: [String]) -> Set<String> {
        guard let projects = readJSON(claudeJSON)?["projects"] as? [String: Any] else { return [] }
        var names: Set<String> = []
        for cwd in cwds {
            for key in Set([cwd, ClaudeSharedMemoryPath.realPath(cwd)]) {
                if let servers = (projects[key] as? [String: Any])?["mcpServers"] as? [String: Any] {
                    names.formUnion(servers.keys)
                }
            }
        }
        return names
    }

    /// MCP-Server, die die Herkunftskonten haben, das Zielkonto aber nicht —
    /// User-Scope plus Local-Scope der betroffenen Projekte (Analyse
    /// 11.10.2026: in main hängen 17 Local-Server an 13 Repos, die Profile
    /// haben fast keine; die erste Fassung verglich nur den User-Scope).
    /// Projekt-Scope (`.mcp.json`) gilt ohnehin für jedes Konto.
    static func missingMCPServers(
        sourceProfiles: Set<String?>,
        targetProfile: String?,
        cwds: [String] = [],
        profiles: ClaudeAccountProfiles = ClaudeAccountProfiles()
    ) -> [String] {
        func servers(_ profile: String?) -> Set<String> {
            let json = profiles.claudeJSONURL(forProfile: profile ?? ClaudeAccountProfiles.mainProfileName)
            return userMCPServers(claudeJSON: json).union(localMCPServers(claudeJSON: json, cwds: cwds))
        }
        let target = servers(targetProfile)
        let sources = sourceProfiles.reduce(into: Set<String>()) { $0.formUnion(servers($1)) }
        return sources.subtracting(target).sorted()
    }

    private static func readJSON(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
