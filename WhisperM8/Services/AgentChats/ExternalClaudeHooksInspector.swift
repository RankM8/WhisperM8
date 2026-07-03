import Foundation

/// Liest die globalen Claude-Code-Settings des Users (READ-ONLY!) und meldet
/// Hooks, die auf denselben Events feuern wie WhisperM8s eigene Bridge —
/// solche Hooks (z. B. selbst gebaute Notification-Skripte) benachrichtigen
/// nach Aktivierung der App-Notifications doppelt. Die App verändert diese
/// Dateien niemals; die Settings-Seite zeigt die Funde nur an, Entfernen
/// bleibt eine bewusste User-Aktion.
enum ExternalClaudeHooksInspector {
    struct Finding: Equatable, Identifiable {
        /// Quelldatei (z. B. "settings.json").
        let source: String
        /// Hook-Event (z. B. "Stop", "PreToolUse").
        let eventName: String
        /// Optionaler Matcher des Eintrags (z. B. "AskUserQuestion").
        let matcher: String?
        /// Gekürzter Command zur Wiedererkennung.
        let commandPreview: String

        var id: String { "\(source)|\(eventName)|\(matcher ?? "")|\(commandPreview)" }
    }

    static let commandPreviewLength = 80

    /// Beide User-Settings-Dateien inspizieren (`settings.json` +
    /// `settings.local.json`). Fehlende/inkompatible Dateien → keine Funde.
    static func inspectUserSettings(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        trackedEvents: [String] = ClaudeHookSettingsBuilder.trackedEventNames
    ) -> [Finding] {
        let claudeDir = home.appendingPathComponent(".claude", isDirectory: true)
        var findings: [Finding] = []
        for fileName in ["settings.json", "settings.local.json"] {
            let url = claudeDir.appendingPathComponent(fileName)
            guard let data = try? Data(contentsOf: url) else { continue }
            findings.append(contentsOf: overlappingHooks(
                settingsData: data,
                source: fileName,
                trackedEvents: trackedEvents
            ))
        }
        return findings
    }

    /// Pure Parser-Logik: extrahiert alle Hook-Einträge, deren Event in
    /// `trackedEvents` liegt. Struktur laut Claude-Code-Settings:
    /// `{ "hooks": { "<Event>": [ { "matcher"?: …, "hooks": [ { "command": … } ] } ] } }`
    static func overlappingHooks(
        settingsData: Data,
        source: String,
        trackedEvents: [String] = ClaudeHookSettingsBuilder.trackedEventNames
    ) -> [Finding] {
        guard let root = try? JSONSerialization.jsonObject(with: settingsData) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any] else {
            return []
        }
        let tracked = Set(trackedEvents)
        var findings: [Finding] = []
        for (eventName, rawEntries) in hooks.sorted(by: { $0.key < $1.key }) {
            guard tracked.contains(eventName),
                  let entries = rawEntries as? [[String: Any]] else { continue }
            for entry in entries {
                let matcher = entry["matcher"] as? String
                guard let commands = entry["hooks"] as? [[String: Any]] else { continue }
                for command in commands {
                    guard let commandString = command["command"] as? String else { continue }
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

    private static func preview(of command: String) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > commandPreviewLength else { return trimmed }
        return String(trimmed.prefix(commandPreviewLength)) + "…"
    }
}
