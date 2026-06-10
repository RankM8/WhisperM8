import Foundation
import XCTest
@testable import WhisperM8

final class AgentTranscriptStatusTests: XCTestCase {
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
}
