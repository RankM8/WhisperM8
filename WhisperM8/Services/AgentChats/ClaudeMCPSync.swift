import Foundation

/// Gleicht die User-MCP-Server (`mcpServers` in der `.claude.json` jedes
/// Kontos) über alle Claude-Konten an. Claude Code speichert sie pro
/// `CLAUDE_CONFIG_DIR`; ein Server, den man in einem Chat einrichtet, landet nur
/// in dessen Konto (Analyse 11.10.2026: nach einem Angleich um 17:13 kam `figma`
/// eine Stunde später nur in ai2 dazu).
///
/// Bewusst über Claudes eigenen Befehl `claude mcp add-json -s user` — keine
/// Schreibzugriffe auf die `.claude.json`, keine Systemdatei
/// (`managedMcpServers` wäre maschinenweit, bräuchte Admin-Rechte und kollidiert
/// mit Firmen-Richtlinien). Regeln:
/// - **nur ergänzen, nie löschen** — wer einen Server loswerden will, entfernt
///   ihn in allen Konten;
/// - **Konflikte nie raten:** haben Konten unter demselben Namen verschiedene
///   Definitionen, wird der Server übersprungen und gemeldet;
/// - **Ausnahmen** (`AppPreferences.mcpSyncExcludedServers`) bleiben pro Konto.
/// Definitionen enthalten mitunter Tokens (Header) — sie werden nie geloggt.
/// **Keine Secrets in argv** (LR-KO-002): `claude mcp add-json` nimmt das JSON
/// nur als Argument (kein stdin, keine Datei — `--help` geprüft 19.10.2026), das
/// würde Header-/Env-Tokens für die Dauer des Aufrufs in `ps` zeigen. Server mit
/// Secrets (`definitionHasSecrets`) verteilt der Angleich deshalb NICHT; sie
/// stehen als „manuell" im Plan und müssen je Konto selbst eingerichtet werden.
/// Ein Direktschreiben in die `.claude.json` kam nicht in Frage: Claude Code
/// schreibt die Datei laufend selbst um (verlorene Updates) und die Invariante
/// „kein Schreibzugriff auf die .claude.json" gilt weiter.
struct ClaudeMCPSync {
    var profiles: ClaudeAccountProfiles = ClaudeAccountProfiles()
    var processRunner: ProcessRunner = DefaultProcessRunner()
    var commandResolver: (String) -> String? = { AgentCommandBuilder.commandPath($0) }

    /// Server × Konto.
    struct Snapshot: Equatable {
        /// In Anzeige-Reihenfolge: `main` zuerst.
        var profileNames: [String]
        /// Name → (Konto → Definition als kanonisches JSON).
        var servers: [String: [String: String]]

        var serverNames: [String] { servers.keys.sorted() }

        func profiles(having server: String) -> Set<String> {
            Set(servers[server]?.keys.map { $0 } ?? [])
        }

        func missingProfiles(for server: String) -> [String] {
            let having = profiles(having: server)
            return profileNames.filter { !having.contains($0) }
        }

        /// Verschiedene Definitionen unter demselben Namen.
        func hasConflict(_ server: String) -> Bool {
            Set(servers[server]?.values.map { $0 } ?? []).count > 1
        }
    }

    struct Addition: Equatable {
        var profile: String
        var server: String
        var definitionJSON: String
    }

    struct Plan: Equatable {
        var additions: [Addition] = []
        /// Server mit widersprüchlichen Definitionen — werden nicht verteilt.
        var conflicts: [String] = []
        var excluded: [String] = []
        /// Server mit Secrets in der Definition — nie über argv verteilt.
        var manual: [String] = []
    }

    struct Outcome: Equatable {
        var added: [Addition] = []
        var failed: [(addition: Addition, message: String)] = []

        static func == (lhs: Outcome, rhs: Outcome) -> Bool {
            lhs.added == rhs.added && lhs.failed.map(\.addition) == rhs.failed.map(\.addition)
        }
    }

    // MARK: - Lesen

    func snapshot() -> Snapshot {
        let names = profiles.profiles().map(\.name)
        var servers: [String: [String: String]] = [:]
        for name in names {
            let json = ClaudeAccountProfiles.readJSONObject(at: profiles.claudeJSONURL(forProfile: name))
            for (server, definition) in (json?["mcpServers"] as? [String: Any]) ?? [:] {
                guard let canonical = Self.canonicalJSON(definition) else { continue }
                servers[server, default: [:]][name] = canonical
            }
        }
        return Snapshot(profileNames: names, servers: servers)
    }

    static func canonicalJSON(_ value: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Secret-Erkennung (pur)

    private static let secretKeyPattern = try! NSRegularExpression(
        pattern: "authorization|token|secret|passw|api[-_]?key|bearer|credential", options: .caseInsensitive)

    /// Konservativ: lieber einmal zu viel „manuell" als ein Token in argv.
    static func definitionHasSecrets(_ canonicalJSON: String) -> Bool {
        guard let data = canonicalJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return true  // unlesbar → nicht verteilen
        }
        if let headers = object["headers"] as? [String: Any], !headers.isEmpty { return true }
        if let env = object["env"] as? [String: Any], !env.isEmpty { return true }
        if containsSecretKey(object) { return true }
        if let args = object["args"] as? [Any],
           args.contains(where: { ($0 as? String).map(looksSecret) ?? false }) { return true }
        if let urlString = object["url"] as? String, let components = URLComponents(string: urlString) {
            if components.user != nil || components.password != nil { return true }
            if components.queryItems?.contains(where: { looksSecret($0.name) }) == true { return true }
        }
        return false
    }

    private static func looksSecret(_ text: String) -> Bool {
        secretKeyPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
            || text.hasPrefix("sk-")
    }

    private static func containsSecretKey(_ value: Any) -> Bool {
        if let dict = value as? [String: Any] {
            for (key, inner) in dict {
                if looksSecret(key), let text = inner as? String, !text.isEmpty { return true }
                if containsSecretKey(inner) { return true }
            }
        } else if let array = value as? [Any] {
            return array.contains(where: containsSecretKey)
        }
        return false
    }

    // MARK: - Planen (pur)

    static func plan(_ snapshot: Snapshot, excluded: Set<String>) -> Plan {
        var plan = Plan()
        for server in snapshot.serverNames {
            if excluded.contains(server) {
                plan.excluded.append(server)
                continue
            }
            if snapshot.hasConflict(server) {
                plan.conflicts.append(server)
                continue
            }
            guard let definition = snapshot.servers[server]?.values.first else { continue }
            if definitionHasSecrets(definition) {
                if !snapshot.missingProfiles(for: server).isEmpty { plan.manual.append(server) }
                continue
            }
            for profile in snapshot.missingProfiles(for: server) {
                plan.additions.append(Addition(profile: profile, server: server, definitionJSON: definition))
            }
        }
        return plan
    }

    // MARK: - Ausführen

    /// Trägt die geplanten Server über `claude mcp add-json -s user` ein —
    /// `main` ohne `CLAUDE_CONFIG_DIR`, Profile mit ihrem Ordner.
    func apply(_ plan: Plan) async -> Outcome {
        var outcome = Outcome()
        guard !plan.additions.isEmpty else { return outcome }
        guard let claude = commandResolver("claude") else {
            outcome.failed = plan.additions.map { ($0, "claude nicht gefunden") }
            return outcome
        }
        for addition in plan.additions {
            var environment: [String: String] = [:]
            if addition.profile != ClaudeAccountProfiles.mainProfileName {
                environment["CLAUDE_CONFIG_DIR"] = profiles.configDir(forProfile: addition.profile).path
            }
            do {
                let result = try await processRunner.run(
                    executable: claude,
                    arguments: ["mcp", "add-json", "-s", "user", addition.server, addition.definitionJSON],
                    workingDirectory: FileManager.default.temporaryDirectory.path,
                    environmentOverrides: environment,
                    timeout: 30
                )
                if result.exitCode == 0 {
                    outcome.added.append(addition)
                } else {
                    // stderr kann die Definition spiegeln — nur die erste Zeile, gekürzt.
                    let firstLine = result.stderr.split(separator: "\n").first.map(String.init) ?? "Exit \(result.exitCode)"
                    outcome.failed.append((addition, String(firstLine.prefix(120))))
                }
            } catch {
                outcome.failed.append((addition, error.localizedDescription))
            }
        }
        Logger.agentStore.notice(
            "claude_mcp_sync added=\(outcome.added.count) failed=\(outcome.failed.count) conflicts=\(plan.conflicts.joined(separator: ","), privacy: .public)")
        return outcome
    }

    /// Start-Hook: nur bei eingeschaltetem Auto-Angleich, nur ergänzen.
    static func runAtLaunchIfEnabled(preferences: AppPreferences = .shared) async {
        guard preferences.isMCPAutoSyncEnabled else { return }
        let sync = ClaudeMCPSync()
        let plan = Self.plan(sync.snapshot(), excluded: Set(preferences.mcpSyncExcludedServers))
        guard !plan.additions.isEmpty else { return }
        _ = await sync.apply(plan)
    }
}
