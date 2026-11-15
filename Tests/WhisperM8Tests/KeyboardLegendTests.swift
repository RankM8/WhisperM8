import AppKit
import Observation
import XCTest
@testable import WhisperM8

/// Legende per Tastatur (WM8-104, Paket 3): folgt dem zuletzt benutzten
/// Gerät, nur mit eingeschalteter Controller-Steuerung.
@MainActor
final class KeyboardLegendTests: XCTestCase {
    private func mode(
        legend: Bool = true, running: Bool = true, device: Bool, last: ControllerIslandInput, keyboard: Bool = true
    ) -> KeyboardLegend.Mode {
        KeyboardLegend.mode(legendEnabled: legend, controllerRunning: running, deviceConnected: device,
                            lastInput: last, keyboardIslandEnabled: keyboard)
    }

    func testFollowsLastDeviceOnlyWithControllerOn() {
        XCTAssertEqual(mode(device: true, last: .controller), .controller)
        XCTAssertEqual(mode(device: true, last: .keyboard), .keyboard, "nach ⌥Tab")
        XCTAssertEqual(mode(device: false, last: .controller), .keyboard, "ohne verbundenen Controller")
        XCTAssertEqual(mode(running: false, device: false, last: .keyboard), .none, "Steuerung aus: keine Leiste wie bisher")
        XCTAssertEqual(mode(legend: false, device: true, last: .keyboard), .none, "Schalter Legende aus")
    }

    /// Ohne ⌥Tab (Schalter aus) nennt die Leiste keine Tastatur-Kürzel.
    func testKeyboardIslandOff() {
        XCTAssertEqual(mode(device: true, last: .keyboard, keyboard: false), .controller)
        XCTAssertEqual(mode(device: false, last: .keyboard, keyboard: false), .none)
    }

    func testItems() {
        XCTAssertEqual(KeyboardLegend.items(dictationKeys: ["⌥", "␣"]).map(\.keys), [["⌥", "⇥"], ["⌥", "␣"], ["⌃", "⇥"]])
        XCTAssertEqual(KeyboardLegend.items(dictationKeys: nil).count, 2, "ohne Diktat-Hotkey kein Eintrag")
    }

    /// ⌥Tab merkt „Tastatur“, die nächste Controller-Eingabe „Controller“;
    /// das Options-Menü per Tastatur bleibt „Tastatur“, obwohl es über
    /// denselben Ausführer läuft.
    func testLastInputSwitches() {
        let window = ControllerWindowFake()
        let center = AgentChatsCommandCenter(keyWindowID: { window.id })
        _ = center.register(windowID: window.id, handler: window.handler)
        let ui = ControllerUIModel()
        let dispatcher = ControllerActionDispatcher(
            chats: center, terminals: ControllerTerminalSpy(), dictation: ControllerDictationSpy(),
            environment: ControllerEnvironmentSpy(), ui: ui, island: ControllerIslandSpy())
        XCTAssertEqual(ui.lastInput, .controller)
        XCTAssertTrue(dispatcher.openKeyboardIsland())
        XCTAssertEqual(ui.lastInput, .keyboard)
        dispatcher.perform(.rejected, in: .list)
        XCTAssertEqual(ui.lastInput, .controller)
        ui.menu = ControllerMenuModel(setup: ControllerMenuSetup())
        ui.menuByKeyboard = true
        dispatcher.keyboardMenu(.move(1))
        XCTAssertEqual(ui.lastInput, .keyboard)
        // Steht schon „Tastatur“, schreibt das Menü per Tastatur gar nicht mehr
        // (kein Umweg über „Controller“, Gegenlesen Paket 3).
        var changes = 0
        withObservationTracking { _ = ui.lastInput } onChange: { changes += 1 }
        dispatcher.keyboardMenu(.move(1))
        XCTAssertEqual(changes, 0)
        XCTAssertEqual(ui.lastInput, .keyboard)
        XCTAssertFalse(dispatcher.performingForKeyboard)
    }
}
