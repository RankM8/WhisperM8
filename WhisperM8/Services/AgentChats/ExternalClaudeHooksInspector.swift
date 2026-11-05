import Foundation

/// Liest die globalen Claude-Code-Settings des Users (READ-ONLY!) und meldet
/// fremde Hooks, die in WhisperM8-Chats doppelte Mitteilungen auslösen
/// könnten: Hooks auf dem Turn-Ende, auf Rückfragen und auf Freigaben, also
/// genau dort, wo WhisperM8 selbst Ton und Mitteilung zeigt. Die App
/// verändert diese Dateien niemals; die Settings-Seite zeigt die Funde nur an,
/// Entfernen bleibt eine bewusste User-Aktion.
///
/// Nicht gemeldet werden (Stufe 0 der Hook-Analyse,
/// `docs/plans/einstellungen-ordnung/hooks-analyse.md`):
/// - Hooks auf reinen Aktivitäts-Events (`PostToolUse`, `UserPromptSubmit`,
///   `SessionStart` …). Sie erzeugen keine Mitteilung und stören den Status
///   nicht, weil der aus Claudes Registry kommt.
/// - Hooks mit Umgebungs-Wächter (`[ -n "$VAR" ] && …`), deren Variable in
///   WhisperM8-Chats nicht gesetzt ist und hinter deren Wächter nichts mehr
///   unbedingt läuft. Beispiel: die Superset-Hooks, die nur mit
///   `SUPERSET_HOME_DIR` etwas tun.
enum ExternalClaudeHooksInspector {
    struct Finding: Equatable, Identifiable {
        /// Quelldatei (z. B. "settings.json").
        let source: String
        /// Hook-Event (z. B. "Stop", "Notification").
        let eventName: String
        /// Optionaler Matcher des Eintrags (z. B. "AskUserQuestion").
        let matcher: String?
        /// Gekürzter Command zur Wiedererkennung.
        let commandPreview: String

        var id: String { "\(source)|\(eventName)|\(matcher ?? "")|\(commandPreview)" }
    }

    static let commandPreviewLength = 80

    /// Events, auf denen ein fremder Hook typischerweise selbst benachrichtigt
    /// und damit WhisperM8s Fertig-Ton, Fertig-Mitteilung oder
    /// Rückfrage-Mitteilung doppelt.
    static let notificationEventNames: Set<String> = ["Stop", "Notification", "PermissionRequest"]

    /// `PreToolUse` zählt nur mit einem Matcher auf die Rückfrage-Tools; ein
    /// Hook auf jedem Tool-Aufruf ist Aktivität, keine Mitteilung.
    static let questionToolNames = ["AskUserQuestion", "ExitPlanMode"]

    /// Beide User-Settings-Dateien inspizieren (`settings.json` +
    /// `settings.local.json`). Fehlende/inkompatible Dateien → keine Funde.
    /// `environment` ist die Umgebung, mit der WhisperM8 Claude startet; die
    /// Hooks laufen mit genau dieser Umgebung.
    static func inspectUserSettings(
        home: URL = AppInstance.home,
        environment: [String: String] = LoginShellEnvironment.shared.processEnvironment()
    ) -> [Finding] {
        let claudeDir = home.appendingPathComponent(".claude", isDirectory: true)
        let files: [(name: String, data: Data)] = ["settings.json", "settings.local.json"].compactMap { name in
            (try? Data(contentsOf: claudeDir.appendingPathComponent(name))).map { (name, $0) }
        }
        // Der `env`-Block beider Dateien gilt für alle Hooks, auch für die
        // der jeweils anderen Datei.
        var effective = environment
        for file in files {
            effective.merge(settingsEnvironment(settingsData: file.data)) { _, fromSettings in fromSettings }
        }
        return files.flatMap { file in
            overlappingHooks(settingsData: file.data, source: file.name, environment: effective)
        }
    }

    /// Der `env`-Block einer Settings-Datei (`{ "env": { "VAR": "wert" } }`).
    static func settingsEnvironment(settingsData: Data) -> [String: String] {
        guard let root = try? JSONSerialization.jsonObject(with: settingsData) as? [String: Any],
              let env = root["env"] as? [String: Any] else { return [:] }
        return env.reduce(into: [:]) { result, pair in
            result[pair.key] = (pair.value as? String) ?? (pair.value as? NSNumber)?.stringValue ?? "1"
        }
    }

    /// Pure Parser-Logik: extrahiert alle Hook-Einträge, die in einem
    /// WhisperM8-Chat eine eigene Mitteilung auslösen könnten. Struktur laut
    /// Claude-Code-Settings:
    /// `{ "hooks": { "<Event>": [ { "matcher"?: …, "hooks": [ { "command": … } ] } ] } }`
    /// `environment` ergänzt sich mit dem `env`-Block derselben Datei.
    static func overlappingHooks(
        settingsData: Data,
        source: String,
        environment: [String: String] = [:]
    ) -> [Finding] {
        guard let root = try? JSONSerialization.jsonObject(with: settingsData) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any] else {
            return []
        }
        let environment = environment.merging(settingsEnvironment(settingsData: settingsData)) { _, new in new }
        var findings: [Finding] = []
        for (eventName, rawEntries) in hooks.sorted(by: { $0.key < $1.key }) {
            guard let entries = rawEntries as? [[String: Any]] else { continue }
            for entry in entries {
                let matcher = entry["matcher"] as? String
                guard canNotify(eventName: eventName, matcher: matcher),
                      let commands = entry["hooks"] as? [[String: Any]] else { continue }
                for command in commands {
                    guard let commandString = command["command"] as? String,
                          !isInactive(command: commandString, environment: environment) else { continue }
                    findings.append(Finding(
                        source: source,
                        eventName: eventName,
                        matcher: matcher,
                        commandPreview: preview(of: commandString)
                    ))
                }
            }
        }
        return findings
    }

    static func canNotify(eventName: String, matcher: String?) -> Bool {
        if notificationEventNames.contains(eventName) { return true }
        guard eventName == "PreToolUse", let matcher else { return false }
        return questionToolNames.contains { matcher.contains($0) }
    }

    /// Wirkt der Befehl in einem WhisperM8-Chat gar nicht? Nur dann, wenn
    /// - er mit einem Wächter `[ -n "$VAR" ] && …` beginnt (auch `[[ … ]]`,
    ///   `test -n` und `${VAR}` oder `${VAR:-}`),
    /// - die Variable in `environment` fehlt oder leer ist, und
    /// - hinter dem Wächter nichts mehr unbedingt läuft: kein `;`, kein
    ///   Zeilenumbruch, kein `&` und kein `||` außer einem abschließenden
    ///   `|| true` oder `|| :`.
    /// Variablen, die WhisperM8 (`WHISPERM8_*`) oder Claude (`CLAUDE*`) dem
    /// Hook mitgeben, gelten als gesetzt. Alles andere gilt als aktiv, im
    /// Zweifel wird also gemeldet.
    static func isInactive(command: String, environment: [String: String]) -> Bool {
        guard let parsed = parseGuard(in: command) else { return false }
        if providedByChat(parsed.variable) { return false }
        guard (environment[parsed.variable] ?? "").isEmpty else { return false }
        return onlyConditional(parsed.remainder)
    }

    static func guardVariable(in command: String) -> String? {
        parseGuard(in: command)?.variable
    }

    /// Variablen, die in jedem WhisperM8-Chat gesetzt sind.
    static func providedByChat(_ variable: String) -> Bool {
        variable.hasPrefix("WHISPERM8_") || variable.hasPrefix("CLAUDE")
    }

    private static func parseGuard(in command: String) -> (variable: String, remainder: Substring)? {
        let pattern = #"^\s*(?:\[\[?|test)\s+-n\s+"?\$(?:\{([A-Za-z_][A-Za-z0-9_]*)(?::-)?\}|([A-Za-z_][A-Za-z0-9_]*))"?\s*(?:\]\]?)?\s*&&"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)),
              let whole = Range(match.range, in: command) else { return nil }
        let name = [1, 2].lazy
            .compactMap { Range(match.range(at: $0), in: command) }
            .first.map { String(command[$0]) }
        guard let name else { return nil }
        return (name, command[whole.upperBound...])
    }

    /// Hängt alles hinter dem Wächter an dessen `&&`? Ein abschließendes
    /// `|| true` oder `|| :` ändert daran nichts.
    private static func onlyConditional(_ remainder: Substring) -> Bool {
        var body = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = body.range(of: #"\|\|\s*(?:true|:)\s*$"#, options: .regularExpression) {
            body = String(body[..<range.lowerBound])
        }
        if body.contains(";") || body.contains("\n") || body.contains("||") { return false }
        // Ein einzelnes `&` mitten im Befehl schickt den Wächter-Teil in den
        // Hintergrund und lässt den Rest unbedingt laufen. Bedingt bleiben
        // `&&`, Umleitungen (`2>&1`, `&>`, `<&`) und ein `&` ganz am Ende,
        // das die ganze Kette in den Hintergrund schickt.
        let withoutAllowed = body
            .replacingOccurrences(of: "&&", with: " ")
            .replacingOccurrences(of: #"[<>]&|&>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"&\s*$"#, with: "", options: .regularExpression)
        return !withoutAllowed.contains("&")
    }

    private static func preview(of command: String) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > commandPreviewLength else { return trimmed }
        return String(trimmed.prefix(commandPreviewLength)) + "…"
    }
}
