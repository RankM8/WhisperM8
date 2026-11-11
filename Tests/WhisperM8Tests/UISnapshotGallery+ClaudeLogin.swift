import CoreGraphics
import SwiftUI
@testable import WhisperM8

/// Fixtures für den Dialog „Claude-Logins erneuern“ — feste Zwischenstände,
/// ohne Keychain, Browser oder CLI.
extension UISnapshotGallery {
    @MainActor
    static func claudeLoginFixtures() -> [Fixture] {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func expiry(_ days: Double, token: Bool = true) -> ClaudeLoginExpiry {
            ClaudeLoginExpiry(hasRefreshToken: token, endsAt: now.addingTimeInterval(days * 86_400))
        }
        func row(
            _ name: String,
            days: Double,
            token: Bool = true,
            selected: Bool = true,
            status: ClaudeLoginRenewalSession.Status = .pending
        ) -> ClaudeLoginRenewalSession.Row {
            ClaudeLoginRenewalSession.Row(
                name: name,
                email: "\(name.lowercased())@example.com",
                expiry: expiry(days, token: token),
                isSelected: selected,
                status: status
            )
        }
        let size = CGSize(width: 620, height: 560)
        let loginURL = URL(string: "https://claude.com/cai/oauth/authorize?code=true")

        return [
            Fixture(name: "konten-login-erneuern-auswahl", size: size) {
                AnyView(ClaudeLoginRenewalSheet(
                    session: .preview(
                        rows: [
                            row("main", days: -8, token: false),
                            row("RankM8", days: 4.4),
                            row("PowerUser", days: 20),
                            row("ai2", days: 29.6, selected: false),
                        ],
                        currentName: nil,
                        loginURL: nil
                    ),
                    openURL: { _ in },
                    now: now
                ))
            },
            Fixture(name: "konten-login-erneuern-laeuft", size: size) {
                AnyView(ClaudeLoginRenewalSheet(
                    session: .preview(
                        rows: [
                            row("main", days: -8, token: false, status: .renewed(endsAt: now.addingTimeInterval(30 * 86_400))),
                            row("RankM8", days: 4.4, status: .waitingForBrowser),
                            row("PowerUser", days: 20),
                            row("ai2", days: 29.6, selected: false),
                        ],
                        currentName: "RankM8",
                        loginURL: loginURL
                    ),
                    openURL: { _ in },
                    now: now
                ))
            },
            Fixture(name: "konten-login-erneuern-falsches-konto", size: size) {
                AnyView(ClaudeLoginRenewalSheet(
                    session: .preview(
                        rows: [
                            row("main", days: -8, token: false, status: .renewed(endsAt: now.addingTimeInterval(30 * 86_400))),
                            row("RankM8", days: 4.4, status: .wrongAccount(signedInAs: "main@example.com")),
                            row("PowerUser", days: 20, status: .failed("Login failed: organization not allowed")),
                            row("ai2", days: 29.6, selected: false, status: .skipped),
                        ],
                        currentName: nil,
                        loginURL: nil
                    ),
                    openURL: { _ in },
                    now: now
                ))
            },
        ]
    }
}
