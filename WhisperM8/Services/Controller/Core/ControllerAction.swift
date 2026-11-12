import Foundation

/// Tasten, die als Bytes ins Terminal des Ziel-Chats gehen.
enum ControllerChatKey: String, CaseIterable, Sendable {
    case enter, escape, up, down, left, right, backspace
    /// Dreieck: ein Leerzeichen.
    case space
    /// Viereck lange gehalten: ganze Wörter löschen.
    case deleteWord
    /// L1 halten, dann Viereck: bis zum Zeilenanfang löschen (Ctrl+U).
    case deleteToLineStart
    /// L1 halten, dann Dreieck: Zeilenumbruch, ohne zu senden (Ctrl+J).
    case newline

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
    /// R3 halten: ganze Eingabe leeren (nicht in einer Rückfrage).
    case chatClearInput
    case lastChat
    /// Im Raster von Kachel zu Kachel; am linken Rand macht der Ausführer
    /// daraus den Wechsel in die Liste.
    case moveInContent(ControllerDirection)
    /// Voriger bzw. nächster Chat in der Reihenfolge der Liste links, ohne die
    /// Liste zu betreten (L1/R1).
    case adjacentChat(step: Int)
    /// Projekt-Auswahl „Neuer Chat“ öffnen (wie ⌘N), das aktuelle bzw.
    /// markierte Projekt vorausgewählt.
    case newChat
    case toggleMaximize
    case scroll(lines: Int)

    // Liste links
    /// Liste betreten, Markierung auf dem aktuellen Chat, dann `step`
    /// Schritte weiter (Einzelansicht: Stick hoch/runter, Runde 3). Der
    /// offene Chat bleibt; gewechselt wird erst mit Kreuz.
    case enterList(step: Int)
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

    // Controller-Insel (Runde 4): L1, R1 und L2 gehalten
    /// Ebene ist seit 0,3 s gehalten: Insel einblenden.
    case islandShow(ControllerLayer)
    /// Ebenen-Taste los oder Ebene abgebrochen: Insel weg, nichts weiter.
    case islandClose
    /// L2 losgelassen: mit offener Liste zum markierten Eintrag wechseln,
    /// sonst nur schließen.
    case islandRelease
    /// Kreis in „Wohin“: abbrechen; bis zum Loslassen von L2 bleibt es still.
    case islandCancel
    /// „Wohin“: hoch/runter. Der erste Stoß öffnet die Liste und rückt gleich
    /// einen Schritt vom aktuellen Eintrag weiter.
    case islandMove(step: Int)
    /// „Wohin“: links/rechts zwischen den Reitern Chats und Workspaces.
    case islandTab(step: Int)
    /// „Wohin“: Kreuz wechselt sofort.
    case islandCommit
    /// „Wohin“: R2 wechselt zum markierten Chat und diktiert.
    case islandCommitAndDictate
    /// „Wohin“: Dreieck springt zum nächsten wartenden Chat (reihum).
    case islandNextWaiting
    /// Schnellbefehl der R1-Raute; dieselben Wege und Schutzregeln wie der
    /// Eintrag im Options-Menü.
    case quickDraw(ControllerMenuItem)

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
