import Foundation

/// Kontowahl für neue Chats aus der CLI (`whisperm8 chats new`) und das
/// Prüfen eines Zielkontos (`chats move-account`).
///
/// Regel: Ohne `--account` gilt das Konto, das in Einstellungen → Konten aktiv
/// ist (`.active`). Ist es verschwunden, abgemeldet oder ist sein Login
/// abgelaufen, scheitert der Befehl mit einer klaren Meldung — nie ein stiller
/// Rückfall auf `main`. Ein Chat, der im falschen Konto entstanden ist, lässt
/// sich nur noch per Transcript-Umzug korrigieren.
extension ClaudeAccountProfiles {
    /// Ergebnis der Kontowahl für einen neuen Chat.
    struct NewChatAccount: Equatable {
        enum Source: String, Equatable {
            /// `--account <profil>`
            case explicit
            /// Das in den Einstellungen aktive Konto.
            case active
            /// Notbremse `chatsNewProfileDefaultEnabled = NO`: immer `main`.
            case killSwitch
        }

        /// Stempel-Wert der Session (`nil` = main).
        var profileName: String?
        var source: Source

        var displayName: String { profileName ?? ClaudeAccountProfiles.mainProfileName }
    }

    /// Warum ein Konto für einen neuen Chat (oder als Umzugsziel) nicht taugt.
    struct NewChatAccountError: LocalizedError, Equatable {
        enum Reason: Equatable {
            case unknownProfile(String)
            /// `.active` nennt ein Profil, das es nicht mehr gibt.
            case activeProfileMissing(String)
            case notLoggedIn(String)
            case loginEnded(String)
        }

        var reason: Reason
        /// Das Konto kam aus den Einstellungen, nicht aus `--account`.
        var isActiveDefault: Bool
        /// Angemeldete Konten, damit die Meldung gleich die Auswahl nennt.
        var usableProfiles: [String]

        var errorDescription: String? {
            let available = usableProfiles.isEmpty
                ? "keins gefunden"
                : usableProfiles.joined(separator: ", ")
            let hint = isActiveDefault
                ? " Ein anderes Konto: --account <profil>, oder in WhisperM8 unter Einstellungen → Konten ein angemeldetes Konto aktiv setzen. Angemeldet: \(available)."
                : " Angemeldet: \(available)."
            let subject: (String) -> String = { name in
                self.isActiveDefault ? "Das aktive Claude-Konto „\(name)“" : "Claude-Konto „\(name)“"
            }
            switch reason {
            case .unknownProfile(let name):
                return "Claude-Konto „\(name)“ existiert nicht." + hint
            case .activeProfileMissing(let name):
                return "Das in den Einstellungen aktive Claude-Konto „\(name)“ existiert nicht mehr." + hint
            case .notLoggedIn(let name):
                return "\(subject(name)) ist nicht angemeldet." + hint
            case .loginEnded(let name):
                return "\(subject(name)) ist abgelaufen — Login in WhisperM8 unter Einstellungen → Konten erneuern („Renew…“)." + hint
            }
        }
    }

    /// Echter Ordnername eines Profils. Ein Profilname, der sich nur in der
    /// Groß-/Kleinschreibung unterscheidet, findet auf APFS zwar denselben
    /// Ordner — Claude bildet den Keychain-Namen aber aus dem unveränderten
    /// Pfad, `rankm8` statt `RankM8` stünde also ohne Login da.
    /// `nil` = kein solches Profil (oder mehrdeutig).
    func canonicalProfileName(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let names = profileNames()
        if names.contains(name) { return name }
        let matches = names.filter { $0.caseInsensitiveCompare(name) == .orderedSame }
        return matches.count == 1 ? matches[0] : nil
    }

    /// Roher Inhalt von `.active`; `nil`, wenn die Datei fehlt oder leer ist
    /// (dann ist `main` aktiv — so legt auch die Konten-Seite es aus).
    func activeProfileFileValue() -> String? {
        guard let raw = try? String(contentsOf: activeFileURL, encoding: .utf8) else { return nil }
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// Prüft, ob ein (kanonisches) Konto gerade nutzbar ist.
    ///
    /// Zusatzprofile: Kontodaten in der `.claude.json` UND ein Login im
    /// Keychain, dessen Frist nicht um ist.
    ///
    /// `main` sperrt nur ein NACHWEISLICH abgelaufener Login. Fehlende
    /// Kontodaten oder ein fehlender Keychain-Eintrag allein sagen bei main
    /// nichts: dort läuft Claude auch mit API-Key, `apiKeyHelper` oder über
    /// einen Proxy, ganz ohne OAuth-Login.
    ///
    /// Ein unlesbarer Keychain (gesperrt, `security` nicht startbar) blockiert
    /// nie — dann gibt es keine verlässliche Aussage.
    func loginProblem(
        forProfile name: String,
        loginReading: (String) -> ClaudeLoginExpiryReading,
        now: Date
    ) -> NewChatAccountError.Reason? {
        let isMain = name == Self.mainProfileName
        if !isMain, !profile(named: name).isLoggedIn { return .notLoggedIn(name) }
        switch loginReading(name) {
        case .noLogin:
            return isMain ? nil : .notLoggedIn(name)
        case .login(let expiry):
            return expiry.status(now: now) == .ended ? .loginEnded(name) : nil
        case .unreadable:
            return nil
        }
    }

    /// Konten, die gerade taugen — für die Fehlermeldung („Angemeldet: …“).
    /// Dieselbe Prüfung wie für das gewählte Konto, ein abgelaufener Login
    /// zählt also nicht. Läuft nur im Fehlerfall (ein Keychain-Zugriff je
    /// Konto mit Kontodaten).
    func usableProfiles(
        loginReading: (String) -> ClaudeLoginExpiryReading,
        now: Date
    ) -> [String] {
        profileNames().filter { loginProblem(forProfile: $0, loginReading: loginReading, now: now) == nil }
    }

    /// Konto für einen neuen Claude-Chat.
    ///
    /// - Parameters:
    ///   - requested: Wert von `--account`; `nil`/leer = aktives Konto.
    ///   - followsActiveProfile: `false` bei gezogener Notbremse
    ///     `chatsNewProfileDefaultEnabled` — dann wie früher `main`.
    ///   - loginReading: Keychain-Zustand eines Profils (Tests: Closure).
    func resolveNewChatAccount(
        requested: String?,
        followsActiveProfile: Bool,
        loginReading: (String) -> ClaudeLoginExpiryReading,
        now: Date = Date()
    ) throws -> NewChatAccount {
        let trimmed = requested?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name: String
        let source: NewChatAccount.Source
        if !trimmed.isEmpty {
            source = .explicit
            guard let canonical = canonicalProfileName(trimmed) else {
                throw NewChatAccountError(
                    reason: .unknownProfile(trimmed), isActiveDefault: false,
                    usableProfiles: usableProfiles(loginReading: loginReading, now: now))
            }
            name = canonical
        } else if !followsActiveProfile {
            source = .killSwitch
            name = Self.mainProfileName
        } else {
            source = .active
            if let raw = activeProfileFileValue() {
                guard let canonical = canonicalProfileName(raw) else {
                    throw NewChatAccountError(
                        reason: .activeProfileMissing(raw), isActiveDefault: true,
                        usableProfiles: usableProfiles(loginReading: loginReading, now: now))
                }
                name = canonical
            } else {
                name = Self.mainProfileName
            }
        }

        if let problem = loginProblem(forProfile: name, loginReading: loginReading, now: now) {
            throw NewChatAccountError(
                reason: problem, isActiveDefault: source != .explicit,
                usableProfiles: usableProfiles(loginReading: loginReading, now: now))
        }
        return NewChatAccount(
            profileName: name == Self.mainProfileName ? nil : name,
            source: source)
    }
}
