import Foundation

// MARK: - Was ein Lauf von Claude Code lädt (Paket 4)

/// Dateien, die ein Lauf statt der Einstellungen des Kontos bekommt.
///
/// Entscheidung Giuliano 17.11.2026: Ein Lauf darf genau das, was die Aufgabe
/// freigibt. Claude Code hat keinen Schalter, der nur die Freigaben einer
/// Einstellungsdatei abschaltet; Freigaben aus `settings.json` (Konto),
/// `.claude/settings.json` und `.claude/settings.local.json` (Projekt) gelten
/// sonst zusätzlich zu `--allowedTools` (gemessen mit Claude Code 2.1.329,
/// Doku „Geplante Aufgaben“). Deshalb startet ein Lauf mit
/// `--setting-sources ""` (keine Einstellungsdatei) und bekommt den Rest
/// einzeln zurück:
///
/// - `settingsFile`: die `settings.json` des Kontos ohne Freigaben, Hooks und
///   Plugins (`--settings`), damit `env`, Sprache, `cleanupPeriodDays` und
///   Ähnliches weiter gelten,
/// - `pluginDirectory`: die Skills des Kontos und des Projekts als Plugins
///   `account` und `project` (`--plugin-dir`); ohne Einstellungsquellen lädt
///   Claude sie sonst nicht,
/// - `contextFile`: die CLAUDE.md von Konto und Projekt (auch
///   `CLAUDE.local.md`; `--append-system-prompt-file`), ebenfalls an die
///   Quellen gebunden,
/// - `mcpConfigFile`: nur die MCP-Server, deren Werkzeuge die Aufgabe nennt
///   (`--strict-mcp-config --mcp-config`).
struct ScheduledTaskRunConfig: Equatable {
    var settingsFile: String
    var pluginDirectory: String?
    var contextFile: String?
    var mcpConfigFile: String?

    /// Lesen im eigenen Plugin-Ordner: Claude nennt einem Skill den
    /// Symlink-Pfad im Lauf als seinen Ordner, eine Leseregel auf den echten
    /// Skill-Ordner greift dort nicht (gemessen). Nur, wenn die Aufgabe Skills
    /// erlaubt; sonst öffnete die Regel in einer eigenen Liste ohne `Read`
    /// das Lesen über Symlinks in Skill-Ordnern.
    func extraAllowedTools(for permissions: ScheduledTaskPermissions) -> [String] {
        guard let pluginDirectory,
              permissions.allowedTools.contains(where: { $0 == "Skill" || $0.hasPrefix("Skill(") }) else { return [] }
        return ["Read(/\(pluginDirectory)/**)"]
    }
}

enum ScheduledTaskRunConfigBuilder {
    /// Unterordner im Lauf-Ordner. Der Wrapper löscht ihn, wenn `claude`
    /// endet: Die Kopie der Einstellungen und die MCP-Konfiguration können
    /// Schlüssel enthalten.
    static let folderName = "claude-config"

    /// Schlüssel der Konto-Einstellungen, die ein Lauf nicht bekommt:
    /// Freigaben (auch `defaultMode`, `additionalDirectories`), Hooks (ein
    /// `PreToolUse`-Hook kann Werkzeuge freigeben) und Plugins (ihre Skills
    /// und Befehle bringen eigene `allowed-tools`, Hooks und Werkzeug-Server
    /// mit). Die Sandbox bleibt, gibt aber Bash nicht von sich aus frei
    /// (`autoAllowBashIfSandboxed` ist sonst ab Werk an).
    static let droppedSettingsKeys = ["permissions", "hooks", "enabledPlugins"]

    /// Felder im Kopf einer SKILL.md, die Freigaben am Lauf vorbei erteilen.
    static let droppedSkillKeys = ["allowed-tools", "hooks"]

    struct Sources: Equatable {
        /// Konto-Ordner (`~/.claude` oder Profil-Ordner).
        var configDirectory: URL
        /// `.claude.json` des Kontos (MCP-Server).
        var claudeJSON: URL
    }

    // MARK: Reine Bausteine

    static func sanitizedSettings(_ settings: [String: Any]) -> [String: Any] {
        var result = settings.filter { !droppedSettingsKeys.contains($0.key) }
        if var sandbox = result["sandbox"] as? [String: Any] {
            sandbox["autoAllowBashIfSandboxed"] = false
            result["sandbox"] = sandbox
        }
        return result
    }

    /// Server-Name, wie er in `mcp__<server>__<werkzeug>` steht: Claude Code
    /// ersetzt alles außer Buchstaben, Ziffern, `_` und `-` durch `_`.
    static func normalizedServerName(_ name: String) -> String {
        String(name.unicodeScalars.map { scalar in
            let allowed = CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII || scalar == "_" || scalar == "-"
            return allowed ? Character(scalar) : "_"
        })
    }

    /// Server aus Konto (`mcpServers`) und Projekt (`projects[<ordner>].mcpServers`
    /// in derselben `.claude.json`); das Projekt geht vor. `missing` nennt
    /// Server, die die Aufgabe nennt, die das Konto aber nicht kennt (etwa die
    /// eines Plugins oder einer claude.ai-Verbindung).
    static func selectMCPServers(named names: [String], user: [String: Any],
                                 project: [String: Any]) -> (servers: [String: Any], missing: [String]) {
        var byName: [String: (String, Any)] = [:]
        for (key, value) in user { byName[normalizedServerName(key)] = (key, value) }
        for (key, value) in project { byName[normalizedServerName(key)] = (key, value) }
        var servers: [String: Any] = [:]
        var missing: [String] = []
        for name in names {
            if let (key, value) = byName[name] {
                servers[key] = value
            } else {
                missing.append(name)
            }
        }
        return (servers, missing)
    }

    /// Zeilen des Kopfs einer SKILL.md (ohne die `---`-Zeilen) und der Index
    /// der schließenden Zeile; `nil` ohne Kopf. Ende ist eine Zeile, die ohne
    /// Leerraum am Ende genau `---` ist — ein eingerücktes `---` (etwa in
    /// `description: |`) beendet den Kopf nicht.
    static func skillHeader(_ lines: [String]) -> (header: ArraySlice<String>, end: Int)? {
        guard let first = lines.first, trimmedTrailing(first) == "---",
              let end = lines.indices.dropFirst().first(where: { trimmedTrailing(lines[$0]) == "---" }) else { return nil }
        return (lines[1..<end], end)
    }

    private static func trimmedTrailing(_ line: String) -> String {
        var line = line
        while let last = line.last, last.isWhitespace { line.removeLast() }
        return line
    }

    /// Schlüssel einer Kopfzeile ohne Einrückung und Anführungszeichen.
    private static func headerKey(_ line: String) -> String? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        return line[..<colon].trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"'")))
    }

    /// Die SKILL.md ohne `allowed-tools` und `hooks` im Kopf, `nil` wenn sie
    /// keins von beiden hat. Fortsetzungszeilen (eingerückt oder `- …`)
    /// gehören zum Schlüssel.
    static func skillTextWithoutGrants(_ text: String) -> String? {
        let lines = (text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text).components(separatedBy: "\n")
        guard let (header, end) = skillHeader(lines) else { return nil }
        var kept: [String] = []
        var removed = false
        var skipping = false
        for line in header {
            let isContinuation = line.hasPrefix(" ") || line.hasPrefix("\t") || line.hasPrefix("-")
            if skipping, isContinuation || line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            skipping = false
            if !isContinuation, let key = headerKey(line), droppedSkillKeys.contains(key) {
                removed = true
                skipping = true
            } else {
                kept.append(line)
            }
        }
        guard removed else { return nil }
        return ([lines[0]] + kept + lines[end...]).joined(separator: "\n")
    }

    /// Nennt der Kopf noch irgendwo `allowed-tools` oder einen Schlüssel
    /// `hooks`, auch eingerückt? Dann lädt der Lauf den Skill nicht: lieber
    /// ein Skill weniger als eine Freigabe am Lauf vorbei.
    static func skillHeaderMentionsGrants(_ text: String) -> Bool {
        let lines = (text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text).components(separatedBy: "\n")
        guard let (header, _) = skillHeader(lines) else { return false }
        return header.contains { line in
            line.lowercased().contains("allowed-tools") || line.lowercased().contains("allowed_tools")
                || headerKey(line) == "hooks"
        }
    }

    /// Text für `--append-system-prompt-file`: jede CLAUDE.md mit ihrem Pfad.
    static func contextText(_ files: [(path: String, text: String)]) -> String? {
        let parts = files.compactMap { file -> String? in
            let text = file.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return "Contents of \(file.path):\n\n\(text)"
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "\n\n")
    }

    // MARK: Anlegen

    struct BuildError: LocalizedError, Equatable {
        var message: String
        var errorDescription: String? { message }
    }

    /// Legt `<lauf>/claude-config/` an. Liest nur: `settings.json`, `skills/`,
    /// `CLAUDE.md` des Kontos und `.claude.json`; im Projekt `CLAUDE.md`,
    /// `.claude/CLAUDE.md` und `.claude/skills/`. Geschrieben wird nur im
    /// Lauf-Ordner (Ordner 0700, Dateien 0600).
    static func prepare(task: ScheduledTask, sources: Sources, runDirectory: URL,
                        fileManager: FileManager = .default) throws -> ScheduledTaskRunConfig {
        let folder = runDirectory.appendingPathComponent(folderName, isDirectory: true)
        try createDirectory(folder, fileManager: fileManager)

        let settingsURL = folder.appendingPathComponent("settings.json")
        let accountSettings = sources.configDirectory.appendingPathComponent("settings.json")
        var settings: [String: Any] = [:]
        if fileManager.fileExists(atPath: accountSettings.path) {
            // Unlesbar: lieber kein Lauf als einer ohne `cleanupPeriodDays`
            // (Claude räumte dann Verläufe nach 30 Tagen weg).
            guard let object = readJSONObject(accountSettings) else {
                throw BuildError(message: "settings.json des Kontos ist nicht lesbar")
            }
            settings = object
        }
        try writeJSON(sanitizedSettings(settings), to: settingsURL)
        var config = ScheduledTaskRunConfig(settingsFile: settingsURL.path)

        let projectDirectory = URL(fileURLWithPath: task.directory, isDirectory: true)
        let accountSkills = sources.configDirectory.appendingPathComponent("skills", isDirectory: true)
        let projectSkills = projectDirectory.appendingPathComponent(".claude/skills", isDirectory: true)
        let plugins = folder.appendingPathComponent("plugins", isDirectory: true)
        var builtPlugin = false
        for (name, skills) in [("account", accountSkills), ("project", projectSkills)] {
            if name == "project", sameFile(skills, accountSkills) { continue }
            if try buildSkillsPlugin(named: name, from: skills, into: plugins, fileManager: fileManager) {
                builtPlugin = true
            }
        }
        if builtPlugin { config.pluginDirectory = plugins.path }

        var contextFiles: [(path: String, text: String)] = []
        var seen: [URL] = []
        for url in [sources.configDirectory.appendingPathComponent("CLAUDE.md"),
                    projectDirectory.appendingPathComponent("CLAUDE.md"),
                    projectDirectory.appendingPathComponent(".claude/CLAUDE.md"),
                    projectDirectory.appendingPathComponent("CLAUDE.local.md")] {
            guard !seen.contains(where: { sameFile($0, url) }), let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            seen.append(url)
            contextFiles.append((url.path, text))
        }
        if let context = contextText(contextFiles) {
            let url = folder.appendingPathComponent("context.md")
            try writeFile(Data(context.utf8), to: url)
            config.contextFile = url.path
        }

        let names = task.permissions.mcpServerNames
        if !names.isEmpty {
            let claudeJSON = readJSONObject(sources.claudeJSON) ?? [:]
            let user = claudeJSON["mcpServers"] as? [String: Any] ?? [:]
            let projects = claudeJSON["projects"] as? [String: Any] ?? [:]
            let project = (projects[task.directory] as? [String: Any])?["mcpServers"] as? [String: Any] ?? [:]
            let selection = selectMCPServers(named: names, user: user, project: project)
            if !selection.missing.isEmpty {
                Logger.scheduledTasks.info(
                    "run_mcp_servers_missing task=\(task.shortID, privacy: .public) servers=\(selection.missing.joined(separator: ","), privacy: .public)")
            }
            if !selection.servers.isEmpty {
                let url = folder.appendingPathComponent("mcp.json")
                try writeJSON(["mcpServers": selection.servers], to: url)
                config.mcpConfigFile = url.path
            }
        }
        return config
    }

    /// Ein Plugin `<name>` mit je einem Eintrag pro Skill: ein Symlink auf den
    /// Skill-Ordner, bei `allowed-tools` oder `hooks` im Kopf ein eigener
    /// Ordner mit bereinigter SKILL.md und Symlinks auf alles andere.
    /// `false`, wenn es keinen Skill gibt.
    static func buildSkillsPlugin(named name: String, from skills: URL, into plugins: URL,
                                  fileManager: FileManager) throws -> Bool {
        let entries = ((try? fileManager.contentsOfDirectory(at: skills, includingPropertiesForKeys: nil,
                                                             options: [.skipsHiddenFiles])) ?? [])
            .filter { fileManager.fileExists(atPath: $0.appendingPathComponent("SKILL.md").path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !entries.isEmpty else { return false }
        let root = plugins.appendingPathComponent(name, isDirectory: true)
        let target = root.appendingPathComponent("skills", isDirectory: true)
        try createDirectory(root.appendingPathComponent(".claude-plugin", isDirectory: true), fileManager: fileManager)
        try createDirectory(target, fileManager: fileManager)
        try writeJSON(["name": name, "description": "Skills for a scheduled run"],
                      to: root.appendingPathComponent(".claude-plugin/plugin.json"))
        for entry in entries {
            let destination = target.appendingPathComponent(entry.lastPathComponent, isDirectory: true)
            let skillFile = entry.appendingPathComponent("SKILL.md")
            let text = try? String(contentsOf: skillFile, encoding: .utf8)
            let cleaned = text.flatMap(skillTextWithoutGrants)
            if let text, skillHeaderMentionsGrants(cleaned ?? text) {
                Logger.scheduledTasks.info("run_skill_skipped skill=\(entry.lastPathComponent, privacy: .public)")
                continue
            }
            if let cleaned {
                try createDirectory(destination, fileManager: fileManager)
                let children = (try? fileManager.contentsOfDirectory(atPath: entry.path)) ?? []
                for child in children where child != "SKILL.md" {
                    try fileManager.createSymbolicLink(atPath: destination.appendingPathComponent(child).path,
                                                       withDestinationPath: entry.appendingPathComponent(child).path)
                }
                try writeFile(Data(cleaned.utf8), to: destination.appendingPathComponent("SKILL.md"))
            } else {
                try fileManager.createSymbolicLink(atPath: destination.path, withDestinationPath: entry.path)
            }
        }
        return true
    }

    // MARK: Dateien

    private static func sameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.resolvingSymlinksInPath().standardizedFileURL.path == rhs.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func readJSONObject(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func createDirectory(_ url: URL, fileManager: FileManager) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    private static func writeJSON(_ object: [String: Any], to url: URL) throws {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw BuildError(message: "\(url.lastPathComponent) ließ sich nicht schreiben")
        }
        try writeFile(try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), to: url)
    }

    private static func writeFile(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

extension ScheduledTaskPermissions {
    /// MCP-Server, deren Werkzeuge `extraTools` nennt (`mcp__<server>` oder
    /// `mcp__<server>__…`), in Reihenfolge, ohne Doppelte.
    var mcpServerNames: [String] {
        var seen = Set<String>()
        return extraTools.compactMap { raw in
            let rule = raw.trimmingCharacters(in: .whitespaces)
            guard rule.hasPrefix("mcp__") else { return nil }
            let rest = rule.dropFirst("mcp__".count)
            let server = rest.range(of: "__").map { String(rest[..<$0.lowerBound]) } ?? String(rest)
            guard !server.isEmpty, server != "*", seen.insert(server).inserted else { return nil }
            return server
        }
    }
}
