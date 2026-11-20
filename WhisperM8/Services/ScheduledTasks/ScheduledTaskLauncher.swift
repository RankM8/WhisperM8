import Foundation
import Darwin

// MARK: - Starter eines Laufs

/// Startet einen Lauf so, dass er einen App-Neustart überlebt:
///
/// - eigene Sitzung und Prozessgruppe (`POSIX_SPAWN_SETSID`), kein Terminal,
/// - stdin `/dev/null`, stdout nach `result.json`, stderr nach `stderr.log`,
/// - alle anderen Deskriptoren der App geschlossen (`POSIX_SPAWN_CLOEXEC_DEFAULT`,
///   die App hält PTY-Master der Chats),
/// - Signale auf Standard zurückgesetzt, leere Signalmaske.
///
/// Gestartet wird `/bin/sh` mit einem festen Skript, das `claude` aufruft und
/// danach den Exit-Code in die Datei `exit` schreibt. Die App muss also nicht
/// leben, wenn der Lauf endet; sie liest das Ergebnis später aus dem Ordner.
enum ScheduledTaskLauncher {
    /// Kennung jedes Laufs in seiner Umgebung (Aufgaben- und Lauf-ID). Daran
    /// erkennen Hooks und Mods einen geplanten Lauf, etwa um ihm keine
    /// Supervisor-Hinweise einzuschieben (WM8-130).
    static let taskIDEnvironmentKey = "WHISPERM8_SCHEDULED_TASK_ID"
    static let runIDEnvironmentKey = "WHISPERM8_SCHEDULED_RUN_ID"

    /// Ruft `"$@"` auf, löscht danach `claude-config/` im Lauf-Ordner (Kopie
    /// der Einstellungen, MCP-Konfiguration; `ScheduledTaskRunConfigBuilder`)
    /// und schreibt „<Code> <Ende>“ atomar nach `$1`. Feste Pfade für `rm`,
    /// `date` und `mv`, kein PATH-Lookup.
    static let wrapperScript = """
    exitfile="$1"; shift
    "$@"
    code=$?
    case "$exitfile" in /*/exit) /bin/rm -rf "${exitfile%/exit}/claude-config" ;; esac
    printf '%s %s\\n' "$code" "$(/bin/date +%s)" > "$exitfile.tmp" && /bin/mv -f "$exitfile.tmp" "$exitfile"
    exit "$code"
    """

    /// Argumente für `claude`. Der Auftrag steht direkt nach `-p` (wie im
    /// launchd-Skript der PM-Analyse belegt). `--disallowedTools`,
    /// `--mcp-config` und `--allowedTools` sind variadisch; jede steht
    /// deshalb vor einer weiteren Option oder ganz hinten.
    ///
    /// Nur die Freigaben der Aufgabe (Paket 4): `--setting-sources ""` lädt
    /// keine Einstellungsdatei von Konto und Projekt, deren Freigaben sonst
    /// zusätzlich gälten; was der Lauf davon braucht, kommt aus `config`.
    /// `--strict-mcp-config` lädt nur die Server aus `config.mcpConfigFile`,
    /// ohne Datei keinen — das hält auch dann, wenn eine ältere
    /// Claude-Version `mcp__*` nicht kennt.
    static func claudeArguments(prompt: String, sessionID: UUID, name: String?,
                                permissions: ScheduledTaskPermissions, config: ScheduledTaskRunConfig) -> [String] {
        var args = ["-p", prompt, "--output-format", "json", "--session-id", sessionID.uuidString.lowercased()]
        if let name, !name.isEmpty { args += ["--name", name] }
        args += ["--setting-sources", "", "--settings", config.settingsFile]
        if let plugins = config.pluginDirectory { args += ["--plugin-dir", plugins] }
        if let context = config.contextFile { args += ["--append-system-prompt-file", context] }
        let disallowed = permissions.disallowedTools
        if !disallowed.isEmpty { args += ["--disallowedTools"] + disallowed }
        args += ["--strict-mcp-config"]
        if let mcp = config.mcpConfigFile { args += ["--mcp-config", mcp] }
        args += ["--permission-mode", "dontAsk"]
        let allowed = permissions.allowedTools + config.extraAllowedTools(for: permissions)
        if !allowed.isEmpty { args += ["--allowedTools"] + allowed }
        return args
    }

    /// Kennungen eines Chats, die ein Lauf nie erben darf: Sonst spräche er
    /// über die CLI als dieser Chat (etwa als Supervisor).
    static let inheritedChatEnvironmentKeys = ["WHISPERM8_SESSION_ID", "WHISPERM8_SESSION_TOKEN"]

    /// Name des Chats: „<Aufgabe> · <Datum>“, Datum in der Sprache des Systems.
    static func sessionName(taskName: String, date: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate("ddMM")
        return "\(taskName) · \(formatter.string(from: date))"
    }

    struct SpawnPlan: Equatable {
        var claudePath: String
        var claudeArguments: [String]
        var environment: [String: String]
        var workingDirectory: String
        var runDirectory: URL

        var exitFile: String { runDirectory.appendingPathComponent(ScheduledTaskRunFiles.exitName).path }
        var stdoutFile: String { runDirectory.appendingPathComponent(ScheduledTaskRunFiles.resultName).path }
        var stderrFile: String { runDirectory.appendingPathComponent(ScheduledTaskRunFiles.stderrName).path }

        /// argv für `/bin/sh`.
        var shellArguments: [String] {
            ["sh", "-c", ScheduledTaskLauncher.wrapperScript, "whisperm8-scheduled-task", exitFile, claudePath] + claudeArguments
        }
    }

    enum SpawnError: LocalizedError, Equatable {
        case spawnFailed(Int32)

        var errorDescription: String? {
            switch self {
            case .spawnFailed(let code): return "Start fehlgeschlagen: \(String(cString: strerror(code)))"
            }
        }
    }

    /// Startet den Wrapper losgelöst und gibt seine PID zurück.
    static func spawnDetached(_ plan: SpawnPlan) throws -> pid_t {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        let flags = POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        posix_spawnattr_setflags(&attributes, Int16(flags))
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for signal in [SIGPIPE, SIGTERM, SIGINT, SIGHUP, SIGQUIT, SIGCHLD, SIGUSR1, SIGUSR2, SIGALRM] {
            sigaddset(&defaults, signal)
        }
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        posix_spawnattr_setsigmask(&attributes, &emptyMask)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, plan.stdoutFile, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        posix_spawn_file_actions_addopen(&actions, 2, plan.stderrFile, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        posix_spawn_file_actions_addchdir_np(&actions, plan.workingDirectory)

        let argv = plan.shellArguments.map { strdup($0) } + [nil]
        let envp = plan.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, "/bin/sh", &actions, &attributes, argv, envp)
        guard status == 0 else { throw SpawnError.spawnFailed(status) }
        return pid
    }

    // MARK: Login-Prüfung

    struct AuthStatus: Equatable {
        var loggedIn: Bool
        var loginExpiresAt: Date?
    }

    /// Liest `claude auth status --json`. Exit 1 = niemand angemeldet (gemessen
    /// an einem leeren Konto-Ordner, Plan geplante-aufgaben.md). Unlesbare
    /// Ausgabe mit Exit 0 → `nil` (nicht prüfbar, der Lauf startet trotzdem).
    static func parseAuthStatus(stdout: String, exitCode: Int32) -> AuthStatus? {
        let object = (try? JSONSerialization.jsonObject(with: Data(stdout.utf8))) as? [String: Any]
        if exitCode != 0 {
            return AuthStatus(loggedIn: false, loginExpiresAt: nil)
        }
        guard let object, let loggedIn = object["loggedIn"] as? Bool else { return nil }
        let expires = (object["loginExpiresAt"] as? String).flatMap(parseISODate)
        return AuthStatus(loggedIn: loggedIn, loginExpiresAt: expires)
    }

    static func parseISODate(_ text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }
        return ISO8601DateFormatter().date(from: text)
    }
}
