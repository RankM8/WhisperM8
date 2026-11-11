import SwiftUI

extension ControllerMenuItem {
    func title(chat: ControllerChatActionInfo?) -> String {
        switch self {
        case .continueWork: return String(localized: "Send “Continue”")
        case .commands: return String(localized: "Commands")
        case .cycleMode: return String(localized: "Switch mode")
        case .switchAccount: return String(localized: "Switch account")
        case .rename: return String(localized: "Rename…")
        case .fork: return String(localized: "Fork")
        case .pin: return chat?.isPinned == true ? String(localized: "Unpin") : String(localized: "Pin")
        case .archive: return chat?.isTerminal == true ? String(localized: "Close terminal") : String(localized: "Archive")
        case .closeChat: return String(localized: "Close chat")
        case .showBindings: return String(localized: "Show button layout")
        case .pause: return String(localized: "Pause controller")
        }
    }

    /// Kurzer Hinweis rechts: was in den Chat geht, oder dass eine zweite Ebene folgt.
    var hint: String? {
        switch self {
        case .commands, .switchAccount: return "›"
        case .cycleMode: return "⇧⇥"
        default: return nil
        }
    }
}

/// Eine Zeile eines Controller-Menüs, so wie das Panel sie zeichnet.
struct ControllerMenuRow: Identifiable, Equatable {
    var id: String
    var title: String
    var hint: String?
    var enabled = true
    var startsGroup = false
}

extension ControllerMenuRow {
    /// Zeilen des Options-Menüs, je nach Ebene.
    static func rows(of menu: ControllerMenuModel) -> [ControllerMenuRow] {
        switch menu.submenu {
        case .commands(let list):
            return list.entries.map { entry in
                let command = ControllerSlashCommand(text: entry.id)
                return ControllerMenuRow(
                    id: entry.id,
                    title: command.isSlashOnly ? String(localized: "Type /") : entry.id,
                    hint: command.summary, enabled: entry.enabled)
            }
        case .accounts(let list):
            let accounts = menu.setup.chat?.accounts ?? []
            return accounts.enumerated().map { index, account in
                ControllerMenuRow(
                    id: account.id, title: account.label,
                    hint: accountHint(account),
                    enabled: list.isEnabled(account.id),
                    startsGroup: index > 0 && account.kind != accounts[index - 1].kind)
            }
        case nil:
            return menu.top.entries.map { entry in
                ControllerMenuRow(
                    id: entry.id.rawValue, title: entry.id.title(chat: menu.setup.chat), hint: entry.id.hint,
                    enabled: entry.enabled, startsGroup: entry.id.startsGroup)
            }
        }
    }

    /// Rechts neben einem Konto: „aktuell“, sonst bei GPT-Konten die Art.
    private static func accountHint(_ account: ControllerAccountChoice) -> String? {
        if account.isCurrent { return String(localized: "current") }
        switch account.kind {
        case .gpt: return "GPT"
        case .claude: return nil
        }
    }

    /// Markierte Zeile, je nach Ebene.
    static func selectedID(of menu: ControllerMenuModel) -> String? {
        switch menu.submenu {
        case .commands(let list), .accounts(let list): return list.selected
        case nil: return menu.selected?.rawValue
        }
    }

    /// Überschrift: der Chat, in der zweiten Ebene deren Name.
    static func heading(of menu: ControllerMenuModel, fallback: String?) -> String {
        switch menu.submenu {
        case .commands: return String(localized: "Commands")
        case .accounts: return String(localized: "Switch account")
        case nil: return menu.setup.chat?.title ?? fallback ?? String(localized: "Menu")
        }
    }
}

extension ControllerSlashCommand {
    /// Kurze Beschreibung rechts neben dem Befehl.
    var summary: String? {
        switch text {
        case "/": return String(localized: "opens the list of the CLI")
        case "/model": return String(localized: "Switch model")
        case "/config": return String(localized: "Settings")
        case "/clear": return String(localized: "Clear conversation")
        case "/compact": return String(localized: "Summarize conversation")
        case "/context": return String(localized: "Context usage")
        case "/usage": return String(localized: "Plan usage")
        case "/resume": return String(localized: "Resume a conversation")
        case "/status": return String(localized: "Status")
        case "/permissions": return String(localized: "Permissions")
        case "/mcp": return String(localized: "MCP servers")
        case "/agents": return String(localized: "Agents")
        case "/memory": return String(localized: "Memory")
        case "/help": return String(localized: "Help")
        case "/approvals": return String(localized: "Approvals")
        case "/new": return String(localized: "New conversation")
        default: return nil
        }
    }
}

/// Menü des Controllers: kurze Liste mit Markierung, bedient mit Stick oder
/// Steuerkreuz. Dasselbe Panel zeigt das Options-Menü im Chat (mit zweiter
/// Ebene) und das Menü im Zwischenablage-Verlauf.
struct ControllerMenuPanel: View {
    let heading: String
    let rows: [ControllerMenuRow]
    let selectedID: String?

    init(heading: String, rows: [ControllerMenuRow], selectedID: String?) {
        self.heading = heading
        self.rows = rows
        self.selectedID = selectedID
    }

    /// Options-Menü (beide Ebenen).
    init(menu: ControllerMenuModel, fallbackHeading: String? = nil) {
        self.init(
            heading: ControllerMenuRow.heading(of: menu, fallback: fallbackHeading),
            rows: ControllerMenuRow.rows(of: menu),
            selectedID: ControllerMenuRow.selectedID(of: menu))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: heading)
                .font(.system(size: 11, weight: .semibold))
                .textCase(.uppercase)
                .tracking(0.6)
                .foregroundStyle(AppTheme.textTertiary)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 4)
            ForEach(rows) { row in
                if row.startsGroup {
                    Rectangle().fill(AppTheme.border).frame(height: 1).padding(.horizontal, 8).padding(.vertical, 4)
                }
                self.row(row, marked: row.id == selectedID)
            }
        }
        .padding(6)
        .frame(width: 300)
        .background(AppTheme.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(AppTheme.borderStrong, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.25), radius: 16, y: 8)
    }

    private func row(_ row: ControllerMenuRow, marked: Bool) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: row.title)
                .font(.system(size: 13))
                .foregroundStyle(row.enabled ? AppTheme.textPrimary : AppTheme.textTertiary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if let hint = row.hint {
                Text(verbatim: hint)
                    .font(.system(size: 11))
                    .foregroundStyle(AppTheme.textTertiary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background {
            if marked {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(AppTheme.accentTint)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(AppTheme.accent, lineWidth: 2)
                    )
            }
        }
    }
}

/// Zeigt das Options-Menü im aktiven Agent-Chats-Fenster. Eigene kleine
/// View, damit nur sie das `ControllerUIModel` beobachtet.
struct ControllerMenuHost: View {
    let windowID: UUID
    @State private var model = ControllerUIModel.shared
    @State private var windows = AgentWindowStore.shared

    var body: some View {
        if let menu = model.menu, windows.keyAgentChatWindowID == windowID {
            ControllerMenuPanel(menu: menu, fallbackHeading: model.targetTitle)
                .padding(.bottom, ControllerLegendBar.height + 12)
                .transition(.opacity)
        }
    }
}
