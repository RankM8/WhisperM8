import AppKit
import os

/// Tastatur-Quelle der Insel (WM8-104): ein lokaler Monitor für ⌥Tab, die
/// Tasten bei offener Insel und das Loslassen von ⌥. Die Regeln stehen pur in
/// `KeyboardIslandKeys`, die Wirkung im Ausführer
/// (`ControllerActionDispatcher+Keyboard`) — dieselbe Insel wie am Controller.
///
/// Wirkt nur, wenn WhisperM8 vorne ist und ein Agent-Chats-Fenster die Tastatur
/// hat (lokaler Monitor, wie ⌃Tab). Ist ein anderes Programm vorne, kommt ⌥Tab
/// gar nicht bei uns an; ein Einstellungsfenster oder ein Dialog vorne lässt
/// ⌥Tab durch. Der Monitor läuft vor SwiftTerms `keyDown`: ⌥Tab und alle Tasten
/// bei offener Insel erreichen das Terminal nicht. ⌥Tab kam dort ohnehin nie an
/// (`optionAsMetaKey = false`, macOS macht `insertTabIgnoringFieldEditor:`
/// daraus, das SwiftTerm nicht kennt), Claude Code verliert also nichts.
@MainActor
final class KeyboardIslandMonitor {
    static let shared = KeyboardIslandMonitor()

    private weak var dispatcher: ControllerActionDispatcher?
    private var monitor: Any?
    private var resignObserver: NSObjectProtocol?
    /// Zuletzt gesehener Modifier-Stand der offenen Insel.
    private var lastModifiers: NSEvent.ModifierFlags = []
    /// Der Diktat-Hotkey hat bei offener Insel „hin und diktieren“ ausgelöst:
    /// Sein Loslassen darf die Aufnahme nicht gleich wieder beenden.
    private var swallowHotkeyUp = false

    var isEnabled: () -> Bool = { AppPreferences.shared.isKeyboardIslandEnabled }
    /// Verzögert ausführen (Erscheinen nach 0,2 s); Tests feuern selbst.
    var schedule: (TimeInterval, @escaping @MainActor () -> Void) -> Void = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated(work) }
    }

    init() {}

    /// Beim App-Start, sobald der Ausführer steht. Idempotent.
    func start(dispatcher: ControllerActionDispatcher) {
        attach(dispatcher)
        guard monitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        monitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) ?? event }
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.dispatcher?.cancelKeyboardIsland() }
        }
    }

    /// Nur den Ausführer anschließen, ohne Monitor (Tests).
    func attach(_ dispatcher: ControllerActionDispatcher) {
        self.dispatcher = dispatcher
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .keyDown:
            return keyDown(keyCode: event.keyCode, modifiers: event.modifierFlags,
                           characters: event.charactersIgnoringModifiers) ? nil : event
        case .flagsChanged:
            flagsChanged(event.modifierFlags)
            return event
        default:
            // Ein Klick irgendwo schließt die Insel ohne Wechsel, ebenso das
            // per Tastatur geöffnete Options-Menü.
            dispatcher?.cancelKeyboardIsland()
            if dispatcher?.isKeyboardMenuOpen == true { dispatcher?.keyboardMenu(.closeAndPassThrough) }
            return event
        }
    }

    /// `true`: Taste gehört der Insel und wird geschluckt.
    func keyDown(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, characters: String? = nil) -> Bool {
        guard let dispatcher else { return false }
        guard dispatcher.isKeyboardIslandOpen else {
            if dispatcher.isKeyboardMenuOpen { return menuKeyDown(keyCode: keyCode, modifiers: modifiers) }
            return open(keyCode: keyCode, modifiers: modifiers)
        }
        lastModifiers = modifiers
        switch KeyboardIslandKeys.action(keyCode: keyCode, modifiers: modifiers, characters: characters) {
        case let .step(step): dispatcher.keyboardIslandStep(step)
        case let .tab(step): dispatcher.keyboardIslandTab(step)
        case .commit: dispatcher.keyboardIslandReturn()
        case let .command(command): dispatcher.keyboardIslandCommand(command)
        case .cheatSheet: dispatcher.toggleKeyboardCheatSheet()
        case .cancel: dispatcher.cancelKeyboardIsland()
        case .dictate: dispatcher.keyboardIslandDictate()
        case .nextWaiting: dispatcher.keyboardIslandNextWaiting()
        case .reopen: dispatcher.keyboardIslandReopen()
        case .ignore: break
        case .cancelAndPassThrough:
            dispatcher.cancelKeyboardIsland()
            return false
        }
        return true
    }

    /// Options-Menü, das B oder K geöffnet hat.
    private func menuKeyDown(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard let dispatcher else { return false }
        let action = KeyboardIslandKeys.menuAction(keyCode: keyCode, modifiers: modifiers)
        dispatcher.keyboardMenu(action)
        return action != .closeAndPassThrough
    }

    private func open(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard let dispatcher, KeyboardIslandKeys.opens(keyCode: keyCode, modifiers: modifiers), isEnabled(),
              dispatcher.openKeyboardIsland() else { return false }
        lastModifiers = modifiers
        swallowHotkeyUp = false
        Logger.controller.debug("keyboard_island_open")
        let generation = dispatcher.islandGeneration
        schedule(KeyboardIslandKeys.revealDelay) { [weak dispatcher] in
            guard let dispatcher, dispatcher.islandGeneration == generation else { return }
            dispatcher.revealKeyboardIsland()
        }
        return true
    }

    func flagsChanged(_ modifiers: NSEvent.ModifierFlags) {
        guard let dispatcher, dispatcher.isKeyboardIslandOpen else { return }
        switch KeyboardIslandKeys.flagsChange(previous: lastModifiers, current: modifiers) {
        case .none: lastModifiers = modifiers
        case .commit: dispatcher.commitKeyboardIsland()
        case .cancel: dispatcher.cancelKeyboardIsland()
        }
    }

    // MARK: - Diktat-Hotkey

    /// Der Diktat-Hotkey (ab Werk ⌥Leertaste, global über Carbon) kommt nie
    /// als `keyDown` an. Ist die Insel offen, heißt er dort „hin und
    /// diktieren“ bzw. „stopp“ wie die Leertaste. `true`: erledigt, der
    /// gewöhnliche Diktat-Weg bleibt aus.
    func consumeDictationHotkeyDown() -> Bool {
        guard let dispatcher, dispatcher.isKeyboardIslandOpen else { return false }
        swallowHotkeyUp = true
        dispatcher.keyboardIslandDictate()
        return true
    }

    /// Das Loslassen eines verbrauchten Hotkey-Drucks.
    func consumeDictationHotkeyUp() -> Bool {
        guard swallowHotkeyUp else { return false }
        swallowHotkeyUp = false
        return true
    }
}
