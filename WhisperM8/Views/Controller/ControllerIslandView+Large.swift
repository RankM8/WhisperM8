import SwiftUI

/// Die Controller-Insel als große Form an einer Kamera-Insel (Dynamic Island
/// der Hardware): EINE schwarze Fläche um die Kamera statt Hals mit Kasten,
/// wie Hinweis, Liste und Diktat dort (`NotchIslandLargeGeometry`). Die
/// Kopfzeile liegt auf Höhe der Kamera und lässt Apples Insel die Mitte;
/// „Wohin“ zeigt Kacheln in zwei Spalten, die das Steuerkreuz in beide
/// Richtungen abfährt, „Schreiben“ große Felder. Rauten, Limits-Karte und
/// Tastatur-Zeilen behalten ihren Inhalt und stehen in derselben Form.
extension ControllerIslandView {
    /// Platz unter dem Inhalt, damit er nicht in die runden Ecken läuft.
    static var largeBottomInset: CGFloat { 6 }

    var footerFontSize: CGFloat { display.isLarge ? 12.5 : 11 }
    /// Rand der Fußzeilen und Hinweise: in der großen Form weiter innen
    /// (runde Ecken mit 36 pt).
    var footerInset: CGFloat { display.isLarge ? NotchIslandLargeGeometry.padding + 2 : 14 }

    // MARK: Kopf

    /// Links der Kamera Taste und Ebene, rechts das Ziel (Chat, Zähler,
    /// Konto). Dazwischen bleibt frei, was Apples Insel gerade zeigt.
    @ViewBuilder
    var largeHeader: some View {
        if case .island(_, let metrics) = display.style {
            NotchIslandLargeHeader(width: display.bodyWidth, metrics: metrics) {
                HStack(spacing: 8) {
                    if display.model.input == .keyboard {
                        keyboardHeaderKeys
                    } else {
                        IslandGlyph(text: display.model.layer.key.glyph(family), round: false, palette: palette)
                    }
                    Text(verbatim: largeTitle)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(palette.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
            } trailing: {
                if let card = limitsCard {
                    limitsStatus(card)
                } else {
                    headerTarget
                }
            }
        }
    }

    private var largeTitle: String {
        if limitsCard != nil { return String(localized: "Limits") }
        if display.model.keyboard?.cheatSheet == true { return ControllerLayer.writing.title }
        return display.model.layer.title
    }

    // MARK: Bewegung

    /// Wächst aus der Kapsel um die Kamera und zieht sich in sie zurück:
    /// ein Umriss, der zwischen Kapsel und voller Form gleitet
    /// (`NotchIslandLargeShape`), wie bei Hinweis, Liste und Diktat.
    func largeReveal(_ band: NotchIslandBand) -> some View {
        GeometryReader { proxy in
            let open = NotchIslandLargeOutline(
                centerOffset: 0, top: 0, width: proxy.size.width, height: proxy.size.height,
                radius: NotchIslandLargeGeometry.cornerRadius)
            let closed = NotchIslandLargeOutline(
                centerOffset: 0, top: band.topGap, width: min(proxy.size.width, band.width),
                height: min(proxy.size.height, band.capsuleHeight), radius: band.capsuleHeight / 2)
            NotchIslandLargeShape(outline: revealed ? open : closed)
        }
    }

    // MARK: Wohin: Kacheln

    /// Zwei Spalten, Lesereihenfolge wie die Liste. Die Markierung ist hell
    /// gefüllt und umrandet; das Steuerkreuz bewegt sie in beide Richtungen
    /// (`ControllerWhereToState.moveRow`, `moveSideways`).
    @ViewBuilder
    func largeTiles(_ state: ControllerWhereToState) -> some View {
        VStack(spacing: 0) {
            switch state.tab {
            case .chats:
                tileGrid(Array(state.chats.visibleRows)) { row in
                    chatTile(row, marked: row.id == state.chats.selected?.id, previous: state.isPrevious(chat: row.id))
                }
                more(state.chats.hiddenCount)
                if state.chats.rows.isEmpty { empty(String(localized: "No chats")) }
            case .workspaces:
                tileGrid(Array(state.workspaces.visibleRows)) { choice in
                    workspaceTile(choice, marked: choice.id == state.workspaces.selected?.id,
                                  previous: state.isPrevious(choice))
                }
                more(state.workspaces.hiddenCount)
                if state.workspaces.rows.isEmpty { empty(String(localized: "No workspaces or projects")) }
            case .tickets:
                tileGrid(Array(state.tickets.visibleRows)) { board in
                    ticketTile(board, marked: board.id == state.tickets.selected?.id)
                }
                more(state.tickets.hiddenCount)
                if state.tickets.rows.isEmpty { empty(String(localized: "No team set up · Settings › Tickets")) }
            }
        }
        .padding(.horizontal, NotchIslandLargeGeometry.padding)
        .padding(.bottom, 8)
    }

    private func tileGrid<Row: Identifiable, Tile: View>(
        _ rows: [Row], @ViewBuilder tile: @escaping (Row) -> Tile
    ) -> some View {
        let pairs = stride(from: 0, to: rows.count, by: 2).map { Array(rows[$0..<min($0 + 2, rows.count)]) }
        return VStack(spacing: 8) {
            ForEach(Array(pairs.enumerated()), id: \.offset) { _, pair in
                HStack(spacing: 8) {
                    ForEach(pair) { row in tile(row) }
                    // Eine einzelne Kachel in der letzten Reihe bleibt halb breit.
                    if pair.count == 1 { Color.clear.frame(maxWidth: .infinity, maxHeight: 1) }
                }
            }
        }
    }

    private func chatTile(_ row: ControllerIslandChatRow, marked: Bool, previous: Bool) -> some View {
        tile(marked: marked) {
            IslandStatusDot(status: row.status).frame(width: 18)
        } title: {
            Text(verbatim: row.title)
                .font(.system(size: 14.5, weight: row.isCurrent ? .bold : .semibold))
        } detail: {
            HStack(spacing: 5) {
                if previous { previousTag() }
                Text(verbatim: row.detail).monospacedDigit().fixedSize()
                // Das Projekt nur, wo Platz ist: „vorher“ und der Stand gehen vor.
                if let project = row.project, !previous {
                    Text(verbatim: "· \(project)").layoutPriority(-1)
                }
            }
        }
    }

    private func workspaceTile(_ choice: ControllerWorkspaceChoice, marked: Bool, previous: Bool) -> some View {
        tile(marked: marked) {
            if choice.kind == .project {
                // Projekt wie in der Seitenleiste: Ordner in der Projektfarbe.
                Image(systemName: "folder.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Color(hex: choice.colorHex))
                    .frame(width: 18, height: 18)
            } else {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color(hex: choice.colorHex))
                    .frame(width: 18, height: 18)
                    .overlay {
                        Text(verbatim: String(choice.name.prefix(1)).uppercased())
                            .font(.system(size: 11.5, weight: .heavy))
                            .foregroundStyle(.white)
                    }
            }
        } title: {
            Text(verbatim: choice.name)
                .font(.system(size: 14.5, weight: choice.isCurrent ? .bold : .semibold))
        } detail: {
            HStack(spacing: 5) {
                if choice.isCurrent {
                    Text("current")
                } else if previous {
                    previousTag()
                }
                // Dasselbe Zeichen wie der Status-Punkt eines wartenden Chats.
                if choice.hasWaitingChat { IslandStatusDot(status: .awaiting) }
                Text(verbatim: choice.kind == .project
                     ? String(localized: "\(choice.chatCount) active") : ChatsUIStrings.chatCount(choice.chatCount))
                    .monospacedDigit()
            }
        }
    }

    private func ticketTile(_ board: ControllerTicketBoardChoice, marked: Bool) -> some View {
        tile(marked: marked) {
            RoundedRectangle(cornerRadius: 5)
                .fill(Color(hex: board.colorHex))
                .frame(width: 18, height: 18)
                .overlay {
                    Text(verbatim: String(board.team.prefix(1)).uppercased())
                        .font(.system(size: 11.5, weight: .heavy))
                        .foregroundStyle(.white)
                }
        } title: {
            HStack(spacing: 6) {
                Text(verbatim: board.team)
                    .font(.system(size: 14.5, weight: board.isCurrent ? .bold : .semibold))
                    .fixedSize()
                Text(verbatim: board.projectName)
                    .font(.system(size: 12))
                    .foregroundStyle(palette.tertiary)
                    .layoutPriority(-1)
            }
        } detail: {
            HStack(spacing: 5) {
                // „jetzt“, „hier“ und „vorher“ als Wort, nie nur als Farbe.
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
                        .monospacedDigit()
                } else {
                    // Ohne geladenen Stand dieses Boards: keine Zahl.
                    Text(verbatim: "–").accessibilityLabel(Text("Not loaded"))
                }
            }
        }
    }

    /// Eine Kachel: Zeichen, Titel, darunter die Angabe. Markiert hell
    /// gefüllt und kräftig umrandet (Form und Helligkeit, nicht nur Farbe).
    private func tile<Symbol: View, Title: View, Detail: View>(
        marked: Bool, @ViewBuilder symbol: () -> Symbol, @ViewBuilder title: () -> Title,
        @ViewBuilder detail: () -> Detail
    ) -> some View {
        HStack(spacing: 10) {
            symbol()
            VStack(alignment: .leading, spacing: 3) {
                title()
                    .foregroundStyle(palette.text)
                detail()
                    .font(.system(size: 12))
                    .foregroundStyle(palette.tertiary)
            }
            .lineLimit(1)
            .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .frame(height: 58)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(marked ? Color.white.opacity(0.18) : palette.slot)
        }
        .overlay {
            if marked {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.85), lineWidth: 2.5)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(marked ? .isSelected : [])
    }

    // MARK: Schreiben: Felder

    /// Was die Tasten bei gehaltenem L1 tun, als große Felder in zwei
    /// Spalten: Taste, daneben die Wirkung. Was gerade nicht geht, ist
    /// gedimmt (wie in der Zeile an Notch und Pille).
    func largeWriting(_ slots: ControllerWritingSlots) -> some View {
        let hints = ControllerWritingSlots.Hint.allCases
        let pairs = stride(from: 0, to: hints.count, by: 2).map { Array(hints[$0..<min($0 + 2, hints.count)]) }
        return VStack(spacing: 0) {
            VStack(spacing: 8) {
                ForEach(Array(pairs.enumerated()), id: \.offset) { _, pair in
                    HStack(spacing: 8) {
                        ForEach(pair, id: \.self) { item in
                            HStack(spacing: 9) {
                                IslandGlyph(
                                    text: item.glyph ?? item.button.glyph(family), round: item.button.isRoundGlyph,
                                    palette: palette)
                                Text(verbatim: item.label(slots))
                                    .font(.system(size: 13.5, weight: .medium))
                                    .foregroundStyle(palette.hint)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.85)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 12)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .background(palette.slot, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .opacity(slots.isOn(item) ? 1 : 0.38)
                        }
                        if pair.count == 1 { Color.clear.frame(maxWidth: .infinity, maxHeight: 1) }
                    }
                }
            }
            .padding(.horizontal, NotchIslandLargeGeometry.padding)
            .padding(.top, 2)
            .padding(.bottom, 12)
            if let note = slots.note { self.note(note.text(family)) }
        }
    }
}
