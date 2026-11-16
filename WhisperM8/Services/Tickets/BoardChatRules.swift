import Foundation

/// Ein Chat, der als Board-Chat in Frage kommt. Nur die Felder, die die
/// Regeln brauchen, damit sie ohne App-Zustand prüfbar bleiben.
struct BoardChatCandidate: Equatable {
    var id: UUID
    var title: String
    /// Projekt in der Anzeige: Arbeitsordner zählen zum Haupt-Projekt (WM8-102).
    var projectID: UUID
    var isRunning: Bool
    var lastActivityAt: Date
    var isArchived: Bool
    /// Nur echte Agent-Chats kommen in Frage (`BoardChatRules.acceptsKind`).
    var kind: AgentSessionKind = .chat
}

/// Warum ein Chat nicht Board-Chat werden kann.
enum BoardChatRejection: Equatable {
    /// Terminal-Tab, `claude agents`, Subagent-Job: In eine Shell gingen
    /// Zeilenumbrüche aus Bezug und Triage als Return, Ticket-Text liefe als Befehl.
    case notAgentChat
    case archived
    /// Arbeitet in einem anderen Projekt als das Board.
    case otherProject
    /// Gruppe aus der Tab-Leiste statt eines einzelnen Chats.
    case group
}

/// Wo der Board-Chat gerade lebt, von diesem Fenster aus gesehen. Ein Chat
/// lebt immer in genau einem Fenster: Sein Terminal hängt nur dort, wo er
/// ein Tab ist (dieselbe Regel wie im Raster).
enum BoardChatPlacement: Equatable {
    /// Tab dieses Fensters: Die Spalte zeigt sein Terminal.
    case here
    /// Tab eines anderen Fensters. `number` zählt wie die Fenster selbst:
    /// das Hauptfenster ist 1, die weiteren folgen in ihrer Reihenfolge.
    case otherWindow(number: Int, windowID: UUID)
    /// In keinem Fenster offen.
    case notOpen
}

/// Regeln der Seitenspalte „Board-Chat“ im Ticket-Modus (WM8-113). Pur:
/// Auswahl, Ort und Breite, ohne Fenster, Terminal oder Platte.
enum BoardChatRules {
    // MARK: Welcher Chat

    /// Der Jarvis eines Projekts: Titel beginnt mit „Jarvis“. Dieselbe Regel,
    /// mit der `tickets board` Supervisor zeigt und `tickets status` „erledigt“
    /// erlaubt. Eine eigene Regel in der App fände früher oder später einen
    /// anderen Jarvis als die CLI.
    static func isJarvis(title: String) -> Bool {
        TicketBoardBuilder.isSupervisor(title: title)
    }

    /// Nur interaktive Agent-Chats (Claude, Codex) und einzelne Hintergrund-
    /// Agents, die in einer Agent-TUI laufen.
    static func acceptsKind(_ kind: AgentSessionKind) -> Bool {
        kind == .chat || kind == .backgroundChat
    }

    /// Darf dieser Chat Board-Chat des Projekts sein? Gilt beim Hineinziehen
    /// und beim Lesen einer gespeicherten Wahl (die Datei kann eine alte enthalten).
    static func rejection(kind: AgentSessionKind, isArchived: Bool, projectID: UUID, boardProjectID: UUID,
                          groupSize: Int = 1) -> BoardChatRejection? {
        if groupSize > 1 { return .group }
        if !acceptsKind(kind) { return .notAgentChat }
        if isArchived { return .archived }
        if projectID != boardProjectID { return .otherProject }
        return nil
    }

    /// Automatisch gewählter Board-Chat: der Jarvis des Projekts. Laufende
    /// vor ruhenden, dann der zuletzt aktive; bei Gleichstand entscheidet die
    /// ID, damit die Wahl nicht zwischen zwei Chats springt.
    static func automaticJarvis(in candidates: [BoardChatCandidate], projectID: UUID) -> UUID? {
        candidates
            .filter { $0.projectID == projectID && !$0.isArchived && acceptsKind($0.kind) && isJarvis(title: $0.title) }
            .min(by: ranksBefore)?
            .id
    }

    /// Der Produkt-Chat: Titel enthält „Produkt“ (oder „Product“) und ist
    /// kein Jarvis. Er steht als zweiter Knopf im Kopf der Spalte.
    static func isProduct(title: String) -> Bool {
        guard !isJarvis(title: title) else { return false }
        // Ganzes Wort: „Produktion“ und „Production-Fix“ sind keine Produkt-Chats.
        return title.range(of: #"\b(produkt|product)\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func automaticProduct(in candidates: [BoardChatCandidate], projectID: UUID) -> UUID? {
        candidates
            .filter { $0.projectID == projectID && !$0.isArchived && acceptsKind($0.kind) && isProduct(title: $0.title) }
            .min(by: ranksBefore)?
            .id
    }

    /// Knöpfe im Kopf: der Jarvis, der Produkt-Chat, und ein von Hand
    /// hineingezogener Chat, wenn er keiner von beiden ist. Gewählt ist der
    /// Chat, der in der Spalte steht.
    static func choices(jarvis: BoardChatChoice.Chat?, product: BoardChatChoice.Chat?, chosen: BoardChatChoice.Chat?,
                        current: UUID?) -> [BoardChatChoice] {
        var result: [BoardChatChoice] = []
        func add(_ chat: BoardChatChoice.Chat?, _ kind: BoardChatChoice.Kind) {
            guard let chat, !result.contains(where: { $0.id == chat.id }) else { return }
            result.append(BoardChatChoice(id: chat.id, name: chat.name, title: chat.title, kind: kind, isSelected: chat.id == current))
        }
        add(jarvis, .jarvis)
        add(product, .product)
        add(chosen, .other)
        return result
    }

    /// Gespeicherte Wahl nach einem Klick auf einen Knopf oder einem
    /// hineingezogenen Chat: Der automatische Jarvis heißt „keine Wahl“, damit
    /// ein neuer Jarvis später von selbst übernimmt.
    static func storedChoice(after pick: UUID, automaticJarvis: UUID?) -> UUID? {
        pick == automaticJarvis ? nil : pick
    }

    private static func ranksBefore(_ lhs: BoardChatCandidate, _ rhs: BoardChatCandidate) -> Bool {
        if lhs.isRunning != rhs.isRunning { return lhs.isRunning }
        if lhs.lastActivityAt != rhs.lastActivityAt { return lhs.lastActivityAt > rhs.lastActivityAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    // MARK: Wo er steht

    /// - Parameters:
    ///   - hostWindowID: Fenster, in dem der Chat ein Tab ist (`nil`: keins).
    ///   - windowOrder: alle Fenster, das Hauptfenster zuerst.
    static func placement(windowID: UUID, hostWindowID: UUID?, windowOrder: [UUID]) -> BoardChatPlacement {
        guard let hostWindowID else { return .notOpen }
        if hostWindowID == windowID { return .here }
        let number = (windowOrder.firstIndex(of: hostWindowID) ?? windowOrder.count) + 1
        return .otherWindow(number: number, windowID: hostWindowID)
    }

    // MARK: Breite

    static let defaultWidth: Double = 380
    static let minimumWidth: Double = 280
    static let maximumWidth: Double = 720
    /// In der Triage stehen schon drei Spalten (Liste, Ticket, Eigenschaften);
    /// mit dem Board-Chat sind es vier. Die Spalte wird dort schmaler.
    static let triageMaximumWidth: Double = 330
    /// So viel Platz behält das Board mindestens neben der Spalte.
    static let boardMinimumWidth: Double = 420
    /// Breite der zugeklappten Spalte.
    static let collapsedWidth: Double = 34

    /// Breite, mit der die Spalte gezeigt wird.
    /// - Parameters:
    ///   - stored: vom Nutzer gezogene Breite, `nil` = Vorgabe.
    ///   - available: Breite des ganzen Bereichs (Board plus Spalte).
    static func width(stored: Double?, isTriage: Bool, available: Double) -> Double {
        var width = clamped(stored ?? defaultWidth)
        if isTriage { width = min(width, triageMaximumWidth) }
        // Das Board behält seinen Platz; die Spalte gibt nach, aber nie unter
        // ihre Mindestbreite (dann wird das Fenster eben eng).
        if available > 0 { width = min(width, max(minimumWidth, available - boardMinimumWidth)) }
        return width.rounded()
    }

    static func clamped(_ width: Double) -> Double {
        min(maximumWidth, max(minimumWidth, width))
    }

    /// Neue Breite nach einem Zug am linken Rand: nach links ziehen macht die
    /// Spalte breiter.
    static func draggedWidth(from start: Double, translation: Double, available: Double) -> Double {
        var width = clamped(start - translation)
        if available > 0 { width = min(width, max(minimumWidth, available - boardMinimumWidth)) }
        return width.rounded()
    }
}

/// Ein Knopf im Kopf der Spalte.
struct BoardChatChoice: Equatable, Identifiable {
    struct Chat: Equatable {
        var id: UUID
        var name: String
        var title: String
    }

    enum Kind: Equatable {
        case jarvis
        case product
        /// Von Hand hineingezogen.
        case other
    }

    var id: UUID
    /// Rufname auf dem Knopf.
    var name: String
    /// Ganzer Titel für Hilfe und Bedienungshilfen.
    var title: String
    var kind: Kind
    var isSelected: Bool
}

