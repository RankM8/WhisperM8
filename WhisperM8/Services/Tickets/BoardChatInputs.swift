import AppKit
import Foundation
import Observation

/// Ein Ticket, wie es an den Board-Chat geht: Nummer, Titel, Adresse. Nie
/// die Beschreibung: Ticket-Text stammt von anderen und ist Daten, keine
/// Anweisung an einen Chat.
struct BoardChatTicket: Equatable {
    var key: String
    var title: String
    var url: String?

    init(key: String, title: String, url: String?) {
        self.key = key
        self.title = title
        self.url = url
    }

    init(_ ticket: Ticket) {
        self.init(key: ticket.key, title: ticket.title, url: TicketCopyText.safeURL(ticket))
    }
}

/// Texte für das Eingabefeld des Board-Chats. Pur.
enum BoardChatText {
    /// `WM8-81 „Titel“ https://…`, eine Zeile, Titel ohne Steuerzeichen.
    static func ticketLine(_ ticket: BoardChatTicket) -> String {
        let head = "\(ticket.key) „\(shortTitle(ticket.title))“"
        return ticket.url.map { "\(head) \($0)" } ?? head
    }

    /// Titel ohne Steuerzeichen, höchstens etwa 200 Zeichen: Ein sehr langer
    /// Titel aus Linear soll das Eingabefeld nicht füllen.
    static let maximumTitleLength = 200
    static func shortTitle(_ title: String) -> String {
        let flat = TicketCopyText.flat(title)
        guard flat.count > maximumTitleLength else { return flat }
        return String(flat.prefix(maximumTitleLength - 1)) + "…"
    }

    /// „→ Jarvis“: das Ticket ins Feld, mit Leerzeichen, damit Giuliano
    /// gleich weiterschreiben kann.
    static func handOff(_ ticket: BoardChatTicket) -> String {
        ticketLine(ticket) + " "
    }

    /// Rufname aus dem Titel: „Jarvis: Supervisor WhisperM8“ → „Jarvis“,
    /// „Pia · Produkt“ → „Pia“.
    static func callName(_ title: String) -> String {
        let flat = TicketCopyText.flat(title)
        let head = flat.components(separatedBy: " · ").first ?? flat
        let name = (head.components(separatedBy: ":").first ?? head).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return flat.isEmpty ? String(localized: "Board chat") : flat }
        return name.count > 24 ? String(name.prefix(23)) + "…" : name
    }

    /// Bezug vor der nächsten Nachricht.
    static func referencePrefix(_ ticket: BoardChatTicket) -> String {
        String(localized: "Re:") + " " + ticketLine(ticket) + "\n"
    }
}

/// Was der Board-Chat gerade annimmt. Dieselben Regeln wie beim Diktat in
/// einen Chat und bei `chats send` (WM8-67/75/107): Bei offener Frage oder
/// Freigabe, beim Hochfahren und am Nutzungslimit kommt nichts hinein.
enum BoardChatInputRules {
    enum Refusal: Equatable {
        case noBoardChat
        case awaitingInput
        case starting
        case usageLimited
        case notRunning
    }

    static func refusal(state: DictationChatState, approvalPending: Bool) -> Refusal? {
        if approvalPending { return .awaitingInput }
        switch state {
        case .ready: return nil
        case .awaitingInput, .questionAcceptsText: return .awaitingInput
        case .starting: return .starting
        case .usageLimited: return .usageLimited
        case .notRunning: return .notRunning
        }
    }

    static func message(_ rejection: BoardChatRejection, chatName: String, projectName: String) -> String {
        switch rejection {
        case .notAgentChat: return String(localized: "Only agent chats can be the board chat, not a terminal or a subagent.")
        case .archived: return String(localized: "Archived chats can't be the board chat.")
        case .otherProject: return String(localized: "\(chatName) works in another project. The board chat must belong to \(projectName).")
        case .group: return String(localized: "Drag a single chat, not a group.")
        }
    }

    static func message(_ refusal: Refusal, chatName: String) -> String {
        switch refusal {
        case .noBoardChat: return String(localized: "No board chat is shown here.")
        case .awaitingInput: return String(localized: "\(chatName) is waiting for your answer. Nothing was added.")
        case .starting: return String(localized: "\(chatName) is still starting. Nothing was added.")
        case .usageLimited: return String(localized: "\(chatName)'s account has reached its usage limit. Nothing was added.")
        case .notRunning: return String(localized: "\(chatName) isn't running. Nothing was added.")
        }
    }
}

/// Eingaben an den Board-Chat (WM8-113, Teil b): Wohin das Diktat geht,
/// welcher Bezug davorsteht und was „→ Jarvis“ ins Eingabefeld legt.
///
/// Grundsatz: Nichts geht an einen Chat, den Giuliano nicht sieht. Ein
/// Fenster meldet seinen Board-Chat nur an, solange die Spalte ihn zeigt
/// (Ticket-Modus, aufgeklappt, Tab dieses Fensters). Die App legt Text nur ins
/// Eingabefeld; abgeschickt wird mit Giulianos Enter.
@MainActor
@Observable
final class BoardChatInputs {
    static let shared = BoardChatInputs()

    struct Registration: Equatable {
        var sessionID: UUID
        /// Rufname für Knöpfe und Hinweise („Jarvis“).
        var name: String
        /// Gehört der anmeldenden Ansicht; nur sie meldet wieder ab.
        var token: UUID = UUID()
    }

    /// Kurzer Hinweis in der Spalte, warum nichts eingefügt wurde.
    struct Notice: Equatable {
        var id = UUID()
        var text: String
    }

    private(set) var registrations: [UUID: Registration] = [:]
    /// Bezug, den Giuliano mit ✕ weggenommen hat (Ticket-Nummer je Fenster).
    private(set) var dismissedReference: [UUID: String] = [:]
    /// Bezug, der schon mitgegangen ist (Ticket-Nummer je Fenster).
    private(set) var usedReference: [UUID: String] = [:]
    var notices: [UUID: Notice] = [:]
    /// Sammelauftrag der Triage je Fenster (Teil d). Gehört zu genau einem
    /// Board-Chat: Wechselt der Chat, beginnt ein neuer Auftrag.
    var triageBatches: [UUID: TriageBatch] = [:]
    /// Wann zuletzt gesammelt wurde (Sperre gegen Doppelklick).
    @ObservationIgnored var lastDecisionAt: [UUID: Date] = [:]

    // MARK: Abhängigkeiten (Tests ersetzen sie)

    @ObservationIgnored var keyWindowID: () -> UUID? = { AgentWindowStore.shared.keyAgentChatWindowID }
    /// Das Ticket, das die Triage dieses Fensters gerade zeigt.
    @ObservationIgnored var shownTicket: (UUID) -> BoardChatTicket? = { windowID in
        let model = TicketBoardControllers.shared.controller(for: windowID).viewModel
        guard let key = model.triage?.current, let entry = model.presentation.entry(key: key) else { return nil }
        return BoardChatTicket(entry.ticket)
    }
    @ObservationIgnored var ticketForKey: (UUID, String) -> BoardChatTicket? = { windowID, key in
        TicketBoardControllers.shared.controller(for: windowID).viewModel.presentation.entry(key: key).map { BoardChatTicket($0.ticket) }
    }
    @ObservationIgnored var chatState: (UUID) -> DictationChatState = { LiveDictationChatWriter().state(of: $0) }
    @ObservationIgnored var approvalPending: (UUID) -> Bool = { sessionID in
        guard let controller = AgentTerminalRegistry.shared.controller(for: sessionID) else { return false }
        return AgentControlRequestHandler.approvalPending(sessionID, controller)
    }
    /// Ins Eingabefeld, ohne Enter.
    @ObservationIgnored var insert: (String, UUID) -> Bool = { text, sessionID in
        LiveDictationChatWriter().write(text, to: sessionID, submit: false)
    }
    /// Steht im Eingabefeld noch ungesendeter Text (Schätzung wie bei `chats send`)?
    @ObservationIgnored var hasUnsentInput: (UUID) -> Bool = { sessionID in
        AgentTerminalRegistry.shared.controller(for: sessionID)?.composerDraft.mayHaveUnsentInput ?? false
    }
    /// Was der Bildschirm über das Eingabefeld sagt (wie die Warteschlange).
    @ObservationIgnored var fieldVisibility: (UUID) -> BoardChatFieldVisibility = { sessionID in
        guard let controller = AgentTerminalRegistry.shared.controller(for: sessionID) else { return .unknown }
        let profile = controller.command.keyboardProfile
        let field = controller.controllerScreenSnapshot()?.promptField
        if PromptSubmitCheck.fieldVisiblyEmpty(field: field, profile: profile) { return .empty }
        if PromptSubmitCheck.visibleDraft(field: field, profile: profile,
                                          clearsBeforeSubmit: controller.composerDraft.shouldClearBeforeSubmit) { return .hasText }
        return .unknown
    }
    @ObservationIgnored var now: () -> Date = { Date() }
    @ObservationIgnored var refuseSound: () -> Void = { NSSound.beep() }
    @ObservationIgnored var noticeSeconds: Double = 4

    // MARK: Anmelden

    func register(windowID: UUID, sessionID: UUID, name: String, token: UUID = UUID()) {
        let registration = Registration(sessionID: sessionID, name: name, token: token)
        guard registrations[windowID] != registration else { return }
        registrations[windowID] = registration
    }

    /// `token == nil`: ohne Rücksicht auf die anmeldende Ansicht (Fenster zu).
    func unregister(windowID: UUID, token: UUID? = nil) {
        guard let current = registrations[windowID], token == nil || current.token == token else { return }
        registrations[windowID] = nil
        notices[windowID] = nil
        triageBatches[windowID] = nil
        lastDecisionAt[windowID] = nil
    }

    /// Steht im Feld dieses Chats vermutlich schon Text (Entwurf, eingefügte
    /// Zeilen, offener Sammelauftrag)? Dann beginnt Neues auf eigener Zeile.
    func fieldProbablyHasText(_ sessionID: UUID, in windowID: UUID) -> Bool {
        switch fieldVisibility(sessionID) {
        case .empty: return false
        case .hasText: return true
        case .unknown: return hasUnsentInput(sessionID) || triageBatches[windowID]?.sessionID == sessionID
        }
    }

    func boardChat(in windowID: UUID) -> Registration? { registrations[windowID] }

    /// Steht dieser Chat gerade in einer Spalte?
    func isShown(_ sessionID: UUID) -> Bool { registrations.values.contains { $0.sessionID == sessionID } }

    // MARK: Diktat

    /// Ziel des Diktats: der Board-Chat des Fensters, das gerade vorn ist.
    /// `nil`, wenn dort keiner sichtbar ist; dann bleibt alles, wie es war.
    func dictationTarget() -> UUID? {
        guard let windowID = keyWindowID() else { return nil }
        return registrations[windowID]?.sessionID
    }

    /// Name für Pille und Insel, wenn das Diktat umgelenkt in den Board-Chat geht.
    func dictationLabel(for target: DictationDeliveryTarget) -> String? {
        guard case .boardChat(let sessionID) = target,
              let registration = registrations.values.first(where: { $0.sessionID == sessionID }) else { return nil }
        return registration.name
    }

    // MARK: Bezug

    /// Bezug, der vor der nächsten Nachricht steht: das Ticket der Triage,
    /// solange es nicht weggenommen und noch nicht mitgegangen ist.
    func reference(in windowID: UUID) -> BoardChatTicket? {
        guard registrations[windowID] != nil, let ticket = shownTicket(windowID),
              dismissedReference[windowID] != ticket.key, usedReference[windowID] != ticket.key else { return nil }
        return ticket
    }

    func dismissReference(in windowID: UUID) {
        guard let ticket = shownTicket(windowID) else { return }
        dismissedReference[windowID] = ticket.key
    }

    /// Für ein Diktat an `sessionID`: der Bezug als Vorspann und ein Abschluss,
    /// der ihn als mitgegangen markiert (nur nach erfolgreichem Schreiben).
    func referenceForDictation(to sessionID: UUID) -> (prefix: String, commit: () -> Void)? {
        guard let windowID = registrations.first(where: { $0.value.sessionID == sessionID })?.key,
              let ticket = reference(in: windowID) else { return nil }
        let lead = fieldProbablyHasText(sessionID, in: windowID) ? "\n" : ""
        return (lead + BoardChatText.referencePrefix(ticket), { [weak self] in self?.usedReference[windowID] = ticket.key })
    }

    // MARK: „→ Jarvis“

    /// Legt Nummer, Titel und Adresse ins Eingabefeld des Board-Chats;
    /// abgeschickt wird erst mit Giulianos Enter. Den Tastaturfokus bekommt das
    /// Terminal nur durch einen Klick hinein (`BoardChatFocusRule`), nicht von hier.
    /// `key == nil`: das Ticket der Triage.
    @discardableResult
    func handOff(key: String? = nil, in windowID: UUID) -> Bool {
        guard let registration = registrations[windowID] else {
            refuse(.noBoardChat, in: windowID, name: "")
            return false
        }
        guard let ticket = key.map({ ticketForKey(windowID, $0) }) ?? shownTicket(windowID) else { return false }
        let sessionID = registration.sessionID
        if let refusal = BoardChatInputRules.refusal(state: chatState(sessionID), approvalPending: approvalPending(sessionID)) {
            refuse(refusal, in: windowID, name: registration.name)
            return false
        }
        let lead = fieldProbablyHasText(sessionID, in: windowID) ? "\n" : ""
        guard insert(lead + BoardChatText.handOff(ticket), sessionID) else {
            refuse(.notRunning, in: windowID, name: registration.name)
            return false
        }
        // Das Ticket steht jetzt im Feld; derselbe Bezug davor wäre doppelt.
        usedReference[windowID] = ticket.key
        notices[windowID] = nil
        return true
    }

    /// Hinweis ohne Ablauf, nur für Bilder.
    func showNoticeForSnapshot(_ text: String, in windowID: UUID) {
        notices[windowID] = Notice(text: text)
    }

    func refuse(_ refusal: BoardChatInputRules.Refusal, in windowID: UUID, name: String) {
        showNotice(BoardChatInputRules.message(refusal, chatName: name), in: windowID)
    }

    /// Warnton und ein Satz unter dem Terminal, der nach einigen Sekunden geht.
    func showNotice(_ text: String, in windowID: UUID) {
        refuseSound()
        let notice = Notice(text: text)
        notices[windowID] = notice
        let seconds = noticeSeconds
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, self.notices[windowID]?.id == notice.id else { return }
            self.notices[windowID] = nil
        }
    }
}
