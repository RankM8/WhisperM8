import Foundation

// Zweite Raute der R1-Insel (Insel-Paket): das Steuerkreuz schaltet die App.
// ▲ Limits-Karte, ◀ Glocke, ▶ Wach bleiben, ▼ Zwischenablage-Verlauf.
// Schalter lassen die Insel offen und bestätigen in einer Zeile, was jetzt
// gilt und was der nächste Druck bringt; Befehle schließen sie.

extension ControllerActionDispatcher {
    /// Ein Feld der App-Raute. Bei offener Limits-Karte scrollen ▲ ▼, ◀ ▶
    /// gehen dort nicht.
    func performAppSlot(_ slot: ControllerAppSlot) {
        guard spentLayer != .quickDraw, ensureIsland(.quickDraw), var slots = quickDrawSlots else { return }
        if slots.card != nil {
            switch slot {
            case .limits: scrollLimitsCard(-1)
            case .clipboard: scrollLimitsCard(1)
            case .alerts, .stayAwake: playHaptic(.rejected)
            }
            return
        }
        switch slot {
        case .limits:
            openLimitsCard()
        case .alerts:
            let stage = environment.cycleAlertLevel()
            slots.app = environment.appToggles
            slots.confirmation = .alert(stage, next: slots.app.nextAlert)
            slots.appHit = .alerts
            setQuickDrawSlots(slots)
            playHaptic(.toggled)
        case .stayAwake:
            // Meist sofort; nur wenn die Freigabe noch unbekannt ist, nach
            // der stillen Prüfung. Ist die Insel bis dahin zu, nur der Impuls.
            let generation = islandGeneration
            environment.cycleStayAwake { [weak self] result in
                self?.stayAwakeCycled(result, generation: generation)
            }
        case .clipboard:
            spendIsland(.quickDraw)
            environment.toggleClipboardPanel()
        }
    }

    private func stayAwakeCycled(_ result: ControllerStayAwakeResult, generation: Int) {
        let open = islandGeneration == generation && spentLayer != .quickDraw
        var slots = open ? quickDrawSlots : nil
        switch result {
        case let .changed(stage):
            slots?.app = environment.appToggles
            slots?.confirmation = .awake(stage, next: stage.next)
            slots?.appHit = .stayAwake
            playHaptic(.toggled)
        case .needsPermission:
            slots?.app = environment.appToggles
            slots?.confirmation = .awakeNeedsPermission
            slots?.appHit = nil
            playHaptic(.rejected)
        case .busy:
            slots = nil
            playHaptic(.rejected)
        }
        if let slots, slots.card == nil { setQuickDrawSlots(slots) }
    }

    // MARK: - Limits-Karte (R1 + ▲)

    /// Öffnet die Karte im Inhalt der R1-Insel: sofort mit dem letzten
    /// Stand, ein passiver Abruf nur, wenn er älter als eine Minute ist. Die
    /// Konten werden hier einmal gelesen und in der Sitzung gemerkt.
    func openLimitsCard() {
        guard var slots = quickDrawSlots, var state = islandState else { return }
        state.limitAccounts = limits.accounts()
        islandState = state
        slots.card = makeLimitsCard()
        slots.confirmation = nil
        slots.appHit = nil
        setQuickDrawSlots(slots)
        limits.refreshIfStale()
    }

    /// Linker Stick oder ▲ ▼ bei offener Karte; sonst ohne Wirkung.
    func scrollLimitsCard(_ step: Int) {
        guard spentLayer != .quickDraw, var slots = quickDrawSlots, var card = slots.card,
              card.scroll(step) else { return }
        slots.card = card
        setQuickDrawSlots(slots)
    }

    /// ✕ bei offener Karte: derselbe Weg wie ↻ im Popover. Läuft schon ein
    /// Abruf, „geht nicht“.
    func refreshLimitsCard() {
        guard !limits.isLoading() else { return playHaptic(.rejected) }
        limits.refresh()
        playHaptic(.toggled)
        limitsMayHaveChanged()
    }

    /// Neue Zahlen oder ein Abruf beginnt bzw. endet: offene Karte und Kopf
    /// nachziehen — für das Konto und die Konten, die beim Öffnen galten.
    func limitsMayHaveChanged() {
        guard var slots = quickDrawSlots, spentLayer != .quickDraw else { return }
        let usageAccount = islandState?.usageAccount
        var changed = false
        let badge = accountBadge(usageAccount)
        if slots.account != badge {
            slots.account = badge
            changed = true
        }
        if var card = slots.card {
            card.update(rows: limitRows(marking: usageAccount), updatedAt: limits.updatedAt(), isLoading: limits.isLoading())
            card.canRefresh = dictation.phase == nil
            if card != slots.card {
                slots.card = card
                changed = true
            }
        }
        if changed { setQuickDrawSlots(slots) }
    }

    /// Ein Diktat beginnt oder endet bei offener Karte: Die Fußzeile bietet
    /// ✕ nur an, wenn es auch geht. Aufgerufen beim Nachführen des
    /// Zusammenhangs (`refreshContext`).
    func limitsCardDictationMayHaveChanged() {
        guard spentLayer != .quickDraw, var slots = quickDrawSlots, var card = slots.card else { return }
        let canRefresh = dictation.phase == nil
        guard card.canRefresh != canRefresh else { return }
        card.canRefresh = canRefresh
        slots.card = card
        setQuickDrawSlots(slots)
    }

    private func makeLimitsCard() -> ControllerLimitsCard {
        var card = ControllerLimitsCard(
            rows: limitRows(marking: islandState?.usageAccount),
            updatedAt: limits.updatedAt(), isLoading: limits.isLoading())
        card.canRefresh = dictation.phase == nil
        return card
    }

    private func limitRows(marking account: ControllerUsageAccount?) -> [ControllerAccountLimitRow] {
        limits.rows(islandState?.limitAccounts ?? ControllerLimitAccounts()).map { row in
            var copy = row
            copy.isCurrentChat = account.map { $0.kind == row.kind && $0.name == row.name } ?? false
            return copy
        }
    }

    /// Kopf der R1-Insel: Konto des Chats mit 5-Stunden-Stand aus dem
    /// letzten Stand — nie ein eigener Abruf.
    func accountBadge(_ account: ControllerUsageAccount?) -> ControllerIslandAccountBadge? {
        guard let account else { return nil }
        return ControllerIslandAccountBadge(
            name: account.name, fiveHourUsed: accountLimit(account.kind, account.name)?.fiveHour)
    }

    // MARK: - Zugriff auf die offene R1-Insel

    var quickDrawSlots: ControllerQuickDrawSlots? {
        guard case let .quickDraw(slots)? = islandState?.model.content else { return nil }
        return slots
    }

    func setQuickDrawSlots(_ slots: ControllerQuickDrawSlots) {
        guard var state = islandState, case .quickDraw = state.model.content else { return }
        state.model.content = .quickDraw(slots)
        islandState = state
        present()
    }
}
