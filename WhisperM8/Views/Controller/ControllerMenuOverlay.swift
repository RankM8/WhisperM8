import SwiftUI

extension ControllerMenuItem {
    func title(chat: ControllerChatActionInfo?, archiveModeActive: Bool = false) -> String {
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
        case .redraw: return String(localized: "Redraw")
        case .refreshTitle: return String(localized: "Re-read title")
        case .openProject:
            let target = chat?.projectOpenTargetName ?? "PhpStorm"
            return String(localized: "Open in \(target)")
        case .revealInFinder: return String(localized: "Show in Finder")
        // Kachel und Workspace klar getrennt benennen, sonst verwechselt man
        // „Notiz zeigen“ und „Notizen aus“ leicht.
        case .toggleTileNote:
            return chat?.tileNoteOpen == true
                ? String(localized: "Hide this tile's note") : String(localized: "Show this tile's note")
        case .toggleNotes:
            // Gilt app-weit (`JarvisNotesShortcut.toggleDefault`), nicht je Workspace.
            return chat?.notesDefaultOpen == true
                ? String(localized: "Turn notes off everywhere") : String(localized: "Turn notes on everywhere")
        case .removeFromWorkspace:
            // Die Gruppe nennt den Workspace schon in ihrer Überschrift.
            return String(localized: "Remove from this workspace")
        case .addToWorkspace:
            return chat?.shownInWorkspace?.chatIsMember == true
                ? String(localized: "Add to another workspace") : String(localized: "Add to workspace")
        case .moveToNewWindow: return String(localized: "Move to new window")
        case .renameWorkspace: return String(localized: "Rename workspace…")
        case .gridCapacity:
            let current = chat?.shownInWorkspace?.capacities.first(where: \.isCurrent)?.label
            return current.map { String(localized: "Grid size · \($0)") } ?? String(localized: "Grid size")
        case .restart: return String(localized: "Restart")
        case .backgroundLogs: return String(localized: "Show logs")
        case .backgroundStop: return String(localized: "Stop")
        case .backgroundRestart: return String(localized: "Respawn")
        case .stopJob: return String(localized: "Stop job")
        case .archiveMode:
            return archiveModeActive ? String(localized: "Leave archive") : String(localized: "Show archive")
        case .clipboardHistory: return String(localized: "Clipboard history")
        case .showBindings: return String(localized: "Show button layout")
        case .pause: return String(localized: "Pause controller")
        }
    }

    /// Kurzer Hinweis rechts: was in den Chat geht, oder dass eine zweite Ebene folgt.
    var hint: String? {
        switch self {
        case .commands, .switchAccount, .addToWorkspace, .gridCapacity: return "›"
        case .cycleMode: return "⇧⇥"
        default: return nil
        }
    }
}

extension ControllerMenuItem.Group {
    /// Überschrift der Gruppe in der Menü-Karte.
    func heading(chat: ControllerChatActionInfo?) -> String {
        switch self {
        case .input: return String(localized: "Into the chat")
        case .chat: return String(localized: "Chat")
        case .project: return String(localized: "Project")
        case .workspace:
            guard let name = chat?.shownInWorkspace?.name else { return String(localized: "Workspace") }
            return String(localized: "Workspace “\(name)”")
        case .lifecycle: return String(localized: "Lifecycle")
        case .controller: return String(localized: "Controller")
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
    /// Überschrift über der Zeile: Beginn einer Gruppe in der Menü-Karte.
    var groupHeading: String? = nil
    /// Plakette hinter dem Titel („am meisten frei“).
    var badge: String? = nil
    /// Verbrauch rechts, in Ampelfarbe (Konto-Menü, Runde 5).
    var usage: String? = nil
    var usageLevel: UsageLevel? = nil

    enum UsageLevel: Equatable {
        case low, medium, high
    }
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
            let chat = menu.setup.chat
            let accounts = chat?.accounts ?? []
            var rows = accounts.enumerated().map { index, account in
                ControllerMenuRow(
                    id: account.id, title: account.label,
                    hint: accountHint(account),
                    enabled: list.isEnabled(account.id),
                    startsGroup: index > 0 && account.kind != accounts[index - 1].kind,
                    badge: account.isMostFree ? String(localized: "most free") : nil,
                    usage: usageText(account), usageLevel: usageLevel(account))
            }
            if let target = chat?.pendingAccountSwitchTarget {
                rows.append(ControllerMenuRow(
                    id: ControllerMenuModel.cancelSwitchID,
                    title: String(localized: "Cancel account switch to \(target)"), startsGroup: true))
            }
            if chat?.canUndoAccountSwitch == true {
                rows.append(ControllerMenuRow(
                    id: ControllerMenuModel.undoSwitchID, title: String(localized: "Undo last account switch (all chats it moved)"),
                    startsGroup: chat?.pendingAccountSwitchTarget == nil))
            }
            return rows
        case .workspaces(let list):
            let workspaces = menu.setup.chat?.addableWorkspaces ?? []
            return workspaces.map { choice in
                ControllerMenuRow(
                    id: choice.id.uuidString, title: choice.name, hint: nil,
                    enabled: list.isEnabled(choice.id.uuidString))
            }
        case .capacities(let list):
            let choices = menu.setup.chat?.shownInWorkspace?.capacities ?? []
            return choices.map { choice in
                ControllerMenuRow(
                    id: choice.id, title: choice.label,
                    hint: choice.isCurrent ? String(localized: "current")
                        : (choice.needsSelection ? String(localized: "choose with the mouse") : nil),
                    enabled: list.isEnabled(choice.id))
            }
        case nil:
            return menu.top.entries.map { entry in
                ControllerMenuRow(
                    id: entry.id.rawValue, title: entry.id.title(chat: menu.setup.chat, archiveModeActive: menu.setup.archiveModeActive), hint: entry.id.hint,
                    enabled: entry.enabled, startsGroup: menu.startsGroup(entry.id),
                    groupHeading: menu.groupStart(entry.id)?.heading(chat: menu.setup.chat))
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

    /// Verbraucht: „42 % · 61 %“ (5 Std. · Woche), wie das Limits-Popover.
    private static func usageText(_ account: ControllerAccountChoice) -> String? {
        guard account.fiveHourUsed != nil || account.weekUsed != nil else { return nil }
        func percent(_ value: Double?) -> String { value.map { "\(Int($0.rounded())) %" } ?? "—" }
        return "\(percent(account.fiveHourUsed)) · \(percent(account.weekUsed))"
    }

    /// Ampel wie `UsageGaugeLine`: unter 50 grün, ab 50 gelb, ab 80 rot (am
    /// knapperen Fenster).
    private static func usageLevel(_ account: ControllerAccountChoice) -> ControllerMenuRow.UsageLevel? {
        guard let used = [account.fiveHourUsed, account.weekUsed].compactMap({ $0 }).max() else { return nil }
        if used >= 80 { return .high }
        if used >= 50 { return .medium }
        return .low
    }

    /// Markierte Zeile, je nach Ebene.
    static func selectedID(of menu: ControllerMenuModel) -> String? {
        switch menu.submenu {
        case .commands(let list), .accounts(let list), .workspaces(let list), .capacities(let list):
            return list.selected
        case nil: return menu.selected?.rawValue
        }
    }

    /// Überschrift: der Chat, in der zweiten Ebene deren Name.
    static func heading(of menu: ControllerMenuModel, fallback: String?) -> String {
        switch menu.submenu {
        case .commands: return String(localized: "Commands")
        case .accounts: return String(localized: "Account · 5 h · week")
        case .workspaces: return String(localized: "Add to workspace")
        case .capacities: return String(localized: "Grid size")
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
        case "/tasks": return String(localized: "Background tasks")
        case "/workflows": return String(localized: "Workflows")
        case "/rewind": return String(localized: "Rewind")
        case "/help": return String(localized: "Help")
        case "/approvals": return String(localized: "Approvals")
        case "/new": return String(localized: "New conversation")
        default: return nil
        }
    }
}

/// Menü des Controllers im Zwischenablage-Verlauf: kurze Liste mit
/// Markierung, bedient mit Stick oder Steuerkreuz. Das Options-Menü im Chat
/// zeichnet `ControllerMenuCard`.
struct ControllerMenuPanel: View {
    let heading: String
    let rows: [ControllerMenuRow]
    let selectedID: String?

    init(heading: String, rows: [ControllerMenuRow], selectedID: String?) {
        self.heading = heading
        self.rows = rows
        self.selectedID = selectedID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ControllerPanelHeading(text: heading)
            ForEach(rows) { row in
                if row.startsGroup {
                    Rectangle().fill(AppTheme.border).frame(height: 1).padding(.horizontal, 8).padding(.vertical, 4)
                }
                self.row(row, marked: row.id == selectedID)
            }
        }
        .controllerPanelChrome()
    }

    private static func color(_ level: ControllerMenuRow.UsageLevel) -> Color {
        switch level {
        case .low: return AppTheme.statusWorking
        case .medium: return AppTheme.statusAwaiting
        case .high: return AppTheme.statusError
        }
    }

    private func row(_ row: ControllerMenuRow, marked: Bool) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: row.title)
                .font(.system(size: 13))
                .foregroundStyle(row.enabled ? AppTheme.textPrimary : AppTheme.textTertiary)
                .lineLimit(1)
            if let badge = row.badge {
                Text(verbatim: badge)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppTheme.statusWorking)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(AppTheme.statusWorking.opacity(0.14), in: RoundedRectangle(cornerRadius: 5))
                    .fixedSize()
            }
            Spacer(minLength: 0)
            if let usage = row.usage {
                Text(verbatim: usage)
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(row.usageLevel.map(Self.color) ?? AppTheme.textTertiary)
                    .fixedSize()
            }
            if let hint = row.hint {
                Text(verbatim: hint)
                    .font(.system(size: 11))
                    .foregroundStyle(AppTheme.textTertiary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .controllerRowMarking(marked)
    }
}

/// Überschrift eines Controller-Panels (Menü).
struct ControllerPanelHeading: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 11, weight: .semibold))
            .textCase(.uppercase)
            .tracking(0.6)
            .foregroundStyle(AppTheme.textTertiary)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 4)
    }
}

extension View {
    /// Rahmen der Controller-Panels: Fläche, Kante, Schatten.
    func controllerPanelChrome(width: CGFloat = 300) -> some View {
        padding(6)
            .frame(width: width)
            .background(AppTheme.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(AppTheme.borderStrong, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.25), radius: 16, y: 8)
    }

    /// Markierung einer Zeile im Controller-Panel.
    func controllerRowMarking(_ marked: Bool) -> some View {
        background {
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
