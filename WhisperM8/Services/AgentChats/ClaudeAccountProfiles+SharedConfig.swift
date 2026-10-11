import Foundation

/// Geteilte Konfiguration über alle Profile (Analyse 11.10.2026): Heilen der
/// Symlinks und Schutz der Plugin-Registry beim Entfernen/Hochstufen.
extension ClaudeAccountProfiles {
    // MARK: - Geteilte Einträge heilen

    struct SharedItemsHealReport: Equatable {
        /// `<profil>/<eintrag>`: fehlender Link angelegt.
        var linked: [String] = []
        /// `<profil>/<eintrag>`: inhaltsgleiche Kopie durch Link ersetzt.
        var replacedCopies: [String] = []
        /// `<profil>/<eintrag>`: echter Ordner mit abweichendem Inhalt — bleibt.
        var divergent: [String] = []
    }

    /// Bringt jedes Profil auf den Stand von `sharedItems`: fehlende Links
    /// anlegen, Ordner, die in main fehlen, dort anlegen, und echte Ordner,
    /// deren Inhalt exakt dem von main entspricht, durch den Link ersetzen
    /// (die Kopie wandert nach `backupRoot`). Abweichende Ordner bleiben
    /// unangetastet und werden nur gemeldet — dort liegt etwas Eigenes.
    /// Idempotent; kostet bei heilem Stand ein `lstat` je Eintrag.
    func healSharedItems(backupRoot: URL) -> SharedItemsHealReport {
        var report = SharedItemsHealReport()
        let mainDir = configDir(forProfile: Self.mainProfileName)
        for profile in profiles() where profile.name != Self.mainProfileName {
            for item in Self.sharedItems {
                let source = mainDir.appendingPathComponent(item)
                let target = profile.configDir.appendingPathComponent(item)
                let label = "\(profile.name)/\(item)"
                let isDirectoryItem = Self.sharedDirectories.contains(item)
                if isDirectoryItem, !fileManager.fileExists(atPath: source.path) {
                    try? fileManager.createDirectory(at: source, withIntermediateDirectories: true)
                }
                guard fileManager.fileExists(atPath: source.path) else { continue }

                let values = try? target.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
                if values?.isSymbolicLink == true { continue }
                if values == nil {
                    // Fehlt ganz (auch kein kaputter Link) → anlegen.
                    if (try? fileManager.createSymbolicLink(at: target, withDestinationURL: source)) != nil {
                        report.linked.append(label)
                    }
                    continue
                }
                guard isDirectoryItem, values?.isDirectory == true else { continue }
                guard fileManager.contentsEqual(atPath: target.path, andPath: source.path) else {
                    report.divergent.append(label)
                    continue
                }
                let backup = backupRoot.appendingPathComponent(profile.name, isDirectory: true)
                do {
                    try fileManager.createDirectory(at: backup, withIntermediateDirectories: true)
                    try fileManager.moveItem(at: target, to: backup.appendingPathComponent(item))
                    try fileManager.createSymbolicLink(at: target, withDestinationURL: source)
                    report.replacedCopies.append(label)
                } catch {
                    Logger.agentStore.warning(
                        "claude_shared_item_heal_failed item=\(label, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                }
            }
        }
        return report
    }

    /// Start-Hook der App (Hintergrund).
    static func healSharedItemsAtLaunch() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let backup = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WhisperM8/config-migration/shared-items-\(formatter.string(from: Date()))")
        let report = ClaudeAccountProfiles().healSharedItems(backupRoot: backup)
        if report != SharedItemsHealReport() {
            Logger.agentStore.notice(
                "claude_shared_items_healed linked=\(report.linked.joined(separator: ","), privacy: .public) replaced=\(report.replacedCopies.joined(separator: ","), privacy: .public) divergent=\(report.divergent.joined(separator: ","), privacy: .public)")
        }
    }

    // MARK: - Plugin-Registry

    /// Plugins und Marketplaces, die über den Ordner dieses Profils registriert
    /// sind. Claude Code schreibt bei Installation und Update den Pfad mit dem
    /// `CLAUDE_CONFIG_DIR` der Session, die es gerade tut — wegen des geteilten
    /// `plugins/`-Links liegt die Datei zwar in main, der Pfad führt aber durch
    /// `~/.claude-profiles/<name>/`. Verschwindet der Profilordner, sind diese
    /// Plugins für ALLE Konten kaputt. Nur lesend; die Registry ist Claudes Datei.
    func pluginRegistryReferences(toProfile name: String) -> [String] {
        let prefix = configDir(forProfile: name).path + "/"
        let pluginsDir = configDir(forProfile: Self.mainProfileName).appendingPathComponent("plugins")
        var references: [String] = []

        if let registry = Self.readJSONObject(at: pluginsDir.appendingPathComponent("installed_plugins.json")),
           let plugins = registry["plugins"] as? [String: Any] {
            for (id, value) in plugins.sorted(by: { $0.key < $1.key }) {
                let entries = (value as? [[String: Any]]) ?? []
                for entry in entries where (entry["installPath"] as? String)?.hasPrefix(prefix) == true {
                    let scope = entry["scope"] as? String ?? "?"
                    let label = "\(id) (\(scope))"
                    if !references.contains(label) { references.append(label) }
                }
            }
        }
        if let marketplaces = Self.readJSONObject(at: pluginsDir.appendingPathComponent("known_marketplaces.json")) {
            for (name, value) in marketplaces.sorted(by: { $0.key < $1.key }) {
                if ((value as? [String: Any])?["installLocation"] as? String)?.hasPrefix(prefix) == true {
                    references.append("Marketplace \(name)")
                }
            }
        }
        return references
    }

    /// Fehlertext für Entfernen/Hochstufen, wenn Plugins am Profil hängen.
    static func pluginRegistryBlockMessage(profile name: String, references: [String]) -> String {
        let sample = references.prefix(6).joined(separator: ", ")
        return "“\(name)” can't be removed yet: \(references.count) plugin registration(s) point through its folder (\(sample)\(references.count > 6 ? ", …" : "")). Removing it would break them for every account. Reinstall them from the main account first — in a terminal without CLAUDE_CONFIG_DIR: `claude plugin uninstall <id> --scope user` then `claude plugin install <id> --scope user` (project-scope entries: in that project with --scope project; marketplaces: `claude plugin marketplace remove/add`)."
    }
}
