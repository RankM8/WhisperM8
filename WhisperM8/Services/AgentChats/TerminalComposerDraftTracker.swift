import AppKit
import Foundation

/// Schaetzt konservativ, was im Eingabefeld (Composer) einer Claude-/Codex-TUI
/// stehen koennte. Zwei Fragen, zwei Flags:
///
/// - `mayHaveUnsentInput`: ein eigener, noch nicht abgeschickter Entwurf des
///   Users. Ein Beenden der TUI verwirft ihn (`--stop-and-resume` verweigert
///   ohne `--force`), ein programmatischer Versand hinge sich daran (`send`
///   lehnt ab, die Queue wartet — `PromptDeliveryGate`).
/// - `mayHoldRestoredPrompt`: ein alter Prompt, den die Claude-CLI selbst
///   zurueckgelegt hat — nach einem Abbruch (ESC, Ctrl+C) oder per
///   Doppel-ESC-Rewind. Er steht schon im Transcript; ein programmatischer
///   Versand leert das Feld vorher (`AgentTerminalController.sendPrompt`).
///
/// Warum Schaetzung und kein Lesen des Terminal-Puffers (Review S1,
/// 05.11.2026): Die Claude-TUI zeichnet ihr Eingabefeld mit Ink, versteckt den
/// echten Cursor, zeigt im leeren Feld einen Platzhaltertext, und Rahmen,
/// Prompt-Zeichen und Position wechseln mit Version, Theme, Mods und
/// Fensterbreite; Codex zeichnet ganz anders. Ein Parser darauf waere ein
/// stiller Fehlerpfad. Die Tastendruecke und die eigenen Zustellungen sieht die
/// App dagegen vollstaendig — die Schaetzung ist deshalb bewusst grob, aber
/// fehlt im Zweifel in die sichere Richtung.
///
/// Konservativ heisst: im Zweifel „vielleicht". Ein Fehlalarm kostet ein
/// `--force`, eine Wartezeit in der Queue oder ein harmloses Ctrl+C in ein
/// leeres Feld; ein uebersehener Rueckleger liesse einen zurueckgezogenen
/// Auftrag zusammen mit dem neuen erneut laufen.
struct TerminalComposerDraftTracker: Equatable {
    /// So lange nach einem programmatischen Absenden gilt ESC/Ctrl+C als
    /// Abbruch, auch wenn der Status noch nicht `working` zeigt: Der
    /// Registry-Status kommt mit kurzer Verzoegerung nach dem Return, ein
    /// schnelles ESC lief sonst als „nur ESC" durch (Review S1, Fall 2).
    static let interruptWindowAfterProgrammaticSubmit: TimeInterval = 5

    private(set) var mayHaveUnsentInput = false
    /// Ein Turn wurde abgebrochen (ESC, Ctrl+C, `chats interrupt`) oder ein
    /// Rewind hat eine alte Nachricht ins Feld gelegt. Ein programmatischer
    /// Versand haengte seinen Text daran an, und der abgebrochene Auftrag
    /// liefe mit dem neuen Prompt zusammen erneut los (E2E 17.10.2026).
    private(set) var mayHoldRestoredPrompt = false
    /// Der Controller hat mit → einen grauen Vorschlag ins Feld geholt
    /// (Claude). Zaehlt nur fuer `fieldMayHaveText`, nicht als eigener Entwurf.
    private(set) var mayShowAcceptedSuggestion = false
    /// Zeitpunkt des letzten programmatischen Absendens (`chats send`,
    /// Queue-Zustellung).
    private(set) var lastProgrammaticSubmitAt: Date?
    /// Ein Abbruch kam nach dem letzten Absenden. Dann darf ein spaet
    /// gemeldeter Turn-Start (der zu genau diesem abgebrochenen Turn gehoert)
    /// den Rueckleger nicht wieder vergessen.
    private var interruptedSinceSubmit = false
    /// Zaehlt jedes Schreiben ins Feld, das nicht getippt ist (Absenden,
    /// Einfuegen, Datei-Drop, Leeren). Ein verzögertes Ctrl+C prüft daran, ob seit seiner Planung
    /// jemand anderes geschrieben hat (`deferredClearIsSafe`).
    private(set) var programmaticWrites = 0
    /// Aufeinanderfolgende ESC ohne Text dazwischen. Ab zwei oeffnet Claude im
    /// leeren Feld die Rewind-Auswahl; das Return darin ist kein Absenden.
    private var escapeRun = 0

    /// Vor einem programmatischen Versand zuerst leeren? Nur bei vermutetem
    /// zurueckgelegtem Prompt — der steht schon im Transcript. Ein eigener
    /// Entwurf des Users (auch ein bearbeiteter Rueckleger) bleibt unangetastet;
    /// dann haelt `PromptDeliveryGate` die Zustellung an.
    var shouldClearBeforeSubmit: Bool {
        mayHoldRestoredPrompt && !mayHaveUnsentInput
    }

    /// Darf ein Ctrl+C, das beim Stand `writes` geplant wurde, jetzt noch
    /// raus? Nur, wenn seitdem nichts programmatisch geschrieben hat.
    func deferredClearIsSafe(sinceWrites writes: Int) -> Bool {
        programmaticWrites == writes
    }

    /// ESC ohne Modifier oder Ctrl+C: in der Claude-TUI waehrend eines Turns
    /// der Abbruch. Auch der Status-Koordinator meldet damit den
    /// Abbruch-Verdacht (`observeTerminalInterruptKey`, Review R2).
    static func isInterruptKey(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        let flags = modifiers.intersection(.deviceIndependentFlagsMask)
        return (keyCode == 53 && flags.isEmpty) || (keyCode == 8 && flags.contains(.control))
    }

    /// Zaehlt ein ESC/Ctrl+C (Taste oder `chats interrupt`) bei diesem Status
    /// als Abbruch eines Turns?
    func countsAsInterrupt(status: AgentSessionRuntimeStatus?, now: Date) -> Bool {
        if status == .working { return true }
        guard let lastProgrammaticSubmitAt else { return false }
        return now.timeIntervalSince(lastProgrammaticSubmitAt) < Self.interruptWindowAfterProgrammaticSubmit
    }

    /// Ein Turn laeuft an — also wurde abgeschickt. Ein danach Getipptes
    /// setzt die Schaetzung wieder. Ein Abbruch, der NACH dem Absenden kam,
    /// bleibt stehen: Der Status meldet den Start dieses Turns oft erst, wenn
    /// das ESC schon durch ist.
    /// Steht vermutlich irgendetwas im Feld — eigener Entwurf, Rueckleger,
    /// zurueckgeholter oder per → uebernommener Text? Nur wenn nicht, sperrt
    /// der Controller Pfeil links bei Claude (leeres Feld: ← schickt die
    /// Sitzung in die Agent-Ansicht).
    var fieldMayHaveText: Bool {
        mayHaveUnsentInput || mayHoldRestoredPrompt || mayShowAcceptedSuggestion
    }

    /// → vom Controller ausserhalb einer Rueckfrage und offenen Auswahl: holt
    /// in Claude den grauen Vorschlag ins Feld.
    mutating func recordSuggestionAccepted() {
        mayShowAcceptedSuggestion = true
    }

    mutating func recordSubmittedByTurnStart() {
        mayHaveUnsentInput = false
        mayShowAcceptedSuggestion = false
        escapeRun = 0
        if !interruptedSinceSubmit {
            mayHoldRestoredPrompt = false
        }
    }

    mutating func recordTurnInterrupted() {
        mayHoldRestoredPrompt = true
        interruptedSinceSubmit = true
    }

    /// `chats interrupt` hat ein ESC geschickt.
    mutating func recordInterruptSignal(status: AgentSessionRuntimeStatus?, now: Date) {
        if countsAsInterrupt(status: status, now: now) {
            recordTurnInterrupted()
        }
    }

    /// Tastendruck an die Terminal-View, mit Kontext. Ergaenzt
    /// `recordKeyDown` um das, was nur in einer Claude-TUI gilt
    /// (`restoresPromptOnInterrupt`): Abbruch per ESC/Ctrl+C legt den Prompt
    /// zurueck, Doppel-ESC + Return holt per Rewind eine alte Nachricht ins
    /// Feld. In Dialogen (`awaitingInput`: Freigabe, Frage, Plan) antworten
    /// 1/2/y ohne Enter und ESC schliesst den Dialog — das betrifft das
    /// Eingabefeld nicht (LR-CLI-002).
    mutating func recordTerminalKey(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        status: AgentSessionRuntimeStatus?,
        restoresPromptOnInterrupt: Bool,
        now: Date
    ) {
        guard status != .awaitingInput else { return }
        guard restoresPromptOnInterrupt else {
            recordKeyDown(keyCode: keyCode, modifiers: modifiers)
            return
        }
        let flags = modifiers.intersection(.deviceIndependentFlagsMask)
        let isEscape = keyCode == 53 && flags.isEmpty
        let isControlC = Self.isInterruptKey(keyCode: keyCode, modifiers: modifiers) && !isEscape
        let isSubmit = (keyCode == 36 || keyCode == 76) && !flags.contains(.shift) && !flags.contains(.option)

        if isEscape || isControlC, countsAsInterrupt(status: status, now: now) {
            // Abbruch: Claude legt den Prompt des Turns zurueck. Ctrl+C leert
            // dabei ein Feld mit Text, statt abzubrechen — ein eigener Entwurf
            // ist danach also weg; ein vermuteter Rueckleger schadet nicht.
            recordTurnInterrupted()
            if isControlC { mayHaveUnsentInput = false }
            // Ein zweites ESC kann schon die Rewind-Auswahl oeffnen.
            escapeRun = isEscape ? escapeRun + 1 : 0
            return
        }
        if isEscape {
            escapeRun += 1
            return
        }
        if isSubmit, escapeRun >= 2, !mayHaveUnsentInput {
            // Auswahl in der Rewind-Liste (Doppel-ESC im leeren Feld): Claude
            // legt die gewaehlte alte Nachricht ins Feld, abgeschickt wird
            // nichts.
            escapeRun = 0
            mayHoldRestoredPrompt = true
            interruptedSinceSubmit = true
            return
        }
        if !Self.navigationKeyCodes.contains(keyCode) {
            escapeRun = 0
        }
        recordKeyDown(keyCode: keyCode, modifiers: modifiers)
    }

    /// Pfeile, Bild, Pos1/Ende: Bewegen in der Rewind-Liste, kein Text.
    private static let navigationKeyCodes: Set<UInt16> = [115, 116, 119, 121, 123, 124, 125, 126]

    /// Tastendruck, der an die Terminal-View ging — nur die Text-Schaetzung,
    /// ohne Abbruch-Logik (siehe `recordTerminalKey`).
    mutating func recordKeyDown(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        let flags = modifiers.intersection(.deviceIndependentFlagsMask)
        switch keyCode {
        case 36, 76:
            // Return/Enter schickt ab; mit Shift/Option ist es ein Zeilenumbruch
            // im Entwurf.
            if flags.contains(.shift) || flags.contains(.option) {
                mayHaveUnsentInput = true
            } else {
                mayHaveUnsentInput = false
                mayHoldRestoredPrompt = false
                mayShowAcceptedSuggestion = false
                interruptedSinceSubmit = false
            }
        case 8 where flags.contains(.control):
            // Ctrl+C leert in Claude Code den Composer.
            mayHaveUnsentInput = false
            mayHoldRestoredPrompt = false
            mayShowAcceptedSuggestion = false
            interruptedSinceSubmit = false
        case 9 where flags.contains(.command):
            // Cmd+V fuegt ein.
            mayHaveUnsentInput = true
        case 53, 48, 51, 117, 115, 119, 116, 121, 123, 124, 125, 126:
            // ESC, Tab, Loeschen, Navigation: fuegen keinen neuen Text ein. Ein
            // nach ESC-Abbruch zurueckgelegter Prompt steht bereits im
            // Transcript — ihn zu verwerfen verliert nichts.
            break
        default:
            // Andere Cmd-/Ctrl-Kuerzel sind Bedienung, kein Text.
            if flags.contains(.command) || flags.contains(.control) { break }
            mayHaveUnsentInput = true
        }
    }

    /// Pfeil hoch vom Controller ausserhalb einer Rueckfrage und einer offenen
    /// Auswahl: holt den letzten Prompt (in einer Shell den letzten Befehl)
    /// ins Feld. Bei Claude steht er schon im Transcript wie ein Rueckleger —
    /// ein programmatischer Versand („Weiter“, Menue-Befehl, `chats send`)
    /// leert das Feld vorher. Sonst gilt er vorsichtshalber als Entwurf.
    mutating func recordHistoryRecall(isClaude: Bool) {
        if isClaude {
            mayHoldRestoredPrompt = true
        } else {
            mayHaveUnsentInput = true
        }
    }

    /// Eingefuegter Text ohne Absenden (Datei-Drop, Report-Routing,
    /// `chats send --no-submit`).
    mutating func recordTextInserted() {
        mayHaveUnsentInput = true
        programmaticWrites += 1
    }

    /// Programmatisch abgeschickt (`chats send`, Queue-Zustellung) oder
    /// geleert (Ctrl+C von `sendComposerClear`). `programmaticAt` nur beim
    /// echten Absenden: ab dann laeuft das Abbruch-Fenster.
    mutating func recordSubmitted(programmaticAt date: Date? = nil) {
        mayHaveUnsentInput = false
        mayHoldRestoredPrompt = false
        mayShowAcceptedSuggestion = false
        interruptedSinceSubmit = false
        escapeRun = 0
        programmaticWrites += 1
        if let date { lastProgrammaticSubmitAt = date }
    }
}
