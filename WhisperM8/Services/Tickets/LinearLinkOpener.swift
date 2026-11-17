import AppKit
import Foundation

// MARK: - Linear-Links öffnen (WM8-132)

/// Führt aus, was `LinearLinkRoute` entscheidet: Ticket ins Board (derselbe Weg
/// wie `whisperm8 tickets open`), sonst Linear-App über `linear://`, sonst
/// Browser. Läuft nur auf einen Klick des Nutzers; die App nach vorn zu holen
/// ist dann gewollt.
///
/// Alles von außen als Closures, damit Tests ohne AppKit und Linear laufen.
@MainActor
struct LinearLinkOpener {
    var target: () -> LinearLinkTarget
    /// Hat macOS eine App für `linear://`? Kein Disk-I/O in einem Body: nur
    /// beim Klick gefragt (Launch Services).
    var appInstalled: () -> Bool
    var openURL: (URL) -> Void
    /// Ticket im Board zeigen; `false`, wenn es nicht geht (Ansicht aus, Team
    /// nicht eingerichtet, Ticket nicht ladbar, anderer Workspace).
    var openBoard: (_ key: String, _ workspace: String) async -> Bool

    /// Einen erkannten Linear-Link öffnen. Gibt die Board-Arbeit zurück (Tests
    /// warten darauf); der Aufrufer im Terminal ignoriert sie.
    @discardableResult
    func open(_ link: LinearLink, gesture: LinearLinkRoute.Gesture) -> Task<Void, Never>? {
        switch LinearLinkRoute.decide(link, gesture: gesture, target: target(), appInstalled: appInstalled()) {
        case .open(let url):
            openURL(url)
            return nil
        case .board(let key, let workspace, let fallback):
            let openBoard = openBoard
            let openURL = openURL
            return Task { @MainActor in
                if !(await openBoard(key, workspace)) { openURL(fallback) }
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
            openBoard: { key, workspace in
                switch await TicketOpenService.live.open(input: key, workspace: workspace) {
                case .opened:
                    return true
                case .failed(_, let message):
                    Logger.terminalSnapshot.info("linear_link_board_fallback key=\(key, privacy: .public) reason=\(message, privacy: .public)")
                    return false
                }
            }
        )
    }
}
