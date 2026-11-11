import Foundation

/// Ein eingebauter Befehl der CLI für die zweite Ebene „Befehle“ im
/// Options-Menü. `text` geht so ins Eingabefeld und wird gesendet; nur „/“
/// selbst bleibt ungesendet stehen, damit sich die Liste der CLI öffnet.
struct ControllerSlashCommand: Equatable, Sendable {
    var text: String

    /// „/“ eintippen statt eines festen Befehls.
    var isSlashOnly: Bool { text == "/" }
    /// Wird nach dem Eintragen gesendet.
    var submits: Bool { !isSlashOnly }
}

/// Feste Tabelle der eingebauten Befehle je CLI (Runde 2 nach dem Handtest).
/// Bewusst keine Skills und keine eigenen Befehle — die erreicht man über „/“.
/// Pur; die Beschreibungen (englisch, deutsch im Katalog) stehen in der UI.
enum ControllerSlashCommands {
    static let claude: [String] = [
        "/", "/model", "/config", "/clear", "/compact", "/context", "/usage", "/resume",
        "/status", "/permissions", "/mcp", "/agents", "/memory", "/help",
    ]

    /// Codex: Im Repo und in der Doku ist keine Befehlsliste belegt; hier
    /// stehen nur die verbreiteten festen Befehle.
    static let codex: [String] = ["/", "/model", "/approvals", "/new", "/compact"]

    /// Befehle für ein Profil. Shell und andere: keine (Eintrag „Befehle“ ist aus).
    static func list(for profile: ControllerChatState.Profile?) -> [ControllerSlashCommand] {
        let texts: [String]
        switch profile {
        case .claude: texts = claude
        case .codex: texts = codex
        case .shell, .other, nil: texts = []
        }
        return texts.map(ControllerSlashCommand.init(text:))
    }
}
