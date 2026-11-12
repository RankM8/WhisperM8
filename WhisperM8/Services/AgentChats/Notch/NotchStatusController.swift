import AppKit
import Combine
import KeyboardShortcuts
import SwiftUI

extension KeyboardShortcuts.Name {
    /// Notch-Anzeige ein- und ausblenden. Ohne Standardbelegung.
    static let toggleNotchStatus = Self("toggleNotchStatus")
}

/// Einstellungen der Anzeige als Wert, damit ein Preference-Schreibzugriff
/// nur dann etwas neu aufbaut, wenn sich wirklich etwas für die Anzeige ändert.
struct NotchConfig: Equatable {
    var isActive: Bool
    var screenChoice: NotchScreenChoice
    var hideFromCapture: Bool
    var showFreshDone: Bool
    var expandOnHover: Bool
    /// Gemerkte Lage der Pille je Bildschirm ohne Notch.
    var pillPositions: [String: NotchPillPosition] = [:]

    static func current(_ prefs: AppPreferences = .shared) -> NotchConfig {
        NotchConfig(
            isActive: prefs.isNotchStatusFeatureEnabled && prefs.isNotchStatusEnabled,
            screenChoice: NotchScreenChoice(rawValue: prefs.notchStatusScreenRaw) ?? .auto,
            hideFromCapture: prefs.isNotchStatusHiddenFromCapture,
            showFreshDone: prefs.isNotchStatusShowingFreshDone,
            expandOnHover: prefs.isNotchStatusExpandingOnHover,
            pillPositions: prefs.notchPillPositions)
    }
}

/// Baut die Eingaben des Modells aus Status, Workspace und Activity-Store.
/// Rein: der Aufrufer reicht die Werte herein.
enum NotchInputBuilder {
    /// Nur Chats mit bekanntem Status, ohne archivierte und ohne
    /// Subagent-Jobs (die stehen als Kinder in der Sidebar).
    static func inputs(
        statuses: [UUID: AgentSessionRuntimeStatus],
        workspace: AgentWorkspace,
        statusSince: (UUID) -> Date?,
        activity: ((UUID) -> AgentSessionActivity?)?
    ) -> [NotchChatInput] {
        guard !statuses.isEmpty else { return [] }
        let projectNames = Dictionary(
            workspace.projects.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        var result: [NotchChatInput] = []
        for session in workspace.sessions {
            guard let status = statuses[session.id],
                  session.status != .archived,
                  !session.isSubagentJob else { continue }
            result.append(NotchChatInput(
                id: session.id,
                title: session.title,
                project: projectNames[session.projectID],
                status: status,
                statusSince: statusSince(session.id),
                lastTurnAt: session.lastTurnAt,
                lastActivityAt: session.lastActivityAt,
                activity: activity?(session.id)))
        }
        return result
    }
}

/// Wert, den die Hosting-View beobachtet.
@MainActor
final class NotchViewModel: ObservableObject {
    @Published var display = NotchDisplay(
        style: .pill, summary: .empty, alert: nil, isExpanded: false, sections: [])
}

struct NotchHostView: View {
    @ObservedObject var model: NotchViewModel
    let controller: NotchStatusController
    let kind: NotchPlacement.Kind

    var body: some View {
        NotchStatusView(
            display: model.display,
            onToggle: { controller.toggleExpanded(kind) },
            onSelect: { controller.select(sessionID: $0) },
            onTurnOff: { controller.turnOff() },
            onHover: { controller.hoverChanged($0, kind: kind) })
    }
}

/// Eine Stelle, an der die Anzeige steht (Notch oder Pille): eigenes
/// Fenster, eigener Wert, eigene Vollbild-Prüfung.
@MainActor
final class NotchSlot {
    let kind: NotchPlacement.Kind
    let viewModel = NotchViewModel()
    var panel: NotchPanel?
    var host: NotchHostingView<NotchHostView>?
    var screen: NotchScreenInfo?
    var lastDisplay: NotchDisplay?
    var lastFrame: CGRect?
    var isFullscreenHidden = false
    /// Ursprung des Fensters beim Beginn eines Ziehens (nur Pille).
    var dragOrigin: CGPoint?
    /// Die Liste war beim letzten Drücken schon offen. Ein Doppelklick setzt
    /// die Pille nur zurück, wenn sie davor zu war; sonst ist er schnelles
    /// Zu und Auf.
    var pressStartedExpanded = false

    init(kind: NotchPlacement.Kind) {
        self.kind = kind
    }
}

/// Besitzer der Notch-Anzeige: Fenster, Beobachter, Auslöser. Die Logik
/// (Sortierung, Zähler, Auslöser, Geometrie) liegt rein in `NotchStatusModel`,
/// `NotchAlertTracker`, `NotchGeometry` und `NotchPillPlacement`; hier hängt
/// nur die AppKit-Seite. Fenster, Bildschirme, Vollbild und Ziehen stehen in
/// `NotchStatusController+Placements.swift`.
///
/// Höchstens zwei Stellen: an der Notch (wie bisher, nur wenn etwas los ist)
/// und als dauerhafte Pille auf dem Bildschirm des Agent-Chats-Fensters, wenn
/// der keine Notch hat.
///
/// Performance: Im Ruhezustand hört die Anzeige nur auf den
/// `AgentSessionRuntimeStatusStore` (gedrosselt auf 300 ms) und baut nur dann
/// eine neue Ansicht, wenn sich der angezeigte Wert ändert. Den
/// `AgentSessionActivityStore` (ändert sich bei arbeitenden Chats ständig)
/// beobachtet sie nur, solange die Liste offen ist. Kein I/O, kein
/// `loadWorkspace()`: Titel kommen aus dem `AgentWorkspaceUIModel`.
@MainActor
final class NotchStatusController {
    static let shared = NotchStatusController()

    /// So lange bleibt die Anzeige nach „braucht dich" verbreitert.
    static let alertDuration: Duration = .seconds(4)
    static let throttleInterval: DispatchQueue.SchedulerTimeType.Stride = .milliseconds(300)

    private let statusStore: AgentSessionRuntimeStatusStore
    private let activityStore: AgentSessionActivityStore
    private let workspaceProvider: @MainActor () -> AgentWorkspace
    let now: () -> Date
    private let appIsActive: @MainActor () -> Bool
    private let focusSession: @MainActor (UUID) -> Void
    /// Bildschirm des Agent-Chats-Fensters (`NSScreenNumber`), dort steht die
    /// Pille, wenn er keine Notch hat. Nur im Ereignis-Pfad gefragt.
    let agentWindowDisplayID: @MainActor () -> UInt32?
    let prefs: AppPreferences

    let slots: [NotchPlacement.Kind: NotchSlot] = Dictionary(
        uniqueKeysWithValues: NotchPlacement.Kind.allCases.map { ($0, NotchSlot(kind: $0)) })
    var config = NotchConfig(
        isActive: false, screenChoice: .auto, hideFromCapture: true, showFreshDone: true, expandOnHover: false)

    private var started = false
    private var tracker = NotchAlertTracker()
    var alert: NotchAlert?
    private var alertTask: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var hoverTask: Task<Void, Never>?
    var fullscreenRecheckTask: Task<Void, Never>?

    /// Stelle, deren Liste offen ist (nur eine zugleich).
    var expandedKind: NotchPlacement.Kind?
    var isExpanded: Bool { expandedKind != nil }
    private var expandedByHover = false
    private var isHovering = false
    var isReleasingKey = false

    var inputs: [NotchChatInput] = []
    /// Stellen der Anzeige; neu bestimmt bei Bildschirmwechsel, Einstellung
    /// und wenn das Agent-Chats-Fenster den Bildschirm wechselt.
    var cachedPlacements: [NotchPlacement]?
    /// Zählt Vollbild-Prüfungen, damit eine überholte Antwort verworfen wird.
    var fullscreenGeneration = 0

    private var generalCancellables = Set<AnyCancellable>()
    var activeCancellables = Set<AnyCancellable>()
    private var expandedCancellables = Set<AnyCancellable>()
    private var globalMonitor: Any?
    private var localMonitor: Any?

    init(
        statusStore: AgentSessionRuntimeStatusStore? = nil,
        activityStore: AgentSessionActivityStore? = nil,
        workspaceProvider: @escaping @MainActor () -> AgentWorkspace = { AgentWorkspaceUIModel.shared.workspace },
        now: @escaping () -> Date = Date.init,
        appIsActive: @escaping @MainActor () -> Bool = { NSApp.isActive },
        focusSession: @escaping @MainActor (UUID) -> Void = { WindowRequestCenter.shared.requestSessionFocus(sessionID: $0) },
        agentWindowDisplayID: @escaping @MainActor () -> UInt32? = {
            AgentChatsCommandCenter.shared.windowDisplayID(preferring: AgentWindowStore.shared.dictationWindowID)
        },
        prefs: AppPreferences = .shared
    ) {
        self.prefs = prefs
        self.statusStore = statusStore ?? AgentSessionStatusCoordinator.shared.statusStore
        self.activityStore = activityStore ?? AgentSessionStatusCoordinator.shared.activityStore
        self.workspaceProvider = workspaceProvider
        self.now = now
        self.appIsActive = appIsActive
        self.focusSession = focusSession
        self.agentWindowDisplayID = agentWindowDisplayID
    }

    // MARK: Start

    /// Einmal beim App-Start. Kostet bei ausgeschalteter Funktion nur den
    /// Preference-Beobachter.
    func start() {
        guard !started else { return }
        started = true

        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .debounce(for: .milliseconds(250), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyConfigIfChanged() }
            .store(in: &generalCancellables)

        if !AppInstance.isTestInstance {
            KeyboardShortcuts.onKeyDown(for: .toggleNotchStatus) {
                Task { @MainActor in NotchStatusController.shared.toggleFeature() }
            }
        }
        applyConfigIfChanged(force: true)
    }

    /// Knopf in der Liste: Anzeige ausschalten (wie der Schalter in den
    /// Einstellungen). Wieder an über Einstellungen, Menüleiste oder Hotkey.
    func turnOff() {
        prefs.isNotchStatusEnabled = false
        applyConfigIfChanged()
    }

    /// Hotkey und Menüleiste: Anzeige ein- oder ausschalten.
    func toggleFeature() {
        guard prefs.isNotchStatusFeatureEnabled else { return }
        prefs.isNotchStatusEnabled.toggle()
        applyConfigIfChanged()
    }

    func applyConfigIfChanged(force: Bool = false) {
        let new = NotchConfig.current(prefs)
        guard force || new != config else { return }
        let wasActive = config.isActive
        let screenChanged = new.screenChoice != config.screenChoice
        config = new
        if screenChanged || !new.isActive || force { cachedPlacements = nil }
        if new.isActive {
            if !wasActive || force { activate() }
            for slot in slots.values {
                slot.panel?.sharingType = new.hideFromCapture ? .none : .readOnly
                // Neue gemerkte Lage (Ziehen, Doppelklick, Knopf in den
                // Einstellungen): Rahmen neu setzen.
                slot.lastFrame = nil
            }
            rebuild()
        } else {
            deactivate()
        }
    }

    private func activate() {
        deactivate()
        guard config.isActive else { return }
        tracker.reset()

        statusStore.$statuses
            .throttle(for: Self.throttleInterval, scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in self?.rebuild() }
            .store(in: &activeCancellables)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                for slot in self.slots.values { slot.lastFrame = nil }
                self.cachedPlacements = nil
                self.scheduleFullscreenCheck()
                self.render()
            }
            .store(in: &activeCancellables)

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceCenter.publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            .merge(with: workspaceCenter.publisher(for: NSWorkspace.didActivateApplicationNotification))
            .sink { [weak self] _ in self?.scheduleFullscreenCheck() }
            .store(in: &activeCancellables)

        observeAgentWindowScreen()
        scheduleFullscreenCheck()
        Logger.info("notch_status_started")
    }

    private func deactivate() {
        activeCancellables.removeAll()
        alertTask?.cancel(); alertTask = nil
        expiryTask?.cancel(); expiryTask = nil
        hoverTask?.cancel(); hoverTask = nil
        fullscreenRecheckTask?.cancel(); fullscreenRecheckTask = nil
        fullscreenGeneration += 1
        collapse(rebuildAfter: false)
        alert = nil
        inputs = []
        cachedPlacements = nil
        for slot in slots.values {
            slot.lastDisplay = nil
            slot.lastFrame = nil
            slot.isFullscreenHidden = false
            slot.dragOrigin = nil
            slot.panel?.orderOut(nil)
        }
    }

    // MARK: Daten

    /// Baut Zeilen, Zähler und Auslöser neu und aktualisiert die Anzeige.
    func rebuild() {
        guard config.isActive else { return }
        let statuses = statusStore.statuses
        let current = now()
        let workspace = workspaceProvider()
        let built = NotchInputBuilder.inputs(
            statuses: statuses,
            workspace: workspace,
            statusSince: { [activityStore] in activityStore.statusSince(for: $0) },
            activity: isExpanded ? { [activityStore] in activityStore.activity(for: $0) } : nil)

        // Auslöser: nur über die Chats, die die Anzeige auch kennt.
        var relevant: [UUID: AgentSessionRuntimeStatus] = [:]
        var titles: [UUID: String] = [:]
        for input in built {
            if let status = input.status { relevant[input.id] = status }
            titles[input.id] = input.title
        }
        let fired = tracker.ingest(
            statuses: relevant, titles: titles, showFreshDone: config.showFreshDone,
            appIsActive: appIsActive(), now: current)
        inputs = NotchStatusModel.applyingObservedTurnEnds(built, tracker.observedTurnEnds)

        if let alert, !NotchStatusModel.isStillValid(alert, statuses: relevant) {
            alertTask?.cancel(); alertTask = nil
            self.alert = nil
        }
        if let fired { show(alert: fired) }

        scheduleExpiry(current)
        render()
    }

    private func show(alert fired: NotchAlert) {
        alert = fired
        alertTask?.cancel()
        alertTask = Task { [weak self] in
            try? await Task.sleep(for: Self.alertDuration)
            guard !Task.isCancelled else { return }
            self?.alert = nil
            self?.render()
        }
    }

    /// „Frisch fertig" läuft von selbst ab: ein einmaliger Neuaufbau zum
    /// frühesten Ablauf, statt zu pollen.
    private func scheduleExpiry(_ current: Date) {
        expiryTask?.cancel()
        expiryTask = nil
        guard config.showFreshDone,
              let expiry = NotchStatusModel.nextFreshDoneExpiry(in: inputs, now: current) else { return }
        let delay = max(1, expiry.timeIntervalSince(current) + 1)
        expiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.rebuild()
        }
    }

    // MARK: Aufklappen

    /// Klick auf den Kopf einer Stelle. Eine offene Liste an der anderen
    /// Stelle klappt dabei zu.
    func toggleExpanded(_ kind: NotchPlacement.Kind = .notch) {
        if let expandedKind, expandedKind != kind { collapse(rebuildAfter: false) }
        switch NotchStatusModel.clickAction(isExpanded: isExpanded, expandedByHover: expandedByHover) {
        case .expand: expand(kind, byHover: false)
        case .collapse: collapse()
        case .pin: pinHoverList()
        }
    }

    /// Klick auf eine per Darüberfahren geöffnete Liste: Sie bleibt offen wie
    /// nach einem Klick (Wegfahren klappt nicht mehr zu, Esc kommt an).
    private func pinHoverList() {
        hoverTask?.cancel(); hoverTask = nil
        expandedByHover = false
        if let panel = expandedKind.flatMap({ slots[$0]?.panel }) {
            panel.allowsKey = true
            panel.makeKey()
        }
    }

    func hoverChanged(_ hovering: Bool, kind: NotchPlacement.Kind = .notch) {
        isHovering = hovering
        hoverTask?.cancel()
        guard config.expandOnHover else { return }
        if hovering, !isExpanded {
            hoverTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled, let self, self.isHovering else { return }
                self.expand(kind, byHover: true)
            }
        } else if !hovering, isExpanded, expandedByHover {
            hoverTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled, let self, !self.isHovering, self.expandedByHover else { return }
                self.collapse()
            }
        }
    }

    private func expand(_ kind: NotchPlacement.Kind, byHover: Bool) {
        guard config.isActive, !isExpanded else { return }
        expandedKind = kind
        expandedByHover = byHover
        alertTask?.cancel(); alert = nil

        // Stand-Zeilen nur lesen, solange die Liste offen ist.
        activityStore.objectWillChange
            .throttle(for: .milliseconds(500), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in self?.rebuild() }
            .store(in: &expandedCancellables)
        tickTask = Task { [weak self] in
            // Dauer-Angaben („2 min") alle 30 s auffrischen.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                self?.rebuild()
            }
        }
        installDismissMonitors()
        rebuild()
        if !byHover, let panel = slots[kind]?.panel {
            panel.allowsKey = true
            panel.makeKey()
        }
    }

    func collapse() { collapse(rebuildAfter: true) }

    func collapse(rebuildAfter: Bool) {
        guard let kind = expandedKind else { return }
        expandedKind = nil
        expandedByHover = false
        expandedCancellables.removeAll()
        tickTask?.cancel(); tickTask = nil
        removeDismissMonitors()
        releaseKey(slots[kind]?.panel)
        if rebuildAfter { rebuild() }
    }

    /// Key-Status zurückgeben, damit Tastatureingaben wieder in der App davor landen.
    private func releaseKey(_ panel: NotchPanel?) {
        guard let panel else { return }
        panel.allowsKey = false
        guard panel.isKeyWindow else { return }
        isReleasingKey = true
        panel.orderOut(nil)
        panel.orderFrontRegardless()
        isReleasingKey = false
    }

    /// Für die Controller-Insel: Mittelpunkt der sichtbaren Pille auf diesem
    /// Bildschirm, damit die Insel genau aus ihr wächst (`nil` ohne Pille).
    func visiblePillCenter(onDisplay displayID: UInt32) -> CGPoint? {
        guard config.isActive, let slot = slots[.pill], slot.panel?.isVisible == true,
              let screen = slot.screen, screen.displayID == displayID else { return nil }
        return pillCenter(on: screen)
    }

    /// Für die Controller-Insel: die Zähler, wenn die Anzeige gerade auf
    /// diesem Bildschirm steht (`nil` sonst). Nur lesen, nichts umbauen.
    func visibleSummary(onDisplay displayID: UInt32) -> NotchSummary? {
        guard config.isActive else { return nil }
        let slot = slots.values.first { $0.screen?.displayID == displayID && $0.panel?.isVisible == true }
        return slot?.lastDisplay?.summary
    }

    /// Klick auf eine Zeile: WhisperM8-Fenster nach vorn, genau dieser Chat.
    func select(sessionID: UUID) {
        collapse(rebuildAfter: true)
        focusSession(sessionID)
    }

    // MARK: Klick daneben

    private func installDismissMonitors() {
        removeDismissMonitors()
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            Task { @MainActor in self?.collapse() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            if let self, !self.slots.values.contains(where: { $0.panel === event.window }) { self.collapse() }
            return event
        }
    }

    private func removeDismissMonitors() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }
}

extension NotchScreenInfo {
    /// `nil`, wenn der Bildschirm keine Display-ID meldet.
    init?(screen: NSScreen) {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        let id = number.uint32Value
        // Feste UUID des Bildschirms: bleibt über Neustarts und Umstecken
        // gleich, anders als die Nummer.
        let uuid = CGDisplayCreateUUIDFromDisplayID(id).map { unmanaged -> String in
            let value = unmanaged.takeRetainedValue()
            return (CFUUIDCreateString(nil, value) as String?) ?? "display-\(id)"
        }
        self.init(
            displayID: id,
            frame: screen.frame,
            visibleFrame: screen.visibleFrame,
            safeAreaTop: screen.safeAreaInsets.top,
            auxiliaryLeftWidth: screen.auxiliaryTopLeftArea?.width,
            auxiliaryRightWidth: screen.auxiliaryTopRightArea?.width,
            isBuiltIn: CGDisplayIsBuiltin(id) != 0,
            uuid: uuid)
    }
}
