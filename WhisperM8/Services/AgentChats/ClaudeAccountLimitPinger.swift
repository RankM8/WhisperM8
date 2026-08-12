import Foundation

/// Erneuert den abgelaufenen OAuth-Token eines Account-Profils über die
/// Claude-CLI statt über einen eigenen OAuth-POST: ein headless
/// `claude -p`-Mini-Prompt („Ping") unter dem CLAUDE_CONFIG_DIR des Profils.
///
/// Der Grund ist gemessen (2026-08-09): WhisperM8s direkter POST auf
/// `console.anthropic.com/v1/oauth/token` wurde in der Praxis ZU NULL PROZENT
/// akzeptiert — der Endpoint ist streng pro IP gedrosselt (429-Sperren im
/// 25+-Minuten-Bereich), und mit mehreren Profilen war jeder Update-Klick ein
/// POST-Burst. Der Refresh der CLI geht dagegen zuverlässig durch: ein
/// `claude -p "ok"` mit seit 12 Tagen abgelaufenem Token rotierte das
/// Keychain-Secret in unter 5 s, danach lieferte der oauth/usage-Endpoint
/// sofort 200. Die Rotation gehört deshalb exklusiv der CLI — das beseitigt
/// nebenbei das Risiko, dass App und eine parallel startende CLI sich
/// gegenseitig den Refresh-Token entwerten.
///
/// Nebenwirkungen und ihre Behandlung:
/// - Der Ping kostet einen Haiku-Einzeiler und startet bei unbenutztem
///   Account ein frisches 5h-Fenster → er läuft NUR auf expliziten
///   User-Klick (Update-Button / ↻ im Popover), nie automatisch.
/// - Die CLI schreibt ein Session-JSONL unter `<config>/projects/…`, und der
///   FSEvents-Monitor importierte eine Test-Ping-Session binnen Sekunden in
///   den Workspace. Doppelschutz: Der Ping läuft in einem festen
///   Arbeitsordner, dessen encodiertes `projects/`-Verzeichnis der Indexer
///   überspringt (`isPingProjectsDirectory`), und nach dem Lauf wird das
///   Verzeichnis gelöscht.
/// - Profile mit laufender Session werden übersprungen — deren CLI-Prozess
///   hält den Token selbst frisch.
/// - Toter Login (Refresh-Token abgelehnt): die CLI bricht mit
///   „Failed to authenticate: OAuth session expired and could not be
///   refreshed" ab (exit 1, verifiziert am Profil ohne Keychain-Token) —
///   wird als `.loginRequired` gemeldet statt als generischer Fehler.
struct ClaudeAccountLimitPinger {
    /// Fester Name des Ping-Arbeitsordners (cwd aller Pings).
    static let workDirectoryName = "whisperm8-limit-ping"

    /// Erkennt das encodierte `projects/`-Verzeichnis des Ping-Ordners: die
    /// CLI ersetzt Pfad-Trennzeichen durch `-`, die letzte Pfad-Komponente
    /// bleibt dabei als Suffix erhalten — unabhängig davon, wo der Ordner
    /// liegt und wie Sonderzeichen davor encodiert werden.
    static func isPingProjectsDirectory(_ name: String) -> Bool {
        name.hasSuffix("-" + workDirectoryName)
    }

    enum Outcome: Equatable {
        /// Ping erfolgreich — das Keychain-Secret ist rotiert, der nächste
        /// passive Usage-Fetch läuft mit frischem Token.
        case refreshed
        /// Unter dem Profil läuft eine Session — kein Ping nötig.
        case skippedBusy
        /// Letzter Ping/Fehlversuch liegt kurz zurück.
        case skippedCooldown(until: Date)
        /// Die CLI konnte sich nicht authentifizieren — nur ein neuer
        /// Browser-Login hilft.
        case loginRequired
        /// `claude` nicht gefunden.
        case claudeMissing
        case failed(String)
    }

    var profiles = ClaudeAccountProfiles()
    var commandResolver: (String) -> String? = { AgentCommandBuilder.commandPath($0) }
    var processRunner: ProcessRunner = DefaultProcessRunner()
    var now: () -> Date = Date.init
    var throttle: ClaudeTokenRefreshThrottle = .shared
    var busyProfileNames: () async -> Set<String> = ClaudeAccountUsageFetcher.defaultBusyProfileNames
    var makeSessionID: () -> UUID = UUID.init
    /// Haiku braucht wenige Sekunden; großzügig für kalte Starts (Plugin-Sync,
    /// langsame erste Läufe).
    var timeout: TimeInterval = 90
    var workDirectory: URL = defaultWorkDirectory()

    /// Erfolg: der frische Token hält Stunden, ein zweiter Ping in dieser
    /// Zeit wäre reine Quota-Verschwendung.
    static let successCooldown: TimeInterval = 10 * 60
    /// Toter Login: ein zweiter Ping ändert nichts, erst der Re-Login.
    static let loginRequiredCooldown: TimeInterval = 15 * 60
    static let failureCooldown: TimeInterval = 5 * 60

    static func defaultWorkDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("WhisperM8", isDirectory: true)
            .appendingPathComponent(workDirectoryName, isDirectory: true)
    }

    /// Pingt EIN Profil (Aufrufer serialisiert — nie mehrere Profile
    /// parallel, das wäre wieder ein Burst).
    func ping(profileNamed name: String) async -> Outcome {
        if let entry = throttle.blockedEntry(forProfile: name, now: now()) {
            return .skippedCooldown(until: entry.nextAllowedAt)
        }
        guard await !busyProfileNames().contains(name) else { return .skippedBusy }
        guard let claude = commandResolver("claude") else { return .claudeMissing }
        try? FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)

        let configDir = profiles.configDir(forProfile: name)
        let result: ProcessRunResult
        do {
            result = try await processRunner.run(
                executable: claude,
                arguments: [
                    "-p", "Antworte nur mit: ok",
                    "--model", "haiku",
                    "--session-id", makeSessionID().uuidString.lowercased(),
                ],
                workingDirectory: workDirectory.path,
                environmentOverrides: ["CLAUDE_CONFIG_DIR": configDir.path],
                timeout: timeout
            )
        } catch {
            cleanupPingArtifacts(configDir: configDir)
            throttle.record(
                profile: name,
                nextAllowedAt: now().addingTimeInterval(Self.failureCooldown),
                problem: nil
            )
            Logger.agentStore.warning("claude_limit_ping_failed profile=\(name, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            return .failed(error.localizedDescription)
        }
        cleanupPingArtifacts(configDir: configDir)

        guard result.exitCode == 0 else {
            let output = (result.stdout + "\n" + result.stderr).lowercased()
            if output.contains("authenticate") || output.contains("oauth") || output.contains("log in")
                || output.contains("login") {
                throttle.record(
                    profile: name,
                    nextAllowedAt: now().addingTimeInterval(Self.loginRequiredCooldown),
                    problem: .loginExpired
                )
                Logger.agentStore.notice("claude_limit_ping_login_required profile=\(name, privacy: .public)")
                return .loginRequired
            }
            throttle.record(
                profile: name,
                nextAllowedAt: now().addingTimeInterval(Self.failureCooldown),
                problem: nil
            )
            Logger.agentStore.warning("claude_limit_ping_failed profile=\(name, privacy: .public) exit=\(result.exitCode)")
            return .failed("claude exited \(result.exitCode)")
        }

        throttle.record(
            profile: name,
            nextAllowedAt: now().addingTimeInterval(Self.successCooldown),
            problem: nil
        )
        Logger.agentStore.notice("claude_limit_ping_ok profile=\(name, privacy: .public)")
        return .refreshed
    }

    /// Räumt die Ping-Spuren aus dem Profil: das encodierte
    /// `projects/`-Verzeichnis des Arbeitsordners (Session-JSONL + das von
    /// der CLI angelegte `memory/`) verschwindet komplett — es enthält nie
    /// etwas anderes als Ping-Artefakte. Zweite Verteidigungslinie neben dem
    /// Indexer-Skip.
    func cleanupPingArtifacts(configDir: URL) {
        let projects = configDir.appendingPathComponent("projects", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: projects, includingPropertiesForKeys: nil
        ) else { return }
        for entry in entries where Self.isPingProjectsDirectory(entry.lastPathComponent) {
            try? FileManager.default.removeItem(at: entry)
        }
    }
}

/// Gemeinsamer Ablauf des manuellen Updates (Accounts-Tab „Update" und ↻ im
/// Usage-Popover): erst die Limits ALLER Profile passiv laden, dann Profile
/// mit abgelaufenem Token SERIELL per CLI-Ping erneuern und einzeln
/// nachladen. Jeder Zwischenstand geht sofort an `onUsage`, damit die UI
/// zeilenweise aktualisiert statt am Ende in einem Rutsch.
enum ClaudeUsageUpdateFlow {
    struct Summary: Equatable {
        var renewed: [String] = []
        var loginRequired: [String] = []
        var failed: [String] = []
        var claudeMissing = false

        var isEmpty: Bool {
            renewed.isEmpty && loginRequired.isEmpty && failed.isEmpty && !claudeMissing
        }
    }

    static func run(
        profileNames: [String],
        fetcher: ClaudeAccountUsageFetcher = ClaudeAccountUsageFetcher(),
        pinger: ClaudeAccountLimitPinger = ClaudeAccountLimitPinger(),
        onUsage: @MainActor @escaping (String, ClaudeAccountUsage) -> Void
    ) async -> Summary {
        // Phase 1: passiv, parallel — zeigt sofort, wer überhaupt Hilfe braucht.
        var problems: [String: ClaudeUsageFetchProblem] = [:]
        await withTaskGroup(of: (String, ClaudeAccountUsage?).self) { group in
            for name in profileNames {
                group.addTask { (name, await fetcher.fetchUsage(forProfile: name)) }
            }
            for await (name, usage) in group {
                guard let usage else { continue }
                problems[name] = usage.liveFetchProblem
                await MainActor.run { onUsage(name, usage) }
            }
        }

        // Phase 2: nur abgelaufene Tokens, seriell (nie ein Ping-Burst) und
        // in stabiler Reihenfolge.
        var summary = Summary()
        let stale = profileNames.filter { problems[$0] == .tokenExpired }
        for name in stale {
            switch await pinger.ping(profileNamed: name) {
            case .refreshed:
                summary.renewed.append(name)
            case .loginRequired:
                summary.loginRequired.append(name)
            case .claudeMissing:
                summary.claudeMissing = true
            case .failed:
                summary.failed.append(name)
            case .skippedBusy, .skippedCooldown:
                break
            }
            // Nachladen zeigt entweder die frischen Limits oder das präzisere
            // Problem aus dem Ping (z. B. „Login abgelaufen").
            if let usage = await fetcher.fetchUsage(forProfile: name) {
                await MainActor.run { onUsage(name, usage) }
            }
        }
        return summary
    }
}
