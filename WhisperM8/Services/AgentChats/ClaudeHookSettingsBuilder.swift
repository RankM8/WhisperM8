import Foundation

/// Pure Helper-Logik fuer das Erzeugen der temporaeren Claude-Code-Settings-
/// Datei, die wir per `--settings <path>` an einen Claude-Launch haengen.
/// Sie definiert nur unsere eigenen Hooks — User-Settings und Project-
/// Settings bleiben unangetastet (Claude mergt additiv).
enum ClaudeHookSettingsBuilder {
    /// Hook-Events, die wir per `--settings`-Bridge mittracken. Derselbe
    /// Append-Command fuer alle Events:
    /// - SessionStart/End       → Lifecycle (externe ID binden, Ende)
    /// - UserPromptSubmit       → Turn-Start ("arbeitet", clear "needs input")
    /// - PreToolUse/PostToolUse → Aktivitaet ("arbeitet", clear "needs input")
    /// - PostToolUseFailure     → Aktivitaet auch bei fehlgeschlagenem Tool —
    ///   ohne dieses Event fehlt nach einem Tool-Fehler das "arbeitet"-Signal
    ///   (Claude verarbeitet den Fehler ja weiter). Vgl. Superset, die es
    ///   ebenfalls registrieren.
    /// - PermissionRequest      → echte Erlaubnis-Anfrage = "braucht Handlung".
    ///   BEWUSST NICHT `Notification`: das feuert auch fuer `idle_prompt`
    ///   (60-s-Stille) und markierte sonst alle fertigen Chats faelschlich
    ///   "wartend". `PermissionRequest` ist Claudes dedizierter Hook, der nur
    ///   beim echten Permission-Dialog feuert (vgl. Superset).
    /// - Stop                   → Turn fertig ("idle" + optionaler Ton)
    /// Reihenfolge bestimmt nur die Serialisierung — Anthropic merged
    /// Hooks ohnehin pro Event-Name.
    static let trackedEventNames: [String] = [
        "SessionStart",
        "SessionEnd",
        "UserPromptSubmit",
        "PreToolUse",
        "PostToolUse",
        "PostToolUseFailure",
        "PermissionRequest",
        "Stop"
    ]

    /// Baut das Settings-Dict mit Hooks fuer alle `trackedEventNames`, die
    /// jeden Event als JSON-Zeile in `eventFilePath` appenden. Wir nutzen
    /// `(cat ; echo) >> "$path"` — robust gegen Pfade mit Leerzeichen,
    /// keine externen Tools wie `jq`. Background-Sessions setzen das
    /// beim `--bg`-Spawn (siehe `BackgroundAgentSpawner`), normale
    /// Chats beim Launch des PTY.
    static func makeSettings(
        eventFilePath: String,
        promptGuardCommand: String? = nil
    ) -> [String: Any] {
        let command = appendCommand(eventFilePath: eventFilePath)
        let entry: [String: Any] = [
            "matcher": ".*",
            "hooks": [
                [
                    "type": "command",
                    "command": command
                ]
            ]
        ]
        var hooks: [String: Any] = [:]
        for name in trackedEventNames {
            hooks[name] = [entry]
        }
        // Send-Guard: zweiter, additiver UserPromptSubmit-Eintrag. Exit 2
        // blockt die Submission (Wiedervorlage eines [via whisperm8 chats]-
        // Prompts ohne frisches Zustell-Token — Vorfall 2026-08-17). Läuft
        // NACH dem Append-Command, damit das Event-Tracking auch für
        // geblockte Prompts vollständig bleibt.
        if let promptGuardCommand {
            var userPromptEntries = hooks["UserPromptSubmit"] as? [[String: Any]] ?? []
            userPromptEntries.append([
                "matcher": ".*",
                "hooks": [
                    [
                        "type": "command",
                        "command": promptGuardCommand
                    ]
                ]
            ])
            hooks["UserPromptSubmit"] = userPromptEntries
        }
        return ["hooks": hooks]
    }

    /// Hook-Command des Send-Guards: absoluter Pfad zum eigenen Binary
    /// (App und CLI sind dasselbe signierte Executable) + internes
    /// Subcommand. Kein PATH-/Symlink-Vertrauen — der Symlink-Install
    /// (`~/.local/bin/whisperm8`) kann fehlen oder veraltet sein.
    static func promptGuardCommand(executablePath: String) -> String {
        "\"\(shellEscapeDoubleQuoted(executablePath))\" chats _prompt-guard"
    }

    /// Serialisiert die Settings als utf8-JSON-Daten. Sortierung der Keys
    /// damit die Datei deterministisch wird (gut fuer Tests + Logs).
    static func serializedSettings(eventFilePath: String) throws -> Data {
        let dict = makeSettings(eventFilePath: eventFilePath)
        return try JSONSerialization.data(
            withJSONObject: dict,
            options: [.prettyPrinted, .sortedKeys]
        )
    }

    /// Schreibt die Settings atomisch nach `outURL` mit POSIX-0600.
    static func writeSettingsFile(eventFilePath: String, to outURL: URL) throws {
        try write(settings: makeSettings(eventFilePath: eventFilePath), to: outURL)
    }

    /// Tiefer Merge mehrerer Settings-Fragmente (Hooks, GPT-Modellkatalog,
    /// internes Worker-Env). Verschachtelte Dictionaries (insbesondere `env`)
    /// werden rekursiv kombiniert; bei Blatt-Kollisionen gewinnt das spaetere
    /// Fragment — interne Werte siegen so deterministisch.
    static func merged(_ fragments: [[String: Any]]) -> [String: Any] {
        fragments.reduce(into: [:]) { result, fragment in
            result = deepMerged(result, fragment)
        }
    }

    private static func deepMerged(
        _ existing: [String: Any],
        _ incoming: [String: Any]
    ) -> [String: Any] {
        existing.merging(incoming) { old, new in
            if let oldDictionary = old as? [String: Any],
               let newDictionary = new as? [String: Any] {
                return deepMerged(oldDictionary, newDictionary)
            }
            return new
        }
    }

    /// Generische Variante: schreibt ein beliebiges Settings-Dict atomisch
    /// mit POSIX-0600 und deterministischer Serialisierung. Genutzt vom
    /// Compose-Pfad, der die Settings-Fragmente in EINE Datei merged
    /// (`ClaudeHookBridge.prepareSettingsFile`).
    static func write(settings: [String: Any], to outURL: URL) throws {
        try FileManager.default.createDirectory(
            at: outURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: outURL, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: outURL.path
        )
    }

    /// Shell-Command der das stdin-JSON appended. Wir packen das in
    /// `bash -lc`, weil Claude Hooks Commands direkt mit `sh` ausfuehren —
    /// `bash -lc` macht Sicherheit, dass Standard-Tools und PATH stimmen.
    /// Der Pfad wird mit doppelten Quotes geschuetzt; sollten Backslashes
    /// oder Quotes im Pfad selbst auftauchen escapen wir die.
    static func appendCommand(eventFilePath: String) -> String {
        let escaped = shellEscapeDoubleQuoted(eventFilePath)
        return "(cat; echo) >> \"\(escaped)\""
    }

    /// Escape-Regeln fuer einen String, der innerhalb von Double-Quotes
    /// in einer Shell auftaucht: `\` -> `\\`, `"` -> `\"`, `$` -> `\$`,
    /// Backtick -> `\``.
    static func shellEscapeDoubleQuoted(_ raw: String) -> String {
        var result = ""
        result.reserveCapacity(raw.count)
        for ch in raw {
            switch ch {
            case "\\":
                result.append("\\\\")
            case "\"":
                result.append("\\\"")
            case "$":
                result.append("\\$")
            case "`":
                result.append("\\`")
            default:
                result.append(ch)
            }
        }
        return result
    }
}

/// Verwaltet die Pfade fuer unsere Claude-Hook-Settings + Event-Dateien.
/// Pro lokaler WhisperM8-Session eine Settings-Datei + ein Event-File.
/// Diese Files liegen im App-Support-Verzeichnis (nicht `/tmp`) und sind
/// 0600.
struct ClaudeHookPaths {
    let rootDirectory: URL

    init(rootDirectory: URL? = nil) {
        self.rootDirectory = rootDirectory ?? Self.defaultRoot()
    }

    static func defaultRoot() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WhisperM8", isDirectory: true)
    }

    var settingsDirectory: URL {
        rootDirectory.appendingPathComponent("claude-hooks", isDirectory: true)
    }

    var eventsDirectory: URL {
        rootDirectory.appendingPathComponent("claude-session-events", isDirectory: true)
    }

    func settingsFileURL(localSessionID: UUID) -> URL {
        settingsDirectory.appendingPathComponent("\(localSessionID.uuidString).json")
    }

    func eventFileURL(localSessionID: UUID) -> URL {
        eventsDirectory.appendingPathComponent("\(localSessionID.uuidString).jsonl")
    }
}
