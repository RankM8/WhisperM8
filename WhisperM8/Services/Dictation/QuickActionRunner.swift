import AppKit

/// Ausgang einer Schnellaktion (Log, Tests).
enum QuickActionOutcome: Equatable {
    /// Markierung durch das Ergebnis ersetzt.
    case replaced
    /// Das Ergebnis war gleich der Markierung, nichts eingefügt.
    case unchanged
    /// Feld nicht beschreibbar oder Einfügen gescheitert: Ergebnis liegt in
    /// der Zwischenablage.
    case copiedToClipboard
    case noSelection
    case cancelled
    case failed(String)
    /// Modus ohne Nacharbeit, unbekannter Modus oder Umfang „Nur Diktat“.
    case unavailable
    /// Ein Diktat oder eine andere Schnellaktion läuft noch.
    case busy
}

/// Woher der Text kommt.
enum QuickActionInput: Equatable {
    /// Markierung der vorderen App lesen und an Ort und Stelle ersetzen
    /// (Kurzbefehl, Menüleiste, Kopfzeile im Zwischenablage-Fenster).
    case selection
    /// Vorgegebener Text, etwa ein Eintrag aus dem Zwischenablage-Verlauf:
    /// umarbeiten und an der Schreibmarke der vorderen App einfügen.
    case text(String)
}

/// Anzeige der Schnellaktion. Live ist das das Aufnahme-Overlay.
@MainActor
protocol QuickActionPresenting: AnyObject {
    /// Pill mit Arbeits-Animation, Text (etwa „Korrigiere…“) und ✕.
    func showQuickActionWorking(label: String, onCancel: @escaping () -> Void)
    /// Kurzer Hinweis, der nach `duration` Sekunden von selbst verschwindet.
    func showQuickActionHint(_ text: String, duration: TimeInterval)
    func hideQuickAction()
}

/// Alle Systemzugriffe der Schnellaktion als Closures (Tests ersetzen sie).
@MainActor
struct QuickActionEnvironment {
    var frontmostApp: @MainActor () -> NSRunningApplication?
    var modeResolver: @MainActor (String) -> OutputMode?
    /// Umfang der App erlaubt Nacharbeit (nicht „Nur Diktat“).
    var isPostProcessingAvailable: @MainActor () -> Bool
    /// Bedienungshilfen: ohne sie lässt sich weder lesen noch einfügen.
    var hasAccessibilityPermission: @MainActor () -> Bool
    var requestAccessibilityPermission: @MainActor () -> Void
    var captureSelection: @MainActor (NSRunningApplication?) async -> CapturedSelection?
    /// Nacharbeit über denselben Weg wie nach dem Diktat (GPT-Backend mit
    /// Rückfall auf Codex). Läuft unter den Task-Locals des Runners.
    var rework: @MainActor (_ text: String, _ mode: OutputMode) async throws -> PostProcessingRun
    /// Ersetzt die Markierung; `false`, wenn nicht eingefügt werden konnte.
    var replaceSelection: @MainActor (_ text: String, _ app: NSRunningApplication?) async -> Bool
    var copyToClipboard: @MainActor (String) -> Void
    /// Ergebnis samt Original in den Zwischenablage-Verlauf.
    var recordHistory: @MainActor (_ result: String, _ original: String, _ mode: OutputMode, _ app: NSRunningApplication?) -> Void
    var postNotice: @MainActor (_ title: String, _ body: String) -> Void
    /// Ton, wenn der Kurzbefehl kommt, während noch etwas läuft.
    var busySignal: @MainActor () -> Void
    /// Bricht laufende Codex-Prozesse und Backend-Anfragen der Schnellaktion ab.
    var cancelEngines: @MainActor () -> Void
}

/// Markierten Text ohne Aufnahme mit einem Modus umarbeiten und ersetzen.
///
/// Ablauf: Markierung lesen → Overlay „Korrigiere…“ → Nacharbeit (ESC und ✕
/// brechen ab, dann bleibt alles, wie es war) → Ergebnis ersetzt die
/// Markierung. Ist das Feld nicht beschreibbar, landet das Ergebnis mit
/// Hinweis in der Zwischenablage. Der Baustein kennt keine Kurzbefehle; die
/// Menüleiste und das Zwischenablage-Fenster rufen ihn genauso auf.
@MainActor
final class QuickActionRunner {
    private let environment: QuickActionEnvironment
    private weak var presenter: QuickActionPresenting?
    private let cancelKey: CleanUpCancelKeyGrabbing
    /// Läuft gerade ein Diktat (Aufnahme, Transkription, Nacharbeit)?
    private let isDictationBusy: () -> Bool

    private(set) var isRunning = false
    private var activeCancelToken: PostProcessingCancelToken?

    init(
        environment: QuickActionEnvironment,
        presenter: QuickActionPresenting?,
        cancelKey: CleanUpCancelKeyGrabbing,
        isDictationBusy: @escaping () -> Bool
    ) {
        self.environment = environment
        self.presenter = presenter
        self.cancelKey = cancelKey
        self.isDictationBusy = isDictationBusy
    }

    @discardableResult
    func run(modeID: String, input: QuickActionInput = .selection) async -> QuickActionOutcome {
        guard !isRunning, !isDictationBusy() else {
            environment.busySignal()
            return log(.busy, modeID: modeID)
        }
        guard let mode = environment.modeResolver(modeID), mode.usesPostProcessing else {
            return log(.unavailable, modeID: modeID)
        }
        guard environment.isPostProcessingAvailable() else {
            presenter?.showQuickActionHint(String(localized: "Text modes are off in “Dictation only”"), duration: 3)
            return log(.unavailable, modeID: modeID)
        }

        guard environment.hasAccessibilityPermission() else {
            environment.requestAccessibilityPermission()
            presenter?.showQuickActionHint(String(localized: "Allow Accessibility for WhisperM8 first"), duration: 4)
            return log(.unavailable, modeID: modeID)
        }

        isRunning = true
        defer { isRunning = false }

        let app = environment.frontmostApp()
        let selection: CapturedSelection
        switch input {
        case .selection:
            guard let captured = await environment.captureSelection(app) else {
                presenter?.showQuickActionHint(String(localized: "Select text first"), duration: 2)
                return log(.noSelection, modeID: modeID)
            }
            selection = captured
        case .text(let text):
            guard !SelectedContextService.isBlank(text) else { return log(.noSelection, modeID: modeID) }
            // Ob die Schreibmarke Text annimmt, weiß hier niemand: einfügen,
            // bei Fehlschlag liegt das Ergebnis in der Zwischenablage.
            selection = CapturedSelection(text: text, writability: .unknown)
        }
        let isEntry = input != .selection
        let notChangedTitle = isEntry ? String(localized: "Text not corrected") : String(localized: "Selection not changed")

        let token = PostProcessingCancelToken()
        activeCancelToken = token
        presenter?.showQuickActionWorking(label: Self.workingLabel(for: mode)) { [weak self] in
            self?.cancel()
        }
        cancelKey.activate { [weak self] in self?.cancel() }
        // Esc nur, solange die Nacharbeit läuft. Danach (Einfügen, Zurücklegen
        // der Zwischenablage) gehört die Taste wieder allen Apps.
        var isCancelKeyActive = true
        func releaseCancelKey() {
            guard isCancelKeyActive else { return }
            isCancelKeyActive = false
            cancelKey.deactivate()
            if activeCancelToken === token { activeCancelToken = nil }
        }
        defer { releaseCancelKey() }

        let run: PostProcessingRun
        do {
            let rework = environment.rework
            run = try await PostProcessingCancelToken.$current.withValue(token) {
                try await CodexRunOwner.$current.withValue(.quickAction) {
                    try await PostProcessingInputSource.$current.withValue(.selection) {
                        try await rework(selection.text, mode)
                    }
                }
            }
        } catch {
            releaseCancelKey()
            presenter?.hideQuickAction()
            if token.isCancelled || Self.isCancellation(error) {
                return log(.cancelled, modeID: modeID)
            }
            let message = error.localizedDescription
            environment.postNotice(notChangedTitle, message)
            return log(.failed(message), modeID: modeID)
        }

        releaseCancelKey()

        // Abbruch kam, aber ein Weg hat noch geliefert: der Nutzer hat
        // abgebrochen, also bleibt alles, wie es war.
        if token.isCancelled {
            presenter?.hideQuickAction()
            return log(.cancelled, modeID: modeID)
        }

        let result = QuickActionText.replacement(for: selection.text, modelOutput: run.text)
        if result.isEmpty {
            presenter?.hideQuickAction()
            environment.postNotice(notChangedTitle, String(localized: "The text clean-up returned no text."))
            return log(.failed("empty result"), modeID: modeID)
        }
        let unchanged = result == selection.text
        // Eine Markierung, die schon stimmt, bleibt unangetastet. Ein Eintrag
        // aus dem Verlauf soll trotzdem eingefügt werden: darum ging es.
        if unchanged, !isEntry {
            presenter?.showQuickActionHint(String(localized: "Nothing to change"), duration: 2)
            return log(.unchanged, modeID: modeID)
        }

        presenter?.hideQuickAction()
        // Unverändert steht der Text schon im Verlauf, kein zweiter Eintrag.
        if !unchanged { environment.recordHistory(result, selection.text, mode, app) }

        if selection.writability == .readOnly {
            environment.copyToClipboard(result)
            presenter?.showQuickActionHint(String(localized: "Can't edit here. The result is on the clipboard."), duration: 4)
            return log(.copiedToClipboard, modeID: modeID)
        }
        if await environment.replaceSelection(result, app) {
            return log(unchanged ? .unchanged : .replaced, modeID: modeID)
        }
        environment.copyToClipboard(result)
        environment.postNotice(
            isEntry ? String(localized: "Text not inserted") : String(localized: "Selection not replaced"),
            String(localized: "WhisperM8 couldn't insert the text. The result is on the clipboard, paste it with Cmd+V.")
        )
        return log(.copiedToClipboard, modeID: modeID)
    }

    /// ESC oder ✕: laufende Nacharbeit abbrechen. Nichts wird ersetzt.
    func cancel() {
        // Nichts mehr abzubrechen (Nacharbeit schon fertig, Einfügen läuft):
        // ✕ schließt die Pill trotzdem, sie darf nicht tot stehen bleiben.
        guard let token = activeCancelToken else {
            presenter?.hideQuickAction()
            return
        }
        token.cancel()
        // Sofort sichtbar: ein später Lauf wird ohnehin verworfen, und ein
        // Codex-Prozess braucht bis zu 3 s bis zum Ende.
        presenter?.hideQuickAction()
        environment.cancelEngines()
    }

    /// „Korrigiere…“ für Korrigieren, sonst der Modusname mit Auslassung.
    static func workingLabel(for mode: OutputMode) -> String {
        if mode.id == OutputMode.correctID && mode.name == "Correct" {
            return String(localized: "Correcting…")
        }
        return "\(mode.displayName)…"
    }

    /// Fehler, die einen Abbruch bedeuten (ESC, ✕, Task-Abbruch).
    private static func isCancellation(_ error: Error) -> Bool {
        if case PostProcessingError.userCancelled = error { return true }
        return error is CancellationError
    }

    private func log(_ outcome: QuickActionOutcome, modeID: String) -> QuickActionOutcome {
        let label: String
        switch outcome {
        case .replaced: label = "replaced"
        case .unchanged: label = "unchanged"
        case .copiedToClipboard: label = "copied"
        case .noSelection: label = "no_selection"
        case .cancelled: label = "cancelled"
        case .failed: label = "failed"
        case .unavailable: label = "unavailable"
        case .busy: label = "busy"
        }
        Logger.transcription.info("quick_action mode=\(modeID, privacy: .public) outcome=\(label, privacy: .public)")
        return outcome
    }
}

/// Reine Textregeln der Schnellaktion.
enum QuickActionText {
    /// Modelle schneiden Leerzeichen und Zeilenumbrüche am Rand ab. Hatte die
    /// Markierung welche (etwa ein ganzer Absatz samt Umbruch), kommen sie
    /// wieder dran, sonst klebt der nächste Absatz am Ergebnis.
    static func replacement(for selection: String, modelOutput: String) -> String {
        let core = modelOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !core.isEmpty else { return "" }
        let leading = String(selection.prefix { $0.isWhitespace || $0.isNewline })
        let trailing = String(selection.reversed().prefix { $0.isWhitespace || $0.isNewline }.reversed())
        return leading + core + trailing
    }
}

extension OutputMode {
    /// Name für Overlay und Menüs: eingebaute Modi über den String-Katalog,
    /// eigene Namen unverändert.
    var displayName: String {
        guard kind != .custom else { return name }
        return String(localized: String.LocalizationValue(name))
    }

    /// Kurzname im Overlay-Chip, wie `displayName` übersetzt.
    var displayShortLabel: String {
        guard kind != .custom else { return shortLabel }
        return String(localized: String.LocalizationValue(shortLabel))
    }
}
