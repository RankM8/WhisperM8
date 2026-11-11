import Foundation

/// Tasten, die als Bytes ins Terminal des Ziel-Chats gehen.
enum ControllerChatKey: String, CaseIterable, Sendable {
    case enter, escape, up, down, left, right

    init(_ direction: ControllerDirection) {
        switch direction {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        }
    }
}

/// Befehle an den Zwischenablage-Verlauf (angebunden an `ClipboardKeyCommand`).
enum ControllerClipboardCommand: String, CaseIterable, Sendable {
    case up, down, paste, pin, delete, close
}

/// Tasten der Tastatur-Brücke für Dialoge und andere Fenster (Plan 3.6).
enum ControllerBridgeKey: String, CaseIterable, Sendable {
    case up, down, left, right, returnKey, escape, tab, backTab

    init(_ direction: ControllerDirection) {
        switch direction {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        }
    }
}

/// Fachliche Aktionen; der Ausführer auf dem MainActor setzt sie um.
enum ControllerAction: Equatable, Sendable {
    // Diktat
    case dictationToggle
    case dictationStopAndSubmit
    case dictationCancel
    case outputMode(step: Int)

    // Chat
    case chatKey(ControllerChatKey)
    case chatInterrupt
    case chatClearComposer
    case nextWaitingChat
    case lastChat
    case tab(step: Int)
    /// Im Raster von Kachel zu Kachel; am linken Rand macht der Ausführer
    /// daraus den Wechsel in die Liste.
    case moveInContent(ControllerDirection)
    case newChat
    case toggleMaximize
    case scroll(lines: Int)

    // Liste links
    case enterList
    case leaveList
    case listMove(step: Int)
    case listActivate
    case listFilter(step: Int)

    // Zwischenablage-Verlauf
    case clipboardToggle
    case clipboard(ControllerClipboardCommand)

    // Menü (Options)
    case menuToggle
    case menuMove(step: Int)
    case menuActivate

    // Chat-Auswahl (L2)
    case pickerBegin
    case pickerMove(ControllerDirection)
    case pickerCommit
    case pickerCancel
    case pickerCommitAndDictate

    // Sonstiges
    case bridgeKey(ControllerBridgeKey)
    case pauseToggle
    case bringAppToFront
    /// Rückmeldung „geht nicht“ (drei kleine Ticks).
    case rejected
    /// Halte-Fortschritt anzeigen (endliche Animation mit bekannter Dauer).
    case holdProgress(ControllerButton, duration: TimeInterval)
    case holdProgressCancelled(ControllerButton)
}
