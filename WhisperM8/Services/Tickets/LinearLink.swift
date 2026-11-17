import Foundation

// MARK: - Linear-Links (WM8-132, pur)

/// Eine Adresse aus Linear (`https://linear.app/<workspace>/…`), zerlegt für die
/// Frage, wohin ein Klick sie öffnet: ins Ticket-Board der App, in die
/// Linear-App oder in den Browser.
///
/// Die Linear-App meldet sich bei macOS für `linear://`. Laut Linear-Doku
/// („Download Linear“, FAQ) öffnet `linear://` plus der Rest der Adresse die
/// Seite in der App; der Pfad wird deshalb 1:1 übernommen, samt Query und
/// Fragment: `https://linear.app/whisperm8/issue/WM8-12/titel` →
/// `linear://whisperm8/issue/WM8-12/titel`.
struct LinearLink: Equatable, Sendable {
    /// Workspace aus der Adresse, klein geschrieben (Linears `urlKey`).
    var workspace: String
    /// Ticket-Nummer, groß geschrieben; `nil` für Projekte, Ansichten, Dokumente.
    var issueKey: String?
    /// Die Adresse, wie sie kam (Browser-Weg).
    var webURL: URL
    /// Dieselbe Seite für die Linear-App.
    var desktopURL: URL

    /// Erste Pfadteile von `linear.app`, die keine Workspaces sind (Website,
    /// Doku, Anmeldung). Sie gehören in den Browser, nie in App oder Board.
    static let reservedPaths: Set<String> = [
        "about", "blog", "brand", "careers", "changelog", "contact", "customers", "developers",
        "docs", "download", "enterprise", "features", "homepage", "integrations", "join", "legal",
        "login", "logout", "method", "now", "oauth", "partners", "pricing", "privacy", "readme",
        "security", "signup", "startups", "terms",
    ]

    /// `nil`, wenn die Adresse keine Seite eines Linear-Workspaces ist.
    init?(url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host?.lowercased(), host == "linear.app" || host == "www.linear.app",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        // Nur der Workspace allein (`/whisperm8`) ist keine Seite darin; ohne
        // zweiten Teil bleibt es beim Browser.
        guard parts.count >= 2, !Self.reservedPaths.contains(parts[0].lowercased()) else { return nil }
        workspace = parts[0].lowercased()
        if parts[1].lowercased() == "issue", parts.count >= 3, Self.isKey(parts[2]) {
            issueKey = parts[2].uppercased()
        } else {
            issueKey = nil
        }
        webURL = url
        // Kodierte Teile 1:1 (Umlaute im Slug bleiben, wie sie kamen).
        var desktop = "linear://" + components.percentEncodedPath.drop(while: { $0 == "/" })
        if let query = components.percentEncodedQuery { desktop += "?" + query }
        if let fragment = components.percentEncodedFragment { desktop += "#" + fragment }
        guard let desktopURL = URL(string: desktop) else { return nil }
        self.desktopURL = desktopURL
    }

    init?(string: String) {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        self.init(url: url)
    }

    private static func isKey(_ text: String) -> Bool {
        text.range(of: #"^[A-Za-z][A-Za-z0-9]*-[0-9]+$"#, options: .regularExpression) != nil
    }
}

// MARK: - Einstellung

/// Einstellungen › Tickets › „Open Linear links in“. Ab Werk das Board
/// (Entscheidung 17.11.2026, WM8-132).
enum LinearLinkTarget: String, CaseIterable, Identifiable, Sendable {
    /// Tickets ins Ticket-Board (Team eingerichtet), sonst Linear-App.
    case board
    /// Alles in die Linear-App.
    case app
    /// Alles in den Browser, wie vor WM8-132.
    case browser

    static let defaultValue: LinearLinkTarget = .board

    var id: String { rawValue }

    init(stored: String?) {
        self = stored.flatMap(LinearLinkTarget.init(rawValue:)) ?? .defaultValue
    }
}

// MARK: - Entscheidung

/// Wohin ein Linear-Link geht. Pur: Einstellung, Geste und „Linear-App da?“
/// kommen von außen.
enum LinearLinkRoute {
    /// Wie der Link ausgelöst wurde.
    enum Gesture: Equatable, Sendable {
        /// ⌘-Klick im Chat: folgt der Einstellung.
        case chatClick
        /// ⌘⌥-Klick im Chat: immer in die Linear-App (⌥ heißt im Terminal
        /// „anderes Ziel“, bei Dateien „im Finder zeigen“).
        case chatAlternateClick
        /// Knopf „In Linear öffnen“ (Board, Ansichten, Controller).
        case openInLinear
    }

    enum Action: Equatable, Sendable {
        /// Ticket im Board zeigen; klappt das nicht, `fallback` öffnen.
        case board(key: String, workspace: String, fallback: URL)
        /// Linear-App oder Browser: diese Adresse an macOS geben.
        case open(URL)
    }

    static func decide(_ link: LinearLink, gesture: Gesture, target: LinearLinkTarget,
                       appInstalled: Bool) -> Action {
        let app = appInstalled ? link.desktopURL : link.webURL
        switch gesture {
        case .chatAlternateClick:
            return .open(app)
        case .openInLinear:
            return .open(target == .browser ? link.webURL : app)
        case .chatClick:
            switch target {
            case .browser: return .open(link.webURL)
            case .app: return .open(app)
            case .board:
                guard let key = link.issueKey else { return .open(app) }
                return .board(key: key, workspace: link.workspace, fallback: app)
            }
        }
    }
}
