import SwiftTerm
import XCTest
@testable import WhisperM8

/// WM8-100: Nach `chats resume` hielt die App einen Claude-Chat nach 6 s für
/// bereit, Claude zeichnete sein Eingabefeld aber erst nach 13 s. Was in der
/// Lücke kam, stand danach im Feld, das Enter war verloren; `send` meldete
/// trotzdem „delivered“, und ein zweites Senden verdoppelte den Auftrag.
@MainActor
final class SendAfterResumeTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("send-after-resume-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private final class PosterSpy: AgentUserNotificationPosting {
        func post(_ notification: AgentSessionUserNotification) {}
    }

    private final class Box<T> {
        var value: T
        init(_ value: T) { self.value = value }
    }

    private struct Fixture {
        var coordinator: AgentSessionStatusCoordinator
        var sessionID: UUID
        var deliveries: Box<[UUID]>
        var inputVisible: Box<Bool?>
        var clock: Box<Date>
    }

    private func makeFixture() throws -> Fixture {
        let store = AgentSessionStore(fileURL: tempDir.appendingPathComponent("workspace.json"))
        let session = try store.createSession(
            provider: .claude, projectPath: tempDir.path, title: "Fortgesetzter Chat", initialPrompt: nil)
        try store.updateSession(id: session.id) { $0.externalSessionID = "ext-1" }
        let coordinator = AgentSessionStatusCoordinator(
            store: store,
            hookBridge: ClaudeHookBridge(paths: ClaudeHookPaths(rootDirectory: tempDir)),
            notificationPoster: PosterSpy(),
            playSound: { _ in },
            loadPreferences: {
                AgentStatusPreferences(hooksEnabled: true, stopNotificationEnabled: false,
                                       awaitingNotificationEnabled: false, stopSoundEnabled: false,
                                       stopSoundName: "Glass")
            },
            launchGraceSeconds: 999)
        coordinator.terminalExternalIDUpdater = { _, _ in }
        coordinator.gptModelsFragmentResolver = { _ in nil }
        coordinator.sharedMemoryFragmentResolver = { _, _ in nil }
        coordinator.isRegistryStatusEnabled = { true }
        coordinator.registryRecordLookup = { _ in nil }
        coordinator.registryAwaitingNotificationDelay = 0
        coordinator.hasRunningTerminal = { _ in true }
        coordinator.freshTranscriptBeforeTurnEnd = { _, action in action() }
        let deliveries = Box<[UUID]>([])
        coordinator.deliverQueued = { deliveries.value.append($0) }
        let visible = Box<Bool?>(false)
        coordinator.startupInputVisible = { _ in visible.value }
        let clock = Box(Date(timeIntervalSince1970: 1_794_000_000))
        coordinator.now = { clock.value }
        return Fixture(coordinator: coordinator, sessionID: session.id, deliveries: deliveries,
                       inputVisible: visible, clock: clock)
    }

    private func record(_ status: String) -> ClaudeSessionRecord {
        ClaudeSessionRecord(
            profileName: "RankM8", pid: 4711, sessionID: "ext-1", cwd: nil, kind: "interactive",
            name: "repo", rawStatus: status, status: ClaudeRegistryStatus(rawValue: status),
            waitingFor: nil, statusUpdatedAt: Date(timeIntervalSince1970: 1_794_000_000),
            messagingSocketPath: "/tmp/cc-socks/4711.sock", procStart: nil, version: "2.1.325")
    }

    private func sendDecision(_ f: Fixture) -> ChatsSendReadinessGuard.Decision {
        ChatsSendReadinessGuard.decide(
            lifecycle: f.coordinator.lifecycleState(for: f.sessionID),
            inputPending: f.coordinator.startupInputPending(f.sessionID))
    }

    private func queueDecision(_ f: Fixture) -> PromptDeliveryGate.Decision {
        PromptDeliveryGate.forQueue(
            runtime: f.coordinator.statusStore.status(for: f.sessionID),
            lifecycle: f.coordinator.lifecycleState(for: f.sessionID),
            mayHaveUnsentInput: false,
            inputPending: f.coordinator.startupInputPending(f.sessionID))
    }

    // MARK: Senden während des Ladens (der Fall aus dem Ticket)

    func testSendWhileLoadingIsRefusedUntilTheInputFieldIsVisible() throws {
        let f = try makeFixture()
        f.coordinator.sessionLaunched(sessionID: f.sessionID)
        XCTAssertEqual(sendDecision(f), .notReady(sinceSec: nil))

        // Die Startfrist läuft ab, das Feld fehlt noch: weiter „startet“.
        f.clock.value += 6
        f.coordinator.launchGraceFired(sessionID: f.sessionID)
        XCTAssertEqual(f.coordinator.lifecycleState(for: f.sessionID), .launching)
        XCTAssertEqual(sendDecision(f), .notReady(sinceSec: nil))
        XCTAssertEqual(queueDecision(f), .notReady)
        XCTAssertTrue(f.deliveries.value.isEmpty, "die Warteschlange darf noch nicht zustellen")

        // Das Feld steht: beim nächsten Nachsehen bereit, Warteschlange einmal angestoßen.
        f.clock.value += 7
        f.inputVisible.value = true
        f.coordinator.launchGraceFired(sessionID: f.sessionID)
        XCTAssertEqual(f.coordinator.lifecycleState(for: f.sessionID), .ready)
        XCTAssertEqual(sendDecision(f), .allowed)
        XCTAssertEqual(queueDecision(f), .deliver)
        XCTAssertEqual(f.deliveries.value, [f.sessionID])
    }

    /// Meldet Claude „bereit“, bevor das Feld zu sehen ist, halten `send` und
    /// Warteschlange trotzdem an, bis es steht.
    func testRegistryReadyBeforeTheFieldStillHoldsSendAndQueue() throws {
        let f = try makeFixture()
        f.coordinator.sessionLaunched(sessionID: f.sessionID)
        f.coordinator.handleRegistryRecord(record("idle"))
        XCTAssertEqual(f.coordinator.lifecycleState(for: f.sessionID), .ready)
        XCTAssertTrue(f.coordinator.startupInputPending(f.sessionID))
        XCTAssertEqual(sendDecision(f), .notReady(sinceSec: nil))
        XCTAssertEqual(queueDecision(f), .notReady)
        let message = ChatsSendReadinessGuard.message(for: sendDecision(f), inputPending: true) ?? ""
        XCTAssertTrue(message.contains("Eingabefeld"), message)

        f.inputVisible.value = true
        XCTAssertFalse(f.coordinator.startupInputPending(f.sessionID))
        XCTAssertEqual(sendDecision(f), .allowed)
    }

    func testNoFieldReadingKeepsTheOldStartGrace() throws {
        let f = try makeFixture()
        f.inputVisible.value = nil   // kein Claude-Chat oder Ansicht hochgescrollt
        f.coordinator.sessionLaunched(sessionID: f.sessionID)
        f.coordinator.launchGraceFired(sessionID: f.sessionID)
        XCTAssertEqual(f.coordinator.lifecycleState(for: f.sessionID), .ready)
        XCTAssertFalse(f.coordinator.startupInputPending(f.sessionID))
    }

    func testTheEmergencyGraceStillFreesAChatWhoseFieldNeverShows() throws {
        let f = try makeFixture()
        f.coordinator.sessionLaunched(sessionID: f.sessionID)
        f.clock.value += AgentSessionStatusCoordinator.startupInputMaxWaitSeconds
        f.coordinator.launchGraceFired(sessionID: f.sessionID)
        XCTAssertEqual(f.coordinator.lifecycleState(for: f.sessionID), .ready)
        XCTAssertFalse(f.coordinator.startupInputPending(f.sessionID))
    }

    func testATurnClosesTheStartWindow() throws {
        let f = try makeFixture()
        f.coordinator.sessionLaunched(sessionID: f.sessionID)
        f.coordinator.handleRegistryRecord(record("busy"))
        f.coordinator.handleRegistryRecord(record("idle"))
        // Später ist das Feld etwa wegen einer offenen Ansicht nicht zu sehen:
        // das ist kein Laden mehr.
        XCTAssertFalse(f.coordinator.startupInputPending(f.sessionID))
    }

    func testAnOpenQuestionIsNotHeldBackByTheMissingField() throws {
        let f = try makeFixture()
        f.coordinator.sessionLaunched(sessionID: f.sessionID)
        f.coordinator.statusStore.setStatus(.awaitingInput, for: f.sessionID)
        XCTAssertFalse(f.coordinator.startupInputPending(f.sessionID), "eine Rückfrage hat kein Eingabefeld")
    }

    func testAdoptedChatsAreLeftToTheHandoverRules() throws {
        let f = try makeFixture()
        f.coordinator.sessionAdopted(sessionID: f.sessionID, handedOverStatus: .idle)
        f.coordinator.handleRegistryRecord(record("idle"))
        XCTAssertFalse(f.coordinator.startupInputPending(f.sessionID),
                       "nach der Übernahme ist der Bildschirm leer, bis Claude neu zeichnet")
    }

    func testKeepWaitingForInput() {
        let start = Date(timeIntervalSince1970: 1_794_000_000)
        typealias C = AgentSessionStatusCoordinator
        XCTAssertTrue(C.keepWaitingForInput(visible: false, since: start, now: start.addingTimeInterval(10)))
        XCTAssertFalse(C.keepWaitingForInput(visible: false, since: start, now: start.addingTimeInterval(120)))
        XCTAssertFalse(C.keepWaitingForInput(visible: true, since: start, now: start))
        XCTAssertFalse(C.keepWaitingForInput(visible: nil, since: start, now: start))
        XCTAssertFalse(C.keepWaitingForInput(visible: false, since: nil, now: start))
    }

    // MARK: Ehrliches „delivered“

    private let empty = ControllerPromptField(rows: 1, cursorRow: 0, cursorAtStart: true, isEmpty: true)
    private let text = ControllerPromptField(rows: 1, cursorRow: 0, cursorAtStart: false, isEmpty: false)

    func testSubmitVerdict() {
        typealias P = PromptSubmitCheck
        XCTAssertEqual(P.evaluate(status: .working, field: text, elapsed: 0.2), .started)
        XCTAssertEqual(P.evaluate(status: .awaitingInput, field: nil, elapsed: 0.2), .started)
        XCTAssertNil(P.evaluate(status: .idle, field: empty, elapsed: 0.4), "zu früh: Paste evtl. noch nicht gezeichnet")
        XCTAssertEqual(P.evaluate(status: .idle, field: empty, elapsed: 1), .submitted)
        XCTAssertNil(P.evaluate(status: .idle, field: text, elapsed: 2))
        XCTAssertEqual(P.evaluate(status: .idle, field: text, elapsed: 4), .stuckInField)
        XCTAssertEqual(P.evaluate(status: .idle, field: nil, elapsed: 4), .unknown)
    }

    func testWaitingForTheVerdictStopsAtTheFirstClearAnswer() async {
        var now = Date(timeIntervalSince1970: 0)
        var probes = 0
        let empty = self.empty
        let verdict = await PromptSubmitCheck.waitForVerdict(
            probe: { probes += 1; return (.idle, empty) },
            sleep: { now += $0 },
            clock: { now })
        XCTAssertEqual(verdict, .submitted)
        XCTAssertTrue((4...5).contains(probes), "erst ab 0,8 s zählt ein leeres Feld (\(probes))")
    }

    func testTextLeftInTheFieldIsReportedAfterTheWindow() async {
        var now = Date(timeIntervalSince1970: 0)
        let text = self.text
        let verdict = await PromptSubmitCheck.waitForVerdict(
            probe: { (.idle, text) }, sleep: { now += $0 }, clock: { now })
        XCTAssertEqual(verdict, .stuckInField)
        XCTAssertTrue(PromptSubmitCheck.stuckMessage.contains("chats submit"))
    }

    func testCheckOnlyForRestingClaudeChatsWithEnter() {
        XCTAssertTrue(PromptSubmitCheck.applies(submit: true, profile: .claudeCodeChat, statusAtSend: .idle))
        XCTAssertFalse(PromptSubmitCheck.applies(submit: false, profile: .claudeCodeChat, statusAtSend: .idle))
        XCTAssertFalse(PromptSubmitCheck.applies(submit: true, profile: .codexChat, statusAtSend: .idle))
        XCTAssertFalse(PromptSubmitCheck.applies(submit: true, profile: .claudeCodeChat, statusAtSend: .awaitingInput))
    }

    // MARK: Kein stilles Verdoppeln

    func testVisibleTextBlocksSendAndQueue() {
        XCTAssertTrue(PromptSubmitCheck.visibleDraft(field: text, profile: .claudeCodeChat, clearsBeforeSubmit: false))
        XCTAssertFalse(PromptSubmitCheck.visibleDraft(field: empty, profile: .claudeCodeChat, clearsBeforeSubmit: false))
        XCTAssertFalse(PromptSubmitCheck.visibleDraft(field: text, profile: .claudeCodeChat, clearsBeforeSubmit: true),
                       "ein Rückleger nach Abbruch wird vor dem Einfügen ohnehin geleert")
        XCTAssertFalse(PromptSubmitCheck.visibleDraft(field: text, profile: .codexChat, clearsBeforeSubmit: false))
        XCTAssertEqual(PromptDeliveryGate.forQueue(runtime: .idle, lifecycle: .ready, mayHaveUnsentInput: false,
                                                   visibleDraft: true), .draftPending)
    }

    // MARK: chats submit

    func testSubmitOnlySendsAnEnterForVisibleTextInARestingClaudeChat() {
        typealias H = AgentControlRequestHandler
        func check(_ profile: TerminalKeyboardProfile = .claudeCodeChat, status: AgentSessionRuntimeStatus? = .idle,
                   approval: Bool = false, field: ControllerPromptField?, readable: Bool = true) -> H.SubmitDecision {
            H.submitCheck(profile: profile, status: status, approvalPending: approval, userDraft: false,
                          field: field, screenReadable: readable)
        }
        XCTAssertEqual(check(field: text), .allowed)
        XCTAssertEqual(check(field: empty), .refused(.conflict, "Im Eingabefeld steht nichts — es gibt nichts abzuschicken."))
        if case .refused(let code, _) = check(.codexChat, field: text) { XCTAssertEqual(code, .unsupported) } else { XCTFail() }
        if case .refused(let code, _) = check(approval: true, field: text) { XCTAssertEqual(code, .approvalPending) } else { XCTFail() }
        if case .refused(let code, _) = check(status: .working, field: text) { XCTAssertEqual(code, .conflict) } else { XCTFail() }
        if case .refused(let code, _) = check(field: nil) { XCTAssertEqual(code, .notReady) } else { XCTFail() }
        if case .refused(let code, _) = check(field: text, readable: false) { XCTAssertEqual(code, .conflict) } else { XCTFail() }
    }

    /// Vic: Tippt der User in einem ruhenden Chat, darf submit seinen halben
    /// Satz nicht abschicken. Ein liegengebliebener Auftrag zählt beim Tracker
    /// als abgeschickt und bleibt erlaubt.
    func testSubmitNeverSendsADraftOfTheUser() {
        let decision = AgentControlRequestHandler.submitCheck(
            profile: .claudeCodeChat, status: .idle, approvalPending: false, userDraft: true,
            field: text, screenReadable: true)
        guard case .refused(let code, let message) = decision else { return XCTFail("muss ablehnen") }
        XCTAssertEqual(code, .conflict)
        XCTAssertTrue(message.contains("Entwurf des Users"), message)

        var tracker = TerminalComposerDraftTracker()
        tracker.recordTextInserted()
        XCTAssertTrue(tracker.mayHaveUnsentInput, "eingefügt ohne Enter: Entwurf")
        tracker.recordSubmitted(programmaticAt: Date())
        XCTAssertFalse(tracker.mayHaveUnsentInput, "liegengebliebener Auftrag gilt als abgeschickt")
    }

    // MARK: Vorschlag im leeren Feld (Platzhalter)

    private final class Sink: TerminalDelegate {
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
    }

    /// Bildschirm durch ein echtes Terminal mit ANSI-Folgen, wie Claude ihn zeichnet.
    private func screen(_ text: String) -> ControllerScreenSnapshot {
        let terminal = Terminal(delegate: Sink(), options: TerminalOptions(cols: 100, rows: 12))
        terminal.feed(text: text.replacingOccurrences(of: "\n", with: "\r\n"))
        let capture = ControllerScreenCapture.bottomLines(of: terminal)
        return ControllerScreenReading.read(lines: capture.lines, cursor: capture.cursor, detectViews: true)
    }

    /// Claude schlägt im leeren Feld einen nächsten Prompt vor (am 14.11.
    /// zweimal beobachtet, etwa „Variante A für WM8-71, bau weiter“). Weder
    /// submit noch die Prüfung auf einen Entwurf dürfen ihn für Text halten —
    /// abgeblendet oder nicht, solange der Cursor am Anfang steht.
    func testClaudesSuggestionInTheEmptyFieldIsNotText() {
        let rule = String(repeating: "─", count: 80)
        let (dim, reset, save, restore) = ("\u{1b}[2m", "\u{1b}[0m", "\u{1b}[s", "\u{1b}[u")
        let suggestion = "Variante A für WM8-71, bau weiter"
        for drawn in ["\(dim)❯ \(reset)\(save)\(dim)\(suggestion)\(reset)",   // abgeblendet
                      "\(dim)❯ \(reset)\(save)\(suggestion)"] {                // nicht abgeblendet
            let field = screen("\(rule)\n\(drawn)\n\(rule)\(restore)").promptField
            XCTAssertNotNil(field, drawn)
            XCTAssertEqual(field?.hasText, false, drawn)
            XCTAssertFalse(PromptSubmitCheck.visibleDraft(field: field, profile: .claudeCodeChat, clearsBeforeSubmit: false))
            guard case .refused = AgentControlRequestHandler.submitCheck(
                profile: .claudeCodeChat, status: .idle, approvalPending: false, userDraft: false,
                field: field, screenReadable: true) else { return XCTFail("Vorschlag darf nicht abgeschickt werden") }
        }
        // Gegenprobe: echter Text mit dem Cursor dahinter.
        let typed = screen("\(rule)\n\(dim)❯ \(reset)\(suggestion)\(save)\n\(rule)\(restore)").promptField
        XCTAssertEqual(typed?.hasText, true)
    }

    // MARK: chats resume mit Auftrag

    func testResumeArguments() {
        typealias R = ChatsResumeCommand
        XCTAssertEqual(try R.parse(["jon"]).get(), .init(ref: "jon", prompt: nil, json: false))
        XCTAssertEqual(try R.parse(["jon", "--prompt", "Weiter mit WM8-99", "--json"]).get(),
                       .init(ref: "jon", prompt: "Weiter mit WM8-99", json: true))
        XCTAssertEqual(try R.parse(["jon", "--", "Weiter", "--mit", "Flag"]).get(),
                       .init(ref: "jon", prompt: "Weiter --mit Flag", json: false))
        XCTAssertThrowsError(try R.parse([]).get())
        XCTAssertThrowsError(try R.parse(["jon", "--prompt"]).get())
        XCTAssertThrowsError(try R.parse(["jon", "--prompt", "  "]).get())
        XCTAssertThrowsError(try R.parse(["jon", "--"]).get())
        XCTAssertThrowsError(try R.parse(["jon", "--weird"]).get())
    }
}
