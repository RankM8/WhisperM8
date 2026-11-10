import Foundation

/// Wie lange der Login eines Claude-Kontos noch gilt.
///
/// Jeder `/login` hat ein festes Enddatum von rund 30 Tagen. Claude Code legt
/// es als `claudeAiOauth.refreshTokenExpiresAt` im Keychain-Eintrag ab. Das
/// laufende Erneuern des Access-Tokens verschiebt es nicht, nur ein neuer
/// Browser-Login. Ist die Frist um, leert die CLI beide Tokens und vermerkt
/// `loginEnded: "time_limit"` (gemessen an Claude Code 2.1.322, 10.11.2026).
/// Bei mehreren Konten läuft deshalb alle paar Tage eines ab — diese Struktur
/// macht das Datum sichtbar, bevor es so weit ist.
struct ClaudeLoginExpiry: Equatable {
    /// Ohne Refresh-Token ist der Login beendet, egal was das Datum sagt.
    var hasRefreshToken: Bool
    /// Festes Enddatum des Logins; `nil` bei alten Einträgen ohne das Feld.
    var endsAt: Date?
    /// Claude selbst hat das Zeitlimit als Grund vermerkt.
    var endedByTimeLimit: Bool = false

    enum Status: Equatable {
        /// `daysLeft` = volle Tage bis zum Ende; `nil` = Enddatum unbekannt.
        case active(daysLeft: Int?)
        case ended
    }

    enum Urgency: Int, Comparable {
        case none
        /// Endet innerhalb von `warnWithinDays`.
        case soon
        /// Endet innerhalb von `urgentWithinDays` — ab hier warnt auch Claude.
        case urgent
        case ended

        static func < (lhs: Urgency, rhs: Urgency) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    static let warnWithinDays = 7
    static let urgentWithinDays = 3

    func status(now: Date) -> Status {
        guard hasRefreshToken else { return .ended }
        guard let endsAt else { return .active(daysLeft: nil) }
        let remaining = endsAt.timeIntervalSince(now)
        guard remaining > 0 else { return .ended }
        return .active(daysLeft: Int(remaining / 86_400))
    }

    func urgency(now: Date) -> Urgency {
        switch status(now: now) {
        case .ended:
            return .ended
        case .active(let daysLeft):
            guard let daysLeft else { return .none }
            if daysLeft < Self.urgentWithinDays { return .urgent }
            if daysLeft < Self.warnWithinDays { return .soon }
            return .none
        }
    }

    /// Eine Zeile für Konten-Seite, Popover und Erneuerungs-Dialog. Leer, wenn
    /// das Enddatum unbekannt ist — dann gibt es nichts Verlässliches zu sagen.
    func summary(now: Date) -> String {
        switch status(now: now) {
        case .ended:
            return String(localized: "Login ended — renew it")
        case .active(let daysLeft):
            guard let daysLeft, let endsAt else { return "" }
            let day = endsAt.formatted(.dateTime.day().month(.abbreviated))
            if daysLeft == 0 {
                let time = endsAt.formatted(.dateTime.hour().minute())
                return String(localized: "Login ends within 24 hours (\(day), \(time))")
            }
            if daysLeft == 1 {
                return String(localized: "Login ends in 1 day (\(day))")
            }
            if daysLeft < Self.warnWithinDays {
                return String(localized: "Login ends in \(daysLeft) days (\(day))")
            }
            return String(localized: "Login valid until \(day)")
        }
    }

    /// Liest den Zustand aus dem rohen Keychain-Secret. `nil`, wenn der Eintrag
    /// kein lesbares `claudeAiOauth` enthält (nie angemeldet, fremdes Item).
    static func parse(secret: String) -> ClaudeLoginExpiry? {
        guard let data = secret.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = raw["claudeAiOauth"] as? [String: Any] else {
            return nil
        }
        let refreshToken = oauth["refreshToken"] as? String ?? ""
        let millis = (oauth["refreshTokenExpiresAt"] as? Double)
            ?? (oauth["refreshTokenExpiresAt"] as? Int).map(Double.init)
        return ClaudeLoginExpiry(
            hasRefreshToken: !refreshToken.isEmpty,
            endsAt: millis.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0 / 1000) : nil },
            endedByTimeLimit: (oauth["loginEnded"] as? String) == "time_limit"
        )
    }
}

/// Ergebnis eines Lese-Versuchs. „Kein Login“ und „gerade nicht lesbar“ sind
/// verschiedene Dinge: im zweiten Fall bleibt der letzte bekannte Stand stehen.
enum ClaudeLoginExpiryReading: Equatable {
    case login(ClaudeLoginExpiry)
    case noLogin
    case unreadable
}

extension ClaudeAccountProfiles {
    /// Login-Zustand eines Profils, nur gelesen. Startet `/usr/bin/security`,
    /// gehört also nie in einen View-Body.
    func readLoginExpiry(forProfile name: String) -> ClaudeLoginExpiryReading {
        let (status, secret) = readKeychainSecret(service: keychainService(forProfile: name))
        // 44 = Eintrag fehlt; alles andere außer 0 ist ein Lesefehler
        // (Schlüsselbund gesperrt, `security` nicht startbar).
        if status == 44 { return .noLogin }
        guard status == 0 else { return .unreadable }
        guard let expiry = ClaudeLoginExpiry.parse(secret: secret) else { return .noLogin }
        return .login(expiry)
    }
}
