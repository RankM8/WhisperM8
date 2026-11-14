import Foundation

/// Erneuert den Login eines bestehenden Claude-Kontos, ohne dass ein falsches
/// Konto im Profil landen kann.
///
/// Ablauf: `claude auth login --email <adresse>` läuft in einem leeren
/// Zwischenordner (eigenes `CLAUDE_CONFIG_DIR`, eigener Keychain-Eintrag).
/// Erst wenn dort genau das erwartete Konto angemeldet ist, wandert der neue
/// Login in den Keychain-Eintrag des Profils. Der Umweg ist nötig, weil der
/// Browser nur eine claude.ai-Sitzung kennt: Ist dort ein anderes Konto
/// angemeldet, hätte ein Login direkt im Profil dessen noch gültigen Login
/// mit dem falschen Konto überschrieben.
///
/// Der Login wird verschoben, nie kopiert: der Zwischen-Eintrag wird danach
/// gelöscht. Vom Profil-Eintrag wird nur `claudeAiOauth` ersetzt, alles
/// andere (`mcpOAuth`) bleibt stehen.
struct ClaudeLoginRenewer {
    enum Outcome: Equatable {
        case renewed(endsAt: Date?)
        /// Im Browser war ein anderes Konto angemeldet; am Profil ist nichts geändert.
        case wrongAccount(signedInAs: String?)
        case cancelled
        case timedOut
        case claudeMissing
        /// Das Profil hat keine Kontodaten — ein erster Login läuft über das Terminal.
        case notRenewable
        case failed(String)
    }

    var profiles = ClaudeAccountProfiles()
    var commandResolver: (String) -> String? = { AgentCommandBuilder.commandPath($0) }
    var processRunner: ClaudeLoginProcessRunning = ClaudeLoginProcessRunner()
    var fileManager: FileManager = .default
    var stagingRoot: URL = defaultStagingRoot()
    var makeStagingName: () -> String = { UUID().uuidString.lowercased().prefix(8).description }
    var now: () -> Date = Date.init
    /// Zeit für Mail-Link und Bestätigung im Browser.
    var timeout: TimeInterval = 10 * 60
    /// Wartezeit, bevor der geschriebene Login nachgeprüft wird. Ein laufender
    /// Chat desselben Kontos, der genau in diesem Moment sein Token erneuert,
    /// könnte den neuen Login mit dem alten überschreiben.
    var settleDelay: TimeInterval = 1.5

    /// `security find-generic-password` meldet einen fehlenden Eintrag so.
    static let keychainItemNotFound: Int32 = 44

    /// Liegengebliebene Zwischenordner (Absturz mitten im Login) räumt der
    /// nächste Lauf ab diesem Alter weg.
    static let staleStagingAge: TimeInterval = 30 * 60

    static func defaultStagingRoot() -> URL {
        AppInstance.applicationSupport
            .appendingPathComponent("WhisperM8", isDirectory: true)
            .appendingPathComponent("claude-login-staging", isDirectory: true)
    }

    /// Konto, das der Login treffen muss — aus der `.claude.json` des Profils.
    struct Identity: Equatable {
        var email: String
        var accountUUID: String?
        var organizationUUID: String?
        var organizationName: String?

        /// Gleiche Person in gleicher Organisation? Dieselbe Adresse kann zu
        /// mehreren Organisationen gehören (privates Abo und Team); der Login
        /// muss beide treffen.
        func matches(_ other: Identity) -> Bool {
            if let mine = accountUUID, let theirs = other.accountUUID {
                guard mine == theirs else { return false }
            } else {
                guard email.caseInsensitiveCompare(other.email) == .orderedSame else { return false }
            }
            if let mine = organizationUUID, let theirs = other.organizationUUID {
                return mine == theirs
            }
            return true
        }

        var displayText: String {
            guard let organizationName, !organizationName.isEmpty,
                  !organizationName.hasSuffix("'s Organization"),
                  !organizationName.hasSuffix("’s Organization") else { return email }
            return "\(email) · \(organizationName)"
        }
    }

    static func identity(inClaudeJSON url: URL) -> Identity? {
        guard let account = ClaudeAccountProfiles.readJSONObject(at: url)?["oauthAccount"] as? [String: Any],
              let email = account["emailAddress"] as? String, !email.isEmpty else {
            return nil
        }
        return Identity(
            email: email,
            accountUUID: account["accountUuid"] as? String,
            organizationUUID: account["organizationUuid"] as? String,
            organizationName: account["organizationName"] as? String
        )
    }

    func renew(
        profileNamed name: String,
        control: ClaudeLoginProcessControl,
        onLoginURL: @escaping @Sendable (URL) -> Void
    ) async -> Outcome {
        guard let expected = Self.identity(inClaudeJSON: profiles.claudeJSONURL(forProfile: name)) else {
            return .notRenewable
        }
        guard let claude = commandResolver("claude") else { return .claudeMissing }

        removeStaleStaging()
        let stagingDir = stagingRoot.appendingPathComponent(makeStagingName(), isDirectory: true)
        do {
            try fileManager.createDirectory(
                at: stagingDir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            return .failed(error.localizedDescription)
        }
        defer { discardStaging(stagingDir) }

        let result = await processRunner.run(
            executable: claude,
            arguments: ["auth", "login", "--claudeai", "--email", expected.email],
            environmentOverrides: ["CLAUDE_CONFIG_DIR": stagingDir.path],
            workingDirectory: stagingDir.path,
            timeout: timeout,
            control: control,
            onLoginURL: onLoginURL
        )
        switch result.end {
        case .cancelled:
            return .cancelled
        case .timedOut:
            return .timedOut
        case .launchFailed(let detail):
            return .failed(detail)
        case .exited:
            guard result.exitCode == 0 else {
                Logger.agentStore.warning("claude_login_renew_cli_failed profile=\(name, privacy: .public) exit=\(result.exitCode)")
                return .failed(Self.failureText(fromOutput: result.output, exitCode: result.exitCode))
            }
        }

        // Wer ist im Zwischenordner angemeldet? Ohne diese Auskunft wird nichts übernommen.
        let stagedJSON = stagingDir.appendingPathComponent(".claude.json", isDirectory: false)
        guard let staged = Self.identity(inClaudeJSON: stagedJSON) else {
            return .failed(String(localized: "The login finished, but the account could not be verified."))
        }
        guard expected.matches(staged) else {
            Logger.agentStore.notice("claude_login_renew_wrong_account profile=\(name, privacy: .public)")
            return .wrongAccount(signedInAs: staged.displayText)
        }
        guard let stagedSecret = readStagedSecret(stagingDir: stagingDir) else {
            return .failed(String(localized: "The login finished, but its credentials were not found."))
        }

        // Der Login kann bis zu zehn Minuten gedauert haben. Wurde das Profil
        // in der Zeit auf ein anderes Konto umgestellt (Terminal-/login,
        // „Zum Hauptkonto machen“), gehört der neue Login nicht mehr hierher.
        guard let stillThere = Self.identity(inClaudeJSON: profiles.claudeJSONURL(forProfile: name)),
              expected.matches(stillThere) else {
            return .failed(String(localized: "The account of this profile changed during the login. Nothing was changed."))
        }

        let service = profiles.keychainService(forProfile: name)
        guard let existing = readExistingSecret(service: service) else {
            Logger.agentStore.error("claude_login_renew_existing_unreadable profile=\(name, privacy: .public)")
            return .failed(String(localized: "The current Keychain entry of this account could not be read. Nothing was changed."))
        }
        guard let merged = Self.mergedSecret(existing: existing, staged: stagedSecret) else {
            return .failed(String(localized: "The new login has an unexpected format."))
        }

        let writeStatus = write(merged, service: service, restoring: existing)
        guard writeStatus == 0 else {
            Logger.agentStore.error("claude_login_renew_keychain_failed profile=\(name, privacy: .public) status=\(writeStatus)")
            return .failed(String(localized: "Could not save the new login to the Keychain (status \(Int(writeStatus)))."))
        }

        // Nachprüfen: steht nach kurzer Zeit noch unser Login im Eintrag?
        if settleDelay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(settleDelay * 1_000_000_000))
        }
        if !holdsLogin(of: stagedSecret, service: service) {
            Logger.agentStore.notice("claude_login_renew_overwritten profile=\(name, privacy: .public)")
            // Einmal neu zusammenführen (ein inzwischen geändertes `mcpOAuth` bleibt erhalten).
            guard let current = readExistingSecret(service: service),
                  let again = Self.mergedSecret(existing: current, staged: stagedSecret),
                  write(again, service: service, restoring: current) == 0,
                  holdsLogin(of: stagedSecret, service: service) else {
                return .failed(String(localized: "Another Claude process overwrote the new login. Renew this account again."))
            }
        }

        let endsAt = ClaudeLoginExpiry.parse(secret: merged)?.endsAt
        Logger.agentStore.notice("claude_login_renewed profile=\(name, privacy: .public)")
        return .renewed(endsAt: endsAt)
    }

    /// Der bestehende Eintrag des Profils: `""`, wenn es keinen gibt, `nil`,
    /// wenn er sich nicht verlässlich lesen lässt. Im zweiten Fall wird nichts
    /// geschrieben — sonst gingen die MCP-Logins des Kontos verloren, die im
    /// selben Eintrag liegen.
    private func readExistingSecret(service: String) -> String? {
        let (status, raw) = profiles.readKeychainSecret(service: service)
        if status == Self.keychainItemNotFound { return "" }
        guard status == 0 else { return nil }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return "" }
        return Self.jsonObject(text) == nil ? nil : text
    }

    /// Schreibt mit Rücklesen. Scheitert es, kommt der vorherige Stand zurück;
    /// gab es keinen, wird ein abweichend geschriebener Eintrag entfernt.
    private func write(_ secret: String, service: String, restoring previous: String) -> Int32 {
        let status = profiles.writeKeychainSecretVerified(
            service: service, account: profiles.keychainAccount, secret: secret)
        guard status != 0 else { return 0 }
        if !previous.isEmpty {
            _ = profiles.writeKeychainSecretVerified(
                service: service, account: profiles.keychainAccount, secret: previous)
        } else if status == 98 {
            profiles.deleteKeychainSecret(service: service)
        }
        return status
    }

    /// Trägt der Eintrag den Refresh-Token des frischen Logins?
    private func holdsLogin(of stagedSecret: String, service: String) -> Bool {
        let (status, raw) = profiles.readKeychainSecret(service: service)
        guard status == 0,
              let stored = (Self.jsonObject(raw)?["claudeAiOauth"] as? [String: Any])?["refreshToken"] as? String,
              let fresh = (Self.jsonObject(stagedSecret)?["claudeAiOauth"] as? [String: Any])?["refreshToken"] as? String else {
            return false
        }
        return stored == fresh
    }

    // MARK: - Zusammenführen

    /// Setzt das `claudeAiOauth` des frischen Logins in den bestehenden
    /// Eintrag des Profils. `nil`, wenn der frische Login keine brauchbaren
    /// Tokens trägt oder der bestehende Eintrag kein JSON-Objekt ist — dann
    /// wird nichts geschrieben. Ein leerer `existing` heißt: es gab keinen.
    static func mergedSecret(existing: String, staged: String) -> String? {
        guard let stagedObject = jsonObject(staged),
              let oauth = stagedObject["claudeAiOauth"] as? [String: Any],
              let access = oauth["accessToken"] as? String, !access.isEmpty,
              let refresh = oauth["refreshToken"] as? String, !refresh.isEmpty else {
            return nil
        }
        var target: [String: Any] = [:]
        if !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let parsed = jsonObject(existing) else { return nil }
            target = parsed
        }
        target["claudeAiOauth"] = oauth
        guard let data = try? JSONSerialization.data(withJSONObject: target, options: [.withoutEscapingSlashes]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func jsonObject(_ text: String) -> [String: Any]? {
        guard let data = text.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Letzte Zeile der CLI-Ausgabe, ohne Login-Adresse und Steuerzeichen.
    static func failureText(fromOutput output: String, exitCode: Int32) -> String {
        let lines = output
            .components(separatedBy: .newlines)
            .map { line in
                String(line.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F })
                    .trimmingCharacters(in: .whitespaces)
            }
            .filter { !$0.isEmpty && !$0.contains("https://") && !$0.hasPrefix("Paste code") && !$0.hasPrefix("Opening browser") }
        guard let last = lines.last else {
            return String(localized: "The Claude CLI ended the login (exit \(Int(exitCode))).")
        }
        return String(last.prefix(200))
    }

    // MARK: - Zwischenordner

    /// Das Secret des Zwischen-Logins: Keychain-Eintrag des Zwischenordners,
    /// sonst die Datei, die Claude schreibt, wenn der Keychain den Eintrag ablehnt.
    private func readStagedSecret(stagingDir: URL) -> String? {
        let service = ClaudeAccountProfiles.keychainService(forConfigDirPath: stagingDir.path)
        let (status, secret) = profiles.readKeychainSecret(service: service)
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        if status == 0, !trimmed.isEmpty { return trimmed }
        let file = stagingDir.appendingPathComponent(".credentials.json", isDirectory: false)
        guard let data = try? Data(contentsOf: file), let text = String(data: data, encoding: .utf8) else { return nil }
        let fileText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return fileText.isEmpty ? nil : fileText
    }

    /// Entfernt Zwischenordner und Zwischen-Eintrag. Nur lokal löschen, nicht
    /// bei Anthropic abmelden: nach einer Übernahme gehört der Login dem Profil.
    private func discardStaging(_ stagingDir: URL) {
        profiles.deleteKeychainSecret(service: ClaudeAccountProfiles.keychainService(forConfigDirPath: stagingDir.path))
        try? fileManager.removeItem(at: stagingDir)
        // Claudes Lock-Ordner liegt als Geschwister neben dem Config-Dir.
        try? fileManager.removeItem(at: stagingDir.appendingPathExtension("lock"))
    }

    /// Räumt liegengebliebene Zwischenordner samt Zwischen-Eintrag weg. Beim
    /// App-Start mit `olderThan: 0`: dann kann kein Login mehr dazugehören.
    func removeStaleStaging(olderThan age: TimeInterval = ClaudeLoginRenewer.staleStagingAge) {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: stagingRoot,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for entry in entries where entry.pathExtension != "lock" {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            guard now().timeIntervalSince(modified) >= age else { continue }
            // Pfad wie beim Login bilden (Wurzel + Name): der Name des
            // Keychain-Eintrags hängt an der exakten Schreibweise, und die
            // Verzeichnisliste kann Symlinks wie /var → /private/var auflösen.
            discardStaging(stagingRoot.appendingPathComponent(entry.lastPathComponent, isDirectory: true))
        }
    }
}
