import SwiftUI

// R1 in der Dynamic Island (Insel-Paket): zwei verschränkte Rauten — links
// das Steuerkreuz mit Schaltern und Befehlen für die App, rechts die Tasten
// für den Chat —, darunter die Bestätigung eines Schalters. R1 + ▲ zeigt
// statt der Rauten die Limits-Karte. Reine Darstellung.

extension ControllerIslandView {
    /// Breite einer halben Spalte und Höhe einer Zeile der Rauten (Entwurf).
    static let diamondColumn: CGFloat = 76
    static let diamondRow: CGFloat = 44
    static let diamondGap: CGFloat = 4
    static var diamondSlotWidth: CGFloat { diamondColumn * 2 + diamondGap }

    var quickDrawSlots: ControllerQuickDrawSlots? {
        if case let .quickDraw(slots) = display.model.content { return slots }
        return nil
    }

    var limitsCard: ControllerLimitsCard? { quickDrawSlots?.card }
    var quickDrawAccount: ControllerIslandAccountBadge? { quickDrawSlots?.account }

    @ViewBuilder
    func quickDraw(_ slots: ControllerQuickDrawSlots) -> some View {
        if let card = slots.card {
            limits(card)
        } else {
            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 22) {
                    diamond(caption: String(localized: "App"), detail: String(localized: "D-pad")) {
                        appDiamond(slots)
                    }
                    diamond(caption: String(localized: "Chat"), detail: String(localized: "Buttons")) {
                        chatDiamond(slots)
                    }
                    // Während des Diktats geht nur die App-Raute (Runde 5).
                    .opacity(slots.note == .dictating ? 0.55 : 1)
                }
                .padding(.horizontal, 14)
                .padding(.top, 2)
                .padding(.bottom, slots.note == nil && slots.confirmation == nil ? 14 : 8)
                if let confirmation = slots.confirmation { self.confirmation(confirmation, app: slots.app) }
                if let note = slots.note { self.note(note.text) }
            }
        }
    }

    // MARK: Rauten

    private func diamond<Content: View>(
        caption: String, detail: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                Text(verbatim: caption).fontWeight(.semibold).foregroundStyle(palette.secondary)
                Text(verbatim: "·")
                Text(verbatim: detail)
            }
            .font(.system(size: 11))
            .foregroundStyle(palette.tertiary)
            content()
        }
    }

    /// Verschränkte Raute: vier halbe Spalten, jedes Feld zwei davon breit.
    private func interlocked<Top: View, Left: View, Right: View, Bottom: View>(
        top: Top, left: Left, right: Right, bottom: Bottom
    ) -> some View {
        Grid(horizontalSpacing: Self.diamondGap, verticalSpacing: Self.diamondGap) {
            GridRow {
                Color.clear.frame(width: Self.diamondColumn, height: Self.diamondRow)
                top.gridCellColumns(2)
                Color.clear.frame(width: Self.diamondColumn, height: Self.diamondRow)
            }
            GridRow {
                left.gridCellColumns(2)
                right.gridCellColumns(2)
            }
            GridRow {
                Color.clear.frame(width: Self.diamondColumn, height: Self.diamondRow)
                bottom.gridCellColumns(2)
                Color.clear.frame(width: Self.diamondColumn, height: Self.diamondRow)
            }
        }
    }

    private func appDiamond(_ slots: ControllerQuickDrawSlots) -> some View {
        interlocked(
            top: appSlot(.limits, slots), left: appSlot(.alerts, slots),
            right: appSlot(.stayAwake, slots), bottom: appSlot(.clipboard, slots))
    }

    private func chatDiamond(_ slots: ControllerQuickDrawSlots) -> some View {
        interlocked(
            top: chatSlot(.cycleMode, slots), left: chatSlot(.commands, slots),
            right: chatSlot(.switchAccount, slots), bottom: chatSlot(.continueWork, slots))
    }

    private func appSlot(_ slot: ControllerAppSlot, _ slots: ControllerQuickDrawSlots) -> some View {
        slotFrame(hit: slots.appHit == slot, on: true) {
            IslandGlyph(text: slot.direction.arrowGlyph, round: false, palette: palette)
            Image(systemName: slot.symbolName(slots.app))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(palette.hint)
                .frame(width: 15)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: slot.title)
                    .font(.system(size: 12))
                    .foregroundStyle(palette.text)
                    .lineLimit(1)
                Text(verbatim: slot.state(slots.app))
                    .font(.system(size: 11))
                    .foregroundStyle(slots.appHit == slot ? palette.markBorder : palette.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            if slot == .limits {
                Text(verbatim: "›")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.tertiary)
            }
        }
    }

    private func chatSlot(_ item: ControllerMenuItem, _ slots: ControllerQuickDrawSlots) -> some View {
        slotFrame(hit: slots.hit == item, on: slots.enabled.contains(item)) {
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
    }

    private func slotFrame<Content: View>(
        hit: Bool, on: Bool, @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 7) { content() }
            .padding(.horizontal, 8)
            .frame(width: Self.diamondSlotWidth, height: Self.diamondRow)
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

    // MARK: Bestätigung

    /// Was der Schalter jetzt tut, und was der nächste Druck bringt. Fehlt
    /// die Admin-Freigabe für „Wach bleiben“, steht hier, wo man sie erteilt.
    private func confirmation(_ confirmation: ControllerToggleConfirmation, app: ControllerAppToggles) -> some View {
        HStack(spacing: 8) {
            Image(systemName: confirmation.slot.symbolName(app))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(confirmation == .awakeNeedsPermission ? palette.awaiting : palette.text)
            Text(verbatim: confirmation.text)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(confirmation == .awakeNeedsPermission ? palette.awaiting : palette.text)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let next = confirmation.nextText {
                HStack(spacing: 5) {
                    IslandGlyph(text: confirmation.slot.direction.arrowGlyph, round: false, palette: palette)
                    Text(verbatim: next)
                }
                .font(.system(size: 11))
                .foregroundStyle(palette.tertiary)
                .fixedSize()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(palette.segment, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }

    // MARK: Kopf

    /// „main · 5 h 42 %“ in der Ampel des Popovers.
    func accountBadge(_ badge: ControllerIslandAccountBadge) -> some View {
        HStack(spacing: 4) {
            Text(verbatim: "·")
            Text(verbatim: badge.name)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(verbatim: "·")
            Text(verbatim: String(localized: "5 h \(ControllerIslandView.percentText(badge.fiveHourUsed))"))
                .fontWeight(.semibold)
                .foregroundStyle(levelColor(ControllerLimitLevel(percent: badge.fiveHourUsed)))
                .fixedSize()
        }
        .font(.system(size: 11).monospacedDigit())
        .foregroundStyle(palette.tertiary)
        .layoutPriority(1)
    }

    /// Kopf der Limits-Karte: „aktualisiere …“ bzw. „Stand vor 1 min“.
    func limitsStatus(_ card: ControllerLimitsCard) -> some View {
        Text(verbatim: ControllerIslandView.limitsStatusText(card, now: Date()))
            .font(.system(size: 11))
            .foregroundStyle(palette.tertiary)
            .lineLimit(1)
    }

    static func limitsStatusText(_ card: ControllerLimitsCard, now: Date) -> String {
        if card.isLoading { return String(localized: "refreshing …") }
        guard let updatedAt = card.updatedAt else { return String(localized: "no data yet") }
        let minutes = Int(now.timeIntervalSince(updatedAt) / 60)
        if minutes < 1 { return String(localized: "as of just now") }
        if minutes < 60 { return String(localized: "as of \(minutes) min ago") }
        return String(localized: "as of \(minutes / 60) h ago")
    }

    static func percentText(_ percent: Double?) -> String {
        percent.map { "\(Int($0.rounded())) %" } ?? "—"
    }

    func levelColor(_ level: ControllerLimitLevel?) -> Color {
        switch level {
        case .low?: return palette.working
        case .medium?: return palette.awaiting
        case .high?: return palette.error
        case nil: return palette.tertiary
        }
    }
}

// MARK: - Texte

extension ControllerDirection {
    /// Pfeil des Steuerkreuzes in der Insel.
    var arrowGlyph: String {
        switch self {
        case .up: return "▲"
        case .down: return "▼"
        case .left: return "◀"
        case .right: return "▶"
        }
    }
}

extension ControllerAppSlot {
    var title: String {
        switch self {
        case .limits: return String(localized: "Limits")
        case .alerts: return String(localized: "Alerts")
        case .stayAwake: return String(localized: "Stay awake")
        case .clipboard: return String(localized: "Clipboard")
        }
    }

    /// Stand unter dem Namen, damit man vor dem Drücken sieht, was gilt.
    func state(_ app: ControllerAppToggles) -> String {
        switch self {
        case .limits: return String(localized: "all accounts")
        case .alerts: return app.alert.shortTitle
        case .stayAwake: return app.awake.shortTitle
        case .clipboard: return String(localized: "history")
        }
    }

    /// Symbole wie in der Seitenleiste (Glocke, Wach-Knopf).
    func symbolName(_ app: ControllerAppToggles) -> String {
        switch self {
        case .limits: return "gauge.with.dots.needle.33percent"
        case .alerts: return SidebarAlertLevelButton.symbolName(for: AgentAlertLevel(app.alert))
        case .stayAwake: return SidebarStayAwakeButton.symbolName(for: StayAwakeMode(app.awake))
        case .clipboard: return "doc.on.clipboard"
        }
    }
}

extension ControllerAlertStage {
    var shortTitle: String {
        switch self {
        case .all: return String(localized: "all on")
        case .soundOff: return String(localized: "sound off")
        case .off: return String(localized: "all off")
        }
    }
}

extension ControllerAwakeStage {
    var shortTitle: String {
        switch self {
        case .off: return String(localized: "off")
        case .whileWorking: return String(localized: "while working on power")
        case .always: return String(localized: "always awake")
        }
    }
}

extension ControllerToggleConfirmation {
    /// Ganz ausgeschrieben, was jetzt gilt (Texte wie Glocke und Wach-Knopf).
    var text: String {
        switch self {
        case .alert(let stage, _): return SidebarAlertLevelButton.title(for: AgentAlertLevel(stage))
        case .awake(let stage, _): return SidebarStayAwakeButton.title(for: StayAwakeMode(stage))
        case .awakeNeedsPermission: return String(localized: "Allow it in the sidebar first")
        }
    }

    /// „noch mal: alles aus“.
    var nextText: String? {
        switch self {
        case .alert(_, let next):
            let action: String
            switch next {
            case .all: action = String(localized: "everything back on")
            case .soundOff: action = String(localized: "sound off")
            case .off: action = String(localized: "everything off")
            }
            return String(localized: "again: \(action)")
        case .awake(_, let next):
            let action: String
            switch next {
            case .off: action = String(localized: "let the Mac sleep")
            case .whileWorking: action = String(localized: "awake while chats work")
            case .always: action = String(localized: "always awake")
            }
            return String(localized: "again: \(action)")
        case .awakeNeedsPermission:
            return String(localized: "one-time admin permission at the stay-awake button")
        }
    }
}

extension AgentAlertLevel {
    init(_ stage: ControllerAlertStage) {
        switch stage {
        case .all: self = .all
        case .soundOff: self = .soundOff
        case .off: self = .off
        }
    }
}

extension StayAwakeMode {
    init(_ stage: ControllerAwakeStage) {
        switch stage {
        case .off: self = .off
        case .whileWorking: self = .whileWorking
        case .always: self = .always
        }
    }
}
