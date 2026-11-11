import Foundation

/// Phase eines laufenden Diktats.
enum ControllerRecordingPhase: String, CaseIterable, Sendable {
    case recording, transcribing, postProcessing
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
    /// Gerade gesendet (`countsAsInterrupt` des Trackers).
    var recentlySubmitted: Bool = false
    /// Seit wann die Rückfrage offen ist; `nil`, wenn unbekannt.
    var secondsSinceAwaitingBegan: TimeInterval?
    /// Innerhalb der letzten Sekunde ging schon ein Escape an den Chat.
    var escapeSentRecently: Bool = false
    var gridActive: Bool = false
    /// Ein lebendes Terminal ist da (nicht nur der Verlauf).
    var hasTerminal: Bool = true

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

/// Zusammenhang, in dem eine Geste ausgewertet wird (Plan 3.1).
enum ControllerContext: Equatable, Sendable {
    case paused
    case outsideApp(backgroundEnabled: Bool)
    case recording(phase: ControllerRecordingPhase, targetIsChat: Bool)
    case quickAction
    case clipboardPanel(ControllerClipboardState)
    case menu(dialogOpen: Bool)
    case chatPicker
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
    var recordingPhase: ControllerRecordingPhase?
    var recordingTargetIsChat: Bool = false
    var quickActionRunning: Bool = false
    var clipboardPanelOpen: Bool = false
    var clipboard = ControllerClipboardState()
    var controllerMenuOpen: Bool = false
    var chatPickerOpen: Bool = false
    var window: ControllerWindowKind = .agentChats
    var modalOpen: Bool = false
    var area: ControllerFocusArea = .content
    var chat: ControllerChatState?
}

enum ControllerContextResolver {
    /// Vorrang: pausiert → Aufnahme → Schnellaktion → Zwischenablage-Verlauf →
    /// andere App vorn → kein Fenster → anderes Fenster → Menü → Chat-Auswahl →
    /// Dialog → Liste → Chat. Aufnahme und Verlauf gehen vor „andere App“,
    /// weil sie auch dann bedienbar sein müssen.
    ///
    /// Ohne Chat im Inhalt gilt die Liste: Dort funktionieren Navigation und
    /// Create, mehr gibt es ohne Ziel-Chat nicht zu tun.
    static func context(for snapshot: ControllerAppSnapshot) -> ControllerContext {
        if snapshot.isPaused { return .paused }
        if let phase = snapshot.recordingPhase {
            return .recording(phase: phase, targetIsChat: snapshot.recordingTargetIsChat)
        }
        if snapshot.quickActionRunning { return .quickAction }
        if snapshot.clipboardPanelOpen { return .clipboardPanel(snapshot.clipboard) }
        if !snapshot.appIsActive { return .outsideApp(backgroundEnabled: snapshot.backgroundEnabled) }
        switch snapshot.window {
        case .none: return .noWindow
        case .other: return .otherWindow
        case .agentChats: break
        }
        if snapshot.controllerMenuOpen {
            return .menu(dialogOpen: snapshot.chat?.status == .awaitingInput)
        }
        if snapshot.chatPickerOpen { return .chatPicker }
        if snapshot.modalOpen { return .modal }
        guard snapshot.area == .content, let chat = snapshot.chat else { return .list }
        return .chat(chat)
    }
}
