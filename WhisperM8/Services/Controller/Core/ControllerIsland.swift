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
    /// `nil`: noch keine Markierung (Startpunkt nicht in der Liste). Der
    /// erste Stoß markiert dann die erste Zeile; bis dahin wechselt nichts.
    private(set) var selectedIndex: Int?
    private(set) var firstVisibleIndex = 0

    /// - Parameter startID: Eintrag, auf dem die Markierung beginnt (voriger
    ///   Ort oder der aktuelle). Steht er nicht in der Liste, gibt es noch
    ///   keine Markierung.
    init(rows: [Row], startID: UUID?) {
        self.rows = rows
        selectedIndex = startID.flatMap { id in rows.firstIndex { $0.id == id } }
        scrollToSelection()
    }

    var selected: Row? { selectedIndex.map { rows[$0] } }

    var visibleRows: ArraySlice<Row> {
        let end = min(rows.count, firstVisibleIndex + Self.maxVisibleRows)
        return rows[firstVisibleIndex..<end]
    }

    /// Zeilen außerhalb des sichtbaren Fensters („+ n weitere“).
    var hiddenCount: Int { rows.count - visibleRows.count }

    func contains(_ id: UUID) -> Bool { rows.contains { $0.id == id } }

    mutating func move(_ step: Int) {
        guard !rows.isEmpty else { return }
        if let index = selectedIndex {
            selectedIndex = min(max(index + step, 0), rows.count - 1)
        } else {
            selectedIndex = 0
        }
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

/// Ebene „Wohin“ (L2 gehalten), wie Cmd-Tab: Die Liste steht sofort da, die
/// Markierung beginnt auf dem vorigen Ort (dem Ziel von L2 getippt), und
/// Loslassen wechselt zum markierten Eintrag. Ohne vorigen Ort beginnt sie
/// auf dem aktuellen Eintrag, Loslassen tut dann nichts.
struct ControllerWhereToState: Equatable, Sendable {
    /// Wohin ein Wechsel führt.
    enum Destination: Equatable, Sendable {
        /// Nichts zu wechseln: keine Markierung oder der aktuelle Eintrag.
        case stay
        case chat(UUID)
        case workspace(UUID)
    }

    private(set) var tab: ControllerIslandTab
    /// Chat, den Viereck wieder öffnen würde (Runde 5); `nil`: nichts
    /// geschlossen in diesem App-Start.
    var reopenTitle: String?
    private(set) var chats: ControllerIslandList<ControllerIslandChatRow>
    private(set) var workspaces: ControllerIslandList<ControllerWorkspaceChoice>
    /// Voriger Ort, sofern er in einer der beiden Listen steht (dort beginnt
    /// die Markierung, die Zeile trägt „vorher“).
    let previous: Destination
    private let currentChatID: UUID?

    /// Start-Reiter: der Reiter des vorigen Orts, damit Loslassen ohne
    /// Bewegung dasselbe tut wie L2 getippt. Ohne vorigen Ort im Raster die
    /// Workspaces, in der Einzelansicht die Chats.
    init(
        chats: [ControllerIslandChatRow], currentChatID: UUID?,
        workspaces: [ControllerWorkspaceChoice], gridActive: Bool,
        previous: Destination = .stay
    ) {
        self.currentChatID = currentChatID
        switch previous {
        case let .chat(id) where chats.contains(where: { $0.id == id }):
            self.previous = previous
            tab = .chats
        case let .workspace(id) where workspaces.contains(where: { $0.id == id }):
            self.previous = previous
            tab = .workspaces
        default:
            self.previous = .stay
            // Ohne angelegten Workspace gibt es im Raster nur die Chats.
            tab = gridActive && !workspaces.isEmpty ? .workspaces : .chats
        }
        self.chats = ControllerIslandList(rows: chats, startID: nil)
        self.workspaces = ControllerIslandList(rows: workspaces, startID: nil)
        self.chats = ControllerIslandList(rows: chats, startID: startID(for: .chats))
        self.workspaces = ControllerIslandList(rows: workspaces, startID: startID(for: .workspaces))
    }

    /// Wo die Markierung in einem Reiter beginnt: voriger Ort, wenn er dort
    /// steht, sonst der aktuelle Eintrag.
    private func startID(for tab: ControllerIslandTab) -> UUID? {
        switch (tab, previous) {
        case let (.chats, .chat(id)): return id
        case let (.workspaces, .workspace(id)): return id
        case (.chats, _): return currentChatID
        case (.workspaces, _): return workspaces.rows.first(where: \.isCurrent)?.id
        }
    }

    /// Hoch/runter im sichtbaren Reiter.
    mutating func move(_ step: Int) {
        switch tab {
        case .chats: chats.move(step)
        case .workspaces: workspaces.move(step)
        }
    }

    /// Links/rechts: anderer Reiter (zwei Reiter, kein Umlauf). Die
    /// Markierung dort beginnt wieder auf ihrem Startpunkt. `false`, wenn es
    /// nichts zu wechseln gab.
    @discardableResult
    mutating func switchTab(_ step: Int) -> Bool {
        let target: ControllerIslandTab = step < 0 ? .chats : .workspaces
        guard target != tab else { return false }
        tab = target
        switch target {
        case .chats: chats = ControllerIslandList(rows: chats.rows, startID: startID(for: .chats))
        case .workspaces: workspaces = ControllerIslandList(rows: workspaces.rows, startID: startID(for: .workspaces))
        }
        return true
    }

    var destination: Destination {
        switch tab {
        case .chats:
            guard let row = chats.selected, !row.isCurrent else { return .stay }
            return .chat(row.id)
        case .workspaces:
            guard let choice = workspaces.selected, !choice.isCurrent else { return .stay }
            return .workspace(choice.id)
        }
    }

    /// Reihenfolge der Chat-Zeilen: die der Liste links, dazu der vorige
    /// Chat, falls sie ihn gerade nicht zeigt (Filter, Suche, eingeklappt,
    /// Archiv) — gleich hinter dem aktuellen, wie bei Cmd-Tab.
    static func chatOrder(_ order: [UUID], current: UUID?, previous: Destination) -> [UUID] {
        guard case let .chat(id) = previous, !order.contains(id) else { return order }
        var result = order
        let index = current.flatMap { result.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
        result.insert(id, at: index)
        return result
    }

    func isPrevious(chat id: UUID) -> Bool { previous == .chat(id) }
    func isPrevious(workspace id: UUID) -> Bool { previous == .workspace(id) }

    /// Workspace, dessen Raster das Fenster zeigt (Kopf „Raster · Name“).
    var currentWorkspaceName: String? { workspaces.rows.first(where: \.isCurrent)?.name }
}

/// Was R1 + Kreuz schickt (Runde 5, R1).
enum ControllerQuickDrawCross: String, Sendable {
    /// „Weiter“ als Text mit Enter (leeres Feld, Chat ruht).
    case continueWork
    /// Enter: den Text im Feld abschicken.
    case send
    /// Ctrl+X Ctrl+S: Claude schickt Entwurf bzw. Warteschlange sofort.
    case sendNow
}

/// Neuester Eintrag der Zwischenablage, wie die Insel ihn für L1 + Kreuz
/// ankündigt (Runde 5).
struct ControllerClipPreview: Equatable, Sendable {
    enum Kind: String, Sendable {
        case text, image
    }

    var id: String
    var kind: Kind
    /// Erste Zeile, gekürzt (bei Bildern leer).
    var preview: String
    var imageWidth: Int?
    var imageHeight: Int?
}

/// Ebene „Schreiben“ (L1 gehalten): was in der Insel an oder aus ist.
struct ControllerWritingSlots: Equatable, Sendable {
    enum Note: String, Sendable {
        /// Shell: dort könnte ein Programm die Tasten anders deuten.
        case shell
        /// Offene Rückfrage: in den Chat geht gerade nichts.
        case question
        /// Chat arbeitet, keine Ansicht erkannt: Escape bricht ab (Runde 5, R3).
        case escapeInterrupts
    }

    /// Ein Eintrag der Insel, in der Reihenfolge der Anzeige.
    enum Hint: String, CaseIterable, Sendable {
        case deleteLine, newline, wordJump, lineMove, paste, escape, undo
    }

    var canDeleteLine: Bool
    var canInsertNewline: Bool
    var note: Note?
    // Runde 5
    var canMoveWord = false
    var canMoveLine = false
    var canPaste = false
    var canEscape = false
    var canUndo = false
    /// Was Kreuz einfügen würde; `nil`: nichts zum Einfügen.
    var clip: ControllerClipPreview?

    init(canDeleteLine: Bool, canInsertNewline: Bool, note: Note?) {
        self.canDeleteLine = canDeleteLine
        self.canInsertNewline = canInsertNewline
        self.note = note
    }

    init(state: ControllerChatState?, clip: ControllerClipPreview? = nil) {
        let allowed = state.map(ControllerBindingResolver.layerWritingAllowed) ?? false
        canDeleteLine = allowed
        canInsertNewline = allowed
        note = nil
        self.clip = clip
        if let state {
            canMoveWord = allowed
            canMoveLine = allowed && (ControllerBindingResolver.lineMoveAllowed(.up, state: state)
                || ControllerBindingResolver.lineMoveAllowed(.down, state: state))
            canPaste = clip != nil && ControllerBindingResolver.pasteAllowed(state)
                && (clip?.kind == .text || state.profile != .shell)
            canEscape = ControllerBindingResolver.escapeOnceAllowed(state)
            canUndo = ControllerBindingResolver.undoAllowed(state)
        }
        guard let state, state.acceptsKeys else { return }
        if !allowed {
            note = ControllerBindingResolver.writingKeysAllowed(state) ? .question : .shell
        } else if state.profile == .claude, state.status == .working, state.openView == nil {
            note = .escapeInterrupts
        }
    }

    func isOn(_ hint: Hint) -> Bool {
        switch hint {
        case .deleteLine: return canDeleteLine
        case .newline: return canInsertNewline
        case .wordJump: return canMoveWord
        case .lineMove: return canMoveLine
        case .paste: return canPaste
        case .escape: return canEscape
        case .undo: return canUndo
        }
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

    /// Was R1 + Kreuz tut (Runde 5, R1; Präzisierung des Nutzers: „wie
    /// Ctrl+Enter, im Prompt direkt nachschießen“):
    /// - Claude, Text im Feld oder eigener Prompt in der Warteschlange, Chat
    ///   arbeitet (oder unklar, gerade gesendet): „Jetzt senden“ (Ctrl+X Ctrl+S).
    /// - Claude, Text im Feld, Chat ruht: Enter („Senden“).
    /// - Codex, Text im Feld: Enter — Codex greift damit sofort in den
    ///   laufenden Turn ein.
    /// - Feld leer, Chat ruht: „Weiter“ wie bisher (`.continueWork`).
    /// - Feld leer, nichts wartet, Chat arbeitet: `nil` („geht nicht“).
    /// Nie in einer offenen Rückfrage oder bei offener Ansicht (`nil`; dort
    /// gilt die bisherige Regel, also aus) und nie in Shells (`.continueWork`
    /// mit den bisherigen Regeln).
    static func crossAction(
        profile: ControllerChatState.Profile?, busy: Bool, dialogOpen: Bool, viewOpen: Bool,
        fieldHasText: Bool, queuedOwnPrompts: Int
    ) -> ControllerQuickDrawCross? {
        guard !dialogOpen, !viewOpen else { return nil }
        switch profile {
        case .claude:
            if busy { return fieldHasText || queuedOwnPrompts > 0 ? .sendNow : nil }
            return fieldHasText ? .send : .continueWork
        case .codex:
            if fieldHasText { return .send }
            return busy ? nil : .continueWork
        case .shell, .other, nil:
            return .continueWork
        }
    }

    enum Note: String, Sendable {
        /// Rückfrage offen: alles, was in den Chat schreibt, ist aus.
        case question
        /// Chat arbeitet (oder gerade gesendet): „Weiter“ und „Modus
        /// wechseln“ warten, bis er ruht.
        case busy
        /// Ein Diktat läuft: Ins Feld kommt gleich der Diktattext (Runde 5).
        case dictating
    }

    var enabled: Set<ControllerMenuItem>
    var note: Note?
    /// Gerade gedrückt (kurze Markierung vor dem Schließen).
    var hit: ControllerMenuItem?

    /// Was Kreuz gerade tut (Beschriftung „Weiter“, „Senden“, „Jetzt senden“).
    var cross: ControllerQuickDrawCross?

    /// Dieselben Regeln wie die Einträge des Options-Menüs; Kreuz nach
    /// `crossAction` (Runde 5).
    init(setup: ControllerMenuSetup, hit: ControllerMenuItem? = nil) {
        cross = setup.dictationRunning ? nil : setup.quickCross
        enabled = Set(Self.items.filter { item in
            guard item == .continueWork, setup.acceptsInput, !setup.dictationRunning else {
                return ControllerMenuModel.isEnabled(item, setup: setup)
            }
            switch setup.quickCross {
            case .send?, .sendNow?: return true
            case .continueWork?: return ControllerMenuModel.isEnabled(item, setup: setup)
            case nil: return false
            }
        })
        if setup.dictationRunning {
            note = .dictating
        } else if setup.acceptsInput, setup.dialogOpen {
            note = .question
        } else if setup.acceptsInput, setup.chatBusy, setup.quickCross != .sendNow, setup.quickCross != .send {
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
