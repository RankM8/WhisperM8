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
    static let shared = LoginShellEnvironment()

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
    private var cachedPath: String?

    /// Aufruf-Closure für Tests injizierbar. Default ruft eine echte Login-Shell.
    let pathLoader: () -> String?

    init(pathLoader: @escaping () -> String? = LoginShellEnvironment.queryLoginShellPath) {
        self.pathLoader = pathLoader
    }

    /// Liefert den Login-Shell-PATH (lazy + cached) oder den Hardcoded-Fallback.
    /// Thread-safe, blockiert kurz beim ersten Call (~50–150 ms für die Shell).
    var path: String {
        lock.lock()
        if let cached = cachedPath {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let resolved = pathLoader()?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value: String
        if let resolved, !resolved.isEmpty {
            value = mergeWithFallback(resolved)
        } else {
            Logger.agentPerformance.info("login_shell_path_query_failed using=fallback")
            value = Self.fallbackPath
        }

        lock.lock()
        cachedPath = value
        lock.unlock()
        return value
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

        env["PATH"] = path

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

    /// Standard-Implementation: ruft `/bin/zsh -l -c 'echo $PATH'` auf.
    /// Bewusst zsh, weil das auf macOS 10.15+ die Default-Shell ist und
    /// `.zprofile` sourcet, das `brew shellenv` enthält.
    static func queryLoginShellPath() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", "echo $PATH"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }
}
