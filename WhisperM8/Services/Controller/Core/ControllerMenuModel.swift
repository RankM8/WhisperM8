import Foundation

/// Einträge des Menüs hinter Options (Runde 2: das eine Menü des Controllers).
/// Gruppen (Runde 5): Eingaben in den Chat · Chat · Projekt · Workspace ·
/// Lebenszyklus · Steuerung. Die Aktionen am Chat nehmen dieselben Wege wie
/// sein Kontextmenü, sein Kopf und seine Kachel. Ein Eintrag erscheint nur,
/// wenn er für diesen Chat passt (`ControllerMenuModel.isVisible`);
/// ausgegraut ist nur, was passt, aber gerade nicht geht.
enum ControllerMenuItem: String, CaseIterable, Sendable {
    // Eingaben in den Chat
    /// „Weiter“ senden.
    case continueWork
    /// Zweite Ebene: eingebaute Befehle der CLI (`ControllerSlashCommands`).
    case commands
    /// Modus wechseln (Shift+Tab).
    case cycleMode
    /// Neu zeichnen (Ctrl+L, nur Claude; Runde 5, R7).
    case redraw
    // Chat
    /// Zweite Ebene: Ziel-Konten wie im Kontextmenü (Claude, bei GPT-Chats auch GPT).
    case switchAccount
    case rename
    /// „Titel neu lesen“ wie im Kontextmenü.
    case refreshTitle
    case fork, pin, archive
    /// Wie „−“/„×“ des Chats in der Seitenleiste (im Filter „Aktiv“
    /// beenden, sonst archivieren).
    case closeChat
    // Projekt
    /// Projekt im gemerkten Ziel öffnen (wie der Knopf im Kopf, meist PhpStorm).
    case openProject
    /// Projektordner im Finder zeigen.
    case revealInFinder
    // Workspace: erst der Chat, dann der Workspace selbst
    /// Aus dem Workspace nehmen, in dem der Chat gerade gezeigt wird.
    case removeFromWorkspace
    /// Zweite Ebene: zu einem (anderen) angelegten Workspace hinzufügen.
    case addToWorkspace
    /// Notiz-Karte der Kachel auf/zu (wie ihr Knopf am Kachelkopf).
    case toggleTileNote
    /// In ein neues Fenster verschieben.
    case moveToNewWindow
    /// Standard „Notizen an/aus“ für alle Kacheln (wie ⌥⌘N).
    case toggleNotes
    /// Workspace umbenennen (dasselbe Sheet wie im Kontextmenü der Seitenleiste).
    case renameWorkspace
    /// Zweite Ebene: Rastergröße (wie der Stufenwähler im Workspace-Kopf).
    case gridCapacity
    // Lebenszyklus
    /// Laufenden Chat neu starten (mit der bestehenden Rückfrage).
    case restart
    /// Hintergrund-Chat (`claude --bg`): Logs, Stoppen, Neu starten.
    case backgroundLogs, backgroundStop, backgroundRestart
    /// Laufenden Subagent-Job stoppen.
    case stopJob
    // Steuerung
    /// Zwischenablage-Verlauf öffnen (wie Touchpad bzw. L2 + Touchpad).
    case clipboardHistory
    case showBindings, pause

    /// Gruppen in der Reihenfolge des Menüs.
    enum Group: Int, CaseIterable, Sendable {
        case input, chat, project, workspace, lifecycle, controller
    }

    /// Feste Gruppe. „Zu Workspace hinzufügen“ und „In neues Fenster“ stehen
    /// außerhalb eines Workspace unter „Chat“ (`ControllerMenuModel.group`).
    var group: Group {
        switch self {
        case .continueWork, .commands, .cycleMode, .redraw: return .input
        case .switchAccount, .rename, .refreshTitle, .fork, .pin, .archive, .closeChat: return .chat
        case .openProject, .revealInFinder: return .project
        case .removeFromWorkspace, .addToWorkspace, .toggleTileNote, .moveToNewWindow, .toggleNotes,
             .renameWorkspace, .gridCapacity: return .workspace
        case .restart, .backgroundLogs, .backgroundStop, .backgroundRestart, .stopJob: return .lifecycle
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
    var opensSubmenu: Bool {
        self == .commands || self == .switchAccount || self == .addToWorkspace || self == .gridCapacity
    }
}

/// Der Workspace, in dem der Chat gerade gezeigt wird: das sichtbare Raster
/// oder der Workspace, aus dem die Kachel groß gemacht wurde. Dann zeigt das
/// Menü die Gruppe „Workspace“.
struct ControllerWorkspaceContext: Equatable, Sendable {
    var id: UUID
    var name: String
    /// Das Raster ist sichtbar (sonst: Kachel groß in der Einzelansicht).
    var gridVisible: Bool
    /// Der Chat ist eine Kachel dieses Workspace.
    var chatIsMember: Bool
    /// Angelegter Workspace (keine Projekt-Ansicht): Umbenennen und
    /// Rastergröße gehen nur dort, wie in Seitenleiste und Workspace-Kopf.
    var isCurated: Bool
    /// Stufen des Rasters wie im Stufenwähler (nur die, die in die Fläche
    /// passen, und die aktuelle).
    var capacities: [ControllerCapacityChoice] = []
    /// Im Raster läuft gerade die Auswahl „wer bleibt“ für ein Verkleinern.
    var shrinkSelectionActive = false
}

/// Eine Stufe der Rastergröße.
struct ControllerCapacityChoice: Equatable, Sendable {
    var capacity: Int
    /// „2×2“ usw. wie im Stufenwähler.
    var label: String
    var isCurrent: Bool
    /// Verkleinern ginge nur, wenn man wählt, welche Chats bleiben. Das kann
    /// der Controller nicht: Die Stufe ist aus („geht nur mit der Maus“).
    var needsSelection: Bool

    var id: String { "capacity:\(capacity)" }
    var isChoosable: Bool { !isCurrent && !needsSelection }
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
    /// Verbraucht im 5-Stunden-Fenster bzw. in der Woche (Prozent, wie das
    /// Limits-Popover); `nil`, wenn kein Stand da ist (Runde 5).
    var fiveHourUsed: Double? = nil
    var weekUsed: Double? = nil
    /// In seiner Gruppe das wählbare Konto mit der meisten Luft
    /// (`ControllerAccountHeadroom`).
    var isMostFree = false

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
    // Runde 5: Kopf-Aktionen des Chats
    var isRunning = false
    /// Der Chat hat ein Projekt mit Ordner (Projekt öffnen, Finder).
    var hasProject = false
    /// Name des gemerkten Ziels für „Projekt öffnen“ (meist „PhpStorm“).
    var projectOpenTargetName: String?
    var canRefreshTitle = false
    /// Laufender Chat, der neu starten kann (kein Hintergrund-Chat).
    var canRestart = false
    var isBackgroundChat = false
    var canStopJob = false
    /// Der Chat hat einen Tab (In neues Fenster).
    var hasTab = false
    /// Raster sichtbar, Notizen eingeschaltet: „Notizen an/aus“ geht.
    var notesAvailable = false
    var notesDefaultOpen = false
    /// Notiz-Karte der Kachel offen oder zu; `nil`: keine Kachel mit Notiz.
    var tileNoteOpen: Bool?
    /// Name des sichtbaren, angelegten Workspace, zu dem der Chat gehört.
    var removableWorkspaceName: String?
    /// Angelegte Workspaces, in denen der Chat noch nicht ist.
    var addableWorkspaces: [ControllerWorkspaceChoice] = []
    /// Der Chat wird in einem Workspace gezeigt (Raster oder große Kachel).
    var shownInWorkspace: ControllerWorkspaceContext?
    /// Vorgemerkter Kontowechsel (Ziel), den man abbrechen kann.
    var pendingAccountSwitchTarget: String?
    var canUndoAccountSwitch = false
}

/// „Am meisten frei“ im Konto-Menü (Runde 5, Punkt 3): je Gruppe das
/// wählbare Konto mit dem kleinsten Verbrauch im knapperen der beiden Fenster
/// (`max(5 Std., Woche)`). Ohne Zahlen keine Markierung; bei Gleichstand das
/// obere. Die Reihenfolge bleibt.
enum ControllerAccountHeadroom {
    static func marked(_ accounts: [ControllerAccountChoice]) -> [ControllerAccountChoice] {
        var result = accounts.map { account -> ControllerAccountChoice in
            var copy = account
            copy.isMostFree = false
            return copy
        }
        for kind in [ControllerAccountChoice.Kind.claude, .gpt] {
            var best: (index: Int, used: Double)?
            for (index, account) in result.enumerated() where account.kind == kind && account.isChoosable {
                let values = [account.fiveHourUsed, account.weekUsed].compactMap { $0 }
                guard let used = values.max() else { continue }
                if best == nil || used < best!.used { best = (index, used) }
            }
            if let best { result[best.index].isMostFree = true }
        }
        return result
    }
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
    /// Was R1 + Kreuz gerade tut (`ControllerQuickDrawSlots.crossAction`,
    /// Runde 5); ohne Angabe „Weiter“ nach den bisherigen Regeln, `nil`
    /// heißt „geht nicht“.
    var quickCross: ControllerQuickDrawCross? = .continueWork
    /// Ein Diktat läuft (Runde 5, Punkt 9): Eingaben in den Chat und „Konto
    /// wechseln“ sind aus — ins Feld kommt gleich der Diktattext.
    var dictationRunning = false
}

/// Das Options-Menü mit zweiter Ebene (Befehle, Konten, Workspaces). Pur.
struct ControllerMenuModel: Equatable, Sendable {
    enum Submenu: Equatable, Sendable {
        case commands(ControllerListMenu<String>)
        case accounts(ControllerListMenu<String>)
        /// „Zu Workspace hinzufügen“: IDs der angelegten Workspaces.
        case workspaces(ControllerListMenu<String>)
        /// „Rastergröße“: `ControllerCapacityChoice.id`.
        case capacities(ControllerListMenu<String>)
    }

    /// Sonder-Einträge unter den Konten (Runde 5): nur, solange ein Wechsel
    /// vorgemerkt bzw. rückgängig zu machen ist.
    static let cancelSwitchID = "action:cancelSwitch"
    static let undoSwitchID = "action:undoSwitch"

    private(set) var setup: ControllerMenuSetup
    private(set) var top: ControllerListMenu<ControllerMenuItem>
    private(set) var submenu: Submenu?

    init(setup: ControllerMenuSetup = ControllerMenuSetup(), selected: ControllerMenuItem? = nil) {
        self.setup = setup
        self.top = ControllerListMenu(entries: Self.entries(setup: setup), selected: selected)
    }

    private static func entries(setup: ControllerMenuSetup) -> [ControllerListMenu<ControllerMenuItem>.Entry] {
        let visible = ControllerMenuItem.allCases.filter { isVisible($0, setup: setup) }
        // Stabil nach Gruppe sortieren: Einträge mit wechselnder Gruppe
        // rücken so zu ihren Nachbarn.
        return visible.enumerated()
            .sorted { lhs, rhs in
                let left = group(of: lhs.element, setup: setup).rawValue
                let right = group(of: rhs.element, setup: setup).rawValue
                return left == right ? lhs.offset < rhs.offset : left < right
            }
            .map { .init(id: $0.element, enabled: isEnabled($0.element, setup: setup)) }
    }

    /// Gruppe im Menü: „Zu Workspace hinzufügen“ und „In neues Fenster“
    /// gehören nur in einem Workspace zur Gruppe „Workspace“, sonst zu „Chat“
    /// — die Gruppe „Workspace“ gibt es nur, wenn der Chat in einem gezeigt wird.
    static func group(of item: ControllerMenuItem, setup: ControllerMenuSetup) -> ControllerMenuItem.Group {
        switch item {
        case .addToWorkspace, .moveToNewWindow:
            return setup.chat?.shownInWorkspace == nil ? .chat : .workspace
        default:
            return item.group
        }
    }

    /// Gruppe eines sichtbaren Eintrags in diesem Menü.
    func group(of item: ControllerMenuItem) -> ControllerMenuItem.Group {
        Self.group(of: item, setup: setup)
    }

    var selected: ControllerMenuItem? { top.selected }

    /// Eintrag der ersten Ebene direkt wählen (sofern er an ist).
    mutating func select(_ item: ControllerMenuItem) {
        top.select(item)
    }

    /// Trennlinie vor `item`: erster sichtbarer Eintrag einer neuen Gruppe.
    func startsGroup(_ item: ControllerMenuItem) -> Bool {
        guard let index = top.entries.firstIndex(where: { $0.id == item }), index > 0 else { return false }
        return group(of: top.entries[index - 1].id) != group(of: item)
    }

    /// Überschrift vor `item`: erster sichtbarer Eintrag seiner Gruppe,
    /// auch der allererste (die Karte zeigt jede Gruppe mit Überschrift).
    func groupStart(_ item: ControllerMenuItem) -> ControllerMenuItem.Group? {
        guard let index = top.entries.firstIndex(where: { $0.id == item }) else { return nil }
        let own = group(of: item)
        if index == 0 || group(of: top.entries[index - 1].id) != own { return own }
        return nil
    }

    /// Passt der Eintrag zu diesem Chat? Sonst fehlt er im Menü (Runde 5).
    static func isVisible(_ item: ControllerMenuItem, setup: ControllerMenuSetup) -> Bool {
        let chat = setup.sessionID == nil ? nil : setup.chat
        switch item {
        case .continueWork, .cycleMode: return setup.acceptsInput
        case .commands: return setup.acceptsInput && !ControllerSlashCommands.list(for: setup.profile).isEmpty
        case .redraw: return setup.acceptsInput && setup.profile == .claude
        case .switchAccount:
            guard let chat, !chat.isArchived else { return false }
            return !chat.accounts.isEmpty || chat.pendingAccountSwitchTarget != nil || chat.canUndoAccountSwitch
        case .rename, .pin: return chat != nil
        case .refreshTitle: return chat?.canRefreshTitle == true
        case .fork: return chat.map { $0.canFork && !$0.isArchived } ?? false
        case .archive, .closeChat: return chat.map { !$0.isArchived } ?? false
        case .openProject, .revealInFinder: return chat?.hasProject == true
        case .toggleTileNote: return chat?.tileNoteOpen != nil
        case .toggleNotes: return chat?.notesAvailable == true
        case .removeFromWorkspace: return chat?.removableWorkspaceName != nil
        case .addToWorkspace: return !(chat?.addableWorkspaces.isEmpty ?? true)
        case .moveToNewWindow: return chat?.hasTab == true
        case .renameWorkspace: return chat?.shownInWorkspace?.isCurated == true
        case .gridCapacity:
            guard let context = chat?.shownInWorkspace else { return false }
            return context.isCurated && context.capacities.count > 1
        case .restart: return chat?.canRestart == true
        case .backgroundLogs, .backgroundStop, .backgroundRestart: return chat?.isBackgroundChat == true
        case .stopJob: return chat?.canStopJob == true
        case .clipboardHistory, .showBindings, .pause: return true
        }
    }

    static func isEnabled(_ item: ControllerMenuItem, setup: ControllerMenuSetup) -> Bool {
        if setup.dictationRunning, item.writesToChat || item == .switchAccount { return false }
        if item.writesToChat {
            guard setup.acceptsInput, !setup.dialogOpen else { return false }
            if item == .commands {
                return !ControllerSlashCommands.list(for: setup.profile).isEmpty
            }
            if item == .redraw { return setup.profile == .claude }
            return !(item.needsRestingChat && setup.chatBusy)
        }
        guard item.group != .controller else { return true }
        guard let chat = setup.chat, setup.sessionID != nil else { return false }
        switch item {
        case .switchAccount:
            return !chat.isArchived && (chat.accounts.contains(where: \.isChoosable)
                || chat.pendingAccountSwitchTarget != nil || chat.canUndoAccountSwitch)
        case .fork: return chat.canFork && !chat.isArchived
        case .archive, .closeChat: return !chat.isArchived
        case .gridCapacity:
            // Während der Auswahl „wer bleibt“ wählt man keine weitere Stufe
            // (wie der Stufenwähler, den dann die Aktionsleiste ersetzt).
            guard let context = chat.shownInWorkspace, !context.shrinkSelectionActive else { return false }
            return context.capacities.contains(where: \.isChoosable)
        default: return isVisible(item, setup: setup)
        }
    }

    /// Rückfrage im Chat geht auf oder zu bzw. der Chat beginnt oder hört auf
    /// zu arbeiten, während das Menü offen ist.
    mutating func update(dialogOpen: Bool, chatBusy: Bool) {
        guard setup.dialogOpen != dialogOpen || setup.chatBusy != chatBusy else { return }
        setup.dialogOpen = dialogOpen
        setup.chatBusy = chatBusy
        top = ControllerListMenu(entries: Self.entries(setup: setup), selected: top.selected)
        // Die Befehle schreiben in den Chat: bei einer Rückfrage zurück zur ersten Ebene.
        if dialogOpen, case .commands = submenu { submenu = nil }
    }

    /// Neue Verbrauchszahlen kamen an, während das Konto-Menü offen ist.
    mutating func updateAccounts(_ accounts: [ControllerAccountChoice]) {
        guard var chat = setup.chat, chat.accounts != accounts else { return }
        chat.accounts = accounts
        setup.chat = chat
    }

    mutating func move(_ step: Int) {
        switch submenu {
        case var .commands(list):
            list.move(step)
            submenu = .commands(list)
        case var .accounts(list):
            list.move(step)
            submenu = .accounts(list)
        case var .workspaces(list):
            list.move(step)
            submenu = .workspaces(list)
        case var .capacities(list):
            list.move(step)
            submenu = .capacities(list)
        case nil:
            top.move(step)
        }
    }

    /// Einträge der Konto-Ebene: die Konten, dazu „Kontowechsel abbrechen“
    /// und „Letzten Kontowechsel rückgängig“, wenn zutreffend.
    static func accountEntries(_ chat: ControllerChatActionInfo?) -> [ControllerListMenu<String>.Entry] {
        guard let chat else { return [] }
        var entries = chat.accounts.map { ControllerListMenu<String>.Entry(id: $0.id, enabled: $0.isChoosable) }
        if chat.pendingAccountSwitchTarget != nil { entries.append(.init(id: cancelSwitchID, enabled: true)) }
        if chat.canUndoAccountSwitch { entries.append(.init(id: undoSwitchID, enabled: true)) }
        return entries
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
            let entries = Self.accountEntries(setup.chat)
            guard entries.contains(where: \.enabled) else { return false }
            // Die Markierung beginnt auf dem Konto des Chats (wie bisher bewusst
            // dort, Runde 5); der erste Schritt geht zum nächsten wählbaren.
            let current = setup.chat?.accounts.first(where: \.isCurrent)?.id
            submenu = .accounts(ControllerListMenu(entries: entries, start: current))
        case .addToWorkspace:
            let workspaces = setup.chat?.addableWorkspaces ?? []
            guard !workspaces.isEmpty else { return false }
            submenu = .workspaces(ControllerListMenu(entries: workspaces.map { .init(id: $0.id.uuidString, enabled: true) }))
        case .gridCapacity:
            let choices = setup.chat?.shownInWorkspace?.capacities ?? []
            guard choices.contains(where: \.isChoosable) else { return false }
            // Wie beim Konto: Start auf der aktuellen Stufe.
            let current = choices.first(where: \.isCurrent)?.id
            submenu = .capacities(ControllerListMenu(
                entries: choices.map { .init(id: $0.id, enabled: $0.isChoosable) }, start: current))
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
