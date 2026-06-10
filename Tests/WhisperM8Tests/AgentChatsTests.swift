import AppKit
import Foundation
import XCTest
@testable import WhisperM8

final class AgentChatsTests: XCTestCase {
    // MARK: - Auto-Chat-Context

    func testTranscriptContextBundleIsNotEmptyWhenAgentChatPresent() {
        let ref = AgentChatContextRef(
            sessionID: UUID(),
            provider: .claude,
            projectName: "heartbeat",
            projectPath: "/tmp/heartbeat",
            title: "Claude Chat",
            externalSessionID: nil
        )
        let bundle = TranscriptContextBundle(agentChat: ref)
        XCTAssertFalse(bundle.isEmpty)
    }

    func testTranscriptContextBundleDisplaySummaryShowsChat() {
        let ref = AgentChatContextRef(
            sessionID: UUID(),
            provider: .codex,
            projectName: "heartbeat",
            projectPath: "/tmp/heartbeat",
            title: "Codex Chat",
            externalSessionID: nil
        )
        let bundle = TranscriptContextBundle(agentChat: ref)
        XCTAssertEqual(bundle.displaySummary, "Chat")
    }

    func testTranscriptContextBundleDisplaySummaryCombinesChatWithText() {
        let ref = AgentChatContextRef(
            sessionID: UUID(),
            provider: .claude,
            projectName: "heartbeat",
            projectPath: "/tmp/heartbeat",
            title: "Claude Chat",
            externalSessionID: nil
        )
        let selected = SelectedContext(
            text: "hello",
            sourceAppName: "Cursor",
            sourceBundleIdentifier: "com.cursor.app"
        )
        let bundle = TranscriptContextBundle(selectedText: selected, agentChat: ref)
        XCTAssertEqual(bundle.displaySummary, "Chat + Text")
    }

    func testTranscriptContextBundleCompactSummaryPrefersChat() {
        let ref = AgentChatContextRef(
            sessionID: UUID(),
            provider: .claude,
            projectName: "x",
            projectPath: "/tmp/x",
            title: "Chat",
            externalSessionID: nil
        )
        // Selbst wenn Screenshots da sind, gewinnt Chat im Compact-Slot.
        let shot = ContextAttachment(
            kind: .screenshot,
            fileURL: URL(fileURLWithPath: "/tmp/shot.png")
        )
        let bundle = TranscriptContextBundle(agentChat: ref, screenshots: [shot])
        XCTAssertEqual(bundle.compactSummary, "Chat")
    }

    func testTranscriptContextBundleFromHelperPropagatesAgentChat() {
        let ref = AgentChatContextRef(
            sessionID: UUID(),
            provider: .claude,
            projectName: "heartbeat",
            projectPath: "/tmp/heartbeat",
            title: "Claude Chat",
            externalSessionID: "ext-id"
        )
        let bundle = TranscriptContextBundle.from(
            selectedContext: .empty,
            sourceApp: nil,
            agentChat: ref
        )
        XCTAssertEqual(bundle.agentChat, ref)
        XCTAssertEqual(bundle.displaySummary, "Chat")
    }

    func testTranscriptContextBundleNoChatStillReportsNoContext() {
        let bundle = TranscriptContextBundle()
        XCTAssertTrue(bundle.isEmpty)
        XCTAssertEqual(bundle.displaySummary, "No Context")
    }

    // MARK: - Terminal Keyboard Shortcuts (Claude Code / Codex / Readline)

    func testTerminalShortcutOptionBackspaceMapsToCtrlW() {
        let bytes = TerminalShortcut.bytes(
            keyCode: TerminalShortcut.KeyCode.delete,
            modifiers: [.option],
            characters: nil
        )
        XCTAssertEqual(bytes, [0x17])
    }

    func testTerminalShortcutCommandBackspaceMapsToCtrlU() {
        let bytes = TerminalShortcut.bytes(
            keyCode: TerminalShortcut.KeyCode.delete,
            modifiers: [.command],
            characters: nil
        )
        XCTAssertEqual(bytes, [0x15])
    }

    func testTerminalShortcutCommandZMapsToReadlineUndo() {
        let bytes = TerminalShortcut.bytes(
            keyCode: TerminalShortcut.KeyCode.z,
            modifiers: [.command],
            characters: "z"
        )
        XCTAssertEqual(bytes, [0x1f])
    }

    func testTerminalShortcutCommandShiftZIsNotIntercepted() {
        // Cmd+Shift+Z (Redo) → durchreichen, Readline kennt kein Redo.
        let bytes = TerminalShortcut.bytes(
            keyCode: TerminalShortcut.KeyCode.z,
            modifiers: [.command, .shift],
            characters: "Z"
        )
        XCTAssertNil(bytes)
    }

    func testTerminalShortcutOptionArrowsMapToWordMovement() {
        let leftBytes = TerminalShortcut.bytes(
            keyCode: TerminalShortcut.KeyCode.leftArrow,
            modifiers: [.option],
            characters: nil
        )
        let rightBytes = TerminalShortcut.bytes(
            keyCode: TerminalShortcut.KeyCode.rightArrow,
            modifiers: [.option],
            characters: nil
        )
        XCTAssertEqual(leftBytes, [0x1b, 0x62])   // Esc+B
        XCTAssertEqual(rightBytes, [0x1b, 0x66])  // Esc+F
    }

    func testTerminalShortcutCommandArrowsMapToLineMovement() {
        let leftBytes = TerminalShortcut.bytes(
            keyCode: TerminalShortcut.KeyCode.leftArrow,
            modifiers: [.command],
            characters: nil
        )
        let rightBytes = TerminalShortcut.bytes(
            keyCode: TerminalShortcut.KeyCode.rightArrow,
            modifiers: [.command],
            characters: nil
        )
        XCTAssertEqual(leftBytes, [0x01])  // Ctrl+A
        XCTAssertEqual(rightBytes, [0x05]) // Ctrl+E
    }

    func testTerminalShortcutPlainBackspaceIsNotIntercepted() {
        // Ohne Modifier soll SwiftTerms Default greifen (sendet 0x7f).
        let bytes = TerminalShortcut.bytes(
            keyCode: TerminalShortcut.KeyCode.delete,
            modifiers: [],
            characters: nil
        )
        XCTAssertNil(bytes)
    }

    func testTerminalShortcutShiftEnterChatProfileBackslashContinuation() {
        // Im normalen Claude-Code-/Codex-Chat soll Shift+Enter als
        // Backslash-Continuation (`\<CR>`) gesendet werden.
        let bytesClaude = TerminalShortcut.bytes(
            keyCode: TerminalShortcut.KeyCode.returnKey,
            modifiers: [.shift],
            characters: nil,
            profile: .claudeCodeChat
        )
        let bytesCodex = TerminalShortcut.bytes(
            keyCode: TerminalShortcut.KeyCode.returnKey,
            modifiers: [.shift],
            characters: nil,
            profile: .codexChat
        )
        XCTAssertEqual(bytesClaude, [0x5c, 0x0d])
        XCTAssertEqual(bytesCodex, [0x5c, 0x0d])
    }

    func testTerminalShortcutShiftEnterAgentsViewProfileSendsCsiU() {
        // `claude agents` hat keine Backslash-Continuation — Shift+Enter
        // muss als kitty/CSI-u-Sequenz `ESC [ 13 ; 2 u` gesendet werden,
        // damit das Input-Field einen Soft-Newline einfuegt.
        let bytes = TerminalShortcut.bytes(
            keyCode: TerminalShortcut.KeyCode.returnKey,
            modifiers: [.shift],
            characters: nil,
            profile: .claudeAgentsView
        )
        XCTAssertEqual(bytes, [0x1b, 0x5b, 0x31, 0x33, 0x3b, 0x32, 0x75])
    }

    func testTerminalShortcutPlainEnterIsNotIntercepted() {
        // Ohne Shift soll Enter durchgereicht werden — sonst killt unser
        // Mapping den normalen Submit.
        for profile in [TerminalKeyboardProfile.claudeCodeChat,
                        .codexChat,
                        .claudeAgentsView] {
            let bytes = TerminalShortcut.bytes(
                keyCode: TerminalShortcut.KeyCode.returnKey,
                modifiers: [],
                characters: nil,
                profile: profile
            )
            XCTAssertNil(bytes, "Enter ohne Modifier muss in \(profile) durchgereicht werden")
        }
    }

    func testTerminalShortcutDefaultProfileIsClaudeCodeChat() {
        // Bestandstests rufen `bytes(...)` ohne profile-Argument auf — das
        // Default muss daher das Chat-Mapping liefern, sonst brechen die
        // alten Aufrufer.
        let bytes = TerminalShortcut.bytes(
            keyCode: TerminalShortcut.KeyCode.returnKey,
            modifiers: [.shift],
            characters: nil
        )
        XCTAssertEqual(bytes, [0x5c, 0x0d])
    }

    // MARK: - Login Shell Environment

    func testLoginShellEnvironmentMergesUserPathWithFallback() {
        let env = LoginShellEnvironment(pathLoader: {
            "/Users/test/.mise/shims:/Users/test/bin:/opt/homebrew/bin:/usr/bin:/bin"
        })
        let path = env.path
        // User-spezifische Pfade müssen vorne stehen (mise/asdf-shims gewinnen).
        XCTAssertTrue(path.hasPrefix("/Users/test/.mise/shims:/Users/test/bin"))
        // Fallback-Pfade dürfen nur einmal vorkommen (Dedup).
        let occurrences = path.components(separatedBy: "/usr/bin").count - 1
        XCTAssertEqual(occurrences, 1)
        // Fallback-Pfade müssen vorhanden sein, auch wenn nicht im User-PATH.
        XCTAssertTrue(path.contains("/usr/sbin"))
        XCTAssertTrue(path.contains("/sbin"))
    }

    func testLoginShellEnvironmentFallsBackOnEmptyResult() {
        let env = LoginShellEnvironment(pathLoader: { "" })
        XCTAssertEqual(env.path, LoginShellEnvironment.fallbackPath)
    }

    func testLoginShellEnvironmentFallsBackOnNil() {
        let env = LoginShellEnvironment(pathLoader: { nil })
        XCTAssertEqual(env.path, LoginShellEnvironment.fallbackPath)
    }

    func testLoginShellEnvironmentCachesResult() {
        var calls = 0
        let env = LoginShellEnvironment(pathLoader: {
            calls += 1
            return "/opt/homebrew/bin:/usr/bin"
        })
        _ = env.path
        _ = env.path
        _ = env.path
        XCTAssertEqual(calls, 1, "PATH-Loader darf nur einmal aufgerufen werden (Cache)")
    }

    func testLoginShellEnvironmentProcessEnvironmentInjectsPath() {
        let env = LoginShellEnvironment(pathLoader: { "/opt/homebrew/bin:/usr/bin" })
        let envDict = env.processEnvironment(base: ["HOME": "/Users/test", "PATH": "/old"])
        XCTAssertEqual(envDict["HOME"], "/Users/test", "Andere ENV-Vars bleiben erhalten")
        XCTAssertTrue(envDict["PATH"]?.contains("/opt/homebrew/bin") == true)
        XCTAssertNotEqual(envDict["PATH"], "/old", "Alter PATH wird ersetzt")
    }

    func testLoginShellEnvironmentTerminalEnvironmentArrayHasPathKey() {
        let env = LoginShellEnvironment(pathLoader: { "/opt/homebrew/bin:/usr/bin" })
        let array = env.terminalEnvironmentArray(base: ["HOME": "/Users/test"])
        XCTAssertTrue(array.contains { $0.hasPrefix("PATH=") && $0.contains("/opt/homebrew/bin") })
        XCTAssertTrue(array.contains("HOME=/Users/test"))
    }

    func testLoginShellEnvironmentSetsTerminalColorDefaults() {
        // Regression: ohne TERM/COLORTERM rendern Claude Code & Codex CLI monochrom,
        // weil GUI-Apps diese Vars nicht von launchd erben.
        let env = LoginShellEnvironment(pathLoader: { "/usr/bin" })
        let envDict = env.processEnvironment(base: [:])
        XCTAssertEqual(envDict["TERM"], "xterm-256color")
        XCTAssertEqual(envDict["COLORTERM"], "truecolor")
        XCTAssertEqual(envDict["CLICOLOR"], "1")
        XCTAssertEqual(envDict["LANG"], "en_US.UTF-8")
    }

    func testLoginShellEnvironmentRepairsMonochromeLauncherEnvironment() {
        // Regression: `make dev` aus Codex kann die App mit TERM=dumb und
        // NO_COLOR=1 starten. Diese Werte dürfen nicht an SwiftTerm-Child-
        // Prozesse weitergereicht werden, sonst rendert Claude/Codex grau.
        let env = LoginShellEnvironment(pathLoader: { "/usr/bin" })
        let envDict = env.processEnvironment(base: [
            "TERM": "dumb",
            "COLORTERM": "",
            "NO_COLOR": "1"
        ])

        XCTAssertEqual(envDict["TERM"], "xterm-256color")
        XCTAssertEqual(envDict["COLORTERM"], "truecolor")
        XCTAssertEqual(envDict["CLICOLOR"], "1")
        XCTAssertNil(envDict["NO_COLOR"])
    }

    func testLoginShellEnvironmentRespectsExistingTerminalVars() {
        // User-Profile (z. B. iTerm-User mit TERM=xterm-kitty) sollen nicht
        // überschrieben werden — wir füllen nur Lücken.
        let env = LoginShellEnvironment(pathLoader: { "/usr/bin" })
        let envDict = env.processEnvironment(base: [
            "TERM": "xterm-kitty",
            "COLORTERM": "24bit",
            "LC_ALL": "de_DE.UTF-8"
        ])
        XCTAssertEqual(envDict["TERM"], "xterm-kitty")
        XCTAssertEqual(envDict["COLORTERM"], "24bit")
        XCTAssertEqual(envDict["LC_ALL"], "de_DE.UTF-8")
        XCTAssertNil(envDict["LANG"], "LANG nicht gesetzt, weil LC_ALL bereits eine Locale liefert")
    }

    func testFallbackPathContainsCommonLocations() {
        // Sanity-Check: alle wichtigen Pfade abgedeckt für Apple Silicon + Intel
        let fallback = LoginShellEnvironment.fallbackPath
        for expected in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"] {
            XCTAssertTrue(fallback.contains(expected), "fallbackPath muss \(expected) enthalten")
        }
        // Regression: der native Claude-Code-Installer legt das Binary unter
        // ~/.local/bin ab — dieser Pfad landet nur via .zshrc im PATH und
        // fehlt deshalb in der nicht-interaktiven Login-Shell.
        XCTAssertTrue(
            fallback.contains("\(NSHomeDirectory())/.local/bin"),
            "fallbackPath muss ~/.local/bin enthalten (nativer Claude-Installer)"
        )
    }

    func testTerminalShortcutControlCombosAreNotIntercepted() {
        // Wenn der User Control hält, soll SwiftTerm seine Standard-Control-
        // Sequences durchgeben (Ctrl+W = 0x17, Ctrl+U = 0x15 etc.) — wir
        // konkurrieren nicht damit.
        XCTAssertNil(TerminalShortcut.bytes(
            keyCode: TerminalShortcut.KeyCode.delete,
            modifiers: [.control, .option],
            characters: nil
        ))
        XCTAssertNil(TerminalShortcut.bytes(
            keyCode: TerminalShortcut.KeyCode.z,
            modifiers: [.control, .command],
            characters: "z"
        ))
    }

    // MARK: - Transcript Parser & Status Decider

    func testTranscriptParserClaudeUserMessage() {
        let line = #"{"type":"user","timestamp":"2026-05-10T12:00:00Z","message":{"role":"user","content":"hallo"}}"#
        let event = AgentTranscriptParser.parseLine(line, provider: .claude)
        guard case .userMessage = event else {
            return XCTFail("Erwartete .userMessage, bekam \(String(describing: event))")
        }
    }

    func testTranscriptParserClaudeToolResultIsNotUserMessage() {
        // Tool-Results sind in Claude technisch User-Messages mit tool_result-
        // Content-Block — wir behandeln sie als eigene Kategorie.
        let line = #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"x"}]}}"#
        let event = AgentTranscriptParser.parseLine(line, provider: .claude)
        guard case .toolResult = event else {
            return XCTFail("Erwartete .toolResult, bekam \(String(describing: event))")
        }
    }

    func testTranscriptParserClaudeAssistantStopped() {
        let line = #"{"type":"assistant","timestamp":"2026-05-10T12:00:01Z","message":{"role":"assistant","content":[{"type":"text","text":"Done."}],"stop_reason":"end_turn"}}"#
        let event = AgentTranscriptParser.parseLine(line, provider: .claude)
        guard case let .assistantMessageStopped(_, reason) = event else {
            return XCTFail("Erwartete .assistantMessageStopped, bekam \(String(describing: event))")
        }
        XCTAssertEqual(reason, "end_turn")
    }

    func testTranscriptParserClaudeAssistantOngoing() {
        let line = #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"x","name":"Bash","input":{}}]}}"#
        let event = AgentTranscriptParser.parseLine(line, provider: .claude)
        guard case .assistantMessageOngoing = event else {
            return XCTFail("Erwartete .assistantMessageOngoing, bekam \(String(describing: event))")
        }
    }

    func testTranscriptParserCodexTurnCompleted() {
        let line = #"{"type":"event","subtype":"turn.completed","timestamp":"2026-05-10T12:00:00Z"}"#
        let event = AgentTranscriptParser.parseLine(line, provider: .codex)
        guard case .assistantMessageStopped = event else {
            return XCTFail("Erwartete .assistantMessageStopped für Codex, bekam \(String(describing: event))")
        }
    }

    func testTranscriptParserCodexUserItem() {
        let line = #"{"type":"item","subtype":"user_message","content":[{"text":"go"}]}"#
        let event = AgentTranscriptParser.parseLine(line, provider: .codex)
        guard case .userMessage = event else {
            return XCTFail("Erwartete .userMessage für Codex, bekam \(String(describing: event))")
        }
    }

    func testTranscriptParserReturnsNilForGarbageLine() {
        XCTAssertNil(AgentTranscriptParser.parseLine("not json", provider: .claude))
        XCTAssertNil(AgentTranscriptParser.parseLine("", provider: .codex))
    }

    func testTranscriptParserPicksLastValidLineFromTail() {
        // Tail-Reads beginnen oft mit einer halben Zeile — der Parser muss
        // robust nur die letzte vollständige Zeile auswerten.
        let truncated = "\"xxxx incomplete pre-line\"\n"
            + #"{"type":"assistant","message":{"stop_reason":"end_turn","content":[]}}"#
            + "\n"
        let event = AgentTranscriptParser.lastEvent(in: truncated, provider: .claude)
        guard case .assistantMessageStopped = event else {
            return XCTFail("Erwartete .assistantMessageStopped als letzte Zeile, bekam \(String(describing: event))")
        }
    }

    func testStatusDeciderReportsWorkingForRecentUserMessage() {
        let now = Date()
        let event: AgentTranscriptEvent = .userMessage(timestamp: now)
        let decision = AgentTranscriptStatusDecider.decide(
            lastEvent: event,
            fileMTime: now,
            now: now,
            priorTurnFinishedAt: nil
        )
        XCTAssertEqual(decision.status, .working)
        XCTAssertFalse(decision.turnFinished)
    }

    func testStatusDeciderReportsIdleAndTurnFinishedAfterStop() {
        let now = Date()
        let stopped = now.addingTimeInterval(-1)
        let event: AgentTranscriptEvent = .assistantMessageStopped(timestamp: stopped, stopReason: "end_turn")
        let decision = AgentTranscriptStatusDecider.decide(
            lastEvent: event,
            fileMTime: stopped,
            now: now,
            priorTurnFinishedAt: nil
        )
        XCTAssertEqual(decision.status, .idle)
        XCTAssertTrue(decision.turnFinished, "Erstes Stop-Event muss als turnFinished melden")
    }

    func testStatusDeciderSuppressesTurnFinishedReDetection() {
        let now = Date()
        let stoppedAt = now.addingTimeInterval(-2)
        let event: AgentTranscriptEvent = .assistantMessageStopped(timestamp: stoppedAt, stopReason: "end_turn")
        let decision = AgentTranscriptStatusDecider.decide(
            lastEvent: event,
            fileMTime: stoppedAt,
            now: now,
            priorTurnFinishedAt: stoppedAt.addingTimeInterval(1)
        )
        XCTAssertEqual(decision.status, .idle)
        XCTAssertFalse(decision.turnFinished, "Älteres oder gleiches Stop-Event darf nicht als neuer Turn melden")
    }

    func testStatusDeciderEscalatesOngoingToAwaitingInputAfterTimeout() {
        let now = Date()
        let event: AgentTranscriptEvent = .assistantMessageOngoing(timestamp: now)
        // mtime liegt weiter zurück als der Heuristik-Schwellwert
        let mtime = now.addingTimeInterval(-(AgentTranscriptStatusDecider.awaitingInputAfterSeconds + 1))
        let decision = AgentTranscriptStatusDecider.decide(
            lastEvent: event,
            fileMTime: mtime,
            now: now,
            priorTurnFinishedAt: nil
        )
        XCTAssertEqual(decision.status, .awaitingInput)
    }

    func testStatusDeciderTreatsRecentOngoingAsWorking() {
        let now = Date()
        let event: AgentTranscriptEvent = .assistantMessageOngoing(timestamp: now)
        let decision = AgentTranscriptStatusDecider.decide(
            lastEvent: event,
            fileMTime: now,
            now: now,
            priorTurnFinishedAt: nil
        )
        XCTAssertEqual(decision.status, .working)
    }

    func testStatusDeciderHandlesEmptyTranscriptAsWorking() {
        // Frisch gestartete Session: Datei noch leer / unparseable.
        let decision = AgentTranscriptStatusDecider.decide(
            lastEvent: nil,
            fileMTime: Date(),
            now: Date(),
            priorTurnFinishedAt: nil
        )
        XCTAssertEqual(decision.status, .working)
    }

    // MARK: - Title Generator Cleanup

    func testTitleGeneratorCleanupStripsQuotesAndPunctuation() {
        XCTAssertEqual(AgentTitleGenerator.cleanTitle("\"Refactor login UI\""), "Refactor login UI")
        XCTAssertEqual(AgentTitleGenerator.cleanTitle("Refactor login UI."), "Refactor login UI")
        XCTAssertEqual(AgentTitleGenerator.cleanTitle("Title: Database Migration!"), "Database Migration")
    }

    func testTitleGeneratorCleanupTakesFirstLineOnly() {
        let raw = "Refactor login UI\nSome explanation goes here"
        XCTAssertEqual(AgentTitleGenerator.cleanTitle(raw), "Refactor login UI")
    }

    func testTitleGeneratorCleanupCapsLength() {
        let long = String(repeating: "A", count: 120)
        let cleaned = AgentTitleGenerator.cleanTitle(long)
        XCTAssertLessThanOrEqual(cleaned.count, 60)
    }

    func testAgentHeadlessCLIReturnsStdout() async throws {
        let output = try await AgentHeadlessCLI(timeout: 2).run(
            executable: URL(fileURLWithPath: "/bin/echo"),
            arguments: ["hello"],
            environment: [:]
        )

        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "hello")
    }

    func testAgentHeadlessCLIReportsNonZeroExit() async throws {
        do {
            _ = try await AgentHeadlessCLI(timeout: 2).run(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "echo nope >&2; exit 7"],
                environment: [:]
            )
            XCTFail("Expected non-zero exit")
        } catch AgentHeadlessCLIError.nonZeroExit(let code, let stderr) {
            XCTAssertEqual(code, 7)
            XCTAssertTrue(stderr.contains("nope"))
        }
    }

    func testAgentHeadlessCLITimesOut() async throws {
        do {
            _ = try await AgentHeadlessCLI(timeout: 0.05).run(
                executable: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["2"],
                environment: [:]
            )
            XCTFail("Expected timeout")
        } catch AgentHeadlessCLIError.timedOut {
            // Expected.
        }
    }

    // MARK: - Auto-Title Flag

    func testCanAutoRenameTitleAllowsLegacyDefaultName() {
        // Legacy-Sessions ohne Flag, aber mit Default-Name → Auto-Rename erlaubt.
        let session = AgentChatSession(
            provider: .claude,
            projectID: UUID(),
            title: "Claude Chat"
        )
        XCTAssertTrue(session.canAutoRenameTitle)
    }

    func testCanAutoRenameTitleBlocksUserSuppliedName() {
        // Wenn der User explizit umbenannt hat, kommt das Flag = false rein.
        var session = AgentChatSession(
            provider: .claude,
            projectID: UUID(),
            title: "My Custom Project Name"
        )
        session.titleIsAutoGenerated = false
        XCTAssertFalse(session.canAutoRenameTitle)
    }

    func testCanAutoRenameTitleAllowsAutoGeneratedReplacement() {
        // Auto-generierter Name darf vom Auto-Namer überschrieben werden
        // (nützlich, falls die Session weiterläuft und sich neu fokussiert).
        var session = AgentChatSession(
            provider: .codex,
            projectID: UUID(),
            title: "Initial auto title"
        )
        session.titleIsAutoGenerated = true
        XCTAssertTrue(session.canAutoRenameTitle)
    }

    func testApplyAutoGeneratedTitleRespectsManualRename() throws {
        let url = makeTempStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AgentSessionStore(fileURL: url)
        let session = try store.createSession(
            provider: .claude,
            projectPath: NSTemporaryDirectory(),
            title: "Claude Chat"
        )
        // User benennt manuell um → Flag = false.
        try store.renameSession(id: session.id, title: "Important Bugfix")
        // Auto-Namer versucht zu schreiben — darf nicht durchkommen.
        try store.applyAutoGeneratedTitle(id: session.id, title: "Generic Auto Name")
        let workspace = store.loadWorkspace()
        let updated = workspace.sessions.first { $0.id == session.id }
        XCTAssertEqual(updated?.title, "Important Bugfix")
        XCTAssertEqual(updated?.titleIsAutoGenerated, false)
    }

    func testApplyAutoGeneratedTitleAcceptsLegacyDefaultName() throws {
        let url = makeTempStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AgentSessionStore(fileURL: url)
        let session = try store.createSession(
            provider: .claude,
            projectPath: NSTemporaryDirectory(),
            title: "Claude Chat"
        )
        try store.applyAutoGeneratedTitle(id: session.id, title: "Login UI Refactor")
        let workspace = store.loadWorkspace()
        let updated = workspace.sessions.first { $0.id == session.id }
        XCTAssertEqual(updated?.title, "Login UI Refactor")
        XCTAssertEqual(updated?.titleIsAutoGenerated, true)
    }

    func testForceGenerateTitleBypassesLastTurnAtAndAttemptedSet() async throws {
        // Force-Pfad: gescannte alte Session hat schon `lastTurnAt` und der
        // Namer hat sie ggf. in `alreadyAttempted`. Beides muss `forceGenerateTitle`
        // ignorieren — solange `canAutoRenameTitle == true` bleibt.
        let url = makeTempStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AgentSessionStore(fileURL: url)

        // Echtes Claude-Transcript anlegen, damit der Locator + Excerpt-Builder Daten sehen.
        let projectDir = try makeTempProjectDirectory()
        defer { try? FileManager.default.removeItem(at: projectDir) }
        let externalSessionID = "11111111-2222-3333-4444-555555555555"
        let claudeBase = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
            .appendingPathComponent("projects")
            .appendingPathComponent(AgentTranscriptLocator.encodeClaudeCwd(projectDir.path))
        try? FileManager.default.createDirectory(at: claudeBase, withIntermediateDirectories: true)
        let transcriptURL = claudeBase.appendingPathComponent("\(externalSessionID).jsonl")
        defer { try? FileManager.default.removeItem(at: transcriptURL) }
        let transcript = #"""
        {"type":"user","message":{"role":"user","content":"refactor my login flow"}}
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Here is a plan."}],"stop_reason":"end_turn"}}
        """#
        try transcript.write(to: transcriptURL, atomically: true, encoding: .utf8)

        var session = try store.createSession(
            provider: .claude,
            projectPath: projectDir.path,
            title: "Claude Chat"
        )
        session.externalSessionID = externalSessionID
        session.lastTurnAt = Date()  // simuliert Resume-Session, blockt normalerweise Auto-Naming
        _ = try store.upsertSession(session)

        let stub = AgentTitleGenerator(
            executableResolver: { _ in "/usr/bin/true" },
            runner: { _, _, _ in "Login Flow Refactor" }
        )
        let namer = await AgentSessionAutoNamer(store: store, titleGenerator: stub)
        await namer.resetAttemptTracking()
        // Auch wenn sie zuvor schon mal blockiert war, force soll es trotzdem tun.
        await namer.handleTurnFinished(session: session, cwd: projectDir.path)

        let snapshotAfterRegular = store.loadWorkspace().sessions.first { $0.id == session.id }
        XCTAssertEqual(snapshotAfterRegular?.title, "Claude Chat",
                       "handleTurnFinished blockt erwartungsgemäß bei lastTurnAt != nil")

        // Force-Pfad: blocking flags werden ignoriert, Title wird gesetzt.
        let expectation = expectation(description: "force-naming completes")
        await namer.forceGenerateTitle(session: session, cwd: projectDir.path) { result in
            if case .success = result { expectation.fulfill() }
        }
        await fulfillment(of: [expectation], timeout: 5)

        let updated = store.loadWorkspace().sessions.first { $0.id == session.id }
        XCTAssertEqual(updated?.title, "Login Flow Refactor")
        XCTAssertEqual(updated?.titleIsAutoGenerated, true)
    }

    func testForceGenerateTitleStillRespectsManualRename() async throws {
        // canAutoRenameTitle == false (User hat manuell umbenannt) → force darf NICHT überschreiben.
        let url = makeTempStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AgentSessionStore(fileURL: url)
        var session = try store.createSession(
            provider: .claude,
            projectPath: NSTemporaryDirectory(),
            title: "Manual Important Name"
        )
        session.titleIsAutoGenerated = false  // wie nach manuellem Rename
        session.externalSessionID = "abc-123"
        _ = try store.upsertSession(session)

        let stub = AgentTitleGenerator(
            executableResolver: { _ in "/usr/bin/true" },
            runner: { _, _, _ in "Should Never Be Set" }
        )
        let namer = await AgentSessionAutoNamer(store: store, titleGenerator: stub)
        let expectation = expectation(description: "force call returns or skips")
        expectation.isInverted = true
        await namer.forceGenerateTitle(session: session, cwd: NSTemporaryDirectory()) { _ in
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: 1)

        let snap = store.loadWorkspace().sessions.first { $0.id == session.id }
        XCTAssertEqual(snap?.title, "Manual Important Name")
    }

    func testRecordTurnEndedSetsLastTurnAt() throws {
        let url = makeTempStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AgentSessionStore(fileURL: url)
        let session = try store.createSession(
            provider: .claude,
            projectPath: NSTemporaryDirectory(),
            title: "Claude Chat"
        )
        let timestamp = Date(timeIntervalSinceReferenceDate: 1_000_000)
        try store.recordTurnEnded(id: session.id, at: timestamp)
        let workspace = store.loadWorkspace()
        let updated = workspace.sessions.first { $0.id == session.id }
        XCTAssertEqual(updated?.lastTurnAt, timestamp)
    }

    // MARK: - Transcript Locator

    func testClaudeCwdEncodingMatchesActualEncoding() {
        // Claude ersetzt jeden Nicht-Alphanumerik-Char durch `-`.
        XCTAssertEqual(
            AgentTranscriptLocator.encodeClaudeCwd("/Users/foo/repos/heartbeat"),
            "-Users-foo-repos-heartbeat"
        )
        XCTAssertEqual(
            AgentTranscriptLocator.encodeClaudeCwd("/var/lib/data_2"),
            "-var-lib-data-2"
        )
    }

    // MARK: - Terminal drag-drop payload

    func testTerminalDropPayloadEscapesNothingForSimplePath() {
        XCTAssertEqual(
            TerminalDropPayload.build(from: ["/Users/me/repos/whisperm8/file.md"]),
            "/Users/me/repos/whisperm8/file.md"
        )
    }

    func testTerminalDropPayloadEscapesSpacesAndSpecialChars() {
        XCTAssertEqual(
            TerminalDropPayload.shellEscape("/Users/me/Tim AI/2026-05-11 plan.md"),
            "/Users/me/Tim\\ AI/2026-05-11\\ plan.md"
        )
    }

    func testTerminalDropPayloadEscapesUmlauts() {
        // Umlaute sind nicht im "safe"-Set, müssen also escapt werden, damit
        // die Shell sie nicht als Argument-Trennzeichen oder Glob behandelt.
        let escaped = TerminalDropPayload.shellEscape("/Users/me/Übersicht.md")
        XCTAssertTrue(escaped.contains("\\Ü"))
    }

    func testTerminalDropPayloadJoinsMultiplePathsWithSpaces() {
        let result = TerminalDropPayload.build(from: [
            "/tmp/a.md",
            "/tmp/b c.md"
        ])
        XCTAssertEqual(result, "/tmp/a.md /tmp/b\\ c.md")
    }

    func testTerminalDropPayloadEmptyInput() {
        XCTAssertEqual(TerminalDropPayload.build(from: []), "")
    }

    // MARK: - Summary excerpt + parser

    func testBuildExtendedKeepsFirstAndLastMessagesWithMarker() {
        var lines: [String] = []
        for i in 1...30 {
            let role = i.isMultiple(of: 2) ? "assistant" : "user"
            let content = "msg-\(i)"
            if role == "assistant" {
                lines.append(#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"\#(content)"}],"stop_reason":"end_turn"}}"#)
            } else {
                lines.append(#"{"type":"user","message":{"role":"user","content":"\#(content)"}}"#)
            }
        }
        let text = lines.joined(separator: "\n")
        let result = AgentTranscriptExcerpt.buildExtended(fromText: text, provider: .claude)

        XCTAssertTrue(result.contains("msg-1"), "Anfangs-Messages müssen erhalten bleiben")
        XCTAssertTrue(result.contains("msg-30"), "Ende-Messages müssen erhalten bleiben")
        XCTAssertTrue(result.contains("trimmed for brevity"), "Truncation-Marker erwartet bei > 24 Messages")
    }

    func testBuildExtendedShortSessionContainsAllMessages() {
        let lines = [
            #"{"type":"user","message":{"role":"user","content":"hi"}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"hello"}],"stop_reason":"end_turn"}}"#
        ]
        let result = AgentTranscriptExcerpt.buildExtended(fromText: lines.joined(separator: "\n"), provider: .claude)
        XCTAssertTrue(result.contains("hi"))
        XCTAssertTrue(result.contains("hello"))
        XCTAssertFalse(result.contains("trimmed"))
    }

    // MARK: - Project icon resolver

    func testProjectIconResolverPicksPublicFavicon() throws {
        let projectURL = try makeTempProjectDirectory()
        defer { try? FileManager.default.removeItem(at: projectURL) }

        let publicDir = projectURL.appendingPathComponent("public")
        try FileManager.default.createDirectory(at: publicDir, withIntermediateDirectories: true)
        let favicon = publicDir.appendingPathComponent("favicon.png")
        try Data([0x89]).write(to: favicon)

        let result = AgentProjectIconResolver.findIconRelativePath(in: projectURL.path)
        XCTAssertEqual(result, "public/favicon.png")
    }

    func testProjectIconResolverPrefersAppleTouchIconOverFavicon() throws {
        let projectURL = try makeTempProjectDirectory()
        defer { try? FileManager.default.removeItem(at: projectURL) }

        let publicDir = projectURL.appendingPathComponent("public")
        try FileManager.default.createDirectory(at: publicDir, withIntermediateDirectories: true)
        try Data([0x89]).write(to: publicDir.appendingPathComponent("favicon.ico"))
        try Data([0x89]).write(to: publicDir.appendingPathComponent("apple-touch-icon.png"))

        let result = AgentProjectIconResolver.findIconRelativePath(in: projectURL.path)
        XCTAssertEqual(result, "public/apple-touch-icon.png", "PNG mit hoher Auflösung muss vor .ico gewinnen")
    }

    func testProjectIconResolverFallsBackToRepoRoot() throws {
        let projectURL = try makeTempProjectDirectory()
        defer { try? FileManager.default.removeItem(at: projectURL) }

        try Data([0x89]).write(to: projectURL.appendingPathComponent("logo.png"))

        let result = AgentProjectIconResolver.findIconRelativePath(in: projectURL.path)
        XCTAssertEqual(result, "logo.png")
    }

    func testProjectIconResolverReturnsNilForEmptyRepo() throws {
        let projectURL = try makeTempProjectDirectory()
        defer { try? FileManager.default.removeItem(at: projectURL) }
        XCTAssertNil(AgentProjectIconResolver.findIconRelativePath(in: projectURL.path))
    }

    // MARK: - Project metadata persistence

    func testRenameProjectPersistsTrimmedName() throws {
        let url = makeTempStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AgentSessionStore(fileURL: url)
        let project = try store.upsertProject(path: NSTemporaryDirectory(), name: "Old Name")
        try store.renameProject(id: project.id, name: "  New Name  ")
        let workspace = store.loadWorkspace()
        XCTAssertEqual(workspace.projects.first?.name, "New Name")
    }

    func testRenameProjectIgnoresEmptyName() throws {
        let url = makeTempStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AgentSessionStore(fileURL: url)
        let project = try store.upsertProject(path: NSTemporaryDirectory(), name: "Stable Name")
        try store.renameProject(id: project.id, name: "   ")
        XCTAssertEqual(store.loadWorkspace().projects.first?.name, "Stable Name")
    }

    func testSetProjectColorPersists() throws {
        let url = makeTempStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AgentSessionStore(fileURL: url)
        let project = try store.upsertProject(path: NSTemporaryDirectory(), name: "p")
        try store.setProjectColor(id: project.id, color: "#FF453A")
        XCTAssertEqual(store.loadWorkspace().projects.first?.color, "#FF453A")
    }

    func testApplyAutoResolvedProjectIconStoresPathAndAttemptedFlag() throws {
        let url = makeTempStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AgentSessionStore(fileURL: url)
        let project = try store.upsertProject(path: NSTemporaryDirectory(), name: "p")
        try store.applyAutoResolvedProjectIcon(id: project.id, relativePath: "public/favicon.png")
        let updated = store.loadWorkspace().projects.first
        XCTAssertEqual(updated?.iconRelativePath, "public/favicon.png")
        XCTAssertEqual(updated?.iconAutoLookupAttempted, true)
    }

    func testApplyAutoResolvedWithNilStillMarksAttempted() throws {
        // Wenn kein Icon gefunden wurde, müssen wir trotzdem `attempted=true`
        // setzen, damit der nächste Reload nicht erneut scannt.
        let url = makeTempStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AgentSessionStore(fileURL: url)
        let project = try store.upsertProject(path: NSTemporaryDirectory(), name: "p")
        try store.applyAutoResolvedProjectIcon(id: project.id, relativePath: nil)
        let updated = store.loadWorkspace().projects.first
        XCTAssertNil(updated?.iconRelativePath)
        XCTAssertEqual(updated?.iconAutoLookupAttempted, true)
    }

    func testClearProjectIconResetsBothSlotsAndAttemptedFlag() throws {
        let url = makeTempStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AgentSessionStore(fileURL: url)
        let project = try store.upsertProject(path: NSTemporaryDirectory(), name: "p")
        try store.setProjectCustomIcon(id: project.id, absolutePath: "/tmp/x.png")
        try store.applyAutoResolvedProjectIcon(id: project.id, relativePath: "public/favicon.png")
        try store.clearProjectIcon(id: project.id)
        let updated = store.loadWorkspace().projects.first
        XCTAssertNil(updated?.iconRelativePath)
        XCTAssertNil(updated?.customIconAbsolutePath)
        XCTAssertNil(updated?.iconAutoLookupAttempted)
    }

    func testProjectResolvedIconURLPrefersCustomOverRelative() throws {
        let projectURL = try makeTempProjectDirectory()
        defer { try? FileManager.default.removeItem(at: projectURL) }
        let custom = projectURL.appendingPathComponent("custom.png")
        try Data([0x89]).write(to: custom)
        try Data([0x89]).write(to: projectURL.appendingPathComponent("logo.png"))

        let project = AgentProject(
            name: "p",
            path: projectURL.path,
            iconRelativePath: "logo.png",
            customIconAbsolutePath: custom.path
        )
        XCTAssertEqual(project.resolvedIconURL?.lastPathComponent, "custom.png")
    }

    func testProjectResolvedIconURLFallsBackToRelativeWhenCustomMissing() throws {
        let projectURL = try makeTempProjectDirectory()
        defer { try? FileManager.default.removeItem(at: projectURL) }
        try Data([0x89]).write(to: projectURL.appendingPathComponent("logo.png"))

        let project = AgentProject(
            name: "p",
            path: projectURL.path,
            iconRelativePath: "logo.png",
            customIconAbsolutePath: "/nonexistent/path.png"
        )
        XCTAssertEqual(project.resolvedIconURL?.lastPathComponent, "logo.png")
    }

    // MARK: - Drag-and-drop reordering

    func testReorderProjectsAssignsSequentialSortIndices() throws {
        let url = makeTempStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AgentSessionStore(fileURL: url)
        // Drei Test-Projekte mit unterschiedlichen Pfaden anlegen.
        let p1 = try store.upsertProject(path: NSTemporaryDirectory() + "p1", name: "A", createdManually: true)
        let p2 = try store.upsertProject(path: NSTemporaryDirectory() + "p2", name: "B", createdManually: true)
        let p3 = try store.upsertProject(path: NSTemporaryDirectory() + "p3", name: "C", createdManually: true)

        // C, A, B — eine vom Default-Order abweichende Reihenfolge.
        try store.reorderProjects(orderedIDs: [p3.id, p1.id, p2.id])

        let sorted = AgentSessionStore.sortedProjects(store.loadWorkspace().projects)
        XCTAssertEqual(sorted.map(\.id), [p3.id, p1.id, p2.id])
        XCTAssertEqual(sorted.map(\.sortIndex), [0, 1, 2])
    }

    func testReorderSessionsAffectsOnlyTargetProject() throws {
        let url = makeTempStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AgentSessionStore(fileURL: url)
        let p1 = try store.upsertProject(path: NSTemporaryDirectory() + "drag-p1", name: "A", createdManually: true)
        let p2 = try store.upsertProject(path: NSTemporaryDirectory() + "drag-p2", name: "B", createdManually: true)
        let s1 = try store.createSession(provider: .claude, projectPath: p1.path, title: "S1")
        let s2 = try store.createSession(provider: .claude, projectPath: p1.path, title: "S2")
        let s3 = try store.createSession(provider: .claude, projectPath: p1.path, title: "S3")
        let other = try store.createSession(provider: .claude, projectPath: p2.path, title: "Other")

        // Innerhalb p1 umordnen: S3, S1, S2
        try store.reorderSessions(in: p1.id, orderedIDs: [s3.id, s1.id, s2.id])

        let workspace = store.loadWorkspace()
        let p1Sessions = AgentSessionStore.sortedSessions(
            workspace.sessions.filter { $0.projectID == p1.id }
        )
        XCTAssertEqual(p1Sessions.map(\.id), [s3.id, s1.id, s2.id])
        // Andere Projekt-Session unverändert.
        let otherSnapshot = workspace.sessions.first { $0.id == other.id }
        XCTAssertNotNil(otherSnapshot)
        XCTAssertEqual(otherSnapshot?.projectID, p2.id)
    }

    func testReorderSessionsWithSameOrderIsNoOpAfterSortIndicesExist() throws {
        let url = makeTempStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AgentSessionStore(fileURL: url)
        let project = try store.upsertProject(path: NSTemporaryDirectory() + "noop-p1", name: "A", createdManually: true)
        let first = try store.createSession(provider: .claude, projectPath: project.path, title: "S1")
        let second = try store.createSession(provider: .claude, projectPath: project.path, title: "S2")
        try store.reorderSessions(in: project.id, orderedIDs: [first.id, second.id])
        let before = store.loadWorkspace()

        try store.reorderSessions(in: project.id, orderedIDs: [first.id, second.id])

        XCTAssertEqual(store.loadWorkspace(), before)
    }

    func testReorderAndMoveIgnoreStaleIDs() throws {
        let url = makeTempStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AgentSessionStore(fileURL: url)
        let project = try store.upsertProject(path: NSTemporaryDirectory() + "stale-p1", name: "A", createdManually: true)
        let session = try store.createSession(provider: .claude, projectPath: project.path, title: "S1")
        let before = store.loadWorkspace()

        try store.reorderSessions(in: project.id, orderedIDs: [UUID()])
        try store.moveSessionToProject(sessionID: session.id, newProjectID: UUID(), targetIndex: 0)

        XCTAssertEqual(store.loadWorkspace(), before)
    }

    func testAgentDragDropPlannerBuildsSessionReorderPlanForLowerToUpperDrop() {
        let project = AgentProject(name: "Repo", path: "/tmp/repo")
        let first = AgentChatSession(provider: .claude, projectID: project.id, title: "First", sortIndex: 0)
        let second = AgentChatSession(provider: .claude, projectID: project.id, title: "Second", sortIndex: 1)
        let workspace = AgentWorkspace(projects: [project], sessions: [first, second])

        let plan = AgentDragDropPlanner.sessionDropPlan(
            dropped: DraggableSession(sessionID: second.id, sourceProjectID: project.id),
            targetProjectID: project.id,
            beforeSessionID: first.id,
            workspace: workspace
        )

        XCTAssertEqual(plan, .reorder(projectID: project.id, orderedIDs: [second.id, first.id]))
    }

    func testAgentDragDropPlannerBuildsSessionReorderPlanForUpperToLowerDrop() {
        let project = AgentProject(name: "Repo", path: "/tmp/repo")
        let first = AgentChatSession(provider: .claude, projectID: project.id, title: "First", sortIndex: 0)
        let second = AgentChatSession(provider: .claude, projectID: project.id, title: "Second", sortIndex: 1)
        let workspace = AgentWorkspace(projects: [project], sessions: [first, second])

        let plan = AgentDragDropPlanner.sessionDropPlan(
            dropped: DraggableSession(sessionID: first.id, sourceProjectID: project.id),
            targetProjectID: project.id,
            beforeSessionID: second.id,
            workspace: workspace
        )

        XCTAssertEqual(plan, .reorder(projectID: project.id, orderedIDs: [second.id, first.id]))
    }

    func testAgentDragDropPlannerPersistsUpperToLowerSessionReorder() throws {
        let url = makeTempStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AgentSessionStore(fileURL: url)
        let project = try store.upsertProject(path: NSTemporaryDirectory() + "dnd-down", name: "Repo", createdManually: true)
        let first = try store.createSession(provider: .claude, projectPath: project.path, title: "First")
        let second = try store.createSession(provider: .claude, projectPath: project.path, title: "Second")
        try store.reorderSessions(in: project.id, orderedIDs: [first.id, second.id])
        let workspace = store.loadWorkspace()

        let plan = AgentDragDropPlanner.sessionDropPlan(
            dropped: DraggableSession(sessionID: first.id, sourceProjectID: project.id),
            targetProjectID: project.id,
            beforeSessionID: second.id,
            workspace: workspace
        )

        guard case .reorder(let projectID, let orderedIDs) = plan else {
            return XCTFail("Expected reorder plan for downward session drop")
        }
        try store.reorderSessions(in: projectID, orderedIDs: orderedIDs)

        let reloaded = store.loadWorkspace()
        let sortedIDs = AgentSessionStore.sortedSessions(reloaded.sessions.filter { $0.projectID == project.id }).map(\.id)
        XCTAssertEqual(sortedIDs, [second.id, first.id])
    }

    func testAgentDragDropPlannerTreatsSelfDropAsNoOp() {
        let project = AgentProject(name: "Repo", path: "/tmp/repo")
        let first = AgentChatSession(provider: .claude, projectID: project.id, title: "First", sortIndex: 0)
        let second = AgentChatSession(provider: .claude, projectID: project.id, title: "Second", sortIndex: 1)
        let workspace = AgentWorkspace(projects: [project], sessions: [first, second])

        let plan = AgentDragDropPlanner.sessionDropPlan(
            dropped: DraggableSession(sessionID: first.id, sourceProjectID: project.id),
            targetProjectID: project.id,
            beforeSessionID: first.id,
            workspace: workspace
        )

        XCTAssertEqual(plan, .none)
    }

    func testAgentDragDropPlannerBuildsCrossProjectMovePlan() {
        let source = AgentProject(name: "Source", path: "/tmp/source")
        let target = AgentProject(name: "Target", path: "/tmp/target")
        let mover = AgentChatSession(provider: .claude, projectID: source.id, title: "Mover")
        let targetSession = AgentChatSession(provider: .claude, projectID: target.id, title: "Target", sortIndex: 0)
        let workspace = AgentWorkspace(projects: [source, target], sessions: [mover, targetSession])

        let plan = AgentDragDropPlanner.sessionDropPlan(
            dropped: DraggableSession(sessionID: mover.id, sourceProjectID: source.id),
            targetProjectID: target.id,
            beforeSessionID: targetSession.id,
            workspace: workspace
        )

        XCTAssertEqual(plan, .move(sessionID: mover.id, newProjectID: target.id, targetIndex: 0))
    }

    func testAgentDragDropPlannerBuildsProjectReorderPlan() {
        let first = AgentProject(name: "First", path: "/tmp/first", sortIndex: 0)
        let second = AgentProject(name: "Second", path: "/tmp/second", sortIndex: 1)

        let plan = AgentDragDropPlanner.projectDropPlan(
            dropped: DraggableProject(projectID: second.id),
            beforeProjectID: first.id,
            visibleProjects: [first, second]
        )

        XCTAssertEqual(plan, .reorder(orderedIDs: [second.id, first.id]))
    }

    func testAgentDragDropPlannerBuildsProjectReorderPlanForUpperToLowerDrop() {
        let first = AgentProject(name: "First", path: "/tmp/first", sortIndex: 0)
        let second = AgentProject(name: "Second", path: "/tmp/second", sortIndex: 1)

        let plan = AgentDragDropPlanner.projectDropPlan(
            dropped: DraggableProject(projectID: first.id),
            beforeProjectID: second.id,
            visibleProjects: [first, second]
        )

        XCTAssertEqual(plan, .reorder(orderedIDs: [second.id, first.id]))
    }

    func testMoveSessionToProjectInsertsAtTargetIndex() throws {
        let url = makeTempStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AgentSessionStore(fileURL: url)
        let p1 = try store.upsertProject(path: NSTemporaryDirectory() + "move-p1", name: "A", createdManually: true)
        let p2 = try store.upsertProject(path: NSTemporaryDirectory() + "move-p2", name: "B", createdManually: true)
        let s1 = try store.createSession(provider: .claude, projectPath: p2.path, title: "T1")
        let s2 = try store.createSession(provider: .claude, projectPath: p2.path, title: "T2")
        let mover = try store.createSession(provider: .claude, projectPath: p1.path, title: "Mover")
        try store.reorderSessions(in: p2.id, orderedIDs: [s1.id, s2.id])

        // Mover von p1 nach p2 verschieben, an Position 1 (zwischen T1 und T2).
        try store.moveSessionToProject(sessionID: mover.id, newProjectID: p2.id, targetIndex: 1)

        let workspace = store.loadWorkspace()
        let p2Sessions = AgentSessionStore.sortedSessions(
            workspace.sessions.filter { $0.projectID == p2.id }
        )
        XCTAssertEqual(p2Sessions.map(\.id), [s1.id, mover.id, s2.id])

        let updatedMover = workspace.sessions.first { $0.id == mover.id }
        XCTAssertEqual(updatedMover?.projectID, p2.id)
    }

    func testSortedProjectsPrefersExplicitSortIndex() {
        let now = Date()
        let p1 = AgentProject(id: UUID(), name: "Latest", path: "/a", createdAt: now, updatedAt: now, sortIndex: nil)
        let p2 = AgentProject(id: UUID(), name: "Pinned", path: "/b", createdAt: now.addingTimeInterval(-1000), updatedAt: now.addingTimeInterval(-1000), sortIndex: 0)
        let sorted = AgentSessionStore.sortedProjects([p1, p2])
        // Explizit gesetzter sortIndex schlägt jüngeres updatedAt.
        XCTAssertEqual(sorted.first?.id, p2.id)
    }

    // MARK: - ThemeManager.resolve

    func testThemeResolveOverrideLightAlwaysReturnsLight() {
        XCTAssertEqual(
            ThemeManager.resolve(override: .light, systemAppearance: NSAppearance(named: .darkAqua)),
            .light
        )
        XCTAssertEqual(
            ThemeManager.resolve(override: .light, systemAppearance: NSAppearance(named: .aqua)),
            .light
        )
        XCTAssertEqual(
            ThemeManager.resolve(override: .light, systemAppearance: nil),
            .light
        )
    }

    func testThemeResolveOverrideDarkAlwaysReturnsDark() {
        XCTAssertEqual(
            ThemeManager.resolve(override: .dark, systemAppearance: NSAppearance(named: .aqua)),
            .dark
        )
        XCTAssertEqual(
            ThemeManager.resolve(override: .dark, systemAppearance: NSAppearance(named: .darkAqua)),
            .dark
        )
    }

    func testThemeResolveSystemFollowsAppearance() {
        XCTAssertEqual(
            ThemeManager.resolve(override: .system, systemAppearance: NSAppearance(named: .aqua)),
            .light
        )
        XCTAssertEqual(
            ThemeManager.resolve(override: .system, systemAppearance: NSAppearance(named: .darkAqua)),
            .dark
        )
    }

    func testThemeResolveSystemFallsBackToDarkWhenAppearanceUnknown() {
        XCTAssertEqual(
            ThemeManager.resolve(override: .system, systemAppearance: nil),
            .dark
        )
    }

    func testAppearanceOverridePreferredColorSchemeMapping() {
        XCTAssertNil(AppearanceOverride.system.preferredColorScheme)
        XCTAssertEqual(AppearanceOverride.light.preferredColorScheme, .light)
        XCTAssertEqual(AppearanceOverride.dark.preferredColorScheme, .dark)
    }

    func testClaudeThemeNameMapping() {
        // Beide Schemata → Claude's eigene Theme-Farben (`light` / `dark`),
        // NICHT die `*-ansi`-Varianten. `light-ansi` rendert UI-Chrome
        // (Input-Box, Status-Pills) mit ANSI-Indizes, die gegen den weißen
        // Background als schwarze Bänder erscheinen. `dark-ansi` führte
        // umgekehrt dazu, dass Highlights mit weißem ANSI-BG gegen den
        // weißen Default-Foreground unlesbar wurden.
        XCTAssertEqual(ClaudeThemeWriter.claudeThemeName(for: .light), "light")
        XCTAssertEqual(ClaudeThemeWriter.claudeThemeName(for: .dark), "dark")
    }

    // MARK: - Transcript readers

    func testClaudeTranscriptURLEncodesCWDWithDashes() {
        let url = ClaudeTranscriptReader.transcriptURL(
            forCwd: "/Users/foo/repos/whisperm8",
            sessionID: "abc-123"
        )
        XCTAssertTrue(url.path.hasSuffix("/.claude/projects/-Users-foo-repos-whisperm8/abc-123.jsonl"))
    }

    func testClaudeTranscriptReaderParsesUserAndAssistantEntries() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-claude-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let lines = [
            #"{"type":"user","timestamp":"2026-05-11T10:00:00Z","message":{"role":"user","content":"Hello Claude"}}"#,
            #"{"type":"queue-operation","timestamp":"2026-05-11T10:00:01Z","operation":"x","sessionId":"s"}"#,
            #"{"type":"assistant","timestamp":"2026-05-11T10:00:02Z","message":{"role":"assistant","content":[{"type":"text","text":"Hi there!"},{"type":"tool_use","name":"Bash","input":{"command":"ls"}}]}}"#,
            #"{"type":"user","timestamp":"2026-05-11T10:00:03Z","message":{"role":"user","content":[{"type":"tool_result","content":"file.txt","is_error":false}]}}"#
        ]
        try lines.joined(separator: "\n").write(to: tempURL, atomically: true, encoding: .utf8)

        let transcript = ClaudeTranscriptReader.read(fileURL: tempURL)
        XCTAssertEqual(transcript.messages.count, 3)
        XCTAssertEqual(transcript.messages[0].role, .user)
        if case .text(let t) = transcript.messages[0].blocks[0] {
            XCTAssertEqual(t, "Hello Claude")
        } else { XCTFail("Expected text block") }

        XCTAssertEqual(transcript.messages[1].role, .assistant)
        XCTAssertEqual(transcript.messages[1].blocks.count, 2)
        if case .toolUse(let name, let input) = transcript.messages[1].blocks[1] {
            XCTAssertEqual(name, "Bash")
            XCTAssertTrue(input.contains("ls"))
        } else { XCTFail("Expected toolUse block") }

        XCTAssertEqual(transcript.messages[2].role, .user)
        if case .toolResult(let content, let isError) = transcript.messages[2].blocks[0] {
            XCTAssertEqual(content, "file.txt")
            XCTAssertFalse(isError)
        } else { XCTFail("Expected toolResult block") }
    }

    func testClaudeTranscriptReaderSkipsCorruptedLines() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-claude-corrupt-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let content = """
        {"type":"user","timestamp":"2026-05-11T10:00:00Z","message":{"role":"user","content":"OK"}}
        not valid json line
        {"type":"assistant","timestamp":"2026-05-11T10:00:02Z","message":{"role":"assistant","content":[{"type":"text","text":"Response"}]}}
        """
        try content.write(to: tempURL, atomically: true, encoding: .utf8)

        let transcript = ClaudeTranscriptReader.read(fileURL: tempURL)
        // Korrupte Mittelzeile uebersprungen, andere zwei kamen durch.
        XCTAssertEqual(transcript.messages.count, 2)
    }

    func testClaudeTranscriptReaderHandlesImagePayload() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-claude-image-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let line = #"{"type":"user","timestamp":"2026-05-11T10:00:00Z","message":{"role":"user","content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"AAAA"}},{"type":"text","text":"look at this"}]}}"#
        try line.write(to: tempURL, atomically: true, encoding: .utf8)

        let transcript = ClaudeTranscriptReader.read(fileURL: tempURL)
        XCTAssertEqual(transcript.messages.count, 1)
        XCTAssertEqual(transcript.messages[0].blocks.count, 2)
        if case .imagePlaceholder(let mediaType, _) = transcript.messages[0].blocks[0] {
            XCTAssertEqual(mediaType, "image/png")
        } else { XCTFail("Expected imagePlaceholder block") }
    }

    func testCodexTranscriptReaderParsesUserAndAgentMessages() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-codex-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let lines = [
            #"{"timestamp":"2026-05-11T10:00:00Z","type":"event_msg","payload":{"type":"task_started","turn_id":"x"}}"#,
            #"{"timestamp":"2026-05-11T10:00:01Z","type":"event_msg","payload":{"type":"user_message","message":"Hi Codex"}}"#,
            #"{"timestamp":"2026-05-11T10:00:02Z","type":"response_item","payload":{"type":"function_call","name":"shell","arguments":"ls"}}"#,
            #"{"timestamp":"2026-05-11T10:00:03Z","type":"event_msg","payload":{"type":"agent_message","message":"Hello back"}}"#
        ]
        try lines.joined(separator: "\n").write(to: tempURL, atomically: true, encoding: .utf8)

        let transcript = CodexTranscriptReader.read(fileURL: tempURL)
        XCTAssertEqual(transcript.messages.count, 2)
        XCTAssertEqual(transcript.messages[0].role, .user)
        XCTAssertEqual(transcript.messages[1].role, .assistant)
        if case .text(let t) = transcript.messages[1].blocks[0] {
            XCTAssertEqual(t, "Hello back")
        } else { XCTFail("Expected assistant text block") }
    }

    // MARK: - Retention

    func testAgentSessionRetentionServicePrunesOrphanedFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperM8Retention-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let hookPaths = ClaudeHookPaths(rootDirectory: root)
        try FileManager.default.createDirectory(at: hookPaths.settingsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: hookPaths.eventsDirectory, withIntermediateDirectories: true)

        let live = UUID()
        let orphan = UUID()

        try Data().write(to: hookPaths.settingsFileURL(localSessionID: live))
        try Data().write(to: hookPaths.settingsFileURL(localSessionID: orphan))
        try Data().write(to: hookPaths.eventFileURL(localSessionID: live))
        try Data().write(to: hookPaths.eventFileURL(localSessionID: orphan))

        let service = AgentSessionRetentionService(hookPaths: hookPaths)
        let result = service.prune(liveLocalSessionIDs: [live])

        XCTAssertEqual(result.hookSettingsRemoved, 1)
        XCTAssertEqual(result.hookEventsRemoved, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: hookPaths.settingsFileURL(localSessionID: live).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: hookPaths.settingsFileURL(localSessionID: orphan).path))
    }

    // MARK: - AgentUIState

    func testAgentUIStateRoundTripsViaJSON() throws {
        let pid1 = UUID()
        let pid2 = UUID()
        let sid1 = UUID()
        let sid2 = UUID()
        let original = AgentUIState(
            schemaVersion: 1,
            openTabIDsByProject: [pid1: [sid1, sid2], pid2: [sid2]],
            selectedSessionIDByProject: [pid1: sid2],
            selectedProjectID: pid1,
            expandedProjectIDs: [pid1, pid2]
        )
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AgentUIState.self, from: encoded)
        XCTAssertEqual(decoded, original)
    }

    func testAgentUIStateLegacyJSONUsesDefaults() throws {
        // Pre-Schema-Version-File ohne explizite Felder — alle decodeIfPresent
        let json = "{}"
        let decoded = try JSONDecoder().decode(AgentUIState.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertTrue(decoded.openTabIDsByProject.isEmpty)
        XCTAssertTrue(decoded.selectedSessionIDByProject.isEmpty)
        XCTAssertNil(decoded.selectedProjectID)
        XCTAssertTrue(decoded.expandedProjectIDs.isEmpty)
    }

    func testAgentUIStatePrunesStaleProjectAndSessionIDs() {
        let livePID = UUID()
        let staleProjectID = UUID()
        let liveSID = UUID()
        let staleSID = UUID()

        let workspace = AgentWorkspace(
            projects: [
                AgentProject(id: livePID, name: "P", path: "/tmp/p")
            ],
            sessions: [
                AgentChatSession(id: liveSID, provider: .claude, projectID: livePID, title: "X")
            ]
        )

        var state = AgentUIState(
            openTabIDsByProject: [
                livePID: [liveSID, staleSID],
                staleProjectID: [staleSID]
            ],
            selectedSessionIDByProject: [
                livePID: staleSID,
                staleProjectID: liveSID
            ],
            selectedProjectID: staleProjectID,
            expandedProjectIDs: [livePID, staleProjectID]
        )
        state.prune(workspace: workspace)

        XCTAssertEqual(state.openTabIDsByProject[livePID], [liveSID])
        XCTAssertNil(state.openTabIDsByProject[staleProjectID])
        XCTAssertNil(state.selectedSessionIDByProject[livePID]) // staleSID war ausgewaehlt
        XCTAssertNil(state.selectedSessionIDByProject[staleProjectID])
        XCTAssertNil(state.selectedProjectID)
        XCTAssertEqual(state.expandedProjectIDs, [livePID])
    }

    func testAgentUIStateInitialMigrationFromWorkspacePopulatesOpenTabs() {
        let pid = UUID()
        let sidManual = UUID()
        let sidImported = UUID()
        let sidArchived = UUID()

        let workspace = AgentWorkspace(
            projects: [
                AgentProject(id: pid, name: "P", path: "/tmp/p")
            ],
            sessions: [
                AgentChatSession(id: sidManual, provider: .claude, projectID: pid, title: "Manual", createdManually: true),
                AgentChatSession(id: sidImported, provider: .claude, projectID: pid, title: "Imported", createdManually: nil),
                AgentChatSession(id: sidArchived, provider: .claude, projectID: pid, title: "Archived", status: .archived, createdManually: true)
            ]
        )

        let state = AgentUIState.initialMigration(from: workspace)
        XCTAssertEqual(state.openTabIDsByProject[pid], [sidManual])
        // Importierte (createdManually=nil) und archivierte werden nicht migriert
    }

    // MARK: - Claude Hook Bridge

    func testClaudeHookSettingsBuilderProducesValidJSON() throws {
        let data = try ClaudeHookSettingsBuilder.serializedSettings(eventFilePath: "/tmp/events.jsonl")
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(parsed?["hooks"])
        let hooks = parsed?["hooks"] as? [String: Any]
        // Alle vier getrackten Events muessen verdrahtet sein — sonst kriegt
        // die Bridge fuer Background-Agents kein "Needs input"-Signal.
        XCTAssertNotNil(hooks?["SessionStart"])
        XCTAssertNotNil(hooks?["SessionEnd"])
        XCTAssertNotNil(hooks?["PreToolUse"])
        XCTAssertNotNil(hooks?["Notification"])
        XCTAssertEqual(
            Set(ClaudeHookSettingsBuilder.trackedEventNames),
            ["SessionStart", "SessionEnd", "PreToolUse", "Notification"]
        )
    }

    func testClaudeHookSettingsBuilderUsesSameAppendCommandForAllEvents() throws {
        // Wir wollen sicherstellen, dass jede Event-Liste denselben
        // Append-Command nutzt — sonst landen Events in unterschiedlichen
        // Dateien und der DispatchSource-Reader sieht nur einen Teil.
        let data = try ClaudeHookSettingsBuilder.serializedSettings(eventFilePath: "/tmp/events.jsonl")
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let hooks = parsed?["hooks"] as? [String: Any] ?? [:]
        var commands: Set<String> = []
        for name in ClaudeHookSettingsBuilder.trackedEventNames {
            let entries = hooks[name] as? [[String: Any]] ?? []
            for entry in entries {
                let hookList = entry["hooks"] as? [[String: Any]] ?? []
                for hook in hookList {
                    if let cmd = hook["command"] as? String { commands.insert(cmd) }
                }
            }
        }
        XCTAssertEqual(commands.count, 1, "all events must share the same append command, got \(commands)")
    }

    func testClaudeHookSettingsBuilderEscapesQuotesInPath() {
        let cmd = ClaudeHookSettingsBuilder.appendCommand(eventFilePath: "/tmp/with\"quote.jsonl")
        XCTAssertTrue(cmd.contains("\\\"quote.jsonl"))
        // Wir wollen ausserdem die Datei in Double-Quotes haben.
        XCTAssertTrue(cmd.hasPrefix("(cat; echo) >> \""))
    }

    func testClaudeHookEventStoreParsesSessionStartLine() {
        let line = "{\"hook_event_name\":\"SessionStart\",\"session_id\":\"abc-123\",\"cwd\":\"/tmp/repo\",\"transcript_path\":\"/tmp/x.jsonl\"}"
        let event = ClaudeHookEventStore.parseLine(line)
        XCTAssertEqual(event?.hookEventName, .sessionStart)
        XCTAssertEqual(event?.sessionID, "abc-123")
        XCTAssertEqual(event?.cwd, "/tmp/repo")
    }

    func testClaudeHookEventStoreParsesSessionEndWithResumeReason() {
        let line = "{\"hook_event_name\":\"SessionEnd\",\"session_id\":\"old\",\"reason\":\"resume\"}"
        let event = ClaudeHookEventStore.parseLine(line)
        XCTAssertEqual(event?.hookEventName, .sessionEnd)
        XCTAssertEqual(event?.reason, "resume")
    }

    func testClaudeHookEventStoreParsesPreToolUseLine() {
        let line = "{\"hook_event_name\":\"PreToolUse\",\"session_id\":\"s1\"}"
        let event = ClaudeHookEventStore.parseLine(line)
        XCTAssertEqual(event?.hookEventName, .preToolUse)
        XCTAssertEqual(event?.sessionID, "s1")
    }

    func testClaudeHookEventStoreParsesNotificationLine() {
        let line = "{\"hook_event_name\":\"Notification\",\"session_id\":\"s1\"}"
        let event = ClaudeHookEventStore.parseLine(line)
        XCTAssertEqual(event?.hookEventName, .notification)
    }

    func testClaudeHookEventStoreIgnoresInvalidLine() {
        XCTAssertNil(ClaudeHookEventStore.parseLine("not json"))
        XCTAssertNil(ClaudeHookEventStore.parseLine(""))
    }

    func testClaudeHookEventStoreTailReadsIncrementally() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hook-tail-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ClaudeHookEventStore()

        let line1 = "{\"hook_event_name\":\"SessionStart\",\"session_id\":\"first\"}\n"
        try line1.write(to: url, atomically: true, encoding: .utf8)
        let events1 = store.readNewEvents(from: url)
        XCTAssertEqual(events1.count, 1)
        XCTAssertEqual(events1.first?.sessionID, "first")

        // Append zweite Zeile — nur die soll im naechsten Read sichtbar sein.
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        let line2 = "{\"hook_event_name\":\"SessionEnd\",\"session_id\":\"first\",\"reason\":\"resume\"}\n"
        handle.write(line2.data(using: .utf8)!)
        try handle.close()

        let events2 = store.readNewEvents(from: url)
        XCTAssertEqual(events2.count, 1)
        XCTAssertEqual(events2.first?.hookEventName, .sessionEnd)
        XCTAssertEqual(events2.first?.reason, "resume")
    }

    func testClaudeHookPathsAreUnderAppSupport() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WhisperM8HookPaths-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ClaudeHookPaths(rootDirectory: root)
        let id = UUID()
        XCTAssertTrue(paths.settingsFileURL(localSessionID: id).path.contains("claude-hooks"))
        XCTAssertTrue(paths.eventFileURL(localSessionID: id).path.contains("claude-session-events"))
        XCTAssertTrue(paths.settingsFileURL(localSessionID: id).lastPathComponent.hasPrefix(id.uuidString))
    }

    // MARK: - ClaudeActiveSessionResolver

    private func makeIndexedClaudeSession(
        id: String,
        cwd: String,
        lastActivityAt: Date,
        title: String = "Some Session"
    ) -> IndexedAgentSession {
        IndexedAgentSession(
            provider: .claude,
            externalSessionID: id,
            cwd: cwd,
            title: title,
            model: nil,
            reasoningEffort: nil,
            createdAt: lastActivityAt.addingTimeInterval(-3600),
            lastActivityAt: lastActivityAt
        )
    }

    func testClaudeActiveSessionResolverReturnsUnchangedWhenNoNewActivity() {
        let entry = ClaudeActiveSessionTrackerEntry(
            localSessionID: UUID(),
            projectCwd: "/tmp/repo",
            currentExternalID: "current",
            launchedAt: Date()
        )
        let indexed = [
            makeIndexedClaudeSession(id: "current", cwd: "/tmp/repo", lastActivityAt: Date()),
            // Andere Session liegt VOR Launch → kein Kandidat.
            makeIndexedClaudeSession(id: "older", cwd: "/tmp/repo", lastActivityAt: Date().addingTimeInterval(-600))
        ]
        let decision = ClaudeActiveSessionResolver.decide(entry: entry, indexedSessions: indexed)
        XCTAssertEqual(decision, .unchanged)
    }

    func testClaudeActiveSessionResolverRebindsOnSingleNewCandidate() {
        let launched = Date().addingTimeInterval(-30)
        let entry = ClaudeActiveSessionTrackerEntry(
            localSessionID: UUID(),
            projectCwd: "/tmp/repo",
            currentExternalID: "current",
            launchedAt: launched
        )
        let indexed = [
            makeIndexedClaudeSession(id: "current", cwd: "/tmp/repo", lastActivityAt: launched),
            makeIndexedClaudeSession(id: "new-one", cwd: "/tmp/repo", lastActivityAt: Date(), title: "Fresh Chat")
        ]
        let decision = ClaudeActiveSessionResolver.decide(entry: entry, indexedSessions: indexed)
        XCTAssertEqual(decision, .rebind(newExternalID: "new-one", title: "Fresh Chat"))
    }

    func testClaudeActiveSessionResolverIgnoresOtherProjects() {
        let launched = Date().addingTimeInterval(-30)
        let entry = ClaudeActiveSessionTrackerEntry(
            localSessionID: UUID(),
            projectCwd: "/tmp/repo",
            currentExternalID: "current",
            launchedAt: launched
        )
        let indexed = [
            makeIndexedClaudeSession(id: "current", cwd: "/tmp/repo", lastActivityAt: launched),
            // Andere CWD darf NIE als Kandidat zaehlen, selbst wenn frischer.
            makeIndexedClaudeSession(id: "wrong-repo", cwd: "/tmp/different", lastActivityAt: Date())
        ]
        let decision = ClaudeActiveSessionResolver.decide(entry: entry, indexedSessions: indexed)
        XCTAssertEqual(decision, .unchanged)
    }

    func testClaudeActiveSessionResolverReturnsAmbiguousOnCompetingCandidates() {
        let launched = Date().addingTimeInterval(-30)
        let entry = ClaudeActiveSessionTrackerEntry(
            localSessionID: UUID(),
            projectCwd: "/tmp/repo",
            currentExternalID: "current",
            launchedAt: launched
        )
        let now = Date()
        let indexed = [
            makeIndexedClaudeSession(id: "candidate-a", cwd: "/tmp/repo", lastActivityAt: now),
            // < 2s Differenz → ambiguous.
            makeIndexedClaudeSession(id: "candidate-b", cwd: "/tmp/repo", lastActivityAt: now.addingTimeInterval(-1))
        ]
        let decision = ClaudeActiveSessionResolver.decide(entry: entry, indexedSessions: indexed)
        if case .ambiguous(let candidates) = decision {
            XCTAssertEqual(candidates.count, 2)
            XCTAssertEqual(candidates.first?.externalSessionID, "candidate-a")
        } else {
            XCTFail("Expected .ambiguous, got \(decision)")
        }
    }

    func testClaudeActiveSessionResolverRebindsWhenLeaderDominatesByGap() {
        let launched = Date().addingTimeInterval(-30)
        let entry = ClaudeActiveSessionTrackerEntry(
            localSessionID: UUID(),
            projectCwd: "/tmp/repo",
            currentExternalID: "current",
            launchedAt: launched
        )
        let now = Date()
        let indexed = [
            makeIndexedClaudeSession(id: "leader", cwd: "/tmp/repo", lastActivityAt: now),
            // 5s zurueck → leader dominiert, automatischer Rebind erlaubt.
            makeIndexedClaudeSession(id: "stale", cwd: "/tmp/repo", lastActivityAt: now.addingTimeInterval(-5))
        ]
        let decision = ClaudeActiveSessionResolver.decide(entry: entry, indexedSessions: indexed)
        XCTAssertEqual(decision, .rebind(newExternalID: "leader", title: "Some Session"))
    }
}
