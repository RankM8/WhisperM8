import Foundation

/// Liefert einen verlässlichen `PATH` für Subprocesses, die WhisperM8 spawned
/// (Agent-Terminals, Codex-Post-Processing, Hilfs-Calls).
///
/// **Hintergrund:** macOS startet GUI-Apps via `launchd` mit minimalem `PATH`
/// (oft nur Plugin-Bin-Verzeichnisse oder `/usr/bin:/bin` — je nach launchd-Mood).
/// `~/.zprofile` (das via `brew shellenv` Homebrew & friends einbindet) wird
/// **nur in Login-Shells** gesourct — `Process()` und `LocalProcessTerminalView.startProcess(...)`
/// erben dagegen das ENV des Parent-Process. Resultat: in WhisperM8 gestartete
/// Claude-/Codex-/Bash-Sessions finden weder `git` noch `npm` noch `mise`-shims.
///
/// **Lösung:** beim ersten Bedarf **einmalig** eine Login-Shell des Users aufrufen
/// (`/bin/zsh -l -c 'echo $PATH'`), das Ergebnis cachen und an alle Subprocesses
/// weiterreichen. Das spiegelt 1:1 die Konfiguration, die der User in Terminal.app
/// hätte — funktioniert mit Homebrew, mise, asdf, rbenv, custom Shell-Configs.
///
/// **Fallback:** wenn der Login-Shell-Call fehlschlägt (z. B. defektes `.zshrc`,
/// kein `zsh` installiert), nutzen wir eine konservative Hardcoded-Liste, die
/// sowohl Apple Silicon (`/opt/homebrew`) als auch Intel-Macs (`/usr/local`) und
/// die System-Pfade abdeckt.
final class LoginShellEnvironment: @unchecked Sendable {
    static let shared = LoginShellEnvironment(isMainThread: { Thread.isMainThread })

    /// Konservativer Fallback-PATH — Reihenfolge bewusst:
    /// User-lokale Verzeichnisse vor Homebrew vor System-Pfaden, damit
    /// User-installierte Tools (claude, git, gh, ...) gegenüber der oft
    /// veralteten System-Variante gewinnen.
    ///
    /// `~/.local/bin` ist wichtig: der native Claude-Code-Installer legt
    /// das Binary dort ab, und der Pfad landet typischerweise nur via
    /// `.zshrc` im PATH — die wird von der nicht-interaktiven Login-Shell
    /// (`zsh -l -c`) aber nicht gesourct.
    static let fallbackPath: String = [
        "\(NSHomeDirectory())/.local/bin",  // native Installer (Claude Code, uv, ...)
        "\(NSHomeDirectory())/bin",
        "/opt/homebrew/bin",   // Apple Silicon Homebrew
        "/opt/homebrew/sbin",
        "/usr/local/bin",      // Intel-Mac Homebrew
        "/usr/local/sbin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin"
    ].joined(separator: ":")

    private let lock = NSLock()
    private var cachedSnapshot: LoginShellSnapshot?
    private var cachedPath: String?
    /// Läuft gerade eine Abfrage? Weitere Aufrufer warten auf genau diese
    /// statt eine zweite Shell zu starten (LR-SH-007).
    private var inFlight: DispatchGroup?

    /// Zeitpunkt des letzten FEHLgeschlagenen Versuchs. Ein Fehler (Timeout,
    /// defekte `.zprofile`) wird nie dauerhaft gecacht: erneuter Versuch
    /// frühestens nach `retryInterval` oder nach `invalidate()` (LR-SH-007).
    private var lastFailureAt: Date?
    /// Läuft die Hintergrund-Abfrage für den Main Thread schon?
    private var backgroundLoadStarted = false

    /// Aufruf-Closure für Tests injizierbar. Default ruft eine echte Login-Shell.
    let snapshotLoader: () -> LoginShellSnapshot?
    let retryInterval: TimeInterval
    private let now: () -> Date
    /// Auf dem Main Thread nie auf die Abfrage warten (nur `shared` setzt das).
    private let isMainThread: () -> Bool

    init(
        retryInterval: TimeInterval = 60,
        now: @escaping () -> Date = Date.init,
        isMainThread: @escaping () -> Bool = { false },
        snapshotLoader: @escaping () -> LoginShellSnapshot? = { LoginShellEnvironment.queryLoginShell() }
    ) {
        self.retryInterval = retryInterval
        self.now = now
        self.isMainThread = isMainThread
        self.snapshotLoader = snapshotLoader
    }

    /// Verwirft Ergebnis und Fehlerstand — der nächste Zugriff fragt neu ab
    /// (z. B. „Erneut prüfen“ nach einer CLI-Installation im Terminal).
    func invalidate() {
        lock.lock()
        cachedSnapshot = nil
        cachedPath = nil
        lastFailureAt = nil
        backgroundLoadStarted = false
        lock.unlock()
    }

    /// Kurzform für Tests, die nur den PATH vorgeben.
    convenience init(pathLoader: @escaping () -> String?) {
        self.init(retryInterval: 60, snapshotLoader: { pathLoader().map { LoginShellSnapshot(path: $0, variables: [:]) } })
    }

    /// Liefert den Login-Shell-PATH (lazy + cached) oder den Hardcoded-Fallback.
    /// Thread-safe. Die erste Abfrage dauert typisch 50–150 ms, höchstens die
    /// Frist von `queryLoginShell` — danach gilt der Fallback.
    var path: String {
        loadSnapshotIfNeeded()
        lock.lock()
        defer { lock.unlock() }
        return cachedPath ?? Self.fallbackPath
    }

    /// Positivliste aus der Login-Shell (Proxy, Zertifikate), siehe `LoginShellSnapshot`.
    var networkVariables: [String: String] {
        loadSnapshotIfNeeded()
        lock.lock()
        defer { lock.unlock() }
        return cachedSnapshot?.variables ?? [:]
    }

    private func loadSnapshotIfNeeded() {
        lock.lock()
        if cachedPath != nil {
            lock.unlock()
            return
        }
        // Frischer Fehler: Fallback liefern, nicht erneut 5 s blockieren.
        if let failed = lastFailureAt, now().timeIntervalSince(failed) < retryInterval {
            lock.unlock()
            return
        }
        if let running = inFlight {
            let onMain = isMainThread()
            lock.unlock()
            // Main Thread wartet nie; der Aufrufer bekommt den (ungecachten) Fallback.
            if !onMain { running.wait() }
            return
        }
        if isMainThread() {
            // Noch kein Ergebnis: Abfrage im Hintergrund anstoßen, Fallback liefern.
            if !backgroundLoadStarted {
                backgroundLoadStarted = true
                lock.unlock()
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    self?.performLoad()
                }
            } else {
                lock.unlock()
            }
            return
        }
        lock.unlock()
        performLoad()
    }

    private func performLoad() {
        lock.lock()
        if cachedPath != nil {
            lock.unlock()
            return
        }
        if let running = inFlight {
            lock.unlock()
            running.wait()
            return
        }
        let group = DispatchGroup()
        group.enter()
        inFlight = group
        lock.unlock()

        let snapshot = snapshotLoader()
        let resolved = snapshot?.path?.trimmingCharacters(in: .whitespacesAndNewlines)

        lock.lock()
        if let resolved, !resolved.isEmpty {
            cachedSnapshot = snapshot
            cachedPath = mergeWithFallback(resolved)
            lastFailureAt = nil
        } else {
            // Fehler NICHT dauerhaft cachen (nur Zeitstempel für die Sperrfrist).
            lastFailureAt = now()
            Logger.agentPerformance.info("login_shell_path_query_failed using=fallback retry_in=\(Int(self.retryInterval), privacy: .public)s")
        }
        backgroundLoadStarted = false
        inFlight = nil
        lock.unlock()
        group.leave()
    }

    /// Liefert das aktuelle Process-ENV erweitert um den korrigierten PATH und
    /// die Terminal-Capability-Variablen, die Claude Code (Ink) und Codex CLI
    /// brauchen, um farbig zu rendern.
    ///
    /// Hintergrund: GUI-Apps erben weder `TERM` noch `COLORTERM` von launchd.
    /// SwiftTerm setzt diese Defaults nur, wenn man `environment: nil` an
    /// `startProcess` übergibt — wir übergeben aber ein eigenes Env (für PATH),
    /// also fallen die Defaults weg und Ink rendert monochrom.
    /// Wir setzen nur, was nicht ohnehin schon vom User-Profil definiert wurde.
    func processEnvironment(base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = base

        // WURZEL-FIX: geerbte `CLAUDE_CODE_*`-Variablen entfernen, BEVOR wir das
        // ENV an einen gespawnten Agenten weiterreichen. Wird WhisperM8 selbst aus
        // einem Claude-Code-Kontext gestartet (z. B. `make dev`/`open` aus einer
        // laufenden Claude-Session, oder ein Terminal mit aktivem `claude`), erbt es
        // u. a. `CLAUDE_CODE_CHILD_SESSION=1` + `CLAUDE_CODE_SESSION_ID=<parent>` +
        // `CLAUDE_CODE_ENTRYPOINT`. Reichen wir das an einen frisch gestarteten
        // `claude` weiter, hält der sich für eine VERSCHACHTELTE Child-Session und
        // schreibt KEIN eigenes Transkript nach ~/.claude/projects/<cwd>/<id>.jsonl
        // → spätere `--resume` ergeben „No conversation found", der Chat wirkt
        // „verschwunden". Jeder von uns gestartete Agent muss eine saubere
        // Top-Level-Session sein. Siehe
        // docs/referenz/claude-code/session-verhalten.md
        for key in env.keys where key.hasPrefix("CLAUDE_CODE_") || key == "CLAUDECODE" {
            env.removeValue(forKey: key)
        }

        // Ebenfalls WURZEL-FIX: geerbtes `CLAUDE_CONFIG_DIR` entfernen. Wird
        // WhisperM8 aus einem Terminal gestartet (`make dev`), in dem ccs.zsh
        // das aktive Account-Profil exportiert hat (~/.claude-profiles/<name>),
        // erbt JEDER von uns gespawnte `claude` diesen Profil-Root — auch
        // Sessions, deren Stempel (`claudeProfileName`) auf main zeigt. Deren
        // `--resume` sucht dann im falschen `projects/`-Root → „No conversation
        // found", der Chat wirkt verloren. Account-Routing läuft ausschließlich
        // über die expliziten per-Launch-Overrides (`ClaudeAccountProfiles.
        // environmentOverrides`), nie über geerbtes Env.
        env.removeValue(forKey: "CLAUDE_CONFIG_DIR")

        // Dieselbe Regel fuer die GPT-Konto-Profile: `ANTHROPIC_CUSTOM_HEADERS`
        // traegt den Konto-Header einer Session, `CCP_CONFIG_DIR` den Store des
        // Proxys. Startet WhisperM8 aus einer gestempelten Shell, liefen sonst
        // ALLE main-Sessions ueber das geerbte Konto. Routing nur ueber die
        // expliziten per-Launch-Overrides (AgentCommandBuilder / ProxyManager).
        env.removeValue(forKey: "ANTHROPIC_CUSTOM_HEADERS")
        env.removeValue(forKey: "CCP_CONFIG_DIR")

        env["PATH"] = path

        // Proxy und Zertifikate aus der Login-Shell (LR-SH-012): Im Terminal
        // laufen claude/codex mit den Variablen aus ~/.zprofile, die GUI-App
        // erbt sie nicht. Ein geerbter Wert gewinnt; Secrets stehen nicht auf
        // der Positivliste.
        for (key, value) in networkVariables where env[key] == nil {
            env[key] = value
        }

        // Lokale Ziele (GPT-Router auf 127.0.0.1) nie über einen Firmenproxy:
        // sobald ein Proxy gesetzt ist, `NO_PROXY`/`no_proxy` ERGÄNZEN (LR-SH-012).
        Self.appendLocalNoProxy(&env)

        // Test-Instanz: Kindprozesse legen ihre Konfiguration im Test-Home an
        // (im Normalbetrieb leer, siehe `AppInstance`).
        for (key, value) in AppInstance.childEnvironmentOverrides {
            env[key] = value
        }

        if (env["TERM"]?.isEmpty ?? true) || env["TERM"] == "dumb" {
            env["TERM"] = "xterm-256color"
        }
        if (env["COLORTERM"]?.isEmpty ?? true) {
            env["COLORTERM"] = "truecolor"
        }
        if (env["CLICOLOR"]?.isEmpty ?? true) {
            env["CLICOLOR"] = "1"
        }
        env.removeValue(forKey: "NO_COLOR")
        let hasLocale = !(env["LANG"]?.isEmpty ?? true) || !(env["LC_ALL"]?.isEmpty ?? true)
        if !hasLocale {
            env["LANG"] = "en_US.UTF-8"
        }
        return env
    }

    static let localNoProxyEntries = ["127.0.0.1", "localhost", "::1"]

    /// Ergänzt `NO_PROXY`/`no_proxy` um die lokalen Ziele, falls ein Proxy gesetzt ist.
    static func appendLocalNoProxy(_ env: inout [String: String]) {
        let proxyKeys = ["HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy", "ALL_PROXY", "all_proxy"]
        guard proxyKeys.contains(where: { !(env[$0]?.isEmpty ?? true) }) else { return }
        for key in ["NO_PROXY", "no_proxy"] {
            var entries = (env[key] ?? "").split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            for local in localNoProxyEntries where !entries.contains(local) {
                entries.append(local)
            }
            env[key] = entries.joined(separator: ",")
        }
    }

    /// Gleiche Daten als `[String]` im `KEY=VALUE`-Format — passt zur SwiftTerm-API
    /// `LocalProcessTerminalView.startProcess(environment:)`.
    func terminalEnvironmentArray(base: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        processEnvironment(base: base).map { "\($0)=\($1)" }
    }

    /// Mergt den Login-Shell-PATH mit der Fallback-Liste, ohne Duplikate.
    /// So bleiben User-spezifische Pfade vorne (mise/asdf-shims), aber Standardpfade
    /// landen am Ende, falls der User-PATH eine Lücke hat.
    private func mergeWithFallback(_ userPath: String) -> String {
        var seen = Set<String>()
        var result: [String] = []
        let candidates = userPath.split(separator: ":", omittingEmptySubsequences: true)
            + Self.fallbackPath.split(separator: ":", omittingEmptySubsequences: true)
        for component in candidates {
            let str = String(component)
            if seen.insert(str).inserted {
                result.append(str)
            }
        }
        return result.joined(separator: ":")
    }

    /// Standard-Implementation: `/bin/zsh -l -c 'env -0'` — bewusst zsh (Default
    /// seit 10.15, sourct `.zprofile` mit `brew shellenv`).
    ///
    /// Gehärtet (LR-SH-007): stdin aus `/dev/null`, stderr verworfen, stdout
    /// parallel gelesen (ein voller Puffer blockiert die Shell nicht), Frist mit
    /// SIGTERM und danach SIGKILL. Eine hängende `.zprofile` kostet so höchstens
    /// `deadline`, nie einen dauerhaft blockierten Main Thread.
    static func queryLoginShell(
        executable: String = "/bin/zsh",
        arguments: [String] = ["-l", "-c", "env -0"],
        fallbackArguments: [String]? = ["-l", "-c", "echo $PATH"],
        deadline: TimeInterval = 5
    ) -> LoginShellSnapshot? {
        switch runShell(executable: executable, arguments: arguments, deadline: deadline) {
        case .success(let output):
            return LoginShellSnapshot.parse(envZeroOutput: output)
        case .failed:
            // `env -0` nicht verfügbar / Exit ≠ 0: wenigstens den PATH per `echo $PATH`.
            guard let fallbackArguments else { return nil }
            guard case .success(let output) = runShell(
                executable: executable, arguments: fallbackArguments, deadline: deadline) else { return nil }
            let path = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return path.isEmpty ? nil : LoginShellSnapshot(path: path, variables: [:])
        case .timedOut:
            return nil
        }
    }

    private enum ShellRun {
        case success(Data)
        case failed      // Start misslungen oder Exit ≠ 0
        case timedOut
    }

    private static func runShell(executable: String, arguments: [String], deadline: TimeInterval) -> ShellRun {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        var output = Data()
        let readDone = DispatchSemaphore(value: 0)
        let reader = pipe.fileHandleForReading
        DispatchQueue.global(qos: .userInitiated).async {
            output = reader.readDataToEndOfFile()
            readDone.signal()
        }

        do {
            try process.run()
        } catch {
            try? pipe.fileHandleForWriting.close()
            return .failed
        }
        // Eigene Schreibseite schließen, sonst endet readDataToEndOfFile nie.
        try? pipe.fileHandleForWriting.close()

        if exited.wait(timeout: .now() + deadline) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 1)
            }
            Logger.agentPerformance.info("login_shell_query_timeout deadline=\(deadline, privacy: .public)")
            return .timedOut
        }
        // Enkel der Shell könnten stdout offen halten — Lesen ebenfalls befristen.
        guard readDone.wait(timeout: .now() + 1) == .success else { return .timedOut }
        guard process.terminationStatus == 0 else { return .failed }
        return .success(output)
    }
}

/// Ergebnis der Login-Shell-Abfrage: PATH plus eine Positivliste von
/// Netzwerk-Variablen. Bewusst KEINE Schlüssel/Tokens (API-Keys o. ä.).
struct LoginShellSnapshot: Equatable {
    static let allowedVariables: Set<String> = [
        "HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy",
        "ALL_PROXY", "all_proxy", "NO_PROXY", "no_proxy",
        "NODE_EXTRA_CA_CERTS", "SSL_CERT_FILE", "SSL_CERT_DIR", "REQUESTS_CA_BUNDLE",
    ]

    var path: String?
    var variables: [String: String]

    static func parse(envZeroOutput data: Data) -> LoginShellSnapshot {
        var path: String?
        var variables: [String: String] = [:]
        for chunk in data.split(separator: 0) {
            let entry = String(decoding: chunk, as: UTF8.self)
            guard let equals = entry.firstIndex(of: "=") else { continue }
            let key = String(entry[..<equals])
            let value = String(entry[entry.index(after: equals)...])
            if key == "PATH" {
                path = value
            } else if allowedVariables.contains(key), !value.isEmpty {
                variables[key] = value
            }
        }
        return LoginShellSnapshot(path: path, variables: variables)
    }
}
