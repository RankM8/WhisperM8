import SwiftUI

/// Reiter „Tickets“ in „Wohin“ (WM8-91): je Team mit Projekt eine Zeile mit
/// Kürzel, Projekt und der Zahl „wartet auf dich“, dazu „hier“, „jetzt“ und
/// „vorher“ als Wort, nie nur als Farbe.
extension ControllerIslandView {
    @ViewBuilder
    func ticketBoards(_ state: ControllerWhereToState) -> some View {
        ForEach(state.tickets.visibleRows) { board in
            ticketBoardRow(board, marked: board.id == state.tickets.selected?.id)
        }
        more(state.tickets.hiddenCount)
        if state.tickets.rows.isEmpty { empty(String(localized: "No team set up · Settings › Tickets")) }
    }

    /// Hinweis unter der Liste: Projekt ohne Team, oder was „hier“ heißt.
    func ticketsHint(_ state: ControllerWhereToState) -> String? {
        guard let boards = state.ticketBoards else { return nil }
        if let project = boards.hereWithoutTeam {
            return String(localized: "\(project) has no team · Settings › Tickets")
        }
        guard !boards.inTickets, boards.rows.contains(where: \.isHere) else { return nil }
        return String(localized: "“here” is the board of your chat's project. Releasing opens it, even without moving.")
    }

    private func ticketBoardRow(_ board: ControllerTicketBoardChoice, marked: Bool) -> some View {
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(hex: board.colorHex))
                .frame(width: 16, height: 16)
                .overlay {
                    Text(verbatim: String(board.team.prefix(1)).uppercased())
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundStyle(.white)
                }
            HStack(spacing: 6) {
                Text(verbatim: board.team)
                    .font(.system(size: 12.5, weight: board.isCurrent ? .bold : .semibold))
                    .foregroundStyle(palette.text)
                    .fixedSize()
                Text(verbatim: board.projectName)
                    .font(.system(size: 11))
                    .foregroundStyle(palette.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(-1)
            }
            Spacer(minLength: 8)
            if board.isCurrent {
                tag(String(localized: "now"), strong: true)
            } else if board.isHere {
                tag(String(localized: "here"), strong: true)
            } else if board.isPrevious {
                previousTag()
            }
            if let waiting = board.waitingCount {
                if waiting > 0 { IslandStatusDot(status: .awaiting) }
                Text(verbatim: waiting == 1
                     ? String(localized: "1 waiting for you") : String(localized: "\(waiting) waiting for you"))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(palette.tertiary)
                    .fixedSize()
            } else {
                // Ohne geladenen Stand dieses Boards: keine Zahl, nichts wird dafür abgerufen.
                Text(verbatim: "–")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.tertiary)
                    .accessibilityLabel(Text("Not loaded"))
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
        .islandMarking(marked, palette: palette)
        .accessibilityElement(children: .combine)
    }

    private func tag(_ text: String, strong: Bool) -> some View {
        Text(verbatim: text)
            .font(.system(size: 11, weight: strong ? .semibold : .regular))
            .foregroundStyle(strong ? palette.markBorder : palette.tertiary)
            .fixedSize()
    }

    /// Fußzeile im Reiter „Tickets“: R2 („hin + diktieren“) kommt mit dem
    /// Board-Chat und steht deshalb gedimmt da.
    func ticketsFooter() -> some View {
        IslandFlow(spacing: 12, lineSpacing: 5) {
            footItem("▲▼", String(localized: "select"))
            footItem("◀▶", String(localized: "tabs"))
            footItem(ControllerButton.l2.glyph(family), String(localized: "release: open"), round: false)
            footItem(ControllerButton.cross.glyph(family), String(localized: "open"))
            footItem(ControllerButton.circle.glyph(family), String(localized: "cancel"))
            footItem(ControllerButton.r2.glyph(family), String(localized: "go + dictate (with board chat)"), round: false)
                .opacity(0.45)
        }
        .font(.system(size: 11))
        .foregroundStyle(palette.secondary)
        .padding(.horizontal, 14)
        .padding(.top, 7)
        .padding(.bottom, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Rectangle().fill(palette.line).frame(height: 1) }
    }
}
