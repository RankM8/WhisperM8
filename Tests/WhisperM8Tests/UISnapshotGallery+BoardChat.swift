import SwiftUI
@testable import WhisperM8

/// Fixtures der Seitenspalte „Board-Chat“ (WM8-113): Board und Triage mit
/// dem Chat rechts, dazu die Hinweise, wenn er nicht hier steht. Das Terminal
/// ist nachgestellt (Text), alle Inhalte stammen aus WM8 oder sind erfunden.
extension UISnapshotGallery {
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

        func screen(_ board: String, state: BoardChatColumnState, triage: Bool = false, collapsed: Bool = false,
                    width: Double? = nil) -> AnyView {
            AnyView(BoardChatSplit {
                base(board)
            } column: { available in
                Group {
                    if collapsed {
                        BoardChatCollapsedRail(title: state.title, expand: {}) { dot(AgentTheme.statusWorking) }
                    } else {
                        BoardChatColumnView(state: state, actions: .none, statusDot: { dot(AgentTheme.statusWorking) }) {
                            Text(terminalText)
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(AgentTheme.textPrimary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        }
                    }
                }
                .modifier(BoardChatColumnFrame(isTriage: { triage }, storedWidth: width, isCollapsed: collapsed,
                                               available: available, setWidth: { _ in }))
            }
            .background(AgentTheme.background))
        }

        let jarvis = BoardChatColumnState(title: "Jarvis: Supervisor WhisperM8", isAutomatic: true, content: .terminal)
        let size = CGSize(width: 1500, height: 860)
        return [
            Fixture(name: "tickets-board-chat", size: size) { screen("tickets-board", state: jarvis) },
            // Triage: vier Spalten, der Board-Chat wird schmaler (330 pt).
            Fixture(name: "tickets-board-chat-triage", size: size) {
                screen("tickets-triage", state: jarvis, triage: true)
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
        ]
    }
}
