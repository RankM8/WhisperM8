import AppKit
import XCTest
@testable import WhisperM8

/// Liefert einen festen Text oder wirft, ohne Netz.
private final class FixedTextTranscriptionService: TranscriptionServiceProtocol {
    var text: String
    var error: Error?
    private(set) var calls = 0
    init(text: String) { self.text = text }
    func transcribe(audioURL: URL, language: String?, audioDuration: TimeInterval?) async throws -> String {
        calls += 1
        if let error { throw error }
        return text
    }
}

/// Spy statt echter Terminal-Registry.
@MainActor
private final class ChatWriterSpy: DictationChatWriting {
    struct Write: Equatable {
        var text: String
        var sessionID: UUID
        var submit: Bool
    }
    var chatState: DictationChatState = .ready
    var writeSucceeds = true
    private(set) var stateQueries: [UUID] = []
    private(set) var writes: [Write] = []

    func state(of sessionID: UUID) -> DictationChatState {
        stateQueries.append(sessionID)
        return chatState
    }

    func write(_ text: String, to sessionID: UUID, submit: Bool) -> Bool {
        writes.append(Write(text: text, sessionID: sessionID, submit: submit))
        return writeSucceeds
    }

    var questionWriteSucceeds = true
    private(set) var questionWrites: [String] = []
    func writeToQuestion(_ text: String, to sessionID: UUID) -> Bool {
        questionWrites.append(text)
        return questionWriteSucceeds
    }
}

private final class AudioStopSpy: AudioRecordingStopping {
    var url: URL?
    private(set) var stopCount = 0
    init(url: URL?) { self.url = url }
    func stopRecording() -> URL? {
        stopCount += 1
        return url
    }
}

/// Attrappe für alles, was das Einfügen am System anfasst: eigene
/// Zwischenablage, kein echtes Cmd+V, keine App-Aktivierung.
private final class PasteEnvironmentSpy {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("wm8-delivery-test-\(UUID().uuidString)"))
    var hasPermission = false
    private(set) var permissionChecks = 0
    private(set) var permissionRequests = 0
    private(set) var activations = 0
    private(set) var keyEvents = 0

    var environment: PasteServiceEnvironment {
        PasteServiceEnvironment(
            hasAccessibilityPermission: { [unowned self] in
                permissionChecks += 1
                return hasPermission
            },
            requestAccessibilityPermission: { [unowned self] in permissionRequests += 1 },
            isFrontmost: { _ in true },
            activate: { [unowned self] _ in activations += 1 },
            postPasteKeyEvent: { [unowned self] in
                keyEvents += 1
                return true
            },
            pasteboard: pasteboard,
            activationTimeout: 0
        )
    }

    var clipboardText: String? { pasteboard.string(forType: .string) }
}

/// Hält fest, was der Diktat-Weg heute ins vordere Programm liefert: Text in
/// der Zwischenablage, Einfügen nur mit Auto-Paste, genau ein
/// Verlaufs-Eintrag, `lastTranscription` gesetzt.
@MainActor
final class RecordingCoordinatorDeliveryTests: XCTestCase {
    private var tempDir: URL!
    private var suiteName: String!
    private var originalPreferences: AppPreferences!
    private var preferences: AppPreferences!
    private var pasteSpy: PasteEnvironmentSpy!
    private var historyRecords: [DictationHistoryRecord] = []
    private var chatWriter: ChatWriterSpy!
    private var notices: [(title: String, body: String)] = []
    private var service: FixedTextTranscriptionService!
    private let sessionID = UUID()

    private struct SavedAppState {
        var lastTranscription: String?
        var lastFinalTranscription: String?
        var lastRawTranscription: String?
        var lastError: String?
        var lastTranscriptRunReport: TranscriptRunReport?
        var isRecording: Bool
        var isTranscribing: Bool
        var isPostProcessing: Bool
        var hasPreservedRecording: Bool
        var selectedOutputMode: OutputMode
        var lastOutputMode: OutputMode?
        var contextBundle: TranscriptContextBundle
        var selectedContext: SelectedContext
    }
    private var saved: SavedAppState!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-delivery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        suiteName = "WhisperM8Tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        originalPreferences = AppPreferences.shared
        preferences = AppPreferences(defaults: defaults, preferredLanguages: ["de-DE"])
        AppPreferences.shared = preferences

        let appState = AppState.shared
        saved = SavedAppState(
            lastTranscription: appState.lastTranscription,
            lastFinalTranscription: appState.lastFinalTranscription,
            lastRawTranscription: appState.lastRawTranscription,
            lastError: appState.lastError,
            lastTranscriptRunReport: appState.lastTranscriptRunReport,
            isRecording: appState.isRecording,
            isTranscribing: appState.isTranscribing,
            isPostProcessing: appState.isPostProcessing,
            hasPreservedRecording: appState.hasPreservedRecording,
            selectedOutputMode: appState.selectedOutputMode,
            lastOutputMode: appState.lastOutputMode,
            contextBundle: appState.contextBundle,
            selectedContext: appState.selectedContext
        )
        appState.lastTranscription = nil
        appState.lastFinalTranscription = nil
        appState.lastError = nil
        appState.lastTranscriptRunReport = nil

        pasteSpy = PasteEnvironmentSpy()
        historyRecords = []
        chatWriter = ChatWriterSpy()
        notices = []
    }

    override func tearDownWithError() throws {
        let appState = AppState.shared
        appState.lastTranscription = saved.lastTranscription
        appState.lastFinalTranscription = saved.lastFinalTranscription
        appState.lastRawTranscription = saved.lastRawTranscription
        appState.lastError = saved.lastError
        appState.lastTranscriptRunReport = saved.lastTranscriptRunReport
        appState.isRecording = saved.isRecording
        appState.isTranscribing = saved.isTranscribing
        appState.isPostProcessing = saved.isPostProcessing
        appState.hasPreservedRecording = saved.hasPreservedRecording
        appState.selectedOutputMode = saved.selectedOutputMode
        appState.lastOutputMode = saved.lastOutputMode
        appState.contextBundle = saved.contextBundle
        appState.selectedContext = saved.selectedContext

        AppPreferences.shared = originalPreferences
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: Helfer

    private var rawMode: OutputMode {
        OutputMode.builtInModes.first { $0.id == OutputMode.rawID }!
    }

    private func makeAudio() throws -> URL {
        let url = tempDir.appendingPathComponent("audio-\(UUID().uuidString).m4a")
        try Data([0, 1, 2, 3]).write(to: url)
        return url
    }

    private func makeCoordinator(text: String) -> RecordingCoordinator {
        let service = FixedTextTranscriptionService(text: text)
        self.service = service
        return RecordingCoordinator(
            appState: .shared,
            pasteService: PasteService(environment: pasteSpy.environment),
            reportStore: TranscriptRunReportStore(reportsDirectory: tempDir.appendingPathComponent("Reports", isDirectory: true)),
            failedRecordingsStore: FailedRecordingsStore(directoryURL: tempDir.appendingPathComponent("failed", isDirectory: true)),
            providerResolver: { .groq },
            modelResolver: { .groq_whisper_v3 },
            apiKeyResolver: { _ in "key" },
            transcriberFactory: { _, _, _ in service },
            transcriptionPrewarmer: { _ in },
            dictationHistoryRecorder: { [weak self] record in
                self?.historyRecords.append(record)
                return true
            },
            chatWriter: chatWriter,
            dictationNoticePoster: { [weak self] title, body in
                self?.notices.append((title, body))
            }
        )
    }

    private var chatDelivery: DictationDelivery {
        DictationDelivery(target: .agentChat(sessionID: sessionID))
    }

    // MARK: Heutiger Weg ins vordere Programm

    func testAutoPasteOnCopiesAndTriesToPaste() async throws {
        preferences.isAutoPasteEnabled = true
        let audio = try makeAudio()
        let coordinator = makeCoordinator(text: "Hallo Welt")

        try await coordinator.transcribeAndDeliver(
            audioURL: audio, audioDuration: 2, outputMode: rawMode, contextBundle: .empty
        )

        XCTAssertEqual(pasteSpy.clipboardText, "Hallo Welt")
        // Einfügen wurde versucht: Die Attrappe verweigert das Recht, damit
        // weder ein Tastendruck noch ein Hinweis entsteht.
        XCTAssertEqual(pasteSpy.permissionChecks, 1)
        XCTAssertEqual(pasteSpy.permissionRequests, 1)
        XCTAssertEqual(pasteSpy.keyEvents, 0)
        XCTAssertEqual(AppState.shared.lastError, "Accessibility permission required for auto-paste")
        XCTAssertEqual(historyRecords.map(\.text), ["Hallo Welt"])
        XCTAssertEqual(AppState.shared.lastTranscription, "Hallo Welt")
        XCTAssertEqual(AppState.shared.lastFinalTranscription, "Hallo Welt")
        let report = try XCTUnwrap(AppState.shared.lastTranscriptRunReport)
        XCTAssertTrue(report.copiedToClipboard)
        XCTAssertTrue(report.autoPasteRequested)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path), "Audio wird nach Erfolg gelöscht")
    }

    func testAutoPasteOffOnlyCopies() async throws {
        preferences.isAutoPasteEnabled = false
        let audio = try makeAudio()
        let coordinator = makeCoordinator(text: "Nur kopieren")

        try await coordinator.transcribeAndDeliver(
            audioURL: audio, audioDuration: 2, outputMode: rawMode, contextBundle: .empty
        )

        XCTAssertEqual(pasteSpy.clipboardText, "Nur kopieren")
        XCTAssertTrue(chatWriter.stateQueries.isEmpty, "Vorderes Programm fragt keinen Chat")
        XCTAssertTrue(chatWriter.writes.isEmpty)
        XCTAssertEqual(pasteSpy.permissionChecks, 0, "Ohne Auto-Paste kein Einfügeversuch")
        XCTAssertEqual(pasteSpy.activations, 0)
        XCTAssertEqual(pasteSpy.keyEvents, 0)
        XCTAssertNil(AppState.shared.lastError)
        XCTAssertEqual(historyRecords.map(\.text), ["Nur kopieren"])
        XCTAssertEqual(AppState.shared.lastTranscription, "Nur kopieren")
        let report = try XCTUnwrap(AppState.shared.lastTranscriptRunReport)
        XCTAssertTrue(report.copiedToClipboard)
        XCTAssertFalse(report.autoPasteRequested)
    }

    /// Heute gibt es keinen Schutz gegen leeren Text im vorderen Programm:
    /// Auch "" landet in der Zwischenablage und im Verlauf.
    func testEmptyTextStillGoesToClipboardForFrontApp() async throws {
        preferences.isAutoPasteEnabled = false
        let audio = try makeAudio()
        let coordinator = makeCoordinator(text: "   ")

        try await coordinator.transcribeAndDeliver(
            audioURL: audio, audioDuration: 2, outputMode: rawMode, contextBundle: .empty
        )

        XCTAssertEqual(pasteSpy.clipboardText, "")
        XCTAssertEqual(historyRecords.map(\.text), [""])
        XCTAssertEqual(AppState.shared.lastTranscription, "")
    }

    // MARK: Zustellung an einen Agent-Chat

    private func deliverToChat(
        _ text: String,
        submit: Bool = false,
        autoPaste: Bool = true
    ) async throws -> (RecordingCoordinator, URL) {
        // Auto-Paste bewusst an: der Chat-Weg darf es nicht benutzen.
        preferences.isAutoPasteEnabled = autoPaste
        let audio = try makeAudio()
        let coordinator = makeCoordinator(text: text)
        var delivery = chatDelivery
        delivery.submit = submit
        try await coordinator.transcribeAndDeliver(
            audioURL: audio, audioDuration: 2, outputMode: rawMode, contextBundle: .empty, delivery: delivery
        )
        return (coordinator, audio)
    }

    private func assertNoPasteAttempt(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(pasteSpy.permissionChecks, 0, "Kein Cmd+V, keine Bedienungshilfen", file: file, line: line)
        XCTAssertEqual(pasteSpy.activations, 0, file: file, line: line)
        XCTAssertEqual(pasteSpy.keyEvents, 0, file: file, line: line)
    }

    func testReadyChatGetsTextWithoutSubmit() async throws {
        let (_, audio) = try await deliverToChat("Hallo Chat")

        XCTAssertEqual(chatWriter.writes, [.init(text: "Hallo Chat", sessionID: sessionID, submit: false)])
        XCTAssertEqual(chatWriter.stateQueries, [sessionID])
        XCTAssertEqual(pasteSpy.clipboardText, "Hallo Chat", "Zwischenablage wie beim vorderen Programm")
        assertNoPasteAttempt()
        XCTAssertEqual(historyRecords.map(\.text), ["Hallo Chat"])
        XCTAssertEqual(AppState.shared.lastTranscription, "Hallo Chat")
        XCTAssertEqual(AppState.shared.lastFinalTranscription, "Hallo Chat")
        XCTAssertNil(AppState.shared.lastError)
        XCTAssertTrue(notices.isEmpty)
        let report = try XCTUnwrap(AppState.shared.lastTranscriptRunReport)
        XCTAssertTrue(report.copiedToClipboard)
        XCTAssertFalse(report.autoPasteRequested)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path))
    }

    func testReadyChatGetsTextWithSubmit() async throws {
        _ = try await deliverToChat("Bitte loslegen", submit: true)

        XCTAssertEqual(chatWriter.writes, [.init(text: "Bitte loslegen", sessionID: sessionID, submit: true)])
        assertNoPasteAttempt()
        XCTAssertTrue(notices.isEmpty)
    }

    func testOpenQuestionKeepsTextOnClipboardWithNotice() async throws {
        chatWriter.chatState = .awaitingInput
        _ = try await deliverToChat("Antwort", submit: true)

        XCTAssertTrue(chatWriter.writes.isEmpty, "In eine offene Rückfrage läuft nie Text")
        assertClipboardOnly(text: "Antwort", reason: .decisionPending)
    }

    /// WM8-66: Erkannte Frage — der Text geht ins freie Textfeld, ohne Enter,
    /// auch wenn beim Stopp „senden“ gewählt war.
    func testRecognizedQuestionGetsTextIntoItsField() async throws {
        chatWriter.chatState = .questionAcceptsText
        let (coordinator, _) = try await deliverToChat("Lila bitte", submit: true)

        XCTAssertEqual(chatWriter.questionWrites, ["Lila bitte"])
        XCTAssertTrue(chatWriter.writes.isEmpty, "nicht der Weg ins Eingabefeld, kein Enter")
        XCTAssertEqual(pasteSpy.clipboardText, "Lila bitte", "auch in der Zwischenablage")
        assertNoPasteAttempt()
        XCTAssertTrue(notices.isEmpty)
        XCTAssertNil(AppState.shared.lastError)
        XCTAssertFalse(coordinator.overlayController.isQuickActionHint)
    }

    func testQuestionThatClosedMeanwhileKeepsTextOnClipboard() async throws {
        chatWriter.chatState = .questionAcceptsText
        chatWriter.questionWriteSucceeds = false
        _ = try await deliverToChat("Zu spät")

        XCTAssertEqual(chatWriter.questionWrites, ["Zu spät"])
        assertClipboardOnly(text: "Zu spät", reason: .decisionPending)
    }

    /// Liegt der Text nur in der Zwischenablage, sagt es auch die Pille.
    func testClipboardOnlyShowsHintInThePill() async throws {
        chatWriter.chatState = .awaitingInput
        let (coordinator, _) = try await deliverToChat("Antwort")

        XCTAssertTrue(coordinator.overlayController.isQuickActionHint)
        XCTAssertEqual(coordinator.overlayController.quickActionLabel,
                       RecordingCoordinator.clipboardOnlyPillHint(for: .decisionPending))
        XCTAssertNotEqual(RecordingCoordinator.clipboardOnlyPillHint(for: .decisionPending),
                          RecordingCoordinator.clipboardOnlyPillHint(for: .chatStarting))
    }

    func testStartingChatKeepsTextOnClipboardWithNotice() async throws {
        chatWriter.chatState = .starting
        _ = try await deliverToChat("Noch zu früh")

        XCTAssertTrue(chatWriter.writes.isEmpty)
        assertClipboardOnly(text: "Noch zu früh", reason: .chatStarting)
    }

    func testStoppedChatKeepsTextOnClipboardWithNotice() async throws {
        chatWriter.chatState = .notRunning
        _ = try await deliverToChat("Niemand da")

        XCTAssertTrue(chatWriter.writes.isEmpty)
        assertClipboardOnly(text: "Niemand da", reason: .chatNotRunning)
    }

    func testFailedWriteKeepsTextOnClipboardWithNotice() async throws {
        chatWriter.writeSucceeds = false
        _ = try await deliverToChat("Kommt nicht an", submit: true)

        XCTAssertEqual(chatWriter.writes.count, 1)
        assertClipboardOnly(text: "Kommt nicht an", reason: .writeFailed)
    }

    private func assertClipboardOnly(
        text: String,
        reason: DictationClipboardReason,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let body = RecordingCoordinator.clipboardOnlyMessage(for: reason)
        XCTAssertEqual(pasteSpy.clipboardText, text, file: file, line: line)
        assertNoPasteAttempt(file: file, line: line)
        XCTAssertEqual(historyRecords.map(\.text), [text], file: file, line: line)
        XCTAssertEqual(AppState.shared.lastTranscription, text, file: file, line: line)
        XCTAssertEqual(notices.map(\.title), ["Text not inserted"], file: file, line: line)
        XCTAssertEqual(notices.map(\.body), [body], file: file, line: line)
        XCTAssertEqual(AppState.shared.lastError, body, file: file, line: line)
        XCTAssertEqual(AppState.shared.lastTranscriptRunReport?.copiedToClipboard, true, file: file, line: line)
        XCTAssertEqual(AppState.shared.lastTranscriptRunReport?.autoPasteRequested, false, file: file, line: line)
    }

    func testEveryClipboardReasonHasItsOwnMessage() {
        let reasons: [DictationClipboardReason] = [.decisionPending, .chatStarting, .chatUsageLimited, .chatNotRunning, .writeFailed]
        let messages = Set(reasons.map(RecordingCoordinator.clipboardOnlyMessage(for:)))
        XCTAssertEqual(messages.count, reasons.count)
    }

    func testEmptyTextForChatTouchesNeitherClipboardNorChat() async throws {
        let (_, audio) = try await deliverToChat("  \n ", submit: true)

        XCTAssertNil(pasteSpy.clipboardText)
        XCTAssertTrue(chatWriter.writes.isEmpty)
        XCTAssertTrue(chatWriter.stateQueries.isEmpty)
        XCTAssertTrue(historyRecords.isEmpty)
        XCTAssertTrue(notices.isEmpty)
        XCTAssertNil(AppState.shared.lastTranscription)
        assertNoPasteAttempt()
        let report = try XCTUnwrap(AppState.shared.lastTranscriptRunReport)
        XCTAssertFalse(report.copiedToClipboard)
        XCTAssertFalse(report.autoPasteRequested)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path))
    }

    // MARK: Stopp, Ziel und Retry

    /// Bereitet eine laufende Aufnahme vor, ohne Audio-Engine.
    private func prepareRunningRecording(
        _ coordinator: RecordingCoordinator,
        target: DictationDeliveryTarget,
        startedSecondsAgo: TimeInterval
    ) throws -> AudioStopSpy {
        let appState = AppState.shared
        appState.isRecording = true
        appState.isTranscribing = false
        appState.isPostProcessing = false
        appState.selectedOutputMode = rawMode
        appState.contextBundle = .empty
        appState.selectedContext = .empty
        let spy = AudioStopSpy(url: try makeAudio())
        coordinator.audioStopper = spy
        coordinator.pendingDeliveryTarget = target
        coordinator.recordingStartTime = Date().addingTimeInterval(-startedSecondsAgo)
        return spy
    }

    func testIgnoredShortStopDoesNotTakeOverSubmit() async throws {
        let coordinator = makeCoordinator(text: "Tap-Diktat")
        let spy = try prepareRunningRecording(
            coordinator, target: .agentChat(sessionID: sessionID), startedSecondsAgo: 0
        )

        // Stopp unter 0,3 s: ignoriert (Tap-Schutz), `submit` darf nicht hängen bleiben.
        await coordinator.stopRecording(submit: true)
        XCTAssertEqual(spy.stopCount, 0)
        XCTAssertTrue(AppState.shared.isRecording)
        XCTAssertEqual(coordinator.pendingDeliveryTarget, .agentChat(sessionID: sessionID), "Ziel bleibt für den echten Stopp")
        XCTAssertTrue(chatWriter.writes.isEmpty)

        coordinator.recordingStartTime = Date().addingTimeInterval(-5)
        await coordinator.stopRecording()

        XCTAssertEqual(spy.stopCount, 1)
        XCTAssertEqual(chatWriter.writes, [.init(text: "Tap-Diktat", sessionID: sessionID, submit: false)])
        XCTAssertEqual(coordinator.pendingDeliveryTarget, .frontApp, "Nach dem Lauf wieder vorderes Programm")
        XCTAssertFalse(AppState.shared.isRecording)
    }

    func testAcceptedStopFreezesSubmit() async throws {
        let coordinator = makeCoordinator(text: "Los")
        _ = try prepareRunningRecording(
            coordinator, target: .agentChat(sessionID: sessionID), startedSecondsAgo: 5
        )

        await coordinator.stopRecording(submit: true)

        XCTAssertEqual(chatWriter.writes, [.init(text: "Los", sessionID: sessionID, submit: true)])
        XCTAssertEqual(coordinator.pendingDeliveryTarget, .frontApp)
    }

    func testHotkeyStopStillGoesToFrontApp() async throws {
        preferences.isAutoPasteEnabled = false
        let coordinator = makeCoordinator(text: "Wie immer")
        _ = try prepareRunningRecording(coordinator, target: .frontApp, startedSecondsAgo: 5)

        await coordinator.stopRecording()

        XCTAssertEqual(pasteSpy.clipboardText, "Wie immer")
        XCTAssertTrue(chatWriter.stateQueries.isEmpty)
        XCTAssertTrue(chatWriter.writes.isEmpty)
        XCTAssertEqual(historyRecords.map(\.text), ["Wie immer"])
    }

    func testCancelledTranscriptionKeepsTargetAndRetryDropsSubmit() async throws {
        let coordinator = makeCoordinator(text: "Zweiter Versuch")
        service.error = CancellationError()
        _ = try prepareRunningRecording(
            coordinator, target: .agentChat(sessionID: sessionID), startedSecondsAgo: 5
        )

        await coordinator.stopRecording(submit: true)

        // Abbruch sichert die Aufnahme samt Ziel; nichts wurde geschrieben.
        XCTAssertTrue(chatWriter.writes.isEmpty)
        XCTAssertEqual(coordinator.pendingRetry?.delivery,
                       DictationDelivery(target: .agentChat(sessionID: sessionID), submit: true))
        XCTAssertEqual(coordinator.pendingDeliveryTarget, .frontApp)

        service.error = nil
        AppState.shared.isRecording = false
        AppState.shared.isTranscribing = false
        await coordinator.retryPendingTranscription()

        XCTAssertEqual(chatWriter.writes, [.init(text: "Zweiter Versuch", sessionID: sessionID, submit: false)],
                       "Retry liefert ins selbe Ziel, sendet aber nie nachträglich")
        XCTAssertNil(coordinator.pendingRetry)
    }

    func testCancelRecordingResetsTarget() throws {
        let coordinator = makeCoordinator(text: "egal")
        _ = try prepareRunningRecording(
            coordinator, target: .agentChat(sessionID: sessionID), startedSecondsAgo: 5
        )
        // `cancelRecording` stoppt den echten Recorder (läuft hier nicht) — ungefährlich.
        XCTAssertTrue(coordinator.cancelRecording())
        XCTAssertEqual(coordinator.pendingDeliveryTarget, .frontApp)
    }
}
