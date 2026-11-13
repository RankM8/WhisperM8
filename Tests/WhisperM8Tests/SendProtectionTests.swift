import AppKit
import XCTest
@testable import WhisperM8

/// Review S1 (05.11.2026): Schutz vor zurückgelegten Prompts ohne den alten
/// `UserPromptSubmit`-Guard — die App schätzt vor jeder Zustellung, was im
/// Eingabefeld steht (`TerminalComposerDraftTracker`).
final class ComposerRestoredPromptTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)
    private let esc: UInt16 = 53
    private let enter: UInt16 = 36

    private func key(
        _ tracker: inout TerminalComposerDraftTracker,
        _ code: UInt16,
        _ modifiers: NSEvent.ModifierFlags = [],
        status: AgentSessionRuntimeStatus? = .idle,
        claude: Bool = true,
        at offset: TimeInterval
    ) {
        tracker.recordTerminalKey(
            keyCode: code, modifiers: modifiers, status: status,
            restoresPromptOnInterrupt: claude, now: t0.addingTimeInterval(offset))
    }

    /// Fall 2: ESC, bevor der Status `working` zeigt — der Rückleger wurde
    /// vorher übersehen und lief mit dem nächsten Queue-Auftrag zusammen.
    func testEscapeRightAfterProgrammaticSubmitCountsAsInterruptEvenWhileIdle() {
        var tracker = TerminalComposerDraftTracker()
        tracker.recordSubmitted(programmaticAt: t0)
        key(&tracker, esc, status: .idle, at: 0.5)
        XCTAssertTrue(tracker.shouldClearBeforeSubmit)
    }

    func testLateTurnStartDoesNotForgetAnEarlyInterrupt() {
        var tracker = TerminalComposerDraftTracker()
        tracker.recordSubmitted(programmaticAt: t0)
        key(&tracker, esc, status: .idle, at: 0.5)
        tracker.recordSubmittedByTurnStart()   // Status meldet den Turn erst jetzt
        XCTAssertTrue(tracker.shouldClearBeforeSubmit, "der Start gehört zum abgebrochenen Turn")
    }

    func testTurnStartWithoutInterruptStillClearsTheEstimate() {
        var tracker = TerminalComposerDraftTracker()
        tracker.recordTextInserted()
        tracker.recordSubmittedByTurnStart()
        XCTAssertFalse(tracker.mayHaveUnsentInput)
        XCTAssertFalse(tracker.shouldClearBeforeSubmit)
    }

    func testEscapeOutsideTheWindowWhileIdleIsNoInterrupt() {
        var tracker = TerminalComposerDraftTracker()
        tracker.recordSubmitted(programmaticAt: t0)
        key(&tracker, esc, status: .idle,
            at: TerminalComposerDraftTracker.interruptWindowAfterProgrammaticSubmit + 1)
        XCTAssertFalse(tracker.mayHoldRestoredPrompt)
    }

    func testEscapeWhileWorkingIsAlwaysAnInterrupt() {
        var tracker = TerminalComposerDraftTracker()
        key(&tracker, esc, status: .working, at: 100)
        XCTAssertTrue(tracker.shouldClearBeforeSubmit)
    }

    /// Fall 4: Ctrl+C während `working` bricht ab wie ESC.
    func testControlCWhileWorkingCountsAsInterrupt() {
        var tracker = TerminalComposerDraftTracker()
        key(&tracker, 8, .control, status: .working, at: 100)
        XCTAssertTrue(tracker.mayHoldRestoredPrompt)
        XCTAssertFalse(tracker.mayHaveUnsentInput)
        XCTAssertTrue(tracker.shouldClearBeforeSubmit)
    }

    func testControlCRightAfterProgrammaticSubmitCountsAsInterrupt() {
        var tracker = TerminalComposerDraftTracker()
        tracker.recordSubmitted(programmaticAt: t0)
        key(&tracker, 8, .control, status: .idle, at: 1)
        XCTAssertTrue(tracker.shouldClearBeforeSubmit)
    }

    func testControlCWhileIdleOutsideTheWindowJustClears() {
        var tracker = TerminalComposerDraftTracker()
        tracker.recordTurnInterrupted()
        key(&tracker, 8, .control, status: .idle, at: 100)
        XCTAssertFalse(tracker.mayHoldRestoredPrompt, "Ctrl+C im Ruhezustand leert das Feld")
    }

    /// Fall 3: Doppel-ESC öffnet die Rewind-Auswahl, das Return wählt eine
    /// alte Nachricht — abgeschickt wird nichts, das Feld ist voll.
    func testRewindSelectionLeavesARestoredPrompt() {
        var tracker = TerminalComposerDraftTracker()
        key(&tracker, esc, at: 100)
        key(&tracker, esc, at: 100.2)
        key(&tracker, 126, at: 101)            // Pfeil hoch in der Liste
        key(&tracker, enter, at: 102)
        XCTAssertTrue(tracker.shouldClearBeforeSubmit)
    }

    func testRewindStaysDetectedWhenEscapesFallIntoTheInterruptWindow() {
        var tracker = TerminalComposerDraftTracker()
        tracker.recordSubmitted(programmaticAt: t0)
        key(&tracker, esc, at: 0.5)
        key(&tracker, esc, at: 0.7)
        key(&tracker, enter, at: 1.5)
        XCTAssertTrue(tracker.mayHoldRestoredPrompt)
    }

    func testSingleEscapeThenEnterIsANormalSubmit() {
        var tracker = TerminalComposerDraftTracker()
        key(&tracker, 0, at: 100)              // getippt
        key(&tracker, esc, at: 101)
        key(&tracker, enter, at: 102)
        XCTAssertFalse(tracker.mayHaveUnsentInput)
        XCTAssertFalse(tracker.mayHoldRestoredPrompt)
    }

    func testTypingBetweenEscapesEndsTheRewindSequence() {
        var tracker = TerminalComposerDraftTracker()
        key(&tracker, esc, at: 100)
        key(&tracker, 0, at: 101)
        key(&tracker, esc, at: 102)
        key(&tracker, enter, at: 103)
        XCTAssertFalse(tracker.mayHoldRestoredPrompt)
    }

    /// Fall 1 bleibt offen (dokumentiert): Enter des Users auf den Rückleger
    /// schickt ihn ab — die Schätzung gilt danach als abgeschickt.
    func testUserEnterOnRestoredPromptCountsAsSubmit() {
        var tracker = TerminalComposerDraftTracker()
        key(&tracker, esc, status: .working, at: 100)
        key(&tracker, enter, at: 101)
        XCTAssertFalse(tracker.mayHoldRestoredPrompt)
    }

    func testDialogKeysNeverTouchTheEstimate() {
        var tracker = TerminalComposerDraftTracker()
        tracker.recordSubmitted(programmaticAt: t0)
        key(&tracker, 18, status: .awaitingInput, at: 0.2)   // „1"
        key(&tracker, esc, status: .awaitingInput, at: 0.3)
        XCTAssertFalse(tracker.mayHaveUnsentInput)
        XCTAssertFalse(tracker.mayHoldRestoredPrompt)
    }

    func testCodexChatsNeverAssumeARestoredPrompt() {
        var tracker = TerminalComposerDraftTracker()
        key(&tracker, esc, status: .working, claude: false, at: 100)
        key(&tracker, esc, claude: false, at: 101)
        key(&tracker, enter, claude: false, at: 102)
        XCTAssertFalse(tracker.mayHoldRestoredPrompt)
        key(&tracker, 0, claude: false, at: 103)
        XCTAssertTrue(tracker.mayHaveUnsentInput, "die Entwurfs-Schätzung gilt weiter")
    }

    func testInterruptCommandUsesTheSameRules() {
        var tracker = TerminalComposerDraftTracker()
        tracker.recordInterruptSignal(status: .idle, now: t0)
        XCTAssertFalse(tracker.mayHoldRestoredPrompt, "ohne Turn und ohne frischen Versand kein Abbruch")
        tracker.recordSubmitted(programmaticAt: t0)
        tracker.recordInterruptSignal(status: .idle, now: t0.addingTimeInterval(2))
        XCTAssertTrue(tracker.mayHoldRestoredPrompt)
        tracker.recordSubmitted()
        tracker.recordInterruptSignal(status: .working, now: t0.addingTimeInterval(60))
        XCTAssertTrue(tracker.mayHoldRestoredPrompt)
    }

    /// Entwurf des Users: nie anhängen, nie leeren — `send` lehnt ab, die
    /// Queue wartet (der Auftrag bleibt stehen).
    func testUserDraftOverARestoredPromptHoldsDeliveryInsteadOfClearing() {
        var tracker = TerminalComposerDraftTracker()
        key(&tracker, esc, status: .working, at: 100)
        key(&tracker, 0, at: 101)              // User bearbeitet den Rückleger
        XCTAssertFalse(tracker.shouldClearBeforeSubmit)
        XCTAssertTrue(PromptDeliveryGate.sendBlockedByDraft(
            mayHaveUnsentInput: tracker.mayHaveUnsentInput, force: false))
        XCTAssertEqual(PromptDeliveryGate.forQueue(
            runtime: .idle, lifecycle: .ready, mayHaveUnsentInput: tracker.mayHaveUnsentInput), .draftPending)
    }

    @MainActor
    func testRestoredPromptAloneIsDeliveredAfterClearing() {
        var tracker = TerminalComposerDraftTracker()
        key(&tracker, esc, status: .working, at: 100)
        XCTAssertEqual(PromptDeliveryGate.forQueue(
            runtime: .idle, lifecycle: .ready, mayHaveUnsentInput: tracker.mayHaveUnsentInput), .deliver)
        XCTAssertTrue(AgentTerminalController.clearsBeforeSubmit(
            draft: tracker, profile: .claudeCodeChat, status: .idle))
    }
}

/// Prüfer-Runde R1/R2: verzögertes Ctrl+C von `interrupt --clear-input` und
/// Abbruch-Tasten für den Status-Koordinator.
final class ComposerDeferredClearTests: XCTestCase {
    func testDeferredClearIsSkippedOnceSomethingWasWritten() {
        var tracker = TerminalComposerDraftTracker()
        tracker.recordTurnInterrupted()
        let planned = tracker.programmaticWrites
        XCTAssertTrue(tracker.deferredClearIsSafe(sinceWrites: planned))
        tracker.recordKeyDown(keyCode: 0, modifiers: [])   // Tippen zählt nicht (opt-in löscht Entwürfe)
        XCTAssertTrue(tracker.deferredClearIsSafe(sinceWrites: planned))

        // `send` leert selbst und fügt ein → das zweite Ctrl+C fiele in den neuen Auftrag.
        tracker.recordSubmitted()
        XCTAssertFalse(tracker.deferredClearIsSafe(sinceWrites: planned))
    }

    func testInsertedTextAlsoBlocksTheDeferredClear() {
        var tracker = TerminalComposerDraftTracker()
        let planned = tracker.programmaticWrites
        tracker.recordTextInserted()   // `send --no-submit`, Datei-Drop, Report
        XCTAssertFalse(tracker.deferredClearIsSafe(sinceWrites: planned))
    }

    func testInterruptKeys() {
        XCTAssertTrue(TerminalComposerDraftTracker.isInterruptKey(keyCode: 53, modifiers: []))
        XCTAssertTrue(TerminalComposerDraftTracker.isInterruptKey(keyCode: 8, modifiers: .control))
        XCTAssertFalse(TerminalComposerDraftTracker.isInterruptKey(keyCode: 53, modifiers: .shift))
        XCTAssertFalse(TerminalComposerDraftTracker.isInterruptKey(keyCode: 8, modifiers: []))
        XCTAssertFalse(TerminalComposerDraftTracker.isInterruptKey(keyCode: 8, modifiers: .command))
    }
}

/// Review-Randnotiz zu 69aa904e: Jede Feature-Methode landet in ihrer Datei,
/// keine bei „Unbekannte Methode".
final class ControlFeatureRoutingTests: XCTestCase {
    func testEveryFeatureMethodHasItsRoute() {
        let expected: [(Set<String>, AgentControlRequestHandler.FeatureRoute)] = [
            (AgentControlRequestHandler.boardMethods, .board),
            (AgentControlRequestHandler.debugMethods, .debug),
            (AgentControlRequestHandler.speechMethods, .speech),
            (AgentControlRequestHandler.clipboardMethods, .clipboard),
        ]
        for (methods, route) in expected {
            XCTAssertFalse(methods.isEmpty)
            for method in methods {
                XCTAssertEqual(AgentControlRequestHandler.featureRoute(for: method), route, method)
            }
        }
    }

    func testFeatureSetsAreDisjoint() {
        let sets = AgentControlRequestHandler.FeatureRoute.allCases.map(\.methods)
        let all = sets.reduce(into: [String]()) { $0 += $1 }
        XCTAssertEqual(Set(all).count, all.count, "eine Methode in zwei Sets wäre mehrdeutig")
    }

    func testCoreAndUnknownMethodsHaveNoFeatureRoute() {
        for method in ["session.send", "ping", "queue.enqueue", "board", "debug.unknown", "speech.whisper"] {
            XCTAssertNil(AgentControlRequestHandler.featureRoute(for: method), method)
        }
    }

    func testUnknownMethodIsUnsupportedThroughHandle() async {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("audit-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        let handler = AgentControlRequestHandler()
        handler.auditLog = ChatsAuditLog(fileURL: file)
        let response = await handler.handle(ChatsControlRequest(actor: ChatsControlActor(), method: "nope.nothing"))
        XCTAssertEqual(response.error?.code, ChatsControlErrorCode.unsupported.rawValue)
        XCTAssertEqual(response.error?.message, "Unbekannte Methode: nope.nothing")
    }

    /// Durch `handle(_:)` ohne Nebenwirkung: leerer Text spricht nichts.
    func testSpeechMethodReachesItsHandlerThroughHandle() async {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("audit-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        let handler = AgentControlRequestHandler()
        handler.auditLog = ChatsAuditLog(fileURL: file)
        let response = await handler.handle(ChatsControlRequest(
            actor: ChatsControlActor(), method: "speech.speak", params: .object(["text": .string("")])))
        XCTAssertFalse(response.ok)
        XCTAssertNotEqual(response.error?.message, "Unbekannte Methode: speech.speak")
    }
}

/// Review S3: Der Stummel des ausgebauten Send-Guards.
final class PromptGuardStubTests: XCTestCase {
    func testStubDrainsLargeHookInputAndExitsZero() throws {
        let pipe = Pipe()
        let writer = pipe.fileHandleForWriting
        let payload = Data(repeating: UInt8(ascii: "x"), count: 256 * 1024)
        let wrote = expectation(description: "Hook-JSON vollständig geschrieben")
        DispatchQueue.global().async {
            // Ohne Lesen bliebe das hier über dem Pipe-Puffer hängen bzw.
            // bekäme EPIPE.
            try? writer.write(contentsOf: payload)
            try? writer.close()
            wrote.fulfill()
        }
        XCTAssertEqual(ChatsPromptGuardStub.run(input: pipe.fileHandleForReading), ChatsCLIExit.ok)
        wait(for: [wrote], timeout: 5)
    }

    /// Über den echten Dispatch: alte Sessions rufen `chats _prompt-guard`.
    func testDispatchExitsZero() async throws {
        let saved = dup(STDIN_FILENO)
        let devNull = open("/dev/null", O_RDONLY)
        XCTAssertGreaterThanOrEqual(saved, 0)
        XCTAssertGreaterThanOrEqual(devNull, 0)
        dup2(devNull, STDIN_FILENO)
        close(devNull)
        defer {
            dup2(saved, STDIN_FILENO)
            close(saved)
        }
        let exit = await AgentChatsCLICommand.run(arguments: ["_prompt-guard"])
        XCTAssertEqual(exit, ChatsCLIExit.ok)
    }

    func testSendTokensAreRemovedOnce() throws {
        let suite = "send-tokens-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("send-tokens-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: dir.appendingPathComponent("a.json"))
        defaults.set(false, forKey: "chatsPromptGuardEnabled")

        let done = expectation(description: "aufgeräumt")
        LegacyDataCleanup.removeObsoleteSendTokens(defaults: defaults, directory: dir) { done.fulfill() }
        wait(for: [done], timeout: 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
        XCTAssertNil(defaults.object(forKey: "chatsPromptGuardEnabled"))
        XCTAssertTrue(defaults.bool(forKey: "sendTokensPurged"))

        // Zweiter Lauf: nichts mehr zu tun, auch ein neu angelegter Ordner bleibt.
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let skipped = expectation(description: "kein zweiter Lauf")
        skipped.isInverted = true
        LegacyDataCleanup.removeObsoleteSendTokens(defaults: defaults, directory: dir) { skipped.fulfill() }
        wait(for: [skipped], timeout: 0.5)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path))
    }

    /// ↑ vom Controller holt den letzten Prompt zurück: Bei Claude leert ein
    /// programmatischer Versand das Feld vorher, sonst gilt er als Entwurf.
    func testHistoryRecallFromController() {
        var claude = TerminalComposerDraftTracker()
        claude.recordHistoryRecall(isClaude: true)
        XCTAssertTrue(claude.shouldClearBeforeSubmit)
        XCTAssertFalse(claude.mayHaveUnsentInput, "← bleibt gesperrt, der Feldinhalt ist nur geschätzt")
        var codex = TerminalComposerDraftTracker()
        codex.recordHistoryRecall(isClaude: false)
        XCTAssertTrue(codex.mayHaveUnsentInput)
    }

    /// Codex (Review Runde 5, Befund 3): ↑ aus dem leeren Feld ist ein
    /// zurückgeholter Prompt — R1 + Kreuz schickt ihn nicht erneut ab. Wer
    /// darin tippt oder löscht, hat einen eigenen Entwurf; ↑ in einem eigenen
    /// Entwurf bewegt nur den Cursor.
    func testCodexRecallIsTellableFromAnOwnDraft() {
        var codex = TerminalComposerDraftTracker()
        codex.recordHistoryRecall(isClaude: false)
        XCTAssertTrue(codex.holdsOnlyRecalledPrompt)
        codex.recordHistoryRecall(isClaude: false)
        XCTAssertTrue(codex.holdsOnlyRecalledPrompt, "weiter zurück im Verlauf")
        codex.recordKeyDown(keyCode: 0, modifiers: [])
        XCTAssertFalse(codex.holdsOnlyRecalledPrompt)
        XCTAssertTrue(codex.mayHaveUnsentInput)

        var edited = TerminalComposerDraftTracker()
        edited.recordHistoryRecall(isClaude: false)
        edited.recordKeyDown(keyCode: 51, modifiers: [])
        XCTAssertFalse(edited.holdsOnlyRecalledPrompt, "Löschen verändert den Prompt")

        var draft = TerminalComposerDraftTracker()
        draft.recordKeyDown(keyCode: 0, modifiers: [])
        draft.recordHistoryRecall(isClaude: false)
        XCTAssertFalse(draft.holdsOnlyRecalledPrompt, "↑ im eigenen Entwurf holt nichts")

        codex.recordSubmitted()
        XCTAssertFalse(codex.holdsOnlyRecalledPrompt)
    }

    /// Review Runde 5: Geleertes Feld, dann ↑ — das ist wieder ein
    /// zurückgeholter Prompt, kein eigener Entwurf.
    func testCodexRecallAfterTheFieldWasCleared() {
        var ctrlU = TerminalComposerDraftTracker()
        ctrlU.recordKeyDown(keyCode: 0, modifiers: [])
        ctrlU.recordKeyDown(keyCode: 32, modifiers: .control)
        ctrlU.recordHistoryRecall(isClaude: false)
        XCTAssertTrue(ctrlU.holdsOnlyRecalledPrompt, "Ctrl+U")

        var ctrlC = TerminalComposerDraftTracker()
        ctrlC.recordKeyDown(keyCode: 0, modifiers: [])
        ctrlC.recordKeyDown(keyCode: 8, modifiers: .control)
        ctrlC.recordHistoryRecall(isClaude: false)
        XCTAssertTrue(ctrlC.holdsOnlyRecalledPrompt, "Ctrl+C")

        // Rücktaste bis leer: nur der Bildschirm weiß es.
        var screen = TerminalComposerDraftTracker()
        screen.recordKeyDown(keyCode: 0, modifiers: [])
        screen.recordKeyDown(keyCode: 51, modifiers: [])
        screen.recordHistoryRecall(isClaude: false, fieldVisiblyEmpty: true)
        XCTAssertTrue(screen.holdsOnlyRecalledPrompt, "sichtbar leer")

        // Sichtbar Text im Feld (eigener Entwurf): ↑ holt nichts.
        var draft = TerminalComposerDraftTracker()
        draft.recordHistoryRecall(isClaude: false, fieldVisiblyEmpty: false)
        XCTAssertFalse(draft.holdsOnlyRecalledPrompt)
    }

    /// → vom Controller (Vorschlag übernommen) und ↑ (Prompt zurückgeholt)
    /// heißen „Text im Feld“: Pfeil links wird frei. Absenden setzt zurück.
    func testFieldMayHaveTextAfterSuggestionAndRecall() {
        var tracker = TerminalComposerDraftTracker()
        XCTAssertFalse(tracker.fieldMayHaveText)
        tracker.recordSuggestionAccepted()
        XCTAssertTrue(tracker.fieldMayHaveText)
        XCTAssertFalse(tracker.mayHaveUnsentInput, "kein eigener Entwurf")
        tracker.recordSubmitted()
        XCTAssertFalse(tracker.fieldMayHaveText)
        tracker.recordHistoryRecall(isClaude: true)
        XCTAssertTrue(tracker.fieldMayHaveText)
        tracker.recordSubmittedByTurnStart()
        tracker.recordSubmitted()
        XCTAssertFalse(tracker.fieldMayHaveText)
    }
}
