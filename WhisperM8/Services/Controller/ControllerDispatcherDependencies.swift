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
    /// Irgendetwas steht vermutlich im Feld (auch Rückleger, zurückgeholter
    /// oder per → übernommener Text) — `TerminalComposerDraftTracker.fieldMayHaveText`.
    var fieldMayHaveText: Bool = false
    /// Wann zuletzt abgeschickt wurde, auf jedem Weg (Enter vom Controller
    /// oder von der Tastatur, `chats send`, Diktat und Menü mit Senden).
    var lastEnterAt: Date?
    /// Wann zuletzt Escape vom Controller rausging.
    var lastEscapeAt: Date?
    /// Zuletzt per Controller ins Eingabefeld geschrieben oder gelöscht
    /// (Rücktaste, Text oder Diktat ohne Senden). Zählt nur, wenn es nach dem
    /// letzten Absenden (`lastEnterAt`) liegt.
    var lastDraftInputAt: Date? = nil
    /// Letzter Pfeil vom Controller, der Kreuz scharf macht.
    var lastArmingArrowAt: Date? = nil
    /// Eine Auswahlliste, die das Controller-Menü geöffnet hat, ist vermutlich
    /// noch offen (`ControllerTerminalMarks.isChoiceListOpen`).
    var choiceListOpen: Bool = false
    /// Shell an ihrer Eingabezeile (normaler Puffer, kein Vollbild-Programm
    /// wie nano oder vim) — dort darf R3 die Zeile leeren.
    var shellAtPrompt: Bool = false
    /// Abgelesener unterer Rand (offene Ansicht, Eingabefeld); `nil`, wenn
    /// nicht ablesbar (hochgescrollt, Shell, kein Prozess).
    var screen: ControllerScreenSnapshot? = nil
    /// Eigene Prompts in Claudes Warteschlange (`ClaudeQueueScan`, Stand des
    /// letzten Transcript-Polls; Runde 5, R1).
    var queuedOwnPrompts: Int = 0
    /// Im Feld steht vermutlich nur ein zurückgelegter oder mit ↑
    /// zurückgeholter Prompt, nichts selbst Getipptes (R1 + Kreuz lehnt ab).
    var onlyRecalledPrompt: Bool = false
    /// Die TUI hat Bracketed Paste eingeschaltet (Einfügen in Shells).
    var bracketedPaste: Bool = false
}

/// Zugriff auf den Zwischenablage-Verlauf für L1 + Kreuz (Runde 5). Closures
/// statt Protokoll, damit Tests synchron antworten können.
@MainActor
struct ControllerClipboardAccess {
    /// Neuester Eintrag (Text oder Bild), aus dem Index im Speicher.
    var newest: () -> ControllerClipPreview? = { nil }
    /// Vollen Text laden (lange Texte liegen in einer Datei).
    var loadText: (_ id: String, _ completion: @escaping @MainActor (String?) -> Void) -> Void = { $1(nil) }
    /// Bild in die allgemeine Zwischenablage legen (als eigener Schreibvorgang
    /// beansprucht, landet also nicht doppelt im Verlauf).
    var copyImage: (_ id: String, _ completion: @escaping @MainActor (Bool) -> Void) -> Void = { $1(false) }
}

/// Zuletzt geschlossene Chats dieses App-Starts (L2 + Viereck, Runde 5).
@MainActor
struct ControllerClosedChatsAccess {
    /// Titel des Chats, den „Wieder öffnen“ als nächstes zurückholt.
    var nextTitle: () -> String? = { nil }
    /// Holt ihn zurück; `false`, wenn es keinen gibt.
    var reopen: () -> Bool = { false }
}

@MainActor
protocol ControllerTerminalControlling: AnyObject {
    /// `nil`: Für diesen Chat gibt es kein Terminal (reiner Verlauf).
    func state(of sessionID: UUID) -> ControllerTerminalState?
    @discardableResult func sendKey(_ key: TerminalControlKey, to sessionID: UUID) -> Bool
    func scroll(lines: Int, in sessionID: UUID)
    /// Ganze Eingabe leeren (R3 halten); `false` bei offener Rückfrage oder
    /// ohne laufenden Prozess.
    @discardableResult func clearInput(in sessionID: UUID) -> Bool
    /// Text als ein Block ins Eingabefeld, wahlweise mit Senden.
    @discardableResult func sendText(_ text: String, submit: Bool, to sessionID: UUID) -> Bool
    /// Der eben gesendete Menü-Befehl öffnet eine Auswahlliste der CLI.
    func noteChoiceListOpened(in sessionID: UUID)
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

/// Anzeige der Controller-Insel (eigenes Fenster an der Notch bzw. als Pille
/// unter der Menüleiste). Die Live-Fassung ist `ControllerIslandPresenter`.
@MainActor
protocol ControllerIslandPresenting: AnyObject {
    /// Einblenden oder, wenn sie schon steht, auf den neuen Inhalt bringen.
    /// - Parameter screenDisplayID: Bildschirm des Agent-Chats-Fensters.
    func show(_ model: ControllerIslandModel, screenDisplayID: UInt32?)
    func hide()
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
