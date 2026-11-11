import Foundation

/// Tasten, die als Bytes ins Terminal des Ziel-Chats gehen.
enum ControllerChatKey: String, CaseIterable, Sendable {
    case enter, escape, up, down, left, right, backspace

    init(_ direction: ControllerDirection) {
        switch direction {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        }
    }
}

/// Befehle an den Zwischenablage-Verlauf (angebunden an `ClipboardKeyCommand`
/// und das Menü im Verlauf).
enum ControllerClipboardCommand: String, CaseIterable, Sendable {
    case up, down, paste, pin, delete, close
    case correctAndPaste
    /// Filter „Alle“ bzw. „Diktate“ (L1 / R1).
    case filterAll, filterDictations
    /// Bild groß ansehen und zurück.
    case zoom
    /// Rückfrage „Verlauf leeren?“ bestätigen.
    case confirmClear
    case menuToggle, menuUp, menuDown, menuActivate
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
    /// Gestoppten Chat wieder starten — wie der Knopf „Starten“ im Kopf.
    case chatResume
    case nextWaitingChat
    case lastChat
    /// Im Raster von Kachel zu Kachel; am linken Rand macht der Ausführer
    /// daraus den Wechsel in die Liste.
    case moveInContent(ControllerDirection)
    /// Voriger bzw. nächster Chat in der Reihenfolge der Liste links, ohne die
    /// Liste zu betreten (L1/R1, in der Einzelansicht auch Stick hoch/runter).
    case adjacentChat(step: Int)
    /// Projekt-Auswahl „Neuer Chat“ öffnen (wie ⌘N), das aktuelle bzw.
    /// markierte Projekt vorausgewählt.
    case newChat
    case toggleMaximize
    case scroll(lines: Int)

    // Liste links
    case enterList
    case leaveList
    case listMove(step: Int)
    case listActivate
    case listFilter(step: Int)
    /// Viereck halten auf einer Chat-Zeile: dasselbe wie „−“/„×“ der Zeile.
    case listCloseRow
    /// R3 auf einer Chat-Zeile: gestoppten Chat starten, sonst nichts.
    case listStartRow

    // Zwischenablage-Verlauf
    case clipboardToggle
    case clipboard(ControllerClipboardCommand)

    // Menü (Options)
    case menuToggle
    case menuMove(step: Int)
    case menuActivate
    /// Kreis: eine Ebene zurück, auf der ersten Ebene schließen.
    case menuBack

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
