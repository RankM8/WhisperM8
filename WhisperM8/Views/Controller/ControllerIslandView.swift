import SwiftUI

/// Was die Insel zeichnet, als ein Wert (Snapshots, Tests). Das Fenster
/// (`ControllerIslandPresenter`) entscheidet nur, wann ein neuer Wert kommt.
struct ControllerIslandDisplay: Equatable {
    enum Style: Equatable {
        /// An der Notch: schwarz, das Band deckt genau die Aussparung.
        case notch(width: CGFloat, height: CGFloat)
        /// Ohne Notch: wächst aus der Pille der Notch-Anzeige, im dunklen
        /// Glas der Diktat-Pille.
        case pill
    }

    var style: Style
    var model: ControllerIslandModel
    /// Zähler der Notch-Anzeige, wenn sie auf diesem Bildschirm steht: Sie
    /// wandern in den Kopf der Insel (Entwurf, Zustand 8).
    var counts: ControllerIslandCounts?
    /// Nur Pille: Sie sitzt in der unteren Bildschirmhälfte, die Insel wächst
    /// nach oben aus ihr heraus.
    var opensUpward = false

    var isNotch: Bool {
        if case .notch = style { return true }
        return false
    }

    /// Breite des Körpers je Zustand (Entwurf); an der Notch nie schmaler
    /// als die Aussparung.
    var bodyWidth: CGFloat {
        let width: CGFloat
        switch model.content {
        case .writing: width = 420
        case .quickDraw: width = 524
        case .whereTo: width = 440
        }
        if case .notch(let notchWidth, _) = style { return max(width, notchWidth) }
        return width
    }
}

struct ControllerIslandCounts: Equatable {
    var working: Int
    var waiting: Int
}

/// Farben der Insel. Immer dunkel: an der Notch wie die Hardware, ohne Notch
/// im dunklen Glas der Diktat-Pille.
struct IslandPalette {
    var background: Color
    var border: Color
    var text: Color
    var secondary: Color
    var tertiary: Color
    var hint: Color
    var key: Color
    var keyBorder: Color
    var mark: Color
    var markBorder: Color
    var segment: Color
    var segmentOn: Color
    var slot: Color
    var line: Color
    var awaiting: Color
    var working: Color

    static let notch = IslandPalette(
        background: .black, border: .clear,
        text: Color(white: 0.957), secondary: Color(white: 0.643), tertiary: Color(white: 0.553),
        hint: Color(white: 0.84),
        key: Color(red: 0.165, green: 0.165, blue: 0.18), keyBorder: Color.white.opacity(0.14),
        mark: Color(red: 0.486, green: 0.518, blue: 0.91).opacity(0.24),
        markBorder: Color(red: 0.553, green: 0.584, blue: 0.933),
        segment: Color.white.opacity(0.08), segmentOn: Color.white.opacity(0.16),
        slot: Color.white.opacity(0.07), line: Color.white.opacity(0.08),
        awaiting: Color(red: 0.914, green: 0.725, blue: 0.286),
        working: Color(red: 0.298, green: 0.765, blue: 0.541))
}

/// Controller-Insel: Kopf mit Taste, Ebene und Ziel, darunter je Ebene die
/// Hinweise, die Raute oder die Liste. Reine Darstellung; keine
/// Dauerbewegung (Auf- und Zuklappen macht das Fenster einmalig).
struct ControllerIslandView: View {
    let display: ControllerIslandDisplay
    /// Aufgeklappt; zu ist nur der Umriss der Notch sichtbar.
    var revealed = true

    private var palette: IslandPalette { .notch }

    var body: some View {
        VStack(spacing: 0) {
            if case .notch(_, let height) = display.style {
                Color.clear.frame(height: height)
            }
            header
            content
        }
        .frame(width: display.bodyWidth)
        .background { background }
        .clipShape(shape)
        .mask(alignment: display.opensUpward ? .bottom : .top) { reveal }
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
    }

    /// An der Notch schwarz, ohne Notch das Glas der Diktat-Pille.
    @ViewBuilder
    private var background: some View {
        if display.isNotch {
            shape.fill(palette.background)
        } else {
            PillGlassBackground(shape: RoundedRectangle(cornerRadius: PillGlass.cornerRadius, style: .continuous))
        }
    }

    private var shape: AnyShape {
        if case .notch(let width, let height) = display.style {
            return AnyShape(NotchHangingShape(bandWidth: width, bandHeight: height, bottomRadius: 20))
        }
        return AnyShape(RoundedRectangle(cornerRadius: PillGlass.cornerRadius, style: .continuous))
    }

    /// Wächst aus der Notch (bzw. aus der Pille) und zieht sich dorthin
    /// zurück; aus einer Pille in der unteren Bildschirmhälfte nach oben.
    private var reveal: some View {
        GeometryReader { proxy in
            let collapsed = collapsedSize(in: proxy.size)
            RoundedRectangle(cornerRadius: revealed ? 0 : collapsed.height / 2, style: .continuous)
                .frame(width: revealed ? proxy.size.width : collapsed.width,
                       height: revealed ? proxy.size.height : collapsed.height)
                .frame(maxWidth: .infinity, maxHeight: .infinity,
                       alignment: display.opensUpward ? .bottom : .top)
        }
    }

    private func collapsedSize(in size: CGSize) -> CGSize {
        switch display.style {
        case .notch(let width, let height):
            return CGSize(width: min(size.width, width), height: min(size.height, height + NotchGeometry.chinHeight))
        case .pill:
            return CGSize(width: min(size.width, NotchGeometry.pillIdleWidth),
                          height: min(size.height, NotchGeometry.pillHeight))
        }
    }

    // MARK: Kopf

    private var header: some View {
        HStack(spacing: 8) {
            IslandGlyph(text: display.model.layer.key.glyph, round: false, palette: palette)
            Text(verbatim: display.model.layer.title)
                .font(.system(size: 11, weight: .bold))
                .tracking(0.2)
                .foregroundStyle(palette.text)
            Spacer(minLength: 12)
            headerTarget
                .frame(maxWidth: 190, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.top, 9)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private var headerTarget: some View {
        // Die Zähler der Notch-Anzeige nur bei „Wohin“ (Entwurf, Zustand 8):
        // Schreiben und Schnellbefehle wirken auf einen Chat, der muss im
        // Kopf stehen.
        if let counts = display.counts, display.model.layer == .whereTo {
            HStack(spacing: 12) {
                if counts.working > 0 { count(.working, counts.working, palette.working) }
                if counts.waiting > 0 { count(.awaiting, counts.waiting, palette.awaiting) }
            }
        } else if let workspace = gridWorkspaceTitle {
            Text(verbatim: workspace)
                .font(.system(size: 11))
                .foregroundStyle(palette.tertiary)
                .lineLimit(1)
        } else if let title = display.model.target.title {
            HStack(spacing: 6) {
                IslandStatusDot(status: display.model.target.status)
                Text(verbatim: title)
                    .font(.system(size: 11))
                    .foregroundStyle(palette.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    /// Reiter Workspaces im Raster: „Raster · Name“ statt des Chats.
    private var gridWorkspaceTitle: String? {
        guard let state = display.model.whereTo, state.tab == .workspaces,
              let name = state.currentWorkspaceName else { return nil }
        return String(localized: "Grid · \(name)")
    }

    private func count(_ status: ControllerIslandStatus, _ value: Int, _ color: Color) -> some View {
        HStack(spacing: 6) {
            IslandStatusDot(status: status)
            Text(verbatim: "\(value)")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(color)
        }
    }

    // MARK: Inhalt

    @ViewBuilder
    private var content: some View {
        switch display.model.content {
        case .writing(let slots): writing(slots)
        case .quickDraw(let slots): quickDraw(slots)
        case .whereTo(let state): whereTo(state)
        }
    }

    private func writing(_ slots: ControllerWritingSlots) -> some View {
        VStack(spacing: 0) {
            IslandFlow {
                ForEach(ControllerWritingSlots.Hint.allCases, id: \.self) { item in
                    hint(item.button, item.label(slots), on: slots.isOn(item), glyph: item.glyph)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 2)
            .padding(.bottom, 12)
            if let note = slots.note { self.note(note.text) }
        }
    }

    private func quickDraw(_ slots: ControllerQuickDrawSlots) -> some View {
        VStack(spacing: 0) {
            Grid(horizontalSpacing: 4, verticalSpacing: 4) {
                GridRow {
                    Color.clear.frame(width: 160, height: 44)
                    slot(.cycleMode, slots)
                    Color.clear.frame(width: 160, height: 44)
                }
                GridRow {
                    slot(.commands, slots)
                    Text(verbatim: ControllerButton.r1.glyph)
                        .font(.system(size: 11))
                        .foregroundStyle(palette.tertiary)
                        .frame(width: 160, height: 44)
                    slot(.switchAccount, slots)
                }
                GridRow {
                    Color.clear.frame(width: 160, height: 44)
                    slot(.continueWork, slots)
                    Color.clear.frame(width: 160, height: 44)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 4)
            .padding(.bottom, slots.note == nil ? 14 : 8)
            if let note = slots.note { self.note(note.text) }
        }
    }

    private func slot(_ item: ControllerMenuItem, _ slots: ControllerQuickDrawSlots) -> some View {
        let on = slots.enabled.contains(item)
        let hit = slots.hit == item
        return HStack(spacing: 7) {
            if let button = ControllerQuickDrawSlots.button(for: item) {
                IslandGlyph(text: button.glyph, round: true, palette: palette)
            }
            Text(verbatim: item == .continueWork ? slots.crossTitle : item.islandTitle)
                .font(.system(size: 12))
                .foregroundStyle(palette.text)
                .lineLimit(1)
            Spacer(minLength: 0)
            if item.opensSubmenu {
                Text(verbatim: "›")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .frame(width: 160, height: 44)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(hit ? palette.mark : palette.slot)
                .overlay {
                    if hit {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(palette.markBorder, lineWidth: 1.5)
                    }
                }
        )
        .opacity(on || hit ? 1 : 0.36)
    }

    /// Die Liste steht sofort da (wie Cmd-Tab), die Markierung auf dem
    /// vorigen Ort.
    private func whereTo(_ state: ControllerWhereToState) -> some View {
        VStack(spacing: 0) {
            tabs(state.tab)
            VStack(spacing: 0) {
                switch state.tab {
                case .chats:
                    ForEach(state.chats.visibleRows) { row in
                        chatRow(row, marked: row.id == state.chats.selected?.id,
                                previous: state.isPrevious(chat: row.id))
                    }
                    more(state.chats.hiddenCount)
                    if state.chats.rows.isEmpty { empty(String(localized: "No chats")) }
                case .workspaces:
                    ForEach(state.workspaces.visibleRows) { choice in
                        workspaceRow(choice, marked: choice.id == state.workspaces.selected?.id,
                                     previous: state.isPrevious(workspace: choice.id))
                    }
                    more(state.workspaces.hiddenCount)
                    if state.workspaces.rows.isEmpty { empty(String(localized: "No workspaces")) }
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
            footer(state.tab, reopenTitle: state.reopenTitle)
        }
    }

    private func empty(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.system(size: 12))
            .foregroundStyle(palette.secondary)
            .frame(height: 34)
    }

    /// Kleiner Hinweis an der Zeile des vorigen Orts: Dorthin führt
    /// Loslassen ohne Bewegung, genau wie L2 getippt.
    private func previousTag() -> some View {
        Text("previous")
            .font(.system(size: 11))
            .foregroundStyle(palette.tertiary)
            .fixedSize()
    }

    private func tabs(_ selected: ControllerIslandTab) -> some View {
        HStack(spacing: 2) {
            tab(String(localized: "Chats"), on: selected == .chats)
            tab(String(localized: "Workspaces"), on: selected == .workspaces)
        }
        .padding(2)
        .background(palette.segment, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    private func tab(_ title: String, on: Bool) -> some View {
        Text(verbatim: title)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(on ? palette.text : palette.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .background {
                if on {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(palette.segmentOn)
                        .shadow(color: .black.opacity(display.isNotch ? 0 : 0.12), radius: 1, y: 1)
                }
            }
    }

    private func chatRow(_ row: ControllerIslandChatRow, marked: Bool, previous: Bool) -> some View {
        HStack(spacing: 9) {
            IslandStatusDot(status: row.status)
                .frame(width: 16)
            HStack(spacing: 6) {
                Text(verbatim: row.title)
                    .font(.system(size: 12.5, weight: row.isCurrent ? .bold : .medium))
                    .foregroundStyle(palette.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let project = row.project {
                    Text(verbatim: project)
                        .font(.system(size: 11))
                        .foregroundStyle(palette.tertiary)
                        .lineLimit(1)
                        .layoutPriority(-1)
                }
            }
            Spacer(minLength: 8)
            if previous { previousTag() }
            Text(verbatim: row.detail)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(palette.tertiary)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
        .islandMarking(marked, palette: palette)
        .accessibilityElement(children: .combine)
    }

    private func workspaceRow(_ choice: ControllerWorkspaceChoice, marked: Bool, previous: Bool) -> some View {
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(hex: choice.colorHex))
                .frame(width: 16, height: 16)
                .overlay {
                    Text(verbatim: String(choice.name.prefix(1)).uppercased())
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundStyle(.white)
                }
            HStack(spacing: 6) {
                Text(verbatim: choice.name)
                    .font(.system(size: 12.5, weight: choice.isCurrent ? .bold : .medium))
                    .foregroundStyle(palette.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if choice.isCurrent {
                    Text("current")
                        .font(.system(size: 11))
                        .foregroundStyle(palette.tertiary)
                } else if previous {
                    previousTag()
                }
            }
            Spacer(minLength: 8)
            if choice.hasWaitingChat {
                // Dasselbe Zeichen wie der Status-Punkt eines wartenden Chats.
                IslandStatusDot(status: .awaiting)
            }
            Text(verbatim: ChatsUIStrings.chatCount(choice.chatCount))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(palette.tertiary)
                .fixedSize()
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
        .islandMarking(marked, palette: palette)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func more(_ count: Int) -> some View {
        if count > 0 {
            Text(verbatim: String(localized: "+ \(count) more"))
                .font(.system(size: 11))
                .foregroundStyle(palette.tertiary)
                .padding(.top, 2)
                .padding(.bottom, 2)
        }
    }

    /// Fußzeile: Was die Tasten jetzt tun. Loslassen wechselt zum markierten
    /// Eintrag, Kreis bricht ab — beides steht immer da, weil es keine
    /// Hinweiszeile mehr davor gibt.
    private func footer(_ tab: ControllerIslandTab, reopenTitle: String? = nil) -> some View {
        IslandFlow(spacing: 12, lineSpacing: 5) {
            footItem("▲▼", String(localized: "select"))
            footItem("◀▶", String(localized: "tabs"))
            footItem(ControllerButton.l2.glyph, String(localized: "release: switch"), round: false)
            footItem(ControllerButton.circle.glyph, String(localized: "cancel"))
            footItem(ControllerButton.triangle.glyph, String(localized: "next waiting"))
            footItem(ControllerButton.square.glyph,
                     reopenTitle.map { String(localized: "reopen \($0)") } ?? String(localized: "nothing closed"),
                     round: false)
            // Im Reiter Workspaces diktiert R2 nur, wenn die Markierung auf
            // dem aktuellen Workspace steht (in den aktuellen Chat).
            footItem(ControllerButton.r2.glyph,
                     tab == .chats ? String(localized: "go + dictate") : String(localized: "dictate here"),
                     round: false)
        }
        .font(.system(size: 11))
        .foregroundStyle(palette.secondary)
        .padding(.horizontal, 14)
        .padding(.top, 7)
        .padding(.bottom, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Rectangle().fill(palette.line).frame(height: 1) }
    }

    private func footItem(_ glyph: String, _ label: String, round: Bool = true) -> some View {
        HStack(spacing: 5) {
            IslandGlyph(text: glyph, round: round, palette: palette)
            Text(verbatim: label)
        }
        .fixedSize()
    }

    // MARK: Bausteine

    private func hint(_ button: ControllerButton, _ label: String, on: Bool, glyph: String? = nil) -> some View {
        HStack(spacing: 6) {
            IslandGlyph(text: glyph ?? button.glyph, round: button.isRoundGlyph, palette: palette)
            Text(verbatim: label)
                .font(.system(size: 12))
                .foregroundStyle(palette.hint)
        }
        .fixedSize()
        .opacity(on ? 1 : 0.38)
    }

    private func note(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.system(size: 11))
            .foregroundStyle(palette.awaiting)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
    }
}

extension ControllerWritingSlots.Note {
    var text: String {
        switch self {
        case .shell: return String(localized: "Not in a shell — a program there could read the keys differently.")
        case .question: return String(localized: "Question open — nothing goes into the chat right now.")
        case .escapeInterrupts: return String(localized: "Working: ○ interrupts if no view is open.")
        }
    }
}

extension ControllerQuickDrawSlots.Note {
    var text: String {
        switch self {
        case .question: return ControllerWritingSlots.Note.question.text
        case .busy: return String(localized: "The chat is working — Continue and Switch mode wait until it is idle.")
        case .dictating: return String(localized: "Dictation running — the text goes into its chat; nothing else goes into the field now.")
        }
    }
}

extension ControllerLayer {
    /// Name der Ebene im Kopf der Insel.
    var title: String {
        switch self {
        case .writing: return String(localized: "Writing")
        case .quickDraw: return String(localized: "Quick commands")
        case .whereTo: return String(localized: "Where to")
        }
    }
}

extension ControllerMenuItem {
    /// Kurzer Text in der R1-Raute.
    var islandTitle: String {
        switch self {
        case .continueWork: return String(localized: "Continue")
        case .cycleMode: return String(localized: "Switch mode")
        case .commands: return String(localized: "Commands")
        case .switchAccount: return String(localized: "Switch account")
        default: return title(chat: nil)
        }
    }
}

extension ControllerIslandStatus {
    var runtimeStatus: AgentSessionRuntimeStatus {
        switch self {
        case .working: return .working
        case .awaiting: return .awaitingInput
        case .idle: return .idle
        case .errored: return .errored
        case .stopped: return .stopped
        }
    }
}

/// Status-Punkt der Insel: derselbe `AgentStatusIndicator` wie in Seitenleiste
/// und Tabs (ruhige Form ohne Puls), etwas größer.
private struct IslandStatusDot: View {
    let status: ControllerIslandStatus?

    var body: some View {
        AgentStatusIndicator(status: status?.runtimeStatus, compact: true)
            .scaleEffect(1.5)
            .frame(width: 8, height: 8)
    }
}

/// Tasten-Symbol der Insel.
private struct IslandGlyph: View {
    let text: String
    let round: Bool
    let palette: IslandPalette

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(palette.text)
            .padding(.horizontal, round ? 4 : 5)
            .frame(minWidth: 20, minHeight: 20)
            // Runde Tasten als Kapsel: Ein `.continuous`-Rechteck mit halber
            // Höhe als Radius wirkt bei 20 pt achteckig.
            .background(palette.key, in: RoundedRectangle(cornerRadius: round ? 10 : 5, style: round ? .circular : .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: round ? 10 : 5, style: round ? .circular : .continuous)
                    .strokeBorder(palette.keyBorder, lineWidth: 1))
            .fixedSize()
    }
}

private extension View {
    func islandMarking(_ marked: Bool, palette: IslandPalette) -> some View {
        background {
            if marked {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(palette.mark)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(palette.markBorder, lineWidth: 1.5))
            }
        }
    }
}

/// Zeilen mit Umbruch, wie `flex-wrap` im Entwurf: 14 pt zwischen den
/// Einträgen, 6 pt zwischen den Zeilen.
private struct IslandFlow: Layout {
    var spacing: CGFloat = 14
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let lines = arrange(subviews, width: width)
        let height = lines.reduce(0) { $0 + $1.height } + CGFloat(max(0, lines.count - 1)) * lineSpacing
        let used = lines.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? used, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in line.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (line.height - size.height) / 2), proposal: .unspecified)
                x += size.width + spacing
            }
            y += line.height + lineSpacing
        }
    }

    private struct Line {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Line] {
        var lines: [Line] = []
        var current = Line()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                lines.append(current)
                current = Line()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { lines.append(current) }
        return lines
    }
}
