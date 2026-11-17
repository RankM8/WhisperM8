import AppKit
import Foundation

// MARK: - Linear-Links öffnen (WM8-132)

/// Führt aus, was `LinearLinkRoute` entscheidet: Ticket ins Board (derselbe Weg
/// wie `whisperm8 tickets open`), sonst Linear-App über `linear://`, sonst
/// Browser. Läuft nur auf einen Klick des Nutzers; die App nach vorn zu holen
/// ist dann gewollt, aber nur gleich danach:
///
/// - Das Board muss binnen `boardDeadline` stehen. Braucht Linear länger, geht
///   der Klick in die Linear-App, und eine späte Antwort zeigt nichts mehr.
/// - Ist WhisperM8 beim Zeigen nicht mehr vorn (der Nutzer ist woanders),
///   kommt weder Board noch Linear-App nach vorn.
/// - Ein zweiter Klick, während ein Öffnen läuft, wird verworfen.
///
/// Alles von außen als Closures, damit Tests ohne AppKit und Linear laufen.
@MainActor
struct LinearLinkOpener {
    /// So lange darf das Board nach dem Klick brauchen.
    static let boardDeadline: Duration = .seconds(2)

    var target: () -> LinearLinkTarget
    /// Hat macOS eine App für `linear://`? Nur beim Klick gefragt (Launch Services).
    var appInstalled: () -> Bool
    var openURL: (URL) -> Void
    /// Ticket im Board zeigen; `false`, wenn es nicht geht (Ansicht aus, Team
    /// nicht eingerichtet, Ticket nicht ladbar, anderer Workspace) oder
    /// `shouldPresent` direkt vor dem Zeigen nein sagt.
    var openBoard: (_ key: String, _ workspace: String,
                    _ shouldPresent: @escaping @MainActor @Sendable () -> Bool) async -> Bool
    /// Ist WhisperM8 die vordere App?
    var isAppActive: () -> Bool
    /// Wartet die Frist ab (Tests: sofort oder nie).
    var waitForDeadline: () async -> Void
    /// Läuft gerade ein Öffnen? Geteilt über alle Klicks.
    var attempts: LinearLinkAttempts

    /// Einen erkannten Linear-Link öffnen. Gibt die Board-Arbeit zurück (Tests
    /// warten darauf); der Aufrufer im Terminal ignoriert sie.
    @discardableResult
    func open(_ link: LinearLink, gesture: LinearLinkRoute.Gesture) -> Task<Void, Never>? {
        switch LinearLinkRoute.decide(link, gesture: gesture, target: target(), appInstalled: appInstalled()) {
        case .open(let url):
            openURL(url)
            return nil
        case .board(let key, let workspace, let fallback):
            guard let attempt = attempts.begin() else {
                Logger.terminalSnapshot.info("linear_link_click_dropped key=\(key, privacy: .public) reason=busy")
                return nil
            }
            let isAppActive = isAppActive
            let openURL = openURL
            // Linear-App nur, solange der Nutzer noch in WhisperM8 ist.
            let fallBack: @MainActor () -> Void = { if isAppActive() { openURL(fallback) } }
            let waitForDeadline = waitForDeadline
            Task { @MainActor in
                await waitForDeadline()
                if attempt.expire() { fallBack() }
            }
            let openBoard = openBoard
            return Task { @MainActor in
                let shown = await openBoard(key, workspace) { attempt.startPresenting(appActive: isAppActive()) }
                if !shown, attempt.finish() { fallBack() }
                attempt.finish()
            }
        }
    }

    /// Knopf „In Linear öffnen“: Linear-Adressen nach Einstellung in App oder
    /// Browser, jede andere Adresse wie bisher an macOS.
    func openInLinear(_ url: URL) {
        guard let link = LinearLink(url: url) else { return openURL(url) }
        open(link, gesture: .openInLinear)
    }

    static var live: LinearLinkOpener {
        LinearLinkOpener(
            target: { AppPreferences().linearLinkTarget },
            appInstalled: {
                guard let probe = URL(string: "linear://") else { return false }
                return NSWorkspace.shared.urlForApplication(toOpen: probe) != nil
            },
            openURL: { NSWorkspace.shared.open($0) },
            openBoard: { key, workspace, shouldPresent in
                switch await TicketOpenService.live.open(input: key, workspace: workspace, shouldPresent: shouldPresent) {
                case .opened:
                    return true
                case .failed(_, let message):
                    Logger.terminalSnapshot.info("linear_link_board_fallback key=\(key, privacy: .public) reason=\(message, privacy: .public)")
                    return false
                }
            },
            isAppActive: { NSApp.isActive },
            waitForDeadline: { try? await Task.sleep(for: boardDeadline) },
            attempts: .shared
        )
    }
}

// MARK: - Ein Öffnen zur Zeit

/// Hält das laufende Öffnen eines Linear-Links fest. Ein Versuch endet genau
/// einmal: Board gezeigt, Rückfall in die Linear-App, oder verworfen.
@MainActor
final class LinearLinkAttempts {
    static let shared = LinearLinkAttempts()

    final class Attempt {
        enum State { case waiting, presenting, done }
        private(set) var state: State = .waiting

        /// Direkt vor dem Zeigen: nur, solange die Frist läuft und die App vorn
        /// ist. Sonst ist der Versuch vorbei, ohne etwas zu öffnen.
        func startPresenting(appActive: Bool) -> Bool {
            guard state == .waiting else { return false }
            state = appActive ? .presenting : .done
            return appActive
        }

        /// Frist abgelaufen: Wartet der Versuch noch auf Linear, ist er vorbei
        /// (`true`, Rückfall). Wird das Board schon gezeigt, bleibt es dabei.
        func expire() -> Bool {
            guard state == .waiting else { return false }
            state = .done
            return true
        }

        /// Beendet den Versuch; `true` nur beim ersten Mal (dann darf der
        /// Aufrufer zurückfallen).
        @discardableResult
        func finish() -> Bool {
            guard state != .done else { return false }
            state = .done
            return true
        }
    }

    private var current: Attempt?

    var isBusy: Bool { current.map { $0.state != .done } ?? false }

    /// Neuer Versuch, oder `nil`, solange einer läuft.
    func begin() -> Attempt? {
        guard !isBusy else { return nil }
        let attempt = Attempt()
        current = attempt
        return attempt
    }
}
