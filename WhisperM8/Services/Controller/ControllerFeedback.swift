import AppKit
import Combine
import Foundation
import Observation

/// Rückmeldung am Controller und Abgleich mit der Umgebung, solange die
/// Steuerung läuft:
///
/// - Lichtleiste nach Zustand (Aufnahme, Ziel arbeitet, Rückfrage)
/// - Doppelimpuls, wenn ein anderer Chat neu auf eine Entscheidung wartet
/// - automatische Pause bei Bildschirmsperre, Ruhezustand und Spielen vorne
/// - Maus oder Tastatur nehmen dem Controller Liste, Menü und Insel ab
///
/// Läuft nichts, hängt hier nichts: Alle Beobachter entstehen in `activate`
/// und verschwinden in `deactivate`.
@MainActor
final class ControllerFeedback {
    private let manager: ControllerManager
    private let dispatcher: ControllerActionDispatcher
    private var cancellables: Set<AnyCancellable> = []
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var inputMonitor: Any?
    private var waiting = ControllerWaitingTracker()
    private var lastTone: ControllerLightTone?
    private var isActive = false

    private var screenLocked = false
    private var systemAsleep = false
    private var gameInFront = false

    init(manager: ControllerManager, dispatcher: ControllerActionDispatcher) {
        self.manager = manager
        self.dispatcher = dispatcher
    }

    /// Gleicht an, ob die Beobachter laufen sollen.
    func sync() {
        if manager.status.isRunning, !isActive {
            activate()
        } else if !manager.status.isRunning, isActive {
            deactivate()
        }
    }

    // MARK: - An und aus

    private func activate() {
        isActive = true
        let statusStore = AgentSessionStatusCoordinator.shared.statusStore
        waiting.prime(awaiting: Self.awaitingIDs(statusStore.statuses))

        // Gedrosselt wie die Notch: Statuswechsel kommen gebündelt.
        statusStore.$statuses
            .throttle(for: .milliseconds(300), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] statuses in
                MainActor.assumeIsolated { self?.statusesChanged(statuses) }
            }
            .store(in: &cancellables)

        observeRecordingPhase()
        observeSystem()
        installInputMonitor()
        refresh()
    }

    private func deactivate() {
        isActive = false
        cancellables = []
        for (center, token) in observers { center.removeObserver(token) }
        observers = []
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
        inputMonitor = nil
        lastTone = nil
        screenLocked = false
        systemAsleep = false
        gameInFront = false
        manager.setSystemPaused(false)
        dispatcher.closeControllerUI()
    }

    // MARK: - Zustand nachführen

    /// Zusammenhang für die Legende und Farbe der Lichtleiste neu bestimmen.
    func refresh() {
        guard isActive else { return }
        dispatcher.refreshContext()
        var phase: ControllerRecordingPhase?
        var status: ControllerChatState.Status?
        switch dispatcher.ui.context {
        case let .recording(recordingPhase, _, _): phase = recordingPhase
        case let .chat(state): status = state.status
        default: break
        }
        guard let tone = ControllerLightPolicy.tone(
            isPaused: manager.isPaused, recordingPhase: phase, targetStatus: status
        ), tone != lastTone else { return }
        lastTone = tone
        let rgb = tone.components
        manager.setLight(ControllerLightColor(red: rgb.red, green: rgb.green, blue: rgb.blue))
    }

    private func statusesChanged(_ statuses: [UUID: AgentSessionRuntimeStatus]) {
        let visibleTarget = AgentChatsCommandCenter.shared.snapshot()?.selectedSessionID
        if waiting.update(
            awaiting: Self.awaitingIDs(statuses),
            visibleTarget: NSApp.isActive ? visibleTarget : nil,
            isRecording: AppState.shared.isRecording,
            at: ProcessInfo.processInfo.systemUptime
        ) {
            manager.play(.chatWaiting)
        }
        refresh()
    }

    private static func awaitingIDs(_ statuses: [UUID: AgentSessionRuntimeStatus]) -> Set<UUID> {
        Set(statuses.compactMap { $0.value == .awaitingInput ? $0.key : nil })
    }

    /// Aufnahme-Phase beobachten, solange die Steuerung läuft (die Phase
    /// ändert sich auch über Hotkey und Pill).
    private func observeRecordingPhase() {
        guard isActive else { return }
        withObservationTracking {
            _ = AppState.shared.recordingPhase
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.isActive else { return }
                    self.refresh()
                    self.observeRecordingPhase()
                }
            }
        }
    }

    // MARK: - Automatische Pause

    private func observeSystem() {
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        func on(_ center: NotificationCenter, _ name: Notification.Name, _ body: @escaping @MainActor (Notification) -> Void) {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { note in
                MainActor.assumeIsolated { body(note) }
            }
            observers.append((center, token))
        }
        on(distributed, Notification.Name("com.apple.screenIsLocked")) { [weak self] _ in self?.setLocked(true) }
        on(distributed, Notification.Name("com.apple.screenIsUnlocked")) { [weak self] _ in self?.setLocked(false) }
        on(distributed, Notification.Name("com.apple.screensaver.didstart")) { [weak self] _ in self?.setLocked(true) }
        on(distributed, Notification.Name("com.apple.screensaver.didstop")) { [weak self] _ in self?.setLocked(false) }
        on(workspace, NSWorkspace.willSleepNotification) { [weak self] _ in self?.setAsleep(true) }
        on(workspace, NSWorkspace.didWakeNotification) { [weak self] _ in self?.setAsleep(false) }
        on(workspace, NSWorkspace.sessionDidResignActiveNotification) { [weak self] _ in self?.setLocked(true) }
        on(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { [weak self] _ in self?.setLocked(false) }
        on(workspace, NSWorkspace.didActivateApplicationNotification) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.frontAppChanged(app)
        }
        frontAppChanged(NSWorkspace.shared.frontmostApplication)
    }

    private func setLocked(_ locked: Bool) {
        screenLocked = locked
        applySystemPause()
    }

    private func setAsleep(_ asleep: Bool) {
        systemAsleep = asleep
        applySystemPause()
    }

    private var gameCache: [String: Bool] = [:]

    /// Spiele zählen nur, wenn Eingaben im Hintergrund an sind — sonst
    /// erreicht der Controller die App ohnehin nicht, solange das Spiel vorne ist.
    private func frontAppChanged(_ app: NSRunningApplication?) {
        guard let app, app.bundleIdentifier != Bundle.main.bundleIdentifier else {
            gameInFront = false
            return applySystemPause()
        }
        let id = app.bundleIdentifier ?? app.bundleURL?.path ?? ""
        if let cached = gameCache[id] {
            gameInFront = cached
        } else {
            // Info.plist nur einmal je Programm lesen.
            let info = app.bundleURL.flatMap { Bundle(url: $0)?.infoDictionary }
            let isGame = ControllerGameDetector.isGame(
                bundleID: app.bundleIdentifier,
                category: info?["LSApplicationCategoryType"] as? String,
                supportsGameMode: info?["LSSupportsGameMode"] as? Bool ?? false
            )
            gameCache[id] = isGame
            gameInFront = isGame
        }
        applySystemPause()
    }

    private func applySystemPause() {
        let gamePause = gameInFront && AppPreferences.shared.isControllerBackgroundEnabled
        manager.setSystemPaused(screenLocked || systemAsleep || gamePause)
        lastTone = nil
        refresh()
    }

    // MARK: - Maus und Tastatur

    /// Greift der Nutzer zu Maus oder Tastatur, gibt der Controller Liste,
    /// Menü und Insel ab. Ein Bool-Vergleich je Ereignis; Ereignisse der Tastatur-Brücke
    /// zählen nicht.
    private func installInputMonitor() {
        let ui = dispatcher.ui
        let dispatcher = dispatcher
        inputMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { event in
            MainActor.assumeIsolated {
                guard ui.area == .list || ui.menu != nil || dispatcher.islandState != nil else { return }
                if event.type == .keyDown, ControllerKeyboardBridge.isBridgeEvent(event) { return }
                ui.leaveList()
                ui.menu = nil
                dispatcher.closeIslandForUserInput()
            }
            return event
        }
    }
}
