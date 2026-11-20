import AppKit
import Combine
import SwiftUI

/// Wie die Diktat-Pille gezeichnet und platziert wird.
enum OverlayPresentation: Equatable {
    /// Getrennte Diktat-Pille wie vor der vereinten Pille (Kill-Switch
    /// `unifiedPillEnabled` aus): eine Lage für alle Bildschirme, unten mittig.
    case classic
    /// Vereinte Pille ohne Notch: an der gemerkten Lage des Bildschirms (oben
    /// mittig), Zustandswechsel wachsen um die Mitte.
    case pill
    /// Vereinte Pille an der Notch: schwarz, die Zeile hängt unter der
    /// Aussparung, nicht verschiebbar.
    case notch(width: CGFloat, height: CGFloat)
    /// Vereinte Pille an einer Kamera-Insel (Dynamic Island): Das Diktat
    /// steht als Kapsel in der Menüleiste neben der Insel
    /// (`IslandDictationView`), eine Schnellaktion ebenso; aufgeklappt und
    /// bei einer Aufnahme per Controller ist es die große Form um die Kamera.
    case island(NotchIslandBand)

    /// An der Hardware (Notch oder Kamera-Insel): schwarz, nicht verschiebbar.
    var isNotch: Bool {
        switch self {
        case .notch, .island: return true
        case .classic, .pill: return false
        }
    }

    /// Höhe des Bands über der Zeile (0 ohne Notch).
    var bandHeight: CGFloat {
        switch self {
        case .notch(_, let height): return height
        case .island(let band): return band.neckHeight
        case .classic, .pill: return 0
        }
    }

    /// Kamera-Insel: Das Fenster beginnt auf Höhe der großen Form, etwas
    /// über der Kapsel; so viel Abstand hält alles andere zur Fensterkante.
    var islandTopGap: CGFloat {
        if case .island(let band) = self { return band.topGap }
        return 0
    }

    var isUnified: Bool { self != .classic }
}

/// Vereinte Pille: Nur Lage und Aussehen des Diktats ändern sich, die
/// Diktat-Logik (Coordinator, Aufnahme, Auslieferung) bleibt unberührt. Der
/// Coordinator ruft weiter `show`/`update`/`hide`; hier wird nur entschieden,
/// WO die Pille erscheint.
extension OverlayController {
    /// Baut die Pille an der Stelle der vereinten Pille auf. Der Bildschirm
    /// des vorderen Fensters wird abseits des Main Threads bestimmt
    /// (Fensterliste); bis dahin (höchstens `frontWindowTimeout`) steht noch
    /// nichts, das Diktat selbst läuft davon unabhängig.
    func presentUnifiedPanel() {
        let screens = NSScreen.screens.compactMap(NotchScreenInfo.init(screen:))
        let mouse = NSEvent.mouseLocation
        let mouseDisplayID = screens.first { $0.frame.contains(mouse) }?.displayID

        // Unsere Fenster aktivieren nicht: vorne ist die App, in der man tippt.
        let frontApp = NSWorkspace.shared.frontmostApplication
        let lookup: (@escaping @MainActor (UInt32?) -> Void) -> Void
        if frontApp?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            // WhisperM8 selbst vorne: das Key-Fenster kennen wir ohne Fensterliste.
            let window = NSApp.keyWindow ?? NSApp.mainWindow
            let displayID = window.flatMap { DictationPillPlacement.displayID(containing: $0.frame, screens: screens) }
            lookup = { answer in answer(displayID) }
        } else if let pid = frontApp?.processIdentifier {
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            lookup = { answer in
                Task.detached(priority: .userInitiated) {
                    let rect = FrontWindowLocator.frontWindowFrame(pid: pid, primaryHeight: primaryHeight)
                    await MainActor.run {
                        answer(rect.flatMap { DictationPillPlacement.displayID(containing: $0, screens: screens) })
                    }
                }
            }
        } else {
            lookup = { answer in answer(nil) }
        }
        beginUnifiedPresentation(
            screens: screens, mouseDisplayID: mouseDisplayID, mainDisplayID: CGMainDisplayID(),
            frontWindowLookup: lookup, timeout: Self.frontWindowTimeout,
            build: { [weak self] placement in
                self?.buildOrAdoptUnifiedPanel(placement) { self?.buildUnifiedPanel($0) }
            })
    }

    /// Kern des asynchronen Aufbaus, ohne Fenster testbar: Die erste Antwort
    /// gewinnt (Fensterliste oder Zeitlimit, dann die Maus). Gebaut wird nur,
    /// solange die Pille noch gezeigt werden soll, kein neuerer Aufbau läuft
    /// (Generation) und noch kein Fenster steht.
    func beginUnifiedPresentation(
        screens: [NotchScreenInfo],
        mouseDisplayID: UInt32?,
        mainDisplayID: UInt32?,
        frontWindowLookup: (@escaping @MainActor (UInt32?) -> Void) -> Void,
        timeout: TimeInterval,
        build: @escaping @MainActor (DictationPillPlacement) -> Void
    ) {
        unifiedGeneration += 1
        let generation = unifiedGeneration
        var settled = false
        let settle: @MainActor (UInt32?) -> Void = { [weak self] frontDisplayID in
            guard !settled else { return }
            settled = true
            // Ein Fenster, das sich noch zurückzieht, hindert nicht: Es wird
            // übernommen oder geschlossen (`buildOrAdoptUnifiedPanel`).
            guard let self, self.isPresented, self.unifiedGeneration == generation,
                  self.panel == nil || self.morph.isRetiring else { return }
            guard let placement = DictationPillPlacement.resolve(
                frontWindowDisplayID: frontDisplayID,
                mouseDisplayID: mouseDisplayID,
                mainDisplayID: mainDisplayID,
                screens: screens,
                positions: AppPreferences.shared.notchPillPositions) else { return }
            build(placement)
        }
        frontWindowLookup(settle)
        guard !settled else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            MainActor.assumeIsolated { settle(nil) }
        }
    }

    /// Ab hier wird es eng: lieber die Maus nehmen als die Pille warten lassen.
    static let frontWindowTimeout: TimeInterval = 0.08

    /// `allowMorph`: Steht dort eine ruhende Pille, wächst das Diktat aus ihr
    /// (`RecordingPanel+PillMorph.swift`); nach einem Bildschirmwechsel nicht.
    private func buildUnifiedPanel(_ placement: DictationPillPlacement, allowMorph: Bool = true) {
        let token = PerfBudgets.unifiedPillShow.begin()
        defer { PerfBudgets.unifiedPillShow.end(token) }
        let screen = placement.screen
        // Ruhebild vor dem Aufbau setzen: Die Ansicht beginnt ohne Animation
        // genau mit dem Bild der ruhenden Pille.
        let snapshot = allowMorph ? restSnapshot(onDisplay: screen.displayID, isNotch: placement.isNotch) : nil
        restLook = snapshot?.look
        restCenter = snapshot?.center
        showsRestLook = snapshot != nil
        let panel: RecordingPanel
        switch placement {
        case .notch(let screen):
            presentation = screen.hasIsland
                ? .island(NotchIslandGeometry.band(
                    screen: screen, occupancy: NotchIslandMonitor.shared.occupancy[screen.displayID]))
                : .notch(width: screen.notchWidth, height: screen.safeAreaTop)

            let frame = UnifiedPillGeometry.notchDictationPanelFrame(
                screen: screen, panelWidth: UnifiedPillGeometry.notchDictationPanelWidth(screen: screen))
            panel = RecordingPanel(initialOrigin: frame.origin, size: frame.size)
            // Über der Menüleiste, damit das Band die Aussparung deckt; an der
            // Notch nichts zum Ziehen.
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
            panel.allowsAboveMenuBar = true
            panel.isMovableByWindowBackground = false
            hasCustomPosition = true
        case .pill(let screen, let center):
            presentation = .pill
            // Genau über der ruhenden Pille, auch wenn die am Rand verschoben steht.
            panel = Self.makeUnifiedPillPanel(center: snapshot?.center ?? center)
            hasCustomPosition = AppPreferences.shared.notchPillPositions[screen.pillStorageKey] != nil
        }
        pillAlignment = .center
        unifiedScreen = screen
        collapsedPillWidth = nil
        // Ein Doppelklick direkt nach dem Erscheinen (Klick auf den Kern hat
        // das Diktat gestartet) setzt die Lage nicht zurück.
        lastPillActionAt = Date()
        panel.sharingType = AppPreferences.shared.isNotchStatusHiddenFromCapture ? .none : .readOnly
        panel.onMoveAnchor = { [weak self] anchor in
            guard let self, !self.isResettingPosition else { return }
            self.rememberUnifiedPosition(anchor)
        }
        // Mit Übergang zuerst unsichtbar über der ruhenden Pille; sichtbar
        // wird es im selben Bild, in dem die Status-Pille unsichtbar wird.
        installPanel(panel, safeAreaFree: placement.isNotch, contentHidden: snapshot != nil)
        observeScreenChanges()
        observeUnifiedBadge()
        beginIslandDictation(on: screen)
        // Ohne Übergang meldet sich das Diktat sofort beim Hub (die
        // Status-Pille dort tritt zurück), mit Übergang erst nach dem ersten Bild.
        applyMorph(morph.show(morph: snapshot != nil))
    }

    /// Fenster der vereinten Pille ohne Notch, mittig um den Mittelpunkt der
    /// Pille. Steht die Pille oben unter der Menüleiste, ragt der Schattenrand
    /// des Fensters in die Leiste; AppKit schöbe das ganze Fenster sonst beim
    /// Einblenden darunter (bis zu 24 pt), und die Pille spränge beim Start des
    /// Diktats nach unten, statt aus der ruhenden Pille zu wachsen. Die
    /// sichtbare Pille halten wir selbst im Bildschirm
    /// (`OverlayFrameResolver.clampedPanelOrigin`), wie die Status-Pille.
    static func makeUnifiedPillPanel(center: CGPoint) -> RecordingPanel {
        let size = OverlayFrameResolver.panelSize
        let panel = RecordingPanel(
            initialOrigin: UnifiedPillGeometry.pillDictationPanelOrigin(center: center, panelSize: size),
            size: size)
        panel.allowsAboveMenuBar = true
        panel.clampsLikeStatusPill = true
        return panel
    }

    // MARK: Kamera-Insel, kompakt

    /// An der Kamera-Insel hängt nichts mehr an einem Hals unter der
    /// Menüleiste (`IslandDictationView`): Das Diktat steht als Kapsel in
    /// der Menüleiste neben der Insel, auch ohne Messung und ohne Platz;
    /// eine Schnellaktion ebenso, mit Zeichen und Beschriftung; die Aufnahme
    /// per Controller steht in der großen Form (`showsIslandLargeForm`).
    var usesIslandCompact: Bool {
        guard case .island = presentation, islandCapsule != nil else { return false }
        return true
    }

    /// Die große Form mit den Bedienknöpfen ist offen: per Klick auf die
    /// Kapsel, oder von selbst bei einer Aufnahme per Controller (Ziel-Chat
    /// und Modus müssen ohne Klick sichtbar sein). Offen darf sie Menüs
    /// neben der Kamera verdecken; ein Diktat per Hotkey klappt nie von
    /// selbst auf.
    var showsIslandLargeForm: Bool {
        guard usesIslandCompact, islandDictationForm != nil, quickActionLabel == nil else { return false }
        return isIslandExpanded || (controllerTargetLabel != nil && !islandFormDismissed)
    }

    /// Klick auf Kapsel, Kopfzeile oder Wellenform: auf bzw. zu. Das gilt
    /// auch für die Form, die bei einer Aufnahme per Controller von selbst
    /// offen steht: Wer sie zuklappt, hat die Kapsel, ein Klick darauf
    /// öffnet sie wieder.
    func toggleIslandExpanded() {
        guard !morph.isRetiring, quickActionLabel == nil else { return }
        if showsIslandLargeForm {
            collapseIslandForm()
        } else {
            if islandFormDismissed { islandFormDismissed = false }
            if isIslandExpanded { refreshIslandInteractiveParts() } else { setIslandExpanded(true) }
        }
    }

    /// Die große Form geht auf Wunsch des Nutzers zu (Klick auf sie, Klick
    /// daneben, Bildschirmfoto, Start eines Clips). Bei einer Aufnahme per
    /// Controller bleibt sie dann zu, bis ein Klick auf die Kapsel sie
    /// wieder öffnet.
    func collapseIslandForm() {
        if controllerTargetLabel != nil, !islandFormDismissed { islandFormDismissed = true }
        if isIslandExpanded { setIslandExpanded(false) } else { refreshIslandInteractiveParts() }
    }

    /// Beschriftung der Schnellaktion oder Ziel des Controllers haben sich
    /// geändert: Kapsel, Form und Trefferflächen neu bestimmen.
    func islandContentChanged() {
        guard case .island = presentation, unifiedScreen != nil else { return }
        refreshIslandCapsule(occupancy: nil, animated: true)
    }

    /// Breite der Kapsel einer Schnellaktion: Zeichen (38 pt), Beschriftung
    /// und, solange sie läuft, ✕ zum Abbrechen. Gemessen wird der Text hier
    /// im Ereignispfad, nie in einem Body.
    nonisolated static func quickActionCapsuleWidth(label: String, isHint: Bool) -> CGFloat {
        let font = NSFont.systemFont(ofSize: quickActionLabelSize, weight: .medium)
        let text = ceil((label as NSString).size(withAttributes: [.font: font]).width)
        return 5 + 38 + 7 + text + (isHint ? 14 : 4 + quickActionCancelSize + 5)
    }

    nonisolated static let quickActionLabelSize: CGFloat = 12.5
    nonisolated static let quickActionCancelSize: CGFloat = 22

    /// Auf- bzw. zuklappen. Offen schließt ein Klick neben der Form (auch
    /// in ein Menü oder eine andere App); die Menüleiste neben der Kapsel
    /// ist beim Zuklappen sofort wieder bedienbar.
    func setIslandExpanded(_ expanded: Bool) {
        guard isIslandExpanded != expanded else { return }
        isIslandExpanded = expanded
        if expanded {
            installIslandDismissMonitors()
        } else {
            removeIslandDismissMonitors()
        }
        refreshIslandInteractiveParts()
    }

    private func installIslandDismissMonitors() {
        removeIslandDismissMonitors()
        guard presentsWindow else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            Task { @MainActor in self?.collapseIslandForm() }
        }) {
            islandDismissMonitors.append(monitor)
        }
        // Klicks in eigene Fenster (Agent-Chats); Menüs der Form selbst
        // (Ausgabemodus, Kontext) sind keine normalen Fenster.
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            if let self, Self.islandClickDismisses(
                windowLevel: event.window?.level, isDictationPanel: event.window === self.panel) {
                self.collapseIslandForm()
            }
            return event
        }) {
            islandDismissMonitors.append(monitor)
        }
    }

    /// Schließt ein Klick in ein eigenes Fenster die große Form? Ja bei
    /// normalen Fenstern (Agent Chats, Einstellungen); nicht beim Fenster
    /// des Diktats selbst und nicht bei Menüs und anderen schwebenden
    /// Fenstern (die Menüs „Ausgabemodus“ und „Kontext“ der Form).
    nonisolated static func islandClickDismisses(windowLevel: NSWindow.Level?, isDictationPanel: Bool) -> Bool {
        guard let windowLevel, !isDictationPanel else { return false }
        return windowLevel == .normal
    }

    func removeIslandDismissMonitors() {
        islandDismissMonitors.forEach(NSEvent.removeMonitor)
        islandDismissMonitors = []
    }

    /// Ein Diktat beginnt an dieser Stelle (neues Fenster oder Übernahme
    /// eines Fensters, das sich gerade zurückzieht): nichts vom vorigen
    /// Diktat bleibt stehen. Zugeklappt, Platz für Apples Insel von vorn,
    /// Messung neu angefordert.
    func beginIslandDictation(on screen: NotchScreenInfo) {
        setIslandExpanded(false)
        // `islandFormDismissed` bleibt: Nach einem Bildschirmwechsel baut
        // dasselbe Diktat sein Fenster neu auf, und eine zugeklappte Form
        // soll dann nicht wieder aufspringen. Zurückgesetzt wird am Ende
        // des Diktats (`tearDownUnified`).
        islandReserve = nil
        islandOccupancy = nil
        // `islandViewFrame` bleibt: Die Ansicht meldet ihren Rahmen schon beim
        // Einbau des Fensters, also vor diesem Aufruf.
        islandDecisionTask?.cancel()
        islandDecisionTask = nil
        islandDecisionLogged = false
        guard screen.hasIsland, case .island = presentation else {
            islandCancellables.removeAll()
            if islandCapsule != nil { islandCapsule = nil }
            if islandDictationForm != nil { islandDictationForm = nil }
            refreshIslandInteractiveParts()
            return
        }
        followSystemIsland(on: screen)
        refreshIslandCapsule(occupancy: NotchIslandMonitor.shared.occupancy[screen.displayID], animated: false)
        // Die Trefferflächen gelten auch, wenn die Kapsel dieselbe ist wie im
        // vorigen Diktat (dann meldet `refreshIslandCapsule` keine Änderung).
        refreshIslandInteractiveParts()
        // Die Log-Zeile kommt nach kurzer Frist: Dann ist die frische Messung
        // da (die erste Lage stammt aus der zwischengespeicherten), und eine
        // Beschriftung von Schnellaktion oder Controller steht fest.
        islandDecisionTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.logIslandDecision()
        }
    }

    /// Lage der Kapsel neu bestimmen. Ein normales Diktat steht an der
    /// Kamera-Insel immer in der Menüleiste: mit Messung dort, wo Platz ist,
    /// ohne Messung (keine Berechtigung, Messung gescheitert oder noch nicht
    /// da) in der schmalsten Form links. Eine Messung, die ausfällt (`nil`),
    /// ersetzt die letzte gültige dieses Diktats nicht.
    func refreshIslandCapsule(occupancy: NotchMenuBarOccupancy?, animated: Bool) {
        guard let screen = unifiedScreen, screen.hasIsland, case .island = presentation else {
            if islandCapsule != nil { islandCapsule = nil }
            if islandDictationForm != nil { islandDictationForm = nil }
            return
        }
        if let occupancy { islandOccupancy = occupancy }
        var reserve = islandReserve
        if let known = islandOccupancy {
            reserve = NotchIslandGeometry.dictationReserve(screen: screen, occupancy: known, previous: islandReserve)
            islandReserve = reserve
        }
        // Die große Form: Ihre Kopfzeile lässt Apples Mikrofon-Hinweis so
        // viel Platz wie die Kapsel (auch bevor er gemessen ist). Per
        // Controller mit einer Zeile für den Ziel-Chat.
        let form = NotchIslandLargeGeometry.form(
            screen: screen, kind: controllerTargetLabel == nil ? .dictation : .dictationWithTarget,
            occupancy: islandOccupancy,
            reserve: reserve ?? NotchIslandGeometry.dictationReserve(screen: screen, occupancy: nil))
        if form != islandDictationForm { islandDictationForm = form }
        let capsule: NotchIslandDictationCapsule?
        if let label = quickActionLabel {
            capsule = NotchIslandGeometry.quickActionCapsule(
                screen: screen, occupancy: islandOccupancy,
                contentWidth: Self.quickActionCapsuleWidth(label: label, isHint: isQuickActionHint),
                maxExtent: UnifiedPillGeometry.islandCapsuleMaxExtent(screen: screen))
        } else {
            capsule = NotchIslandGeometry.dictationCapsule(
                screen: screen, occupancy: islandOccupancy, hasBadge: statusBadge != nil, reserve: reserve)
        }
        if capsule != islandCapsule {
            if animated {
                withAnimation(.pill) { islandCapsule = capsule }
            } else {
                islandCapsule = capsule
            }
        }
        refreshIslandInteractiveParts()
    }

    /// Einmal je Diktat: in welcher Form es an der Kamera-Insel steht und
    /// warum. Geschrieben 0,6 s nach dem Beginn, bei einem kürzeren Diktat
    /// an seinem Ende.
    func logIslandDecision() {
        guard !islandDecisionLogged, let screen = unifiedScreen, case .island = presentation else { return }
        islandDecisionLogged = true
        islandDecisionTask?.cancel()
        islandDecisionTask = nil
        Logger.info(Self.islandDecisionLine(
            capsule: islandCapsule, occupancy: islandOccupancy, screen: screen,
            quickAction: quickActionLabel != nil, controller: controllerTargetLabel != nil,
            trusted: islandAXTrusted(), failure: NotchIslandMonitor.shared.failures[screen.displayID]))
    }

    /// Die Log-Zeile zur Entscheidung, rein (für Tests).
    nonisolated static func islandDecisionLine(
        capsule: NotchIslandDictationCapsule?, occupancy: NotchMenuBarOccupancy?, screen: NotchScreenInfo,
        quickAction: Bool, controller: Bool, trusted: Bool, failure: String?
    ) -> String {
        let form: String
        if let capsule {
            // Schnellaktion: Kapsel mit Beschriftung. Controller: große Form.
            let stage = quickAction ? "label" : controller ? "large" : capsule.showsClock ? "compact" : "minimal"
            let side = capsule.side == .leading ? "leading" : "trailing"
            let reason: String
            if occupancy == nil {
                reason = trusted ? "no_measurement(\(failure ?? "pending"))" : "no_accessibility_permission"
            } else {
                reason = capsule.isForced ? "no_room" : "measured"
            }
            form = "\(stage) side=\(side) reason=\(reason)"
        } else {
            form = "below_menu_bar reason=no_capsule"
        }
        guard let occupancy else { return "island_dictation form=\(form)" }
        let free = NotchIslandGeometry.freeSpace(screen: screen, occupancy: occupancy)
        let system = occupancy.systemIsland.map { "\(Int($0.lowerBound))-\(Int($0.upperBound))" } ?? "rest"
        return "island_dictation form=\(form) free=\(Int(free.leading))/\(Int(free.trailing)) system_island=\(system)"
    }

    // MARK: Kamera-Insel, Trefferflächen

    /// Wo das Fenster in der kompakten Form Klicks annimmt (Koordinaten der
    /// Ansicht, oben links): zugeklappt die Kapsel neben der Insel,
    /// aufgeklappt die große Form (`openForm`: ihre Größe). Die Ansicht
    /// selbst reicht symmetrisch um die Kamera und beginnt an der Oberkante
    /// der großen Form; zugeklappt bleibt die Menüleiste zwischen Kapsel und
    /// Kamera und auf der anderen Seite bedienbar. Beides kommt aus der
    /// Geometrie, nicht aus einer Meldung der Ansicht: Beim Zuklappen gilt
    /// sofort wieder nur die Kapsel, auch während die Form noch schrumpft.
    nonisolated static func islandInteractiveParts(
        viewFrame: CGRect, capsule: NotchIslandDictationCapsule, band: NotchIslandBand, openForm: CGSize?
    ) -> [CGRect] {
        if let openForm {
            return [CGRect(
                x: viewFrame.midX - openForm.width / 2, y: viewFrame.minY,
                width: openForm.width, height: openForm.height)]
        }
        return [CGRect(
            x: viewFrame.midX + capsule.offset - capsule.width / 2, y: viewFrame.minY + band.topGap,
            width: capsule.width, height: band.capsuleHeight)]
    }

    func refreshIslandInteractiveParts() {
        var parts: [CGRect] = []
        if usesIslandCompact, !showsRestLook, let capsule = islandCapsule, let viewFrame = islandViewFrame,
           case .island(let band) = presentation {
            parts = Self.islandInteractiveParts(
                viewFrame: viewFrame, capsule: capsule, band: band,
                openForm: showsIslandLargeForm ? islandDictationForm?.size : nil)
        }
        islandInteractiveParts = parts
        hostingView?.setInteractiveParts(swiftUIFrames: parts)
        // Auch die Fläche fürs Darüberfahren folgt sofort (beim Auf- und
        // Zuklappen meldet die Ansicht ihren Rahmen erst während der Bewegung).
        let hover = parts.dropFirst().reduce(parts.first) { $0?.union($1) }
        if hover != islandHoverFrame {
            islandHoverFrame = hover
            if let hover { hostingView?.setInteractive(swiftUIFrame: hover) }
        }
    }

    /// Kamera-Insel: Mit dem Mikrofon wird Apples Insel breiter (Hinweis
    /// rechts der Kamera). Der Hals der Ausweichform ist so breit wie sie,
    /// die kompakte Kapsel hält Abstand. Gemessen wird ein paarmal nach dem
    /// Erscheinen und bei jedem App- oder Space-Wechsel während des Diktats
    /// (die Menüs der neuen App können weiter reichen), nicht laufend.
    private func followSystemIsland(on screen: NotchScreenInfo) {
        islandCancellables.removeAll()
        NotchIslandMonitor.shared.$occupancy
            .dropFirst()
            .sink { [weak self] occupancy in
                guard let self, case .island(let current) = self.presentation, self.unifiedScreen == screen else { return }
                self.refreshIslandCapsule(occupancy: occupancy[screen.displayID], animated: true)
                let band = NotchIslandGeometry.band(screen: screen, occupancy: self.islandOccupancy)
                guard band != current else { return }
                withAnimation(.pill) { self.presentation = .island(band) }
            }
            .store(in: &islandCancellables)
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .merge(with: workspace.publisher(for: NSWorkspace.activeSpaceDidChangeNotification))
            .sink { _ in NotchIslandMonitor.shared.measure([screen], followUps: [.milliseconds(900)]) }
            .store(in: &islandCancellables)
        NotchIslandMonitor.shared.measure(
            [screen], followUps: [.milliseconds(700), .milliseconds(2500), .seconds(7)])
    }

    /// Raute für wartende Chats und Fehler, solange das Diktat steht.
    func observeUnifiedBadge() {
        statusBadge = UnifiedPillHub.shared.badge
        badgeCancellable = UnifiedPillHub.shared.$badge
            .removeDuplicates()
            .sink { [weak self] badge in
                guard let self, self.statusBadge != badge else { return }
                self.statusBadge = badge
                // Mit Raute ist die Kapsel an der Kamera-Insel etwas breiter.
                self.refreshIslandCapsule(occupancy: self.islandOccupancy, animated: true)
            }
    }

    /// Gezogen: Lage je Bildschirm merken (wie die Status-Pille), als Anteil
    /// am Bildschirm über die Display-UUID.
    private func rememberUnifiedPosition(_ anchor: PillAnchor) {
        // Nur echtes Ziehen (linke Maustaste gedrückt) merken; Verschiebungen
        // durch AppKit (Bildschirm abgesteckt) überschrieben sonst die Lage
        // auf einem anderen Bildschirm.
        guard presentation == .pill, NSEvent.pressedMouseButtons & 1 != 0 else { return }
        let center = UnifiedPillGeometry.center(of: anchor)
        let screens = NSScreen.screens.compactMap(NotchScreenInfo.init(screen:))
        guard let screen = screens.first(where: { $0.frame.contains(center) }) ?? unifiedScreen else { return }
        hasCustomPosition = true
        var positions = AppPreferences.shared.notchPillPositions
        positions[screen.pillStorageKey] = NotchPillPlacement.position(forCenter: center, on: screen)
        AppPreferences.shared.notchPillPositions = positions
        if screen.displayID != unifiedScreen?.displayID {
            unifiedScreen = screen
            UnifiedPillHub.shared.dictationMoved(toDisplay: screen.displayID)
        }
    }

    /// Doppelklick: zurück nach oben mittig, gemerkte Lage dieses Bildschirms
    /// vergessen. An der Notch gibt es nichts zurückzusetzen.
    func resetUnifiedPosition() {
        guard presentation == .pill, let panel, let screen = unifiedScreen else { return }
        var positions = AppPreferences.shared.notchPillPositions
        positions.removeValue(forKey: screen.pillStorageKey)
        AppPreferences.shared.notchPillPositions = positions
        hasCustomPosition = false
        let origin = UnifiedPillGeometry.pillDictationPanelOrigin(
            center: NotchPillPlacement.defaultCenter(screen), panelSize: panel.frame.size)
        isResettingPosition = true
        panel.animateOrigin(to: origin) { [weak self] in
            self?.isResettingPosition = false
        }
    }

    /// Bildschirme geändert (abgesteckt, Auflösung): Steht der Bildschirm des
    /// Diktats nicht mehr oder hat er andere Maße, wird die Pille neu
    /// platziert (Maus-Bildschirm, gemerkte Lage), damit ✓ und ✕ sichtbar
    /// bleiben. Das Diktat selbst läuft weiter.
    private func observeScreenChanges() {
        if let unifiedScreenObserver { NotificationCenter.default.removeObserver(unifiedScreenObserver) }
        unifiedScreenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.retiringPanelScreenChanged()
                self?.relocateAfterScreenChange()
            }
        }
    }

    func relocateAfterScreenChange() {
        guard isPresented, presentation.isUnified, let current = unifiedScreen else { return }
        let screens = NSScreen.screens.compactMap(NotchScreenInfo.init(screen:))
        if let same = screens.first(where: { $0.displayID == current.displayID }), same == current { return }
        let mouse = NSEvent.mouseLocation
        guard let placement = DictationPillPlacement.resolve(
            frontWindowDisplayID: screens.first(where: { $0.displayID == current.displayID })?.displayID,
            mouseDisplayID: screens.first { $0.frame.contains(mouse) }?.displayID,
            mainDisplayID: CGMainDisplayID(),
            screens: screens,
            positions: AppPreferences.shared.notchPillPositions) else { return }
        Logger.info("unified_pill_relocated")
        resetForRebuild()
        buildUnifiedPanel(placement, allowMorph: false)
    }

    /// Vor dem Neuaufbau an anderer Stelle: altes Fenster zu, Übergang auf
    /// Anfang, die Status-Pille wieder sichtbar (das neue Diktat steht direkt).
    func resetForRebuild() {
        closePanelForRebuild()
        cancelMorphSignpost()
        morph.reset()
        UnifiedPillHub.shared.setStatusContentHidden(onDisplay: nil)
    }

    /// Aufräumen beim Ausblenden (aus `hide`). `keepingWindow`: Die Pille
    /// zieht sich noch zurück; Fenster, Bildschirm und Meldung beim Hub
    /// räumt dann der Übergang selbst ab.
    func tearDownUnified(keepingWindow: Bool = false) {
        unifiedGeneration += 1
        badgeCancellable = nil
        islandCancellables.removeAll()
        // Mit dem Diktat geht auch die große Form zu; das nächste per
        // Controller beginnt wieder offen.
        setIslandExpanded(false)
        if islandFormDismissed { islandFormDismissed = false }
        // Ein Diktat, das vor der Frist endet, bekommt seine Log-Zeile hier.
        logIslandDecision()
        islandDecisionTask?.cancel()
        islandDecisionTask = nil
        if statusBadge != nil { statusBadge = nil }
        guard !keepingWindow else { return }
        if let unifiedScreenObserver {
            NotificationCenter.default.removeObserver(unifiedScreenObserver)
            self.unifiedScreenObserver = nil
        }
        unifiedScreen = nil
        // Kein Ruhebild mehr übrig (etwa Stopp vor dem ersten Bild): Das
        // nächste Diktat, auch die getrennte Pille, beginnt sauber.
        if showsRestLook { showsRestLook = false }
        restLook = nil
        restCenter = nil
        UnifiedPillHub.shared.dictationDidHide()
        UnifiedPillHub.shared.setStatusContentHidden(onDisplay: nil)
    }

    /// Klappen Listen an der Pille nach unten auf (obere Bildschirmhälfte)?
    var unifiedMenusOpenDownward: Bool {
        guard presentation.isUnified, let screen = unifiedScreen else { return false }
        if presentation.isNotch { return true }
        guard let panel, panel.pillFrameInPanel.width > 0 else { return true }
        let pill = panel.pillFrameInPanel.offsetBy(dx: panel.frame.origin.x, dy: panel.frame.origin.y)
        return UnifiedPillMenuDirection.opensDownward(pillFrame: pill, screenFrame: screen.frame)
    }
}

/// Bildschirm des vorderen Fensters einer App über die Fensterliste. Läuft
/// abseits des Main Threads; braucht keine Aufnahmerechte (nur Rahmen und
/// Besitzer, keine Titel).
enum FrontWindowLocator {
    /// Rahmen (Cocoa-Koordinaten) des vordersten normalen Fensters von `pid`.
    nonisolated static func frontWindowFrame(pid: pid_t, primaryHeight: CGFloat) -> CGRect? {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return frontWindowFrame(in: list, pid: pid, primaryHeight: primaryHeight)
    }

    /// Rein: erstes Fenster der Liste (vorne nach hinten) von `pid` auf der
    /// normalen Ebene, sichtbar und nicht winzig.
    nonisolated static func frontWindowFrame(in list: [[String: Any]], pid: pid_t, primaryHeight: CGFloat) -> CGRect? {
        for info in list {
            guard (info[kCGWindowOwnerPID as String] as? Int32) == pid,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  ((info[kCGWindowAlpha as String] as? Double) ?? 1) > 0,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.width > 40, bounds.height > 40 else { continue }
            return NotchFullscreenDetector.quartzFrame(fromCocoa: bounds, primaryHeight: primaryHeight)
        }
        return nil
    }
}
