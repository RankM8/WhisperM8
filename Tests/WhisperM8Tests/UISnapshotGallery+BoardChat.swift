import SwiftUI
@testable import WhisperM8

/// Fixtures der Seitenspalte „Board-Chat“ (WM8-113): Board und Triage mit
/// dem Chat rechts, dazu die Hinweise, wenn er nicht hier steht. Das Terminal
/// ist nachgestellt (Text), alle Inhalte stammen aus WM8 oder sind erfunden.
extension UISnapshotGallery {
    /// Fenster der Bilder mit Board-Chat (Triage-Knopf „→ Jarvis“, Bezug).
    static let boardChatSnapshotWindowID = UUID(uuidString: "00000000-0000-4000-8000-0000000000b1")!

    @MainActor
    static func boardChatFixtures() -> [Fixture] {
        let boards = ticketBoardFixtures()
        func base(_ name: String) -> AnyView { boards.first { $0.name == name }!.view() }

        let terminalText = """
        ❯ Was ist bei WM8 gerade offen für mich?

        ⏺ WM8 heute, 16.11.
          Abnahme: WM8-86 (Entscheidung festhalten)
          ist merge-bereit, der Abschluss mit den
          Schritten für den Handtest steht am Ticket.
          Entscheidungen bei dir: WM8-84, WM8-57.

        ❯ Erst die Abnahme.

        ⏺ WM8-86 liegt links groß. Sag mir je
          Schritt: bestanden oder nicht.

        ────────────────────────────────────────
        ❯ \u{2009}
        ────────────────────────────────────────
          ⏵⏵ accept edits on · 1 background task
        """

        func dot(_ color: Color) -> some View {
            Circle().fill(color).frame(width: 7, height: 7)
        }

        // Eingaben wie in der App: Board-Chat des Fensters angemeldet, Triage zeigt WM8-81.
        let window = boardChatSnapshotWindowID
        let ticket = BoardChatTicket(key: "WM8-81", title: "Ticket-Board in der App, Stufe 1",
                                     url: "https://linear.app/whisperm8/issue/WM8-81")
        func inputs(notice: String? = nil) -> BoardChatInputs {
            let inputs = BoardChatInputs()
            inputs.register(windowID: window, sessionID: UUID(), name: "Jarvis")
            inputs.shownTicket = { _ in ticket }
            if let notice { inputs.showNoticeForSnapshot(notice, in: window) }
            return inputs
        }
        func inputBar(notice: String? = nil) -> AnyView {
            AnyView(BoardChatInputBar(windowID: window, inputs: inputs(notice: notice)))
        }

        let collectedText = """
        ❯ Erst die Abnahme.

        ⏺ WM8-86 liegt links groß. Sag mir je
          Schritt: bestanden oder nicht.

        ────────────────────────────────────────
        ❯ Triage in WM8, bitte ausführen:
          - WM8-69 „Chats am Nutzungslimit …“
            https://linear.app/whisperm8/issue/WM8-69:
            annehmen
          - WM8-12 „Neustart ohne Chatverlust …“
            https://linear.app/whisperm8/issue/WM8-12:
            später, in zwei Wochen wieder vorlegen
        ────────────────────────────────────────
        """

        func screen(_ board: String, state: BoardChatColumnState, triage: Bool = false, collapsed: Bool = false,
                    width: Double? = nil, inputBar: AnyView? = nil, terminal: String? = nil) -> AnyView {
            AnyView(BoardChatSplit {
                base(board)
            } column: { available in
                Group {
                    if collapsed {
                        BoardChatCollapsedRail(title: state.title, expand: {}) { dot(AgentTheme.statusWorking) }
                    } else {
                        BoardChatColumnView(state: state, actions: .none, inputBar: inputBar,
                                            statusDot: { dot(AgentTheme.statusWorking) }) {
                            Text(terminal ?? terminalText)
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(AgentTheme.textPrimary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        }
                    }
                }
                .modifier(BoardChatColumnFrame(storedWidth: width, isCollapsed: collapsed,
                                               available: available, setWidth: { _ in }))
            }
            .background(AgentTheme.background))
        }

        let jarvisChoice = BoardChatChoice.Chat(id: UUID(), name: "Jarvis", title: "Jarvis: Supervisor WhisperM8")
        let productChoice = BoardChatChoice.Chat(id: UUID(), name: "Pia", title: "Pia · Produkt WM8 (Beispiel)")
        let vicChoice = BoardChatChoice.Chat(id: UUID(), name: "Vic", title: "Vic · Prüfer: Insel Paket 2")
        let jarvis = BoardChatColumnState(title: "Jarvis: Supervisor WhisperM8", isAutomatic: true, content: .terminal)
        let size = CGSize(width: 1500, height: 860)
        return [
            Fixture(name: "tickets-board-chat", size: size) { screen("tickets-board", state: jarvis) },
            // Triage mit Board-Chat ab Werk (40 %): mittleres Fenster, Eigenschaften als Zeile im Kopf.
            Fixture(name: "tickets-board-chat-triage", size: size) {
                screen("tickets-triage", state: jarvis, triage: true)
            },
            // Breites Fenster: Liste, Ticket und Eigenschaften-Spalte neben dem Board-Chat.
            Fixture(name: "tickets-board-chat-triage-breit", size: CGSize(width: 1900, height: 900)) {
                screen("tickets-triage", state: jarvis, triage: true)
            },
            // Schmales Fenster: nur das Ticket, Eigenschaften als Zeile.
            Fixture(name: "tickets-board-chat-triage-schmal", size: CGSize(width: 1000, height: 760)) {
                screen("tickets-triage", state: jarvis, triage: true)
            },
            // Weit gezogen: Das Board behält 420 pt.
            Fixture(name: "tickets-board-chat-weit-gezogen", size: size) {
                screen("tickets-board", state: jarvis, width: 1400)
            },
            Fixture(name: "tickets-board-chat-fenster-2", size: size) {
                screen("tickets-board", state: BoardChatColumnState(title: "Jarvis: Supervisor WhisperM8", isAutomatic: true,
                                                                   content: .otherWindow(number: 2)))
            },
            Fixture(name: "tickets-board-chat-nicht-offen", size: size) {
                screen("tickets-board", state: BoardChatColumnState(title: "Jarvis: Supervisor WhisperM8", isAutomatic: true,
                                                                   content: .notOpen))
            },
            Fixture(name: "tickets-board-chat-ruht", size: size) {
                screen("tickets-board", state: BoardChatColumnState(title: "Jarvis: Supervisor WhisperM8", isAutomatic: true,
                                                                   content: .terminal, isRunning: false))
            },
            Fixture(name: "tickets-board-chat-kein-jarvis", size: size) {
                screen("tickets-board", state: BoardChatColumnState(title: nil, isAutomatic: true, content: .noChat))
            },
            Fixture(name: "tickets-board-chat-zugeklappt", size: size) {
                screen("tickets-board", state: jarvis, collapsed: true)
            },
            Fixture(name: "tickets-board-chat-schmales-fenster", size: CGSize(width: 900, height: 700)) {
                screen("tickets-board", state: jarvis, width: 600)
            },
            // Teil c: Knöpfe für Jarvis und den Produkt-Chat, dazu ein hineingezogener Chat.
            Fixture(name: "tickets-board-chat-wahl", size: size) {
                var state = jarvis
                state.choices = BoardChatRules.choices(jarvis: jarvisChoice, product: productChoice, chosen: nil, current: jarvisChoice.id)
                return screen("tickets-board", state: state)
            },
            Fixture(name: "tickets-board-chat-wahl-gezogen", size: size) {
                var state = BoardChatColumnState(title: "Vic · Prüfer: Insel Paket 2", isAutomatic: false, content: .terminal)
                state.choices = BoardChatRules.choices(jarvis: jarvisChoice, product: productChoice, chosen: vicChoice, current: vicChoice.id)
                return screen("tickets-triage", state: state, triage: true)
            },
            // Teil d: Triage-Knöpfe, gesammelte Entscheidungen an den Zeilen und im Eingabefeld.
            Fixture(name: "tickets-board-chat-gesammelt", size: size) {
                let shared = BoardChatInputs.shared
                let board = UUID()
                shared.register(windowID: window, sessionID: board, name: "Jarvis")
                shared.triageBatches[window] = TriageBatch(sessionID: board, decisions: ["WM8-69": .accept, "WM8-12": .later])
                return screen("tickets-triage-mit-fenster", state: jarvis, triage: true, terminal: collectedText)
            },
            // Teil b: „→ Jarvis“ oben in der Triage, Bezug unter dem Terminal.
            Fixture(name: "tickets-board-chat-bezug", size: size) {
                BoardChatInputs.shared.register(windowID: window, sessionID: UUID(), name: "Jarvis")
                return screen("tickets-triage-mit-fenster", state: jarvis, triage: true, inputBar: inputBar())
            },
            Fixture(name: "tickets-board-chat-nichts-eingefuegt", size: size) {
                BoardChatInputs.shared.register(windowID: window, sessionID: UUID(), name: "Jarvis")
                return screen("tickets-triage-mit-fenster", state: jarvis, triage: true,
                              inputBar: inputBar(notice: BoardChatInputRules.message(.awaitingInput, chatName: "Jarvis")))
            },
            // WM8-124 Paket 2: „← Chats · WM8 Aktiv“ auch im schmalen Board.
            Fixture(name: "tickets-board-chat-kopf-board-schmal", size: CGSize(width: 1000, height: 760)) {
                screen("tickets-board", state: jarvis)
            },
        ]
    }
}
