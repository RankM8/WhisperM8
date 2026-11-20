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
    /// Ein Diktat läuft, der Kopf nennt sein Ziel („→ Chat“). Per Tastatur
    /// heißt Leertaste dann „stopp“, Esc schließt nur die Insel.
    var dictating = false
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

/// Ein angelegter Workspace oder ein Projekt im Reiter „Workspaces &
/// Projekte“ (früher die eigene Workspace-Auswahl unten). Wird im
/// Ereignis-Pfad gebaut, wenn die Insel aufgeht — nie in einem Body.
struct ControllerWorkspaceChoice: Equatable, Sendable, Identifiable {
    /// Workspace oder Projekt (Insel-Paket): Ein Projekt öffnet wie in der
    /// Seitenleiste als Raster seiner aktiven Chats.
    enum Kind: String, Sendable {
        case workspace, project
    }

    /// Workspace-ID bzw. bei Projekten die Projekt-ID.
    var id: UUID
    var name: String
    var colorHex: String
    /// Belegte Slots; bei Projekten die aktiven Chats.
    var chatCount: Int
    /// Dort wartet ein Chat auf den Nutzer — derselbe Status
    /// (`awaitingInput`), den der Punkt in Seitenleiste und Tab zeigt.
    var hasWaitingChat: Bool
    /// Das Raster dieses Fensters zeigt ihn gerade.
    var isCurrent: Bool
    var kind: Kind = .workspace
    /// Nur Projekte: die versteckte Projekt-Ansicht, sofern es sie gibt. Ist
    /// sie der vorige Ort des Fensters, trägt die Projekt-Zeile „vorher“.
    var viewWorkspaceID: UUID? = nil
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
    /// Spalten der Anzeige: 1 als Liste (Notch, Pille), 2 als Kacheln (große
    /// Form an der Kamera-Insel). Das sichtbare Fenster beginnt immer am
    /// Anfang einer Reihe.
    private(set) var columns = 1

    mutating func setColumns(_ count: Int) {
        columns = max(1, count)
        scrollToSelection()
    }

    /// Spalte der Markierung (0 = links); `nil` ohne Markierung.
    var selectedColumn: Int? { selectedIndex.map { $0 % columns } }

    /// Einen Schritt zur Seite in derselben Reihe. `false`, wenn es dort
    /// keinen Nachbarn gibt (Rand der Reihe, einspaltige Liste, keine
    /// Markierung); dann bleibt alles, wie es ist.
    @discardableResult
    mutating func moveSideways(_ step: Int) -> Bool {
        guard columns > 1, let index = selectedIndex else { return false }
        let target = index + (step < 0 ? -1 : 1)
        guard rows.indices.contains(target), target / columns == index / columns else { return false }
        selectedIndex = target
        scrollToSelection()
        return true
    }

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

    /// Markierung auf diese Zeile (Tastatur: Start auf „vorher“). `false`,
    /// wenn sie nicht in der Liste steht; dann bleibt alles, wie es ist.
    @discardableResult
    mutating func select(_ id: UUID) -> Bool {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return false }
        selectedIndex = index
        scrollToSelection()
        return true
    }

    mutating func move(_ step: Int) {
        guard !rows.isEmpty else { return }
        if let index = selectedIndex {
            selectedIndex = min(max(index + step, 0), rows.count - 1)
        } else {
            selectedIndex = 0
        }
        scrollToSelection()
    }

    /// Hoch/runter um eine Reihe: in der Liste ein Eintrag, in Kacheln
    /// dieselbe Spalte der Nachbar-Reihe. Kein Umlauf. Endet die letzte
    /// Reihe vor dieser Spalte, geht es auf ihren letzten Eintrag; ganz oben
    /// und ganz unten bleibt die Markierung stehen.
    mutating func moveRow(_ step: Int) {
        guard columns > 1, let index = selectedIndex else { return move(step) }
        let target = index + (step < 0 ? -columns : columns)
        if rows.indices.contains(target) {
            selectedIndex = target
        } else if step > 0, index / columns < (rows.count - 1) / columns {
            selectedIndex = rows.count - 1
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
        guard columns > 1 else { return }
        // Kacheln: Das Fenster beginnt an einem Reihenanfang und rückt
        // reihenweise.
        if firstVisibleIndex % columns != 0 {
            let start = firstVisibleIndex - firstVisibleIndex % columns
            firstVisibleIndex = index >= start + maxRows ? start + columns : start
        }
    }
}

/// Reiter der Ebene „Wohin“: Chats, Workspaces & Projekte und, bei
/// eingeschalteter Ticket-Ansicht, Tickets (WM8-91).
enum ControllerIslandTab: Int, CaseIterable, Sendable {
    case chats, workspaces, tickets
}

/// Ebene „Wohin“ (L2 gehalten, Insel-Paket): Die Liste steht sofort da, die
/// Markierung beginnt auf dem aktuellen Eintrag. Loslassen ohne Bewegung tut
/// deshalb nichts; erst nach einer Bewegung wechseln Loslassen und Kreuz zum
/// markierten Eintrag. Der vorige Ort (Ziel von L2 getippt) trägt „vorher“
/// und steht in beiden Reitern gleich unter dem aktuellen, einen Schritt weit
/// weg — auch wenn die Seitenleiste ihn weiter unten zeigt.
struct ControllerWhereToState: Equatable, Sendable {
    /// Wohin ein Wechsel führt.
    enum Destination: Equatable, Sendable {
        /// Nichts zu wechseln: keine Markierung oder der aktuelle Eintrag.
        case stay
        case chat(UUID)
        case workspace(UUID)
        /// Projekt als Raster seiner aktiven Chats (wie in der Seitenleiste).
        case project(UUID)
        /// Ticket-Board dieses Projekts (WM8-91).
        case tickets(UUID)
    }

    private(set) var tab: ControllerIslandTab
    /// Chat, den Viereck wieder öffnen würde (Runde 5); `nil`: nichts
    /// geschlossen in diesem App-Start.
    var reopenTitle: String?
    private(set) var chats: ControllerIslandList<ControllerIslandChatRow>
    private(set) var workspaces: ControllerIslandList<ControllerWorkspaceChoice>
    /// Boards im Reiter „Tickets“; leer ohne den Reiter.
    private(set) var tickets: ControllerIslandList<ControllerTicketBoardChoice>
    /// Was der Reiter „Tickets“ zeigt; `nil`: Es gibt ihn nicht (Ticket-Ansicht aus).
    let ticketBoards: ControllerTicketBoards?
    /// Voriger Ort, sofern er in einer der Listen steht (die Zeile trägt
    /// „vorher“).
    let previous: Destination
    private let currentChatID: UUID?

    /// Start-Reiter: im Ticket-Modus „Tickets“, im Raster „Workspaces &
    /// Projekte“, in der Einzelansicht „Chats“ (ohne Workspace oder Projekt im
    /// Reiter nur die Chats), jeweils auf dem aktuellen Eintrag. Im Reiter
    /// „Tickets“ beginnt die Markierung auf „hier“, dem Board des aktuellen
    /// Projekts: Außerhalb des Boards ist es ein Ziel, L2 halten, ▶ ▶ und
    /// Loslassen öffnen es.
    init(
        chats: [ControllerIslandChatRow], currentChatID: UUID?,
        workspaces: [ControllerWorkspaceChoice], gridActive: Bool,
        previous: Destination = .stay, tickets: ControllerTicketBoards? = nil
    ) {
        self.currentChatID = currentChatID
        let previous = Self.resolve(previous, chats: chats, workspaces: workspaces, tickets: tickets?.rows ?? [])
        self.previous = previous
        ticketBoards = tickets
        self.tickets = ControllerIslandList(
            rows: tickets?.rows ?? [], startID: tickets?.rows.first(where: \.isHere)?.id)
        if tickets?.inTickets == true {
            tab = .tickets
        } else {
            tab = gridActive && !workspaces.isEmpty ? .workspaces : .chats
        }
        let chats = Self.placingPrevious(
            chats, isPrevious: { previous == .chat($0.id) }, isCurrent: { $0.id == currentChatID })
        let workspaces = Self.placingPrevious(
            workspaces, isPrevious: { Self.destination(of: $0) == previous }, isCurrent: \.isCurrent)
        self.chats = ControllerIslandList(rows: chats, startID: currentChatID)
        self.workspaces = ControllerIslandList(rows: workspaces, startID: workspaces.first(where: \.isCurrent)?.id)
    }

    /// Der vorige Ort rückt gleich hinter den aktuellen (ohne aktuellen ganz
    /// nach oben), wo immer die Liste ihn sonst führt: ein Schritt bis dorthin,
    /// wie bei Cmd-Tab. Die übrigen Zeilen behalten ihre Reihenfolge.
    static func placingPrevious<Row>(
        _ rows: [Row], isPrevious: (Row) -> Bool, isCurrent: (Row) -> Bool
    ) -> [Row] {
        guard let index = rows.firstIndex(where: isPrevious), !isCurrent(rows[index]) else { return rows }
        var result = rows
        let row = result.remove(at: index)
        let target = result.firstIndex(where: isCurrent).map { $0 + 1 } ?? 0
        result.insert(row, at: target)
        return result
    }

    private static func destination(of choice: ControllerWorkspaceChoice) -> Destination {
        choice.kind == .project ? .project(choice.id) : .workspace(choice.id)
    }

    /// Der vorige Ort, wie die Listen ihn kennen: Eine Projekt-Ansicht ist
    /// als Workspace gemerkt, steht hier aber als Projekt-Zeile.
    private static func resolve(
        _ previous: Destination, chats: [ControllerIslandChatRow], workspaces: [ControllerWorkspaceChoice],
        tickets: [ControllerTicketBoardChoice]
    ) -> Destination {
        switch previous {
        case let .tickets(id) where tickets.contains(where: { $0.id == id }):
            return previous
        case let .chat(id) where chats.contains(where: { $0.id == id }):
            return previous
        case let .workspace(id):
            if workspaces.contains(where: { $0.kind == .workspace && $0.id == id }) { return previous }
            if let project = workspaces.first(where: { $0.kind == .project && $0.viewWorkspaceID == id }) {
                return .project(project.id)
            }
            return .stay
        case let .project(id) where workspaces.contains(where: { $0.kind == .project && $0.id == id }):
            return previous
        default:
            return .stay
        }
    }

    /// Ein Schritt vor oder zurück im sichtbaren Reiter, in Lesereihenfolge
    /// (Tab und ⇧Tab der Tastatur; in der einspaltigen Liste dasselbe wie
    /// hoch/runter).
    mutating func move(_ step: Int) {
        switch tab {
        case .chats: chats.move(step)
        case .workspaces: workspaces.move(step)
        case .tickets: tickets.move(step)
        }
    }

    /// Spalten der Anzeige (`ControllerIslandList.columns`): 2 in der großen
    /// Form an der Kamera-Insel, sonst 1. Mit Kacheln bewegt das Steuerkreuz
    /// in beide Richtungen: hoch/runter die Reihe, links/rechts die Spalte;
    /// erst am Rand der Reihe wechselt links/rechts den Reiter.
    var columns: Int { chats.columns }

    mutating func setColumns(_ count: Int) {
        chats.setColumns(count)
        workspaces.setColumns(count)
        tickets.setColumns(count)
    }

    /// Hoch/runter am Controller (Steuerkreuz, Stick): eine Reihe. Die
    /// Tastatur geht mit Tab und ↓/↑ über `move` in Lesereihenfolge.
    mutating func moveRow(_ step: Int) {
        switch tab {
        case .chats: chats.moveRow(step)
        case .workspaces: workspaces.moveRow(step)
        case .tickets: tickets.moveRow(step)
        }
    }

    /// Links/rechts am Controller: mit Kacheln zuerst die Nachbar-Kachel der
    /// Reihe; am Rand der Reihe (und in der einspaltigen Liste immer) der
    /// Nachbar-Reiter. `false`, wenn sich nichts bewegt hat. Per Tastatur
    /// wechseln ←/→ immer den Reiter (`switchTabForKeyboard`).
    @discardableResult
    mutating func moveSideways(_ step: Int) -> Bool {
        let moved: Bool
        switch tab {
        case .chats: moved = chats.moveSideways(step)
        case .workspaces: moved = workspaces.moveSideways(step)
        case .tickets: moved = tickets.moveSideways(step)
        }
        if moved { return true }
        return switchTab(step)
    }

    /// Die Reiter in ihrer Reihenfolge; „Tickets“ nur bei eingeschalteter
    /// Ticket-Ansicht.
    var tabs: [ControllerIslandTab] {
        ticketBoards == nil ? [.chats, .workspaces] : [.chats, .workspaces, .tickets]
    }

    /// Links/rechts: der Nachbar-Reiter, ein Schritt je Druck, kein Umlauf
    /// (aus „Chats“ sind es zwei Schritte bis „Tickets“). Die Markierung dort
    /// beginnt wieder auf dem aktuellen Eintrag, in „Tickets“ auf „hier“.
    /// `false`, wenn es nichts zu wechseln gab.
    @discardableResult
    mutating func switchTab(_ step: Int) -> Bool {
        let tabs = tabs
        guard let index = tabs.firstIndex(of: tab) else { return false }
        let target = index + (step < 0 ? -1 : 1)
        guard tabs.indices.contains(target) else { return false }
        tab = tabs[target]
        let columns = columns
        switch tab {
        case .chats: chats = ControllerIslandList(rows: chats.rows, startID: currentChatID)
        case .workspaces:
            workspaces = ControllerIslandList(rows: workspaces.rows, startID: workspaces.rows.first(where: \.isCurrent)?.id)
        case .tickets:
            tickets = ControllerIslandList(rows: tickets.rows, startID: tickets.rows.first(where: \.isHere)?.id)
        }
        setColumns(columns)
        return true
    }

    // MARK: Tastatur (⌥Tab, WM8-104)

    /// Start per Tastatur: Wie bei ⌘Tab ist der Druck auf Tab schon ein
    /// Schritt. Die Markierung steht auf dem vorigen Ort, im Reiter, der ihn
    /// führt — so führt ⌥Tab kurz getippt dorthin wie L2 getippt. Ohne vorigen
    /// Ort ein Schritt weiter im Start-Reiter (die Zeile unter dem aktuellen).
    mutating func markPreviousForKeyboard() {
        guard selectPrevious(switchingTab: true) else { return move(1) }
    }

    /// ←/→ per Tastatur: anderer Reiter, die Markierung dort auf „vorher“,
    /// wenn der Reiter den vorigen Ort führt, sonst auf dem aktuellen Eintrag.
    @discardableResult
    mutating func switchTabForKeyboard(_ step: Int) -> Bool {
        guard switchTab(step) else { return false }
        selectPrevious(switchingTab: false)
        return true
    }

    /// Markiert den vorigen Ort. `switchingTab`: auch in den Reiter wechseln,
    /// der ihn führt; sonst nur, wenn er im sichtbaren Reiter steht.
    @discardableResult
    private mutating func selectPrevious(switchingTab: Bool) -> Bool {
        switch previous {
        case .stay:
            return false
        case let .chat(id):
            guard switchingTab || tab == .chats, chats.contains(id) else { return false }
            tab = .chats
            return chats.select(id)
        case let .workspace(id), let .project(id):
            guard switchingTab || tab == .workspaces, workspaces.contains(id) else { return false }
            tab = .workspaces
            return workspaces.select(id)
        case let .tickets(id):
            guard switchingTab || tab == .tickets, tickets.contains(id) else { return false }
            tab = .tickets
            return tickets.select(id)
        }
    }

    var destination: Destination {
        switch tab {
        case .chats:
            guard let row = chats.selected, !row.isCurrent else { return .stay }
            return .chat(row.id)
        case .workspaces:
            guard let choice = workspaces.selected, !choice.isCurrent else { return .stay }
            return choice.kind == .project ? .project(choice.id) : .workspace(choice.id)
        case .tickets:
            guard let board = tickets.selected, !board.isCurrent else { return .stay }
            return .tickets(board.id)
        }
    }

    /// Reihenfolge der Chat-Zeilen: die der Liste links, der vorige Chat aber
    /// immer gleich hinter dem aktuellen (ohne aktuellen ganz oben), wie bei
    /// Cmd-Tab — auch wenn die Liste ihn weiter unten oder gar nicht zeigt
    /// (Filter, Suche, eingeklappt, Archiv).
    static func chatOrder(_ order: [UUID], current: UUID?, previous: Destination) -> [UUID] {
        guard case let .chat(id) = previous, id != current else { return order }
        let rows = order.contains(id) ? order : [id] + order
        return placingPrevious(rows, isPrevious: { $0 == id }, isCurrent: { $0 == current })
    }

    func isPrevious(chat id: UUID) -> Bool { previous == .chat(id) }

    func isPrevious(_ choice: ControllerWorkspaceChoice) -> Bool {
        previous == Self.destination(of: choice)
    }

    /// Workspace oder Projekt, dessen Raster das Fenster zeigt (Kopf „Raster · Name“).
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
            // In eine Rückfrage (erkannte Frage, WM8-66) und in Shells nur Text.
            canPaste = clip != nil && ControllerBindingResolver.pasteAllowed(state)
                && (clip?.kind == .text || (state.profile != .shell && state.status != .awaitingInput))
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

    /// Was R1 + Kreuz tut (Runde 5, R1; seit 13.11.2026 auf Wunsch des
    /// Nutzers fest „Jetzt senden“, ohne Raten am Feldinhalt):
    /// - Claude: immer „Jetzt senden“ (Ctrl+X Ctrl+S, wie Ctrl+Enter). Claude
    ///   schickt damit den Entwurf sofort ab bzw. die Warteschlange; bei
    ///   leerem Feld passiert nichts. Früher entschied die Erkennung des
    ///   Feldinhalts zwischen „Senden“, „Jetzt senden“ und „Weiter“ — lag sie
    ///   daneben, tippte R1 + Kreuz „Weiter“ in einen fertigen Prompt.
    /// - Codex, Text im Feld, Chat ruht: Enter. Arbeitet Codex, „geht nicht“:
    ///   Codex meldet nie „wartet“, Enter könnte eine Freigabe bestätigen
    ///   (Review Runde 5, Befund 2). Steht nur ein mit ↑ zurückgeholter Prompt
    ///   im Feld, „geht nicht“ (Befund 3).
    /// - Codex, Feld leer, Chat ruht: „Weiter“ wie bisher (`.continueWork`).
    /// Nie in einer offenen Rückfrage oder bei offener Ansicht (`nil`; dort
    /// gilt die bisherige Regel, also aus) und nie in Shells (`.continueWork`
    /// mit den bisherigen Regeln).
    static func crossAction(
        profile: ControllerChatState.Profile?, busy: Bool, dialogOpen: Bool, viewOpen: Bool,
        fieldHasText: Bool, queuedOwnPrompts: Int, onlyRecalledPrompt: Bool = false
    ) -> ControllerQuickDrawCross? {
        guard !dialogOpen, !viewOpen else { return nil }
        switch profile {
        case .claude:
            return .sendNow
        case .codex:
            if busy { return nil }
            if fieldHasText, onlyRecalledPrompt { return nil }
            return fieldHasText ? .send : .continueWork
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
        /// Das Fenster zeigt die Tickets: Die Chat-Raute wirkt erst auf den
        /// Board-Chat (WM8-113); bis dahin ist sie aus (WM8-91).
        case noBoardChat
    }

    var enabled: Set<ControllerMenuItem>
    var note: Note?
    /// Gerade gedrückt (kurze Markierung vor dem Schließen).
    var hit: ControllerMenuItem?

    // Insel-Paket: zweite Raute, Kopf mit Konto, Limits-Karte
    /// Stand der App-Schalter (Glocke, Wach bleiben).
    var app = ControllerAppToggles()
    /// Nach einem Schalter: was jetzt gilt und was der nächste Druck bringt.
    var confirmation: ControllerToggleConfirmation?
    /// Gerade gedrücktes Feld der App-Raute (kurze Markierung).
    var appHit: ControllerAppSlot?
    /// Konto des Ziel-Chats mit 5-Stunden-Stand für den Kopf.
    var account: ControllerIslandAccountBadge?
    /// Offene Limits-Karte (R1 + ▲); statt der Rauten, bis R1 losgelassen ist.
    var card: ControllerLimitsCard?

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

    /// Neu nach den Regeln aus `setup` (Rückfrage, Chat arbeitet), alles
    /// andere bleibt: App-Raute, Bestätigung, Konto, Karte.
    func refreshed(setup: ControllerMenuSetup) -> ControllerQuickDrawSlots {
        var fresh = ControllerQuickDrawSlots(setup: setup, hit: hit)
        fresh.app = app
        fresh.confirmation = confirmation
        fresh.appHit = appHit
        fresh.account = account
        fresh.card = card
        return fresh
    }
}

/// Womit die Insel bedient wird: Controller (Ebenen-Tasten) oder Tastatur
/// (⌥Tab, WM8-104). Dieselbe Insel, dieselben Wege; nur Kopf und Fußzeile
/// zeigen Tastenkappen statt Controller-Zeichen.
enum ControllerIslandInput: String, Sendable {
    case controller, keyboard
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
    var input: ControllerIslandInput = .controller
    /// Nur per Tastatur: Tastenzeile, Schalter, Karte, Spickzettel (Paket 2).
    var keyboard: ControllerKeyboardCommands?

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
