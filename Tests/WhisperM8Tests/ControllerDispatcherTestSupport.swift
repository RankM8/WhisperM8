import Foundation
@testable import WhisperM8

// Attrappen für den Ausführer der Controller-Steuerung, geteilt von
// `ControllerActionDispatcherTests` und `ControllerActionDispatcherIslandTests`.

@MainActor
final class ControllerTerminalSpy: ControllerTerminalControlling {
    var states: [UUID: ControllerTerminalState] = [:]
    private(set) var keys: [TerminalControlKey] = []
    private(set) var scrolled: [Int] = []
    private(set) var texts: [(text: String, submit: Bool)] = []

    func state(of sessionID: UUID) -> ControllerTerminalState? { states[sessionID] }
    func sendKey(_ key: TerminalControlKey, to sessionID: UUID) -> Bool { keys.append(key); return true }
    func scroll(lines: Int, in sessionID: UUID) { scrolled.append(lines) }
    var clearResult = true
    private(set) var clearedSessions: [UUID] = []
    func clearInput(in sessionID: UUID) -> Bool {
        clearedSessions.append(sessionID)
        return clearResult
    }
    func sendText(_ text: String, submit: Bool, to sessionID: UUID) -> Bool {
        texts.append((text, submit))
        return true
    }
    private(set) var choiceListsOpened: [UUID] = []
    func noteChoiceListOpened(in sessionID: UUID) { choiceListsOpened.append(sessionID) }
}

@MainActor
final class ControllerDictationSpy: ControllerDictationControlling {
    var phase: ControllerRecordingPhase?
    var isQuickActionRunning = false
    var targetSessionID: UUID?
    private(set) var started: [DictationDeliveryTarget] = []
    private(set) var stopped: [Bool] = []
    private(set) var cancelCount = 0
    private(set) var modeSteps: [Int] = []

    private(set) var labels: [String?] = []
    func start(target: DictationDeliveryTarget, label: String?) {
        started.append(target); labels.append(label); phase = .recording
        if case let .agentChat(id) = target { targetSessionID = id }
    }
    func stop(submit: Bool) { stopped.append(submit); phase = .transcribing; targetSessionID = nil }
    func cancel() { cancelCount += 1; phase = nil }
    func stepOutputMode(_ step: Int) { modeSteps.append(step) }
}

@MainActor
final class ControllerEnvironmentSpy: ControllerAppEnvironment {
    var isAppActive = true
    var hasOtherKeyWindow = false
    var isModalOpen = false
    var isClipboardPanelOpen = false
    private(set) var clipboardToggles = 0
    private(set) var clipboardCommands: [ControllerClipboardCommand] = []
    private(set) var broughtToFront = 0
    private(set) var bridgeKeys: [ControllerBridgeKey] = []
    private(set) var openedSettings = 0
    var clipboardState = ControllerClipboardState()

    func toggleClipboardPanel() { clipboardToggles += 1 }
    func clipboard(_ command: ControllerClipboardCommand) { clipboardCommands.append(command) }
    func bringAgentChatsToFront() { broughtToFront += 1 }
    func postBridgeKey(_ key: ControllerBridgeKey) { bridgeKeys.append(key) }
    func openControllerSettings() { openedSettings += 1 }

    // Insel-Paket: App-Raute
    var appToggles = ControllerAppToggles()
    private(set) var alertCycles = 0
    var stayAwakeResult: ControllerStayAwakeResult = .changed(.whileWorking)
    func cycleAlertLevel() -> ControllerAlertStage {
        alertCycles += 1
        let order: [ControllerAlertStage] = [.all, .soundOff, .off]
        appToggles.alert = order[(order.firstIndex(of: appToggles.alert)! + 1) % 3]
        appToggles.nextAlert = order[(order.firstIndex(of: appToggles.alert)! + 1) % 3]
        return appToggles.alert
    }
    func cycleStayAwake() -> ControllerStayAwakeResult {
        if case let .changed(stage) = stayAwakeResult { appToggles.awake = stage }
        return stayAwakeResult
    }
}

/// Fenster-Attrappe am Befehls-Katalog.
@MainActor
final class ControllerWindowFake {
    let id = UUID()
    var selected: UUID? = UUID()
    var isGridActive = false
    var isSwitcherOpen = false
    var hasSheet = false
    var isSidebarVisible = true
    var hasMultiSelection = false
    var isNewChatPickerOpen = false
    var chatInfo: ControllerChatActionInfo? = ControllerChatActionInfo(title: "Chat")
    var rows: [AgentChatsListRow] = []
    var workspaces: [ControllerWorkspaceChoice] = []
    var backTarget: ControllerBackTarget?
    /// Wird mit `lastChat` zum neuen Ziel (wie der Ort, den man verlässt).
    var backTargetAfterJump: ControllerBackTarget?
    /// Befehle, die „ging nicht“ melden sollen.
    var failing: Set<String> = []
    private(set) var commands: [AgentChatsCommand] = []

    var handler: AgentChatsCommandCenter.Handler {
        AgentChatsCommandCenter.Handler(
            perform: { [unowned self] command in
                commands.append(command)
                switch command {
                case .switcherCancel: isSwitcherOpen = false
                case .setSidebarVisible(let visible): isSidebarVisible = visible
                case .clearMultiSelection: hasMultiSelection = false
                case .selectSession(let id): selected = id
                case .selectWorkspaceChat(let id, _): selected = id
                case .showNewChatPicker: isNewChatPickerOpen = true
                case .switchToProject: break
                case .lastChat:
                    // Wie `goBack`: ein voriger Chat wird ausgewählt.
                    if let target = backTarget, target.kind == .chat, let id = target.id { selected = id }
                    backTarget = backTargetAfterJump
                default: break
                }
                return !failing.contains(String(describing: command))
            },
            snapshot: { [unowned self] in
                AgentChatsWindowSnapshot(
                    windowID: id, isKeyWindow: true, selectedSessionID: selected,
                    isGridActive: isGridActive, canReturnToWorkspace: false,
                    isSwitcherOpen: isSwitcherOpen, hasSheet: hasSheet,
                    isSidebarVisible: isSidebarVisible, hasMultiSelection: hasMultiSelection,
                    isArchiveMode: false, isNewChatPickerOpen: isNewChatPickerOpen, screenDisplayID: 7,
                    backTarget: backTarget)
            },
            listRows: { [unowned self] in rows },
            chatActionInfo: { [unowned self] _ in chatInfo },
            workspaceChoices: { [unowned self] in workspaces }
        )
    }
}

/// Anzeige der Insel: merkt sich, was gezeigt wurde.
@MainActor
final class ControllerIslandSpy: ControllerIslandPresenting {
    private(set) var shown: [ControllerIslandModel] = []
    private(set) var screens: [UInt32?] = []
    private(set) var hideCount = 0
    var isVisible = false

    func show(_ model: ControllerIslandModel, screenDisplayID: UInt32?) {
        shown.append(model)
        screens.append(screenDisplayID)
        isVisible = true
    }

    func hide() {
        hideCount += 1
        isVisible = false
    }

    var last: ControllerIslandModel? { isVisible ? shown.last : nil }
}
