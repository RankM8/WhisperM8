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
///   WhisperM8-Chats nicht gesetzt ist. Beispiel: die Superset-Hooks, die nur
///   mit `SUPERSET_HOME_DIR` etwas tun.
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
        var findings: [Finding] = []
        for fileName in ["settings.json", "settings.local.json"] {
            let url = claudeDir.appendingPathComponent(fileName)
            guard let data = try? Data(contentsOf: url) else { continue }
            findings.append(contentsOf: overlappingHooks(
                settingsData: data,
                source: fileName,
                environment: environment
            ))
        }
        return findings
    }

    /// Pure Parser-Logik: extrahiert alle Hook-Einträge, die in einem
    /// WhisperM8-Chat eine eigene Mitteilung auslösen könnten. Struktur laut
    /// Claude-Code-Settings:
    /// `{ "hooks": { "<Event>": [ { "matcher"?: …, "hooks": [ { "command": … } ] } ] } }`
    static func overlappingHooks(
        settingsData: Data,
        source: String,
        environment: [String: String] = [:]
    ) -> [Finding] {
        guard let root = try? JSONSerialization.jsonObject(with: settingsData) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any] else {
            return []
        }
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

    /// Wirkt der Befehl in einem WhisperM8-Chat gar nicht? Erkannt wird nur ein
    /// führender Wächter `[ -n "$VAR" ] && …` (auch `[[ … ]]` und `test -n`),
    /// dessen Variable in `environment` fehlt oder leer ist. Alles andere gilt
    /// als aktiv, im Zweifel wird also gemeldet.
    static func isInactive(command: String, environment: [String: String]) -> Bool {
        guard let variable = guardVariable(in: command) else { return false }
        return (environment[variable] ?? "").isEmpty
    }

    static func guardVariable(in command: String) -> String? {
        let pattern = #"^\s*(?:\[\[?|test)\s+-n\s+"?\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?"?\s*(?:\]\]?)?\s*&&"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)),
              let range = Range(match.range(at: 1), in: command) else { return nil }
        return String(command[range])
    }

    private static func preview(of command: String) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > commandPreviewLength else { return trimmed }
        return String(trimmed.prefix(commandPreviewLength)) + "…"
    }
}
