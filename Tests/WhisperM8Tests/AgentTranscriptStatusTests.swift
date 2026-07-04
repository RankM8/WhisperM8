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
        XCTAssertEqual(decision?.status, .working)
        XCTAssertEqual(decision?.turnFinished, false)
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
        XCTAssertEqual(decision?.status, .idle)
        XCTAssertEqual(decision?.turnFinished, true, "Erstes Stop-Event muss als turnFinished melden")
    }

    func testStatusDeciderTreatsToolUseStopAsWorkingNotTurnFinished() {
        // Regression: Während ein langlaufendes Bash-/Tool-Kommando läuft, ist
        // die letzte JSONL-Zeile die Assistant-Message mit stop_reason
        // "tool_use". Diese darf NICHT als Turn-Ende gelten — sonst feuert die
        // „Agent fertig"-Notification, während der Chat noch arbeitet
        // („Whirlpooling…").
        let now = Date()
        let event: AgentTranscriptEvent = .assistantMessageStopped(timestamp: now, stopReason: "tool_use")
        let decision = AgentTranscriptStatusDecider.decide(
            lastEvent: event,
            fileMTime: now,
            now: now,
            priorTurnFinishedAt: nil
        )
        XCTAssertEqual(decision?.status, .working, "tool_use bedeutet: Agent arbeitet weiter")
        XCTAssertEqual(decision?.turnFinished, false, "tool_use darf kein Turn-Ende melden")
    }

    func testStatusDeciderTreatsPauseTurnStopAsWorking() {
        let now = Date()
        let event: AgentTranscriptEvent = .assistantMessageStopped(timestamp: now, stopReason: "pause_turn")
        let decision = AgentTranscriptStatusDecider.decide(
            lastEvent: event,
            fileMTime: now,
            now: now,
            priorTurnFinishedAt: nil
        )
        XCTAssertEqual(decision?.status, .working)
        XCTAssertEqual(decision?.turnFinished, false)
    }

    func testStatusDeciderStillFinishesTurnForRealEndReasons() {
        // Echte Turn-Enden bleiben unangetastet.
        for reason in ["end_turn", "stop_sequence", "max_tokens"] {
            let now = Date()
            let stopped = now.addingTimeInterval(-1)
            let event: AgentTranscriptEvent = .assistantMessageStopped(timestamp: stopped, stopReason: reason)
            let decision = AgentTranscriptStatusDecider.decide(
                lastEvent: event,
                fileMTime: stopped,
                now: now,
                priorTurnFinishedAt: nil
            )
            XCTAssertEqual(decision?.status, .idle, "\(reason) ist ein echtes Turn-Ende")
            XCTAssertEqual(decision?.turnFinished, true, "\(reason) muss turnFinished melden")
        }
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
        XCTAssertEqual(decision?.status, .idle)
        XCTAssertEqual(decision?.turnFinished, false, "Älteres oder gleiches Stop-Event darf nicht als neuer Turn melden")
    }

    func testStatusDeciderTreatsLongRunningOngoingAsWorking() {
        // Langer Tool-/Reasoning-Schritt schreibt nichts ins JSONL → bleibt
        // innerhalb des Stall-Fensters „arbeitet". awaitingInput kommt nur
        // noch vom Hook, nicht mehr aus einer Stille-Heuristik (die langes
        // Arbeiten mit Permission-Warten verwechselte).
        let now = Date()
        let event: AgentTranscriptEvent = .assistantMessageOngoing(timestamp: now)
        let mtime = now.addingTimeInterval(-AgentTranscriptStatusDecider.workingStallSeconds)
        let decision = AgentTranscriptStatusDecider.decide(
            lastEvent: event,
            fileMTime: mtime,
            now: now,
            priorTurnFinishedAt: nil
        )
        XCTAssertEqual(decision?.status, .working)
    }

    func testStatusDeciderDowngradesStalledActivityToIdle() {
        // Sicherheitsnetz: „Aktivität", deren Datei seit über
        // `workingStallSeconds` unangetastet ist, ist keine Arbeit mehr —
        // typisch nach Interrupt ohne Marker-Zeile, Netz-/API-Abbruch oder
        // Crash. Ohne dieses Netz pulsierte der Chat für immer grün.
        let now = Date()
        let staleMTime = now.addingTimeInterval(-(AgentTranscriptStatusDecider.workingStallSeconds + 1))
        let staleEvents: [AgentTranscriptEvent] = [
            .userMessage(timestamp: staleMTime),
            .toolResult(timestamp: staleMTime),
            .assistantMessageOngoing(timestamp: staleMTime),
            .assistantMessageStopped(timestamp: staleMTime, stopReason: "tool_use")
        ]
        for event in staleEvents {
            let decision = AgentTranscriptStatusDecider.decide(
                lastEvent: event,
                fileMTime: staleMTime,
                now: now,
                priorTurnFinishedAt: nil
            )
            XCTAssertEqual(decision?.status, .idle, "\(event) muss nach Stall-Fenster idle melden")
            XCTAssertEqual(decision?.turnFinished, false, "Stall ist kein Turn-Ende — keine Notification")
        }
    }

    func testTranscriptParserSkipsMetaLinesInTailScan() {
        // Claude schreibt nach der semantischen Zeile häufig Meta-Zeilen
        // (mode/last-prompt/queue-operation/attachment/…). Die dürfen den
        // Status nicht bestimmen — der Scan muss rückwärts bis zur letzten
        // semantischen Zeile laufen (hier: assistant mit tool_use = arbeitet).
        let tail = #"{"type":"assistant","message":{"stop_reason":"tool_use","content":[]}}"# + "\n"
            + #"{"type":"queue-operation","operation":"dequeue"}"# + "\n"
            + #"{"type":"mode","mode":"default","sessionId":"abc"}"# + "\n"
            + #"{"type":"last-prompt","prompt":"x"}"# + "\n"
            + #"{"type":"attachment","attachment":{}}"# + "\n"
        let event = AgentTranscriptParser.lastEvent(in: tail, provider: .claude)
        guard case .assistantMessageStopped(_, let reason) = event else {
            return XCTFail("Erwartete die assistant-Zeile hinter den Meta-Zeilen, bekam \(String(describing: event))")
        }
        XCTAssertEqual(reason, "tool_use")
    }

    func testTranscriptParserReturnsNilForMetaOnlyTail() {
        // Nur Meta im Tail → keine Meinung (nil), statt über die
        // mtime-Heuristik einen Status zu raten.
        let tail = #"{"type":"mode","mode":"default"}"# + "\n"
            + #"{"type":"summary","summary":"t"}"# + "\n"
            + #"{"type":"system","content":"x"}"# + "\n"
        XCTAssertNil(AgentTranscriptParser.lastEvent(in: tail, provider: .claude))
    }

    func testTranscriptParserDetectsUserInterrupt() {
        // ESC-Abbruch: Claude schreibt eine user-Zeile mit dem
        // Interrupt-Marker. Sie ist das GEGENTEIL eines Turn-Starts.
        let line = #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]}}"#
        guard case .turnInterrupted = AgentTranscriptParser.parseLine(line, provider: .claude) else {
            return XCTFail("Interrupt-Marker muss .turnInterrupted liefern")
        }

        let toolVariant = #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]}}"#
        guard case .turnInterrupted = AgentTranscriptParser.parseLine(toolVariant, provider: .claude) else {
            return XCTFail("Tool-Use-Variante des Markers muss .turnInterrupted liefern")
        }

        let stringVariant = #"{"type":"user","message":{"role":"user","content":"[Request interrupted by user]"}}"#
        guard case .turnInterrupted = AgentTranscriptParser.parseLine(stringVariant, provider: .claude) else {
            return XCTFail("String-Content-Variante muss .turnInterrupted liefern")
        }
    }

    func testStatusDeciderReportsAbortForInterrupt() {
        let now = Date()
        let decision = AgentTranscriptStatusDecider.decide(
            lastEvent: .turnInterrupted(timestamp: now),
            fileMTime: now,
            now: now,
            priorTurnFinishedAt: nil
        )
        XCTAssertEqual(decision?.status, .idle)
        XCTAssertEqual(decision?.turnAborted, true)
        XCTAssertEqual(decision?.turnFinished, false, "Abbruch darf kein Auto-Naming/Notification triggern")
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
        XCTAssertEqual(decision?.status, .working)
    }

    func testStatusDeciderHasNoOpinionOnEmptyTranscript() {
        // Frisch gestartete Session: Datei noch leer / unparseable → KEINE
        // Meinung. Der frühere `.working`-Default ließ neue Chats ohne
        // Prompt dauerhaft als „arbeitet" pulsieren.
        let decision = AgentTranscriptStatusDecider.decide(
            lastEvent: nil,
            fileMTime: Date(),
            now: Date(),
            priorTurnFinishedAt: nil
        )
        XCTAssertNil(decision)
    }
}
