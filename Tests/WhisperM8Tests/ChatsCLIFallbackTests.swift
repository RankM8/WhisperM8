import XCTest
@testable import WhisperM8

/// WM8-85, Paket 1: die CLI als gehärteter Rückfall. Dazu WM8-71 (Alter der
/// wartenden Meldungen) und WM8-47 (Steuerzeichen in Terminal-Tabs).
final class ChatsCLIFallbackTests: XCTestCase {
    // MARK: Offene Rückfrage (WM8-71, Nachtrag)

    func testAnOpenQuestionIsNotAnsweredWithoutAskingForIt() {
        let message = AgentControlRequestHandler.statusConflictMessage(.awaitingInput, allowed: ["idle"])
        XCTAssertTrue(message.contains("--answer"), message)
        XCTAssertTrue(message.contains("nicht von sich aus"), message)
        XCTAssertEqual(AgentControlRequestHandler.statusConflictMessage(.working, allowed: ["idle"]),
                       "Ziel ist working (erlaubt: idle)")
    }

    // MARK: Terminal-Tabs (WM8-47)

    func testShellWithoutPasteModeGetsTheTextAsTyped() {
        let payload = TerminalPasteSanitizer.payload("soak-probe-1", profile: .plainShell, bracketedPasteMode: false)
        XCTAssertEqual(payload, "soak-probe-1")
        XCTAssertFalse(payload.contains("\u{1B}"))
        XCTAssertEqual(TerminalPasteSanitizer.payload("a\u{1B}[31mb\nc\u{07}", profile: .plainShell,
                                                      bracketedPasteMode: false), "ab\rc",
                       "Steuerzeichen raus, Zeilenumbruch wie ein getipptes Enter")
    }

    func testShellThatAskedForPasteModeAndTheAgentsKeepTheBrackets() {
        XCTAssertEqual(TerminalPasteSanitizer.payload("x", profile: .plainShell, bracketedPasteMode: true),
                       "\u{1B}[200~x\u{1B}[201~", "zsh schaltet den Modus selbst ein")
        for profile in [TerminalKeyboardProfile.claudeCodeChat, .codexChat] {
            XCTAssertEqual(TerminalPasteSanitizer.payload("a\nb", profile: profile, bracketedPasteMode: false),
                           "\u{1B}[200~a\nb\u{1B}[201~", "Claude und Codex immer verpackt, auch in der Startphase")
        }
    }

    // MARK: Postfach des Supervisors (WM8-71)

    private func prompt(_ session: UUID, at seconds: TimeInterval, state: QueuedPrompt.State = .pending) -> QueuedPrompt {
        QueuedPrompt(sessionID: session, prompt: "Meldung", enqueuedAt: Date(timeIntervalSince1970: seconds),
                     enqueuedBy: "whisperm8/Gus", state: state)
    }

    func testInboxCountsOnlyWaitingMessagesAndKnowsTheOldest() {
        let jarvis = UUID(), other = UUID()
        let all = [
            prompt(jarvis, at: 1_000), prompt(jarvis, at: 400), prompt(jarvis, at: 100, state: .delivered),
            prompt(other, at: 50),
        ]
        let inbox = AgentPromptQueueLogic.inbox(for: jarvis, in: all)
        XCTAssertEqual(inbox.open, 2)
        XCTAssertEqual(inbox.oldest, Date(timeIntervalSince1970: 400))
        XCTAssertEqual(AgentPromptQueueLogic.oldestOpen(in: all)[other], Date(timeIntervalSince1970: 50))
        XCTAssertEqual(AgentPromptQueueLogic.inbox(for: UUID(), in: all).open, 0)
    }

    func testInboxLine() {
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertNil(AgentPromptQueueLogic.inboxLine(open: 0, oldest: nil, now: now))
        let two = AgentPromptQueueLogic.inboxLine(open: 2, oldest: now.addingTimeInterval(-720), now: now) ?? ""
        XCTAssertTrue(two.hasPrefix("2 Meldungen warten, älteste seit "), two)
        let one = AgentPromptQueueLogic.inboxLine(open: 1, oldest: now.addingTimeInterval(-60), now: now) ?? ""
        XCTAssertTrue(one.hasPrefix("1 Meldung wartet, seit "), one)
    }

    func testSnapshotCarriesTheAgeOfTheOldestWaitingMessage() {
        let session = ChatsSnapshotSession(
            ref: "a1b2c3d4", name: "whisperm8/Jarvis", bucket: .working,
            axes: ChatsSessionAxes(
                catalog: .active,
                execution: ChatsExecutionAxis(mode: .foreground, worker: .alive, attachment: .detached),
                conversation: ChatsConversationAxis(state: .working, reason: nil, sinceSec: nil),
                evidence: ChatsEvidenceAxis(quality: .observed, source: "app", ageMs: 0)),
            queued: 2, actions: [], excerpt: nil, doneSec: nil,
            queuedOldestSec: 720)
        XCTAssertEqual(session.json["queuedOldestSec"] as? Int, 720)
        XCTAssertEqual(session.json["queued"] as? Int, 2)
    }
}
