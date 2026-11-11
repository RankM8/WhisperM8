import Foundation
import Observation

/// Ablauf der Sammel-Erneuerung: geht die gewählten Konten nacheinander durch
/// und hält je Konto fest, was passiert ist. Der Dialog zeigt nur diesen Stand.
///
/// Immer ein Konto zur Zeit — der Browser hat eine einzige claude.ai-Sitzung,
/// zwei gleichzeitige Logins kämen sich dort in die Quere.
@MainActor
@Observable
final class ClaudeLoginRenewalSession {
    enum Status: Equatable {
        case pending
        /// Browser ist offen, die CLI wartet auf die Bestätigung.
        case waitingForBrowser
        case renewed(endsAt: Date?)
        case wrongAccount(signedInAs: String?)
        case skipped
        case timedOut
        case failed(String)

        var isDone: Bool {
            if case .renewed = self { return true }
            return false
        }
    }

    struct Row: Identifiable, Equatable {
        let name: String
        let email: String
        var expiry: ClaudeLoginExpiry?
        var isSelected: Bool
        var status: Status = .pending

        var id: String { name }
    }

    typealias Renew = (
        _ profile: String,
        _ control: ClaudeLoginProcessControl,
        _ onLoginURL: @escaping @Sendable (URL) -> Void
    ) async -> ClaudeLoginRenewer.Outcome

    private(set) var rows: [Row]
    private(set) var isRunning = false
    private(set) var currentName: String?
    /// Ausweich-Adresse des laufenden Logins („Seite erneut öffnen“).
    private(set) var loginURL: URL?
    /// Die Claude-CLI fehlt — dann hilft kein weiterer Versuch.
    private(set) var claudeMissing = false

    @ObservationIgnored var renew: Renew
    /// Nach jedem übernommenen Login, z. B. um Anzeigen nachzuladen.
    @ObservationIgnored var onRenewed: (String) -> Void = { _ in }

    @ObservationIgnored private var control: ClaudeLoginProcessControl?
    @ObservationIgnored private var stopRequested = false

    /// Der Lauf, der gerade einen Login offen hat. Es gibt höchstens einen:
    /// der Browser hat eine einzige claude.ai-Sitzung, und ohne sichtbaren
    /// Dialog soll nie ein Login weiterlaufen.
    private static weak var active: ClaudeLoginRenewalSession?

    /// Beendet einen laufenden Login — beim Beenden der App, damit die CLI
    /// nicht ohne uns weiter auf den Browser wartet.
    static func stopActive() {
        active?.stop()
    }

    init(rows: [Row], renew: @escaping Renew = ClaudeLoginRenewalSession.liveRenew) {
        self.rows = rows
        self.renew = renew
    }

    /// Fester Zwischenstand für Vorschau-Bilder — startet keinen Login.
    static func preview(rows: [Row], currentName: String?, loginURL: URL?) -> ClaudeLoginRenewalSession {
        let session = ClaudeLoginRenewalSession(rows: rows) { _, _, _ in .cancelled }
        session.currentName = currentName
        session.loginURL = loginURL
        session.isRunning = currentName != nil
        return session
    }

    nonisolated static func liveRenew(
        profile: String,
        control: ClaudeLoginProcessControl,
        onLoginURL: @escaping @Sendable (URL) -> Void
    ) async -> ClaudeLoginRenewer.Outcome {
        await ClaudeLoginRenewer().renew(profileNamed: profile, control: control, onLoginURL: onLoginURL)
    }

    /// Zeilen für den Dialog: alle Konten mit bekannter Adresse. Vorgewählt
    /// sind `preselected`, sonst alle außer den gerade erst erneuerten —
    /// so landen die Konten auf demselben Stichtag.
    static func makeRows(
        profiles: [ClaudeAccountProfile],
        expiries: [String: ClaudeLoginExpiry],
        preselected: Set<String>? = nil,
        now: Date
    ) -> [Row] {
        profiles.compactMap { profile in
            guard let email = profile.emailAddress else { return nil }
            let expiry = expiries[profile.name]
            let selected: Bool
            if let preselected {
                selected = preselected.contains(profile.name)
            } else if let expiry, case .active(let daysLeft?) = expiry.status(now: now) {
                selected = daysLeft < Self.freshLoginDays
            } else {
                selected = true
            }
            return Row(name: profile.name, email: email, expiry: expiry, isSelected: selected)
        }
    }

    /// Ab so vielen Resttagen gilt ein Login als frisch erneuert.
    static let freshLoginDays = 29

    var selectedCount: Int { rows.filter { $0.isSelected && !$0.status.isDone }.count }
    var renewedCount: Int { rows.filter(\.status.isDone).count }

    func setSelected(_ selected: Bool, for name: String) {
        guard !isRunning, let index = rows.firstIndex(where: { $0.name == name }) else { return }
        rows[index].isSelected = selected
    }

    /// Startet (oder setzt fort): alle gewählten, noch nicht erneuerten Konten
    /// der Reihe nach. Ein falsches Konto im Browser hält den Lauf an — erst
    /// dort abmelden, dann weiter.
    func start() {
        guard !isRunning, !claudeMissing else { return }
        let queue = rows.filter { $0.isSelected && !$0.status.isDone }.map(\.name)
        guard !queue.isEmpty else { return }
        if let other = Self.active, other !== self { other.stop() }
        Self.active = self
        isRunning = true
        stopRequested = false
        for name in queue { setStatus(.pending, for: name) }
        Task { await run(queue) }
    }

    /// Überspringt das laufende Konto, der Lauf geht mit dem nächsten weiter.
    func skipCurrent() {
        control?.cancel()
    }

    /// Bricht den ganzen Lauf ab.
    func stop() {
        stopRequested = true
        control?.cancel()
    }

    /// Code, den claude.ai anzeigt, wenn die Rückleitung in die CLI nicht klappt.
    func submit(code: String) {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        control?.submit(code: trimmed)
    }

    private func run(_ queue: [String]) async {
        defer {
            isRunning = false
            currentName = nil
            loginURL = nil
            control = nil
            if Self.active === self { Self.active = nil }
        }
        for name in queue {
            guard !stopRequested else { break }
            let control = ClaudeLoginProcessControl()
            self.control = control
            currentName = name
            loginURL = nil
            setStatus(.waitingForBrowser, for: name)

            let outcome = await renew(name, control) { [weak self] url in
                Task { @MainActor in
                    guard let self, self.currentName == name else { return }
                    self.loginURL = url
                }
            }

            switch outcome {
            case .renewed(let endsAt):
                setStatus(.renewed(endsAt: endsAt), for: name)
                onRenewed(name)
            case .wrongAccount(let signedInAs):
                setStatus(.wrongAccount(signedInAs: signedInAs), for: name)
                // Das nächste Konto träfe dieselbe Browser-Sitzung.
                return
            case .cancelled:
                setStatus(.skipped, for: name)
            case .timedOut:
                setStatus(.timedOut, for: name)
            case .claudeMissing:
                claudeMissing = true
                setStatus(.failed(String(localized: "Claude CLI not found — install Claude Code first.")), for: name)
                return
            case .notRenewable:
                setStatus(.failed(String(localized: "No account data — log in once via the ⋯ menu.")), for: name)
            case .failed(let message):
                setStatus(.failed(message), for: name)
            }
        }
    }

    private func setStatus(_ status: Status, for name: String) {
        guard let index = rows.firstIndex(where: { $0.name == name }) else { return }
        rows[index].status = status
    }
}
