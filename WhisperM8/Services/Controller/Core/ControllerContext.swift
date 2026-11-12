import Foundation

/// Phase eines laufenden Diktats.
enum ControllerRecordingPhase: String, CaseIterable, Sendable {
    case recording, transcribing, postProcessing
}

/// Wohin L2 getippt zurückführt: der vorige Ort des Fensters, ein Chat oder
/// ein Workspace im Raster. Die Legende nennt ihn.
struct ControllerBackTarget: Equatable, Sendable {
    enum Kind: String, Sendable {
        case chat, workspace
    }

    var kind: Kind
    var title: String
    /// Chat- bzw. Workspace-ID. Dort beginnt die Markierung, wenn L2
    /// gehalten wird (Cmd-Tab: Loslassen führt ebenfalls dorthin).
    var id: UUID? = nil
}

/// Was der Controller über den Ziel-Chat wissen muss (Plan, „Kreuz, Kreis und
/// Viereck im Chat“). Der Schnappschuss wird beim Eintreffen einer Geste auf
/// dem MainActor gezogen.
struct ControllerChatState: Equatable, Sendable {
    enum Status: String, CaseIterable, Sendable {
        case idle, awaitingInput, working, unknown, ended
    }

    enum Profile: String, CaseIterable, Sendable {
        case claude, codex, shell, other
    }

    var status: Status
    var profile: Profile
    /// Im Eingabefeld steht vermutlich ein Entwurf (Draft-Tracker).
    var draftSuspected: Bool = false
    /// Irgendetwas steht vermutlich im Feld (Entwurf, Rückleger, ↑ oder →).
    /// Nur ohne das sperrt Pfeil links bei Claude.
    var fieldMayHaveText: Bool = false
    /// Gerade gesendet (`countsAsInterrupt` des Trackers).
    var recentlySubmitted: Bool = false
    /// Seit wann die Rückfrage offen ist; `nil`, wenn unbekannt.
    var secondsSinceAwaitingBegan: TimeInterval?
    /// Innerhalb der letzten Sekunde ging schon ein Escape an den Chat.
    var escapeSentRecently: Bool = false
    /// Kurz vorher per Controller getippt, gelöscht oder diktiert (ohne zu
    /// senden): Ein Entwurf zum Abschicken ist plausibel.
    var recentDraftInput: Bool = false
    /// Vor höchstens 5 s ein Pfeil vom Controller, der Kreuz scharf macht
    /// (nicht ↑ als erster Pfeil; `ControllerTerminalMarks.arrowArmWindow`).
    var recentArrowNavigation: Bool = false
    /// Das Controller-Menü hat eine Auswahlliste der CLI geöffnet (`/model`,
    /// `/config`, „/“ …), und sie ist vermutlich noch offen
    /// (`ControllerTerminalMarks`): Pfeile und Kreuz gehen dann ins Terminal.
    var choiceListOpen: Bool = false
    var gridActive: Bool = false
    /// Ein lebendes Terminal ist da (nicht nur der Verlauf).
    var hasTerminal: Bool = true
    /// Shell an ihrer Eingabezeile (kein Vollbild-Programm): R3 halten darf
    /// die Zeile leeren.
    var shellAtPrompt: Bool = false
    /// Ziel von L2 getippt; `nil`, wenn es keinen vorigen Ort (mehr) gibt.
    var backTarget: ControllerBackTarget?
    /// Am unteren Rand erkannte Claude-Ansicht, die Escape selbst abfängt
    /// (Runde 5, R2); `nil`, wenn keine erkannt oder nicht ablesbar.
    var openView: ControllerOpenView?
    /// Eingabefeld, wie es am Bildschirm steht; `nil`, wenn nicht ablesbar.
    var promptField: ControllerPromptField?

    /// Tasten, die ins Terminal schreiben, wirken nur bei lebendem Chat.
    var acceptsKeys: Bool { status != .ended && hasTerminal }
}

/// Was der Controller über den offenen Zwischenablage-Verlauf wissen muss.
struct ControllerClipboardState: Equatable, Sendable {
    /// Bild füllt das Fenster (große Ansicht).
    var isZoomed = false
    /// Rückfrage „Verlauf leeren?“ in der Fußzeile.
    var isConfirmingClear = false
    /// „Korrigieren und einfügen“ geht für den gewählten Eintrag.
    var canCorrect = false
    var selectedIsImage = false
    /// Menü (Options) im Verlauf offen.
    var menuOpen = false
}

/// Wo man während eines Diktats steht, dessen Ziel ein Chat ist (Runde 5,
/// Punkt 9): Dann navigieren Stick, L1/R1 und L2 wie sonst; der Text geht
/// trotzdem in den Chat, in dem das Diktat begann.
struct ControllerRecordingNavigation: Equatable, Sendable {
    var area: ControllerFocusArea
    var gridActive: Bool
}

/// Zusammenhang, in dem eine Geste ausgewertet wird (Plan 3.1).
enum ControllerContext: Equatable, Sendable {
    case paused
    /// Ein anderes Programm ist vorne. `wakeOnInput`: Fast jede Eingabe holt
    /// das Agent-Chats-Fenster nach vorn (nur mit Hintergrund-Empfang).
    case outsideApp(backgroundEnabled: Bool, wakeOnInput: Bool = false)
    /// `navigation`: nur, wenn das Diktat an einen Chat gebunden ist und das
    /// Agent-Chats-Fenster die Eingaben hat (Runde 5, Punkt 9).
    case recording(phase: ControllerRecordingPhase, targetIsChat: Bool, navigation: ControllerRecordingNavigation? = nil)
    case quickAction
    case clipboardPanel(ControllerClipboardState)
    case menu(dialogOpen: Bool)
    case modal
    case list
    case chat(ControllerChatState)
    case otherWindow
    case noWindow
}

enum ControllerWindowKind: String, Sendable {
    case agentChats, other, none
}

/// Bereich im Agent-Chats-Fenster: Liste links oder Inhalt rechts.
enum ControllerFocusArea: String, Sendable {
    case list, content
}

/// Einfache Momentaufnahme der App, aus der sich der Zusammenhang ergibt.
struct ControllerAppSnapshot: Equatable, Sendable {
    var isPaused: Bool = false
    var appIsActive: Bool = true
    var backgroundEnabled: Bool = false
    var wakeOnInputEnabled: Bool = false
    var recordingPhase: ControllerRecordingPhase?
    var recordingTargetIsChat: Bool = false
    /// Das Diktat ist an einen Chat gebunden (auch eine Shell).
    var recordingTargetBound: Bool = false
    var quickActionRunning: Bool = false
    var clipboardPanelOpen: Bool = false
    var clipboard = ControllerClipboardState()
    var controllerMenuOpen: Bool = false
    var window: ControllerWindowKind = .agentChats
    var modalOpen: Bool = false
    var area: ControllerFocusArea = .content
    var chat: ControllerChatState?
}

enum ControllerContextResolver {
    /// Vorrang: pausiert → Aufnahme → Schnellaktion → Zwischenablage-Verlauf →
    /// andere App vorn → kein Fenster → anderes Fenster → Menü → Dialog →
    /// Liste → Chat. Die Insel (L1, R1, L2 gehalten) ist kein eigener
    /// Zusammenhang: Ihre Gesten tragen die Ebene selbst (`.inLayer`), und die
    /// Legende bleibt beim Halten, wie sie ist. Aufnahme und Verlauf gehen vor „andere App“,
    /// weil sie auch dann bedienbar sein müssen.
    ///
    /// Ohne Chat im Inhalt gilt die Liste: Dort funktionieren Navigation und
    /// Create, mehr gibt es ohne Ziel-Chat nicht zu tun.
    static func context(for snapshot: ControllerAppSnapshot) -> ControllerContext {
        if snapshot.isPaused { return .paused }
        if let phase = snapshot.recordingPhase {
            // Navigation nur mit gebundenem Ziel und nur im Agent-Chats-Fenster
            // ohne Menü und Dialog: Bei „Programm vorne“ ginge der Text per ⌘V
            // dorthin, wo beim Stopp der Fokus liegt.
            let navigates = snapshot.recordingTargetBound && snapshot.appIsActive && snapshot.window == .agentChats
                && !snapshot.controllerMenuOpen && !snapshot.modalOpen
            let navigation = navigates
                ? ControllerRecordingNavigation(area: snapshot.area, gridActive: snapshot.chat?.gridActive ?? false)
                : nil
            return .recording(phase: phase, targetIsChat: snapshot.recordingTargetIsChat, navigation: navigation)
        }
        if snapshot.quickActionRunning { return .quickAction }
        if snapshot.clipboardPanelOpen { return .clipboardPanel(snapshot.clipboard) }
        if !snapshot.appIsActive {
            return .outsideApp(
                backgroundEnabled: snapshot.backgroundEnabled,
                wakeOnInput: snapshot.backgroundEnabled && snapshot.wakeOnInputEnabled
            )
        }
        switch snapshot.window {
        case .none: return .noWindow
        case .other: return .otherWindow
        case .agentChats: break
        }
        if snapshot.controllerMenuOpen {
            return .menu(dialogOpen: snapshot.chat?.status == .awaitingInput)
        }
        if snapshot.modalOpen { return .modal }
        guard snapshot.area == .content, let chat = snapshot.chat else { return .list }
        return .chat(chat)
    }
}
