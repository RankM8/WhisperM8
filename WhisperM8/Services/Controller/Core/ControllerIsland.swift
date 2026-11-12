import Foundation

// Pures Modell der Controller-Insel (Runde 4): was die Insel an der Notch
// zeigt, solange L1, R1 oder L2 gehalten wird. Gebaut im Ereignis-Pfad des
// Ausführers, nie in einem Body; die Ansicht zeichnet es nur.

/// Status-Punkt einer Zeile oder des Ziel-Chats, ohne App-Typen (der Kern
/// bleibt reine Foundation). Die Ansicht macht daraus den
/// `AgentStatusIndicator`, dieselbe Logik wie überall.
enum ControllerIslandStatus: String, CaseIterable, Sendable {
    case working, awaiting, idle, errored, stopped
}

/// Ziel im Kopf der Insel: Chat mit Status-Punkt.
struct ControllerIslandTarget: Equatable, Sendable {
    var title: String?
    var status: ControllerIslandStatus?
}

/// Ein Chat im Reiter „Chats“.
struct ControllerIslandChatRow: Equatable, Sendable, Identifiable {
    var id: UUID
    var title: String
    var project: String?
    var status: ControllerIslandStatus?
    /// Rechts: „wartet · 2 min“, „bereit“, beim aktuellen „jetzt“ — fertig
    /// formatiert im Ereignis-Pfad (dieselben Wörter wie Tab-Switcher und Notch).
    var detail: String
    var isCurrent: Bool
}

/// Ein angelegter Workspace im Reiter „Workspaces“ (früher die eigene
/// Workspace-Auswahl unten). Wird im Ereignis-Pfad gebaut, wenn die Insel
/// aufgeht — nie in einem Body.
struct ControllerWorkspaceChoice: Equatable, Sendable, Identifiable {
    var id: UUID
    var name: String
    var colorHex: String
    /// Belegte Slots.
    var chatCount: Int
    /// Dort wartet ein Chat auf den Nutzer — derselbe Status
    /// (`awaitingInput`), den der Punkt in Seitenleiste und Tab zeigt.
    var hasWaitingChat: Bool
    /// Das Raster dieses Fensters zeigt ihn gerade.
    var isCurrent: Bool
}

/// Liste der Insel mit Markierung und sichtbarem Fenster: höchstens
/// `maxVisibleRows` Zeilen, die Liste rückt mit der Markierung, darunter
/// steht „+ n weitere“. Kein Umlauf — am Rand bleibt die Markierung stehen.
struct ControllerIslandList<Row: Identifiable & Equatable & Sendable>: Equatable, Sendable where Row.ID == UUID {
    static var maxVisibleRows: Int { 6 }

    private(set) var rows: [Row]
    private(set) var selectedIndex: Int?
    private(set) var firstVisibleIndex = 0
    /// Die Markierung steht auf dem aktuellen Eintrag (Startpunkt gefunden).
    private(set) var startsAtCurrent: Bool

    init(rows: [Row], currentID: UUID?) {
        self.rows = rows
        let current = currentID.flatMap { id in rows.firstIndex { $0.id == id } }
        startsAtCurrent = current != nil
        selectedIndex = current ?? (rows.isEmpty ? nil : 0)
        scrollToSelection()
    }

    var selected: Row? { selectedIndex.map { rows[$0] } }

    var visibleRows: ArraySlice<Row> {
        let end = min(rows.count, firstVisibleIndex + Self.maxVisibleRows)
        return rows[firstVisibleIndex..<end]
    }

    /// Zeilen außerhalb des sichtbaren Fensters („+ n weitere“).
    var hiddenCount: Int { rows.count - visibleRows.count }

    mutating func move(_ step: Int) {
        guard let index = selectedIndex, !rows.isEmpty else { return }
        selectedIndex = min(max(index + step, 0), rows.count - 1)
        scrollToSelection()
    }

    private mutating func scrollToSelection() {
        guard let index = selectedIndex else {
            firstVisibleIndex = 0
            return
        }
        let maxRows = Self.maxVisibleRows
        if index < firstVisibleIndex { firstVisibleIndex = index }
        if index >= firstVisibleIndex + maxRows { firstVisibleIndex = index - maxRows + 1 }
        firstVisibleIndex = max(0, min(firstVisibleIndex, max(0, rows.count - maxRows)))
    }
}

/// Reiter der Ebene „Wohin“.
enum ControllerIslandTab: Int, CaseIterable, Sendable {
    case chats, workspaces
}

/// Ebene „Wohin“ (L2 gehalten).
struct ControllerWhereToState: Equatable, Sendable {
    /// Wohin ein Wechsel führt.
    enum Destination: Equatable, Sendable {
        /// Nichts zu wechseln: Liste zu oder der aktuelle Eintrag markiert.
        case stay
        case chat(UUID)
        case workspace(UUID)
    }

    /// Erst Stick oder Steuerkreuz öffnen die Liste; davor zeigt die Insel nur
    /// die Hinweiszeile.
    private(set) var isListOpen = false
    private(set) var tab: ControllerIslandTab
    private(set) var chats: ControllerIslandList<ControllerIslandChatRow>
    private(set) var workspaces: ControllerIslandList<ControllerWorkspaceChoice>
    /// Im sichtbaren Reiter wurde seit dem Öffnen bzw. dem letzten
    /// Reiterwechsel hoch/runter bewegt. Nur dann wechselt Loslassen oder
    /// Kreuz — ein bloßer Reiterwechsel springt nicht zum ersten Eintrag.
    private(set) var hasMovedInTab = false

    /// Start-Reiter: im Raster die Workspaces, in der Einzelansicht die Chats.
    init(
        chats: [ControllerIslandChatRow], currentChatID: UUID?,
        workspaces: [ControllerWorkspaceChoice], gridActive: Bool
    ) {
        self.chats = ControllerIslandList(rows: chats, currentID: currentChatID)
        self.workspaces = ControllerIslandList(
            rows: workspaces, currentID: workspaces.first(where: \.isCurrent)?.id)
        // Ohne angelegten Workspace gibt es im Raster nur die Chats.
        tab = gridActive && !workspaces.isEmpty ? .workspaces : .chats
    }

    /// Hoch/runter. Der erste Stoß öffnet die Liste und rückt gleich einen
    /// Schritt vom aktuellen Eintrag weiter; steht der aktuelle nicht in der
    /// Liste, bleibt die Markierung auf der ersten Zeile.
    mutating func move(_ step: Int) {
        hasMovedInTab = true
        if !isListOpen {
            isListOpen = true
            switch tab {
            case .chats: if chats.startsAtCurrent { chats.move(step) }
            case .workspaces: if workspaces.startsAtCurrent { workspaces.move(step) }
            }
            return
        }
        switch tab {
        case .chats: chats.move(step)
        case .workspaces: workspaces.move(step)
        }
    }

    /// Links/rechts: anderer Reiter (zwei Reiter, kein Umlauf). Öffnet die
    /// Liste, falls sie noch zu ist. `false`, wenn es nichts zu wechseln gab.
    @discardableResult
    mutating func switchTab(_ step: Int) -> Bool {
        let target: ControllerIslandTab = step < 0 ? .chats : .workspaces
        let wasOpen = isListOpen
        isListOpen = true
        guard target != tab else { return !wasOpen }
        tab = target
        hasMovedInTab = false
        return true
    }

    var destination: Destination {
        guard isListOpen, hasMovedInTab else { return .stay }
        switch tab {
        case .chats:
            guard let row = chats.selected, !row.isCurrent else { return .stay }
            return .chat(row.id)
        case .workspaces:
            guard let choice = workspaces.selected, !choice.isCurrent else { return .stay }
            return .workspace(choice.id)
        }
    }

    /// Workspace, dessen Raster das Fenster zeigt (Kopf „Raster · Name“).
    var currentWorkspaceName: String? { workspaces.rows.first(where: \.isCurrent)?.name }
}

/// Ebene „Schreiben“ (L1 gehalten): was in der Insel an oder aus ist.
struct ControllerWritingSlots: Equatable, Sendable {
    enum Note: String, Sendable {
        /// Shell: dort könnte ein Programm die Tasten anders deuten.
        case shell
        /// Offene Rückfrage: in den Chat geht gerade nichts.
        case question
    }

    var canDeleteLine: Bool
    var canInsertNewline: Bool
    var note: Note?

    init(canDeleteLine: Bool, canInsertNewline: Bool, note: Note?) {
        self.canDeleteLine = canDeleteLine
        self.canInsertNewline = canInsertNewline
        self.note = note
    }

    init(state: ControllerChatState?) {
        let allowed = state.map(ControllerBindingResolver.layerWritingAllowed) ?? false
        canDeleteLine = allowed
        canInsertNewline = allowed
        note = nil
        guard let state, state.acceptsKeys, !allowed else { return }
        note = ControllerBindingResolver.writingKeysAllowed(state) ? .question : .shell
    }
}

/// Ebene „Schnellbefehle“ (R1 gehalten): die Raute in der Lage der Tasten.
struct ControllerQuickDrawSlots: Equatable, Sendable {
    /// Oben, links, rechts, unten — wie Dreieck, Viereck, Kreis, Kreuz.
    static let items: [ControllerMenuItem] = [.cycleMode, .commands, .switchAccount, .continueWork]

    static func item(for button: ControllerButton) -> ControllerMenuItem? {
        switch button {
        case .cross: return .continueWork
        case .triangle: return .cycleMode
        case .square: return .commands
        case .circle: return .switchAccount
        default: return nil
        }
    }

    static func button(for item: ControllerMenuItem) -> ControllerButton? {
        [ControllerButton.cross, .triangle, .square, .circle].first { self.item(for: $0) == item }
    }

    enum Note: String, Sendable {
        /// Rückfrage offen: alles, was in den Chat schreibt, ist aus.
        case question
        /// Chat arbeitet (oder gerade gesendet): „Weiter“ und „Modus
        /// wechseln“ warten, bis er ruht.
        case busy
    }

    var enabled: Set<ControllerMenuItem>
    var note: Note?
    /// Gerade gedrückt (kurze Markierung vor dem Schließen).
    var hit: ControllerMenuItem?

    /// Dieselben Regeln wie die Einträge des Options-Menüs.
    init(setup: ControllerMenuSetup, hit: ControllerMenuItem? = nil) {
        enabled = Set(Self.items.filter { ControllerMenuModel.isEnabled($0, setup: setup) })
        if setup.acceptsInput, setup.dialogOpen {
            note = .question
        } else if setup.acceptsInput, setup.chatBusy {
            note = .busy
        }
        self.hit = hit
    }

    var dialogOpen: Bool { note == .question }
}

/// Alles, was die Insel zeigt.
struct ControllerIslandModel: Equatable, Sendable {
    enum Content: Equatable, Sendable {
        case writing(ControllerWritingSlots)
        case quickDraw(ControllerQuickDrawSlots)
        case whereTo(ControllerWhereToState)
    }

    var target: ControllerIslandTarget
    var content: Content

    var layer: ControllerLayer {
        switch content {
        case .writing: return .writing
        case .quickDraw: return .quickDraw
        case .whereTo: return .whereTo
        }
    }

    var whereTo: ControllerWhereToState? {
        if case let .whereTo(state) = content { return state }
        return nil
    }
}
