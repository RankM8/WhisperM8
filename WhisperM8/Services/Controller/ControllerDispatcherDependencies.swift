import Foundation
import Observation

// Schnittstellen, über die der `ControllerActionDispatcher` die App bedient.
// Die Live-Fassungen stehen in `ControllerLiveAdapters.swift`; Tests setzen
// Attrappen ein.

/// Was der Ausführer über das Terminal eines Chats wissen muss.
struct ControllerTerminalState: Equatable {
    var isRunning: Bool
    var profile: ControllerChatState.Profile
    var status: AgentSessionRuntimeStatus?
    /// Seit wann der aktuelle Status gilt.
    var statusSince: Date?
    var draftSuspected: Bool
    /// Wann zuletzt Enter bzw. Escape vom Controller rausging.
    var lastEnterAt: Date?
    var lastEscapeAt: Date?
}

@MainActor
protocol ControllerTerminalControlling: AnyObject {
    /// `nil`: Für diesen Chat gibt es kein Terminal (reiner Verlauf).
    func state(of sessionID: UUID) -> ControllerTerminalState?
    @discardableResult func sendKey(_ key: TerminalControlKey, to sessionID: UUID) -> Bool
    func scroll(lines: Int, in sessionID: UUID)
    /// Text als ein Block ins Eingabefeld, wahlweise mit Senden.
    @discardableResult func sendText(_ text: String, submit: Bool, to sessionID: UUID) -> Bool
}

@MainActor
protocol ControllerDictationControlling: AnyObject {
    /// Läuft gerade eine Aufnahme, Transkription oder Nacharbeit?
    var phase: ControllerRecordingPhase? { get }
    var isQuickActionRunning: Bool { get }
    /// Chat, in den die laufende Aufnahme geht; `nil` = vorderes Programm.
    var targetSessionID: UUID? { get }
    /// `label`: Ziel, das die Pill zeigt („Titel des Chats“, „Programm vorne“).
    func start(target: DictationDeliveryTarget, label: String?)
    func stop(submit: Bool)
    /// Bricht ab, was gerade läuft: Aufnahme, Transkription, Nacharbeit oder
    /// Schnellaktion.
    func cancel()
    func stepOutputMode(_ step: Int)
}

@MainActor
protocol ControllerAppEnvironment: AnyObject {
    var isAppActive: Bool { get }
    /// Ein WhisperM8-Fenster ist Key, das kein Agent-Chats-Fenster ist
    /// (Einstellungen, Onboarding).
    var hasOtherKeyWindow: Bool { get }
    /// Im Key-Fenster ist etwas offen, dem die Eingaben gehören: Popover,
    /// Menü oder ein Textfeld mit Fokus.
    var isModalOpen: Bool { get }
    var isClipboardPanelOpen: Bool { get }
    /// Zustand des offenen Verlaufs (große Bildansicht, Rückfrage, Menü …).
    var clipboardState: ControllerClipboardState { get }
    func toggleClipboardPanel()
    func clipboard(_ command: ControllerClipboardCommand)
    func bringAgentChatsToFront()
    func postBridgeKey(_ key: ControllerBridgeKey)
    func openControllerSettings()
}

/// Fortschritt eines Haltens, als Start und Dauer: Die Anzeige läuft als eine
/// endliche Animation, nicht als Wert pro Bild.
struct ControllerHoldProgress: Equatable {
    var button: ControllerButton
    var startedAt: Date
    var duration: TimeInterval
}

/// Sichtbarer Zustand der Controller-Führung: Bereich, Markierung in der
/// Liste, offenes Menü, Halte-Fortschritt.
///
/// Eigener Beobachtungswert. Die großen Ansichten lesen ihn nicht; nur die
/// kleinen Stücke, die etwas davon zeigen (Markierung je Zeile, Menü, Legende).
@MainActor
@Observable
final class ControllerUIModel {
    static let shared = ControllerUIModel()

    /// Fenster, in dem die Liste gerade den Fokus hat.
    var listWindowID: UUID?
    var area: ControllerFocusArea = .content
    var markedRow: SidebarNavigationRow?
    /// Offenes Menü (Options); `nil` = zu.
    var menu: ControllerMenuModel?
    /// Offene Workspace-Auswahl (L2 halten im Raster); `nil` = zu.
    var workspacePicker: ControllerWorkspacePickerModel?
    /// Im Ziel-Chat ist eine Rückfrage offen: Einträge, die Text senden, sind aus.
    var menuDialogOpen = false
    var holdProgress: ControllerHoldProgress?
    /// Zusammenhang der letzten Eingabe — daraus baut die Legende ihre Zeile.
    var context: ControllerContext = .noWindow
    /// Titel des Ziel-Chats für die Legende.
    var targetTitle: String?

    @ObservationIgnored var listModel = SidebarNavigationModel()

    /// Zurück in den Inhalt (Maus, Tastatur, Auswahl von außen).
    func leaveList() {
        guard area != .content || markedRow != nil else { return }
        area = .content
        markedRow = nil
        listWindowID = nil
    }
}
