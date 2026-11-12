import Foundation

/// Einträge des Menüs hinter Options (Runde 2: das eine Menü des Controllers).
/// Drei Gruppen: Eingaben in den Chat, Aktionen am Chat (dieselben Wege wie
/// sein Kontextmenü) und die Steuerung selbst. Die Felder sind fest.
enum ControllerMenuItem: String, CaseIterable, Sendable {
    // Eingaben in den Chat
    /// „Weiter“ senden.
    case continueWork
    /// Zweite Ebene: eingebaute Befehle der CLI (`ControllerSlashCommands`).
    case commands
    /// Modus wechseln (Shift+Tab).
    case cycleMode
    // Aktionen am Chat
    /// Zweite Ebene: Ziel-Konten wie im Kontextmenü (Claude, bei GPT-Chats auch GPT).
    case switchAccount
    case rename, fork, pin, archive
    /// Wie „−“/„×“ des Chats in der Seitenleiste (im Filter „Aktiv“
    /// beenden, sonst archivieren).
    case closeChat
    // Steuerung
    /// Zwischenablage-Verlauf öffnen (wie Touchpad bzw. L2 + Touchpad).
    case clipboardHistory
    case showBindings, pause

    enum Group: Sendable {
        case input, chat, controller
    }

    var group: Group {
        switch self {
        case .continueWork, .commands, .cycleMode: return .input
        case .switchAccount, .rename, .fork, .pin, .archive, .closeChat: return .chat
        case .clipboardHistory, .showBindings, .pause: return .controller
        }
    }

    /// Einträge, die in den Chat schreiben. Bei offener Rückfrage aus, weil
    /// dort nie Text hineinlaufen darf — auch Shift+Tab nicht, das ist in
    /// Claudes Freigabe-Dialog „alle Änderungen erlauben“.
    var writesToChat: Bool { group == .input }

    /// Nur, wenn der Chat ruht (`ControllerMenuSetup.chatBusy`): „Weiter“
    /// schickt Enter mit, „Modus wechseln“ ist Shift+Tab.
    var needsRestingChat: Bool { self == .continueWork || self == .cycleMode }

    /// Öffnet eine zweite Ebene statt etwas auszuführen.
    var opensSubmenu: Bool { self == .commands || self == .switchAccount }

    /// Trennlinie vor dem ersten Eintrag einer Gruppe.
    var startsGroup: Bool { self == .switchAccount || self == .clipboardHistory }
}

/// Ein Ziel-Konto in der zweiten Ebene von „Konto wechseln“.
struct ControllerAccountChoice: Equatable, Sendable {
    enum Kind: String, Sendable {
        /// „Zu Account verschieben“ (Umzug mit Vorschau).
        case claude
        /// „GPT-Konto“ (gilt ab dem nächsten Start).
        case gpt
    }

    var kind: Kind
    var name: String
    /// Anzeige wie im Kontextmenü.
    var label: String
    var isCurrent: Bool
    var isLoggedIn: Bool

    var id: String { "\(kind.rawValue):\(name)" }
    /// Wählbar wie im Kontextmenü: angemeldet und nicht schon das des Chats.
    var isChoosable: Bool { isLoggedIn && !isCurrent }
}

/// Was das Menü über den Chat wissen muss, auf den es wirkt. Liefert die
/// Ansicht im Ereignis-Pfad (`AgentChatsCommandCenter.Handler.chatActionInfo`).
struct ControllerChatActionInfo: Equatable, Sendable {
    var title: String
    var isPinned = false
    var isArchived = false
    var isTerminal = false
    var canFork = false
    var accounts: [ControllerAccountChoice] = []
}

/// Lage beim Öffnen des Menüs.
struct ControllerMenuSetup: Equatable, Sendable {
    /// Im gemeinten Chat ist eine Rückfrage offen.
    var dialogOpen = false
    /// Eingaben in den Chat sind möglich: Der Chat lebt und ist der
    /// ausgewählte (in der Liste kann eine andere Zeile markiert sein).
    var acceptsInput = false
    /// Profil des Chats, für die Befehls-Liste.
    var profile: ControllerChatState.Profile?
    /// Chat, auf den die Aktionen wirken; `nil` = keiner.
    var sessionID: UUID?
    /// Zeile für „Chat schließen“ (im Inhalt `.chat(id)`, in der Liste die markierte).
    var target: SidebarNavigationRow?
    var chat: ControllerChatActionInfo?
    /// Der Chat ruht nicht: Er arbeitet, sein Zustand ist unklar oder es
    /// wurde gerade gesendet. Dann sind „Weiter“ und „Modus wechseln“ aus —
    /// zwischen dem Erscheinen eines Freigabe-Dialogs und dem Status „wartet“
    /// bestätigte „Weiter“ mit Enter die Vorauswahl, und Shift+Tab heißt dort
    /// „alle Änderungen erlauben“. Codex meldet nie „wartet“.
    var chatBusy = false
}

/// Das Options-Menü mit zweiter Ebene (Befehle, Konten). Pur.
struct ControllerMenuModel: Equatable, Sendable {
    enum Submenu: Equatable, Sendable {
        case commands(ControllerListMenu<String>)
        case accounts(ControllerListMenu<String>)
    }

    private(set) var setup: ControllerMenuSetup
    private(set) var top: ControllerListMenu<ControllerMenuItem>
    private(set) var submenu: Submenu?

    init(setup: ControllerMenuSetup = ControllerMenuSetup(), selected: ControllerMenuItem? = nil) {
        self.setup = setup
        self.top = ControllerListMenu(
            entries: ControllerMenuItem.allCases.map { .init(id: $0, enabled: Self.isEnabled($0, setup: setup)) },
            selected: selected
        )
    }

    var selected: ControllerMenuItem? { top.selected }

    /// Eintrag der ersten Ebene direkt wählen (sofern er an ist).
    mutating func select(_ item: ControllerMenuItem) {
        top.select(item)
    }

    static func isEnabled(_ item: ControllerMenuItem, setup: ControllerMenuSetup) -> Bool {
        if item.writesToChat {
            guard setup.acceptsInput, !setup.dialogOpen else { return false }
            if item == .commands {
                return !ControllerSlashCommands.list(for: setup.profile).isEmpty
            }
            return !(item.needsRestingChat && setup.chatBusy)
        }
        guard item.group == .chat else { return true }
        guard let chat = setup.chat, setup.sessionID != nil else { return false }
        switch item {
        case .switchAccount: return !chat.isArchived && chat.accounts.contains(where: \.isChoosable)
        case .rename, .pin: return true
        case .fork: return chat.canFork && !chat.isArchived
        case .archive, .closeChat: return !chat.isArchived
        default: return true
        }
    }

    /// Rückfrage im Chat geht auf oder zu bzw. der Chat beginnt oder hört auf
    /// zu arbeiten, während das Menü offen ist.
    mutating func update(dialogOpen: Bool, chatBusy: Bool) {
        guard setup.dialogOpen != dialogOpen || setup.chatBusy != chatBusy else { return }
        setup.dialogOpen = dialogOpen
        setup.chatBusy = chatBusy
        top = ControllerListMenu(
            entries: ControllerMenuItem.allCases.map { .init(id: $0, enabled: Self.isEnabled($0, setup: setup)) },
            selected: top.selected
        )
        // Die Befehle schreiben in den Chat: bei einer Rückfrage zurück zur ersten Ebene.
        if dialogOpen, case .commands = submenu { submenu = nil }
    }

    mutating func move(_ step: Int) {
        switch submenu {
        case var .commands(list):
            list.move(step)
            submenu = .commands(list)
        case var .accounts(list):
            list.move(step)
            submenu = .accounts(list)
        case nil:
            top.move(step)
        }
    }

    /// Öffnet die zweite Ebene des ausgewählten Eintrags. `false`, wenn es
    /// dort nichts gibt.
    mutating func openSubmenu() -> Bool {
        guard let item = top.selectedEnabled, item.opensSubmenu else { return false }
        switch item {
        case .commands:
            let commands = ControllerSlashCommands.list(for: setup.profile)
            guard !commands.isEmpty else { return false }
            submenu = .commands(ControllerListMenu(entries: commands.map { .init(id: $0.text, enabled: true) }))
        case .switchAccount:
            let accounts = setup.chat?.accounts ?? []
            guard accounts.contains(where: \.isChoosable) else { return false }
            submenu = .accounts(ControllerListMenu(entries: accounts.map { .init(id: $0.id, enabled: $0.isChoosable) }))
        default:
            return false
        }
        return true
    }

    /// Kreis: eine Ebene zurück. `false` auf der ersten Ebene (dann schließt
    /// der Aufrufer das Menü).
    mutating func back() -> Bool {
        guard submenu != nil else { return false }
        submenu = nil
        return true
    }
}
