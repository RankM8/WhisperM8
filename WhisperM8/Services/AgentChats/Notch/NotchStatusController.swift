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

    static func current(_ prefs: AppPreferences = .shared) -> NotchConfig {
        NotchConfig(
            isActive: prefs.isNotchStatusFeatureEnabled && prefs.isNotchStatusEnabled,
            screenChoice: NotchScreenChoice(rawValue: prefs.notchStatusScreenRaw) ?? .auto,
            hideFromCapture: prefs.isNotchStatusHiddenFromCapture,
            showFreshDone: prefs.isNotchStatusShowingFreshDone,
            expandOnHover: prefs.isNotchStatusExpandingOnHover)
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

private struct NotchHostView: View {
    @ObservedObject var model: NotchViewModel
    let controller: NotchStatusController

    var body: some View {
        NotchStatusView(
            display: model.display,
            onToggle: { controller.toggleExpanded() },
            onSelect: { controller.select(sessionID: $0) },
            onTurnOff: { controller.turnOff() },
            onHover: { controller.hoverChanged($0) })
    }
}

/// Besitzer der Notch-Anzeige: Fenster, Beobachter, Auslöser. Die Logik
/// (Sortierung, Zähler, Auslöser, Geometrie) liegt rein in `NotchStatusModel`,
/// `NotchAlertTracker` und `NotchGeometry`; hier hängt nur die AppKit-Seite.
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
    private let now: () -> Date
    private let appIsActive: @MainActor () -> Bool
    private let focusSession: @MainActor (UUID) -> Void
    private let prefs: AppPreferences

    private let viewModel = NotchViewModel()
    private var panel: NotchPanel?
    private var config = NotchConfig(
        isActive: false, screenChoice: .auto, hideFromCapture: true, showFreshDone: true, expandOnHover: false)

    private var started = false
    private var tracker = NotchAlertTracker()
    private var alert: NotchAlert?
    private var alertTask: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var hoverTask: Task<Void, Never>?
    private var fullscreenRecheckTask: Task<Void, Never>?

    private var isExpanded = false
    private var expandedByHover = false
    private var isHovering = false
    private var isFullscreenHidden = false
    private var isReleasingKey = false

    private var inputs: [NotchChatInput] = []
    private var lastDisplay: NotchDisplay?
    private var lastFrame: CGRect?
    /// Gewählter Bildschirm; neu bestimmt bei Bildschirmwechsel und Einstellung.
    private var cachedScreen: NotchScreenInfo??
    /// Zählt Vollbild-Prüfungen, damit eine überholte Antwort verworfen wird.
    private var fullscreenGeneration = 0

    private var generalCancellables = Set<AnyCancellable>()
    private var activeCancellables = Set<AnyCancellable>()
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
        prefs: AppPreferences = .shared
    ) {
        self.prefs = prefs
        self.statusStore = statusStore ?? AgentSessionStatusCoordinator.shared.statusStore
        self.activityStore = activityStore ?? AgentSessionStatusCoordinator.shared.activityStore
        self.workspaceProvider = workspaceProvider
        self.now = now
        self.appIsActive = appIsActive
        self.focusSession = focusSession
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

    private func applyConfigIfChanged(force: Bool = false) {
        let new = NotchConfig.current(prefs)
        guard force || new != config else { return }
        let wasActive = config.isActive
        config = new
        cachedScreen = nil
        if new.isActive {
            if !wasActive || force { activate() }
            panel?.sharingType = new.hideFromCapture ? .none : .readOnly
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
                self?.lastFrame = nil
                self?.cachedScreen = nil
                self?.scheduleFullscreenCheck()
                self?.render()
            }
            .store(in: &activeCancellables)

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceCenter.publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            .merge(with: workspaceCenter.publisher(for: NSWorkspace.didActivateApplicationNotification))
            .sink { [weak self] _ in self?.scheduleFullscreenCheck() }
            .store(in: &activeCancellables)

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
        lastDisplay = nil
        lastFrame = nil
        cachedScreen = nil
        isFullscreenHidden = false
        panel?.orderOut(nil)
    }

    // MARK: Daten

    /// Baut Zeilen, Zähler und Auslöser neu und aktualisiert die Anzeige.
    private func rebuild() {
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

    // MARK: Darstellung

    private func render() {
        guard config.isActive else { return }
        let current = now()
        let rows = NotchStatusModel.rows(from: inputs, now: current, showFreshDone: config.showFreshDone)
        let summary = NotchStatusModel.summary(of: rows)
        let sections = isExpanded ? NotchStatusModel.sections(of: rows) : []

        guard let screen = selectedScreen(),
              !isFullscreenHidden,
              NotchStatusModel.isVisible(summary: summary, isExpanded: isExpanded, alert: alert) else {
            lastDisplay = nil
            panel?.orderOut(nil)
            return
        }

        let mode = NotchStatusModel.panelMode(isExpanded: isExpanded, alert: alert, rows: rows, sections: sections)
        let display = NotchDisplay(
            style: screen.hasNotch ? .notch(width: screen.notchWidth, height: screen.safeAreaTop) : .pill,
            summary: summary, alert: alert, isExpanded: isExpanded, sections: sections)
        let frame = NotchGeometry.panelFrame(screen: screen, mode: mode)

        let panel = ensurePanel()
        panel.hasShadow = !screen.hasNotch
        let wasVisible = panel.isVisible
        if display != lastDisplay {
            lastDisplay = display
            viewModel.display = display
        }
        if frame != lastFrame {
            lastFrame = frame
            if wasVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                // Über den Animator: `setFrame(_:display:animate:)` hielte den
                // Main Thread für die ganze Animation fest.
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.2
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    panel.animator().setFrame(frame, display: true)
                }
            } else {
                panel.setFrame(frame, display: true)
            }
        }
        if !wasVisible { panel.orderFrontRegardless() }
    }

    private func ensurePanel() -> NotchPanel {
        if let panel { return panel }
        let panel = NotchPanel()
        let host = NotchHostingView(rootView: NotchHostView(model: viewModel, controller: self))
        host.safeAreaRegions = []
        host.sizingOptions = []
        panel.contentView = host
        panel.sharingType = config.hideFromCapture ? .none : .readOnly
        panel.onCancel = { [weak self] in self?.collapse() }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isReleasingKey else { return }
                self.collapse()
            }
        }
        self.panel = panel
        return panel
    }

    // MARK: Bildschirm

    private func selectedScreen() -> NotchScreenInfo? {
        if let cachedScreen { return cachedScreen }
        let screens = NSScreen.screens.compactMap(NotchScreenInfo.init(screen:))
        // Hauptbildschirm = der mit der Menüleiste (`CGMainDisplayID`), nicht
        // `NSScreen.main`: das folgt dem Fokus und ließe die Anzeige springen.
        let screen = NotchGeometry.selectScreen(
            choice: config.screenChoice, screens: screens, mainDisplayID: CGMainDisplayID())
        cachedScreen = .some(screen)
        return screen
    }

    /// Vollbild-Spaces verstecken die Anzeige. Geprüft bei Space- und App-Wechsel
    /// und kurz danach noch einmal, weil der Übergang erst nach der Meldung endet.
    private func scheduleFullscreenCheck() {
        updateFullscreenState()
        fullscreenRecheckTask?.cancel()
        fullscreenRecheckTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            self?.updateFullscreenState()
        }
    }

    /// Die Fensterliste kostet je nach Anzahl der Fenster einige Millisekunden
    /// und wird deshalb abseits des Main Threads gelesen.
    private func updateFullscreenState() {
        guard config.isActive, let screen = selectedScreen() else { return }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let screenQuartz = NotchFullscreenDetector.quartzFrame(fromCocoa: screen.frame, primaryHeight: primaryHeight)
        let safeAreaTop = screen.safeAreaTop
        let systemFullScreen = NSApp.currentSystemPresentationOptions.contains(.fullScreen)
        let ownPID = ProcessInfo.processInfo.processIdentifier
        fullscreenGeneration += 1
        let generation = fullscreenGeneration
        Task.detached(priority: .utility) { [weak self] in
            let hidden = NotchFullscreenDetector.isFullscreen(
                screenFrameQuartz: screenQuartz,
                safeAreaTop: safeAreaTop,
                windows: Self.onScreenWindows(),
                ownPID: ownPID,
                systemReportsFullScreen: systemFullScreen,
                windowIsFullScreen: Self.accessibilityReportsFullScreen)
            await MainActor.run { [weak self] in
                guard let self, self.fullscreenGeneration == generation,
                      hidden != self.isFullscreenHidden else { return }
                self.isFullscreenHidden = hidden
                self.render()
            }
        }
    }

    /// Fragt die Besitzer-App per Accessibility, ob ein Fenster mit genau
    /// diesen Maßen im Vollbild ist. Läuft abseits des Main Threads, nur für
    /// Fenster mit den Maßen „Vollbild unter der Kamera“. Ohne Recht: nein.
    nonisolated private static func accessibilityReportsFullScreen(_ window: NotchWindowSample) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let app = AXUIElementCreateApplication(window.ownerPID)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var list: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &list) == .success,
              let windows = list as? [AXUIElement] else { return false }
        for element in windows {
            // Abgeleitete Elemente erben das Zeitlimit der App nicht (Standard ~6 s).
            AXUIElementSetMessagingTimeout(element, 0.25)
            var flag: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, "AXFullScreen" as CFString, &flag) == .success,
                  (flag as? Bool) == true else { continue }
            // Dieselben Koordinaten wie die Fensterliste (oben links am Hauptbildschirm).
            guard let frame = axFrame(of: element) else { return true }
            if abs(frame.minX - window.bounds.minX) <= 2, abs(frame.minY - window.bounds.minY) <= 2,
               abs(frame.width - window.bounds.width) <= 2, abs(frame.height - window.bounds.height) <= 2 {
                return true
            }
        }
        return false
    }

    nonisolated private static func axFrame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }

    nonisolated private static func onScreenWindows() -> [NotchWindowSample] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return list.compactMap { info in
            guard let layer = info[kCGWindowLayer as String] as? Int,
                  let pid = info[kCGWindowOwnerPID as String] as? Int32,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict) else { return nil }
            return NotchWindowSample(layer: layer, bounds: bounds, ownerPID: pid)
        }
    }

    // MARK: Aufklappen

    func toggleExpanded() {
        switch NotchStatusModel.clickAction(isExpanded: isExpanded, expandedByHover: expandedByHover) {
        case .expand: expand(byHover: false)
        case .collapse: collapse()
        case .pin: pinHoverList()
        }
    }

    /// Klick auf eine per Darüberfahren geöffnete Liste: Sie bleibt offen wie
    /// nach einem Klick (Wegfahren klappt nicht mehr zu, Esc kommt an).
    private func pinHoverList() {
        hoverTask?.cancel(); hoverTask = nil
        expandedByHover = false
        if let panel {
            panel.allowsKey = true
            panel.makeKey()
        }
    }

    func hoverChanged(_ hovering: Bool) {
        isHovering = hovering
        hoverTask?.cancel()
        guard config.expandOnHover else { return }
        if hovering, !isExpanded {
            hoverTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled, let self, self.isHovering else { return }
                self.expand(byHover: true)
            }
        } else if !hovering, isExpanded, expandedByHover {
            hoverTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled, let self, !self.isHovering, self.expandedByHover else { return }
                self.collapse()
            }
        }
    }

    private func expand(byHover: Bool) {
        guard config.isActive, !isExpanded else { return }
        isExpanded = true
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
        if !byHover, let panel {
            panel.allowsKey = true
            panel.makeKey()
        }
    }

    func collapse() { collapse(rebuildAfter: true) }

    private func collapse(rebuildAfter: Bool) {
        guard isExpanded else { return }
        isExpanded = false
        expandedByHover = false
        expandedCancellables.removeAll()
        tickTask?.cancel(); tickTask = nil
        removeDismissMonitors()
        releaseKey()
        if rebuildAfter { rebuild() }
    }

    /// Key-Status zurückgeben, damit Tastatureingaben wieder in der App davor landen.
    private func releaseKey() {
        guard let panel else { return }
        panel.allowsKey = false
        guard panel.isKeyWindow else { return }
        isReleasingKey = true
        panel.orderOut(nil)
        panel.orderFrontRegardless()
        isReleasingKey = false
    }

    /// Für die Controller-Insel: die Zähler, wenn die Anzeige gerade auf
    /// diesem Bildschirm steht (`nil` sonst). Nur lesen, nichts umbauen.
    func visibleSummary(onDisplay displayID: UInt32) -> NotchSummary? {
        guard config.isActive, let lastDisplay, panel?.isVisible == true,
              let screen = cachedScreen ?? nil, screen.displayID == displayID else { return nil }
        return lastDisplay.summary
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
            if let self, event.window !== self.panel { self.collapse() }
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
        self.init(
            displayID: id,
            frame: screen.frame,
            visibleFrame: screen.visibleFrame,
            safeAreaTop: screen.safeAreaInsets.top,
            auxiliaryLeftWidth: screen.auxiliaryTopLeftArea?.width,
            auxiliaryRightWidth: screen.auxiliaryTopRightArea?.width,
            isBuiltIn: CGDisplayIsBuiltin(id) != 0)
    }
}
