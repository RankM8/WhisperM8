import Foundation

/// „Als Hauptkonto übernehmen": Der Login eines Zusatzprofils wird zum Login
/// von `main` (`~/.claude`), seine Chats ziehen mit, das Profil verschwindet.
///
/// Warum nötig: `main` ist kein Zeiger, sondern das Default-Config-Dir — dort
/// laufen `claude` im Terminal, der Supervisor-Daemon (`claude --bg`) und alle
/// Chats ohne Profil-Stempel. Ein totes Konto in `main` (Befund 2026-10-08:
/// HTTP 403, Konto existiert nicht mehr) liess sich bisher weder ersetzen noch
/// entfernen, weil `main` keine Verwaltungs-Aktionen hatte.
///
/// Der bisherige main-Login wird dabei überschrieben (er ist danach weg; ein
/// neues Profil kann ihn jederzeit wieder anmelden). Den Login des Profils zu
/// KOPIEREN statt zu verschieben wäre falsch: beide Keychain-Items trügen
/// denselben Refresh-Token, und der erste Refresh des einen entwertete das
/// andere.
extension ClaudeAccountProfiles {
    enum PromoteError: LocalizedError, Equatable {
        case cannotPromoteMain
        case profileMissing(String)
        case notLoggedIn(String)
        case mainConfigUnreadable(String)
        case keychainWriteFailed(String)

        var errorDescription: String? {
            switch self {
            case .cannotPromoteMain:
                return "“main” already is the main account."
            case .profileMissing(let name):
                return "Account profile “\(name)” does not exist."
            case .notLoggedIn(let name):
                return "“\(name)” has no usable login (Keychain entry or account data missing) — log in first."
            case .mainConfigUnreadable(let detail):
                return "Could not read ~/.claude.json: \(detail)"
            case .keychainWriteFailed(let detail):
                return "Could not write the main Keychain login: \(detail)"
            }
        }
    }

    struct PromotionResult: Equatable {
        /// Dateien/Ordner, die aus dem Profil in den main-Root gewandert sind.
        var movedItemCount: Int
        /// Relativ zum Profil-Verzeichnis: Einträge, die es in main schon gab
        /// (z. B. `projects/<cwd>/memory/MEMORY.md`). Sie bleiben im
        /// Profil-Ordner und gehen mit ihm in den Papierkorb.
        var conflicts: [String]
    }

    /// Diese Unterordner des Profils werden in die gleichnamigen von
    /// `~/.claude` gemischt: `projects/` trägt die Transcripts (ohne sie
    /// fände `--resume` die Chats nicht mehr) und das Projekt-Memory,
    /// `file-history/` die /rewind-Checkpoints dieser Chats.
    static let promotedDataFolders = ["projects", "file-history"]

    /// Übernimmt das Profil als Hauptkonto. Reihenfolge mit Rücknahme bei
    /// Fehlern: (1) Login + `oauthAccount` nach main — gescheitert → main
    /// unverändert; (2) Daten mischen — gescheitert → Daten zurück und main-
    /// Login wiederhergestellt; (3) Aufräumen (Keychain-Item des Profils,
    /// Ordner in den Papierkorb, `.active`). Ab (3) ist der Umzug vollzogen,
    /// Aufräum-Fehler brechen ihn nicht mehr ab.
    ///
    /// Der Caller muss sicherstellen, dass keine Session dieses Profils läuft
    /// (ihr `CLAUDE_CONFIG_DIR` verschwindet), und danach die Session-Stempel
    /// umziehen (`AgentSessionStore.renameClaudeSessionProfiles(from:to: nil)`).
    @discardableResult
    func promoteToMain(
        _ name: String,
        trashItem: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    ) throws -> PromotionResult {
        guard name != Self.mainProfileName else { throw PromoteError.cannotPromoteMain }
        let profileDir = configDir(forProfile: name)
        guard Self.isValidProfileName(name), fileManager.fileExists(atPath: profileDir.path) else {
            throw PromoteError.profileMissing(name)
        }

        // Vorab alles lesen, was gebraucht wird — bevor irgendetwas geändert ist.
        guard let profileAccount = Self.readJSONObject(at: claudeJSONURL(forProfile: name))?["oauthAccount"]
                as? [String: Any] else {
            throw PromoteError.notLoggedIn(name)
        }
        let profileService = keychainService(forProfile: name)
        let (readStatus, rawSecret) = securityRunner(["find-generic-password", "-s", profileService, "-w"])
        let secret = rawSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard readStatus == 0, !secret.isEmpty else { throw PromoteError.notLoggedIn(name) }

        let mainJSONURL = claudeJSONURL(forProfile: Self.mainProfileName)
        var mainJSON: [String: Any] = [:]
        if fileManager.fileExists(atPath: mainJSONURL.path) {
            guard let parsed = Self.readJSONObject(at: mainJSONURL) else {
                throw PromoteError.mainConfigUnreadable("not valid JSON")
            }
            mainJSON = parsed
        }
        let previousMainJSONData = try? Data(contentsOf: mainJSONURL)
        let mainService = keychainService(forProfile: Self.mainProfileName)
        let (oldMainStatus, oldMainRaw) = securityRunner(["find-generic-password", "-s", mainService, "-w"])
        let previousMainSecret = oldMainStatus == 0
            ? oldMainRaw.trimmingCharacters(in: .whitespacesAndNewlines)
            : ""

        // (1) Login nach main
        try writeMainSecret(secret, service: mainService)
        mainJSON["oauthAccount"] = profileAccount
        do {
            let data = try JSONSerialization.data(withJSONObject: mainJSON, options: [.prettyPrinted, .withoutEscapingSlashes])
            try data.write(to: mainJSONURL, options: .atomic)
        } catch {
            restoreMainSecret(previousMainSecret, service: mainService)
            throw PromoteError.mainConfigUnreadable(error.localizedDescription)
        }

        // (2) Daten mischen
        var moves: [(from: URL, to: URL)] = []
        var conflicts: [String] = []
        do {
            let mainDir = configDir(forProfile: Self.mainProfileName)
            for folder in Self.promotedDataFolders {
                try mergeContents(
                    of: profileDir.appendingPathComponent(folder, isDirectory: true),
                    into: mainDir.appendingPathComponent(folder, isDirectory: true),
                    relativePath: folder,
                    moves: &moves,
                    conflicts: &conflicts
                )
            }
        } catch {
            for move in moves.reversed() {
                try? fileManager.moveItem(at: move.to, to: move.from)
            }
            restoreMainSecret(previousMainSecret, service: mainService)
            if let previousMainJSONData {
                try? previousMainJSONData.write(to: mainJSONURL, options: .atomic)
            } else {
                try? fileManager.removeItem(at: mainJSONURL)
            }
            throw error
        }

        // (3) Aufräumen — der Umzug ist vollzogen.
        _ = securityRunner(["delete-generic-password", "-s", profileService])
        do {
            try trashItem(profileDir)
        } catch {
            Logger.agentStore.error(
                "claude_profile_promote_trash_failed name=\(name, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
        }
        if (try? String(contentsOf: activeFileURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) == name {
            try? setActiveProfile(Self.mainProfileName)
        }
        Logger.agentStore.notice(
            "claude_profile_promoted_to_main name=\(name, privacy: .public) moved=\(moves.count) conflicts=\(conflicts.count)"
        )
        return PromotionResult(movedItemCount: moves.count, conflicts: conflicts)
    }

    /// Verschiebt jeden Eintrag aus `source` nach `target`. Ordner, die es auf
    /// beiden Seiten gibt, werden rekursiv gemischt (z. B. derselbe
    /// Projekt-Ordner unter `projects/`); gleichnamige Dateien werden nie
    /// überschrieben, sondern als Konflikt gemeldet und bleiben liegen.
    private func mergeContents(
        of source: URL,
        into target: URL,
        relativePath: String,
        moves: inout [(from: URL, to: URL)],
        conflicts: inout [String]
    ) throws {
        guard isDirectory(source) else { return }
        // Symlinks (geteilte Einträge aus `ccs`) nicht verfolgen — sie zeigen
        // ohnehin nach main.
        let entries = try fileManager.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        )
        if !entries.isEmpty, !fileManager.fileExists(atPath: target.path) {
            try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
        }
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = entry.lastPathComponent
            let destination = target.appendingPathComponent(name)
            let relative = "\(relativePath)/\(name)"
            if fileManager.fileExists(atPath: destination.path) {
                if isDirectory(entry), isDirectory(destination) {
                    try mergeContents(
                        of: entry,
                        into: destination,
                        relativePath: relative,
                        moves: &moves,
                        conflicts: &conflicts
                    )
                } else {
                    conflicts.append(relative)
                }
                continue
            }
            try fileManager.moveItem(at: entry, to: destination)
            moves.append((entry, destination))
        }
    }

    private func isDirectory(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return values?.isDirectory == true && values?.isSymbolicLink != true
    }

    private func writeMainSecret(_ secret: String, service: String) throws {
        let (status, _) = securityRunner([
            "add-generic-password", "-a", NSUserName(), "-s", service,
            "-l", service, "-w", secret, "-U",
        ])
        guard status == 0 else {
            throw PromoteError.keychainWriteFailed("security add-generic-password exit \(status)")
        }
    }

    /// Rücknahme von Schritt (1): alten main-Login zurückschreiben; gab es
    /// keinen, das neu angelegte Item wieder löschen.
    private func restoreMainSecret(_ previousSecret: String, service: String) {
        if previousSecret.isEmpty {
            _ = securityRunner(["delete-generic-password", "-s", service])
        } else {
            _ = try? writeMainSecret(previousSecret, service: service)
        }
    }

    private static func readJSONObject(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
