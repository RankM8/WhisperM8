import XCTest
@testable import WhisperM8

@MainActor
final class AgentPromptRoutingServiceTests: XCTestCase {
    // MARK: - promptText (pure)

    func testReportPromptTextContainsAllSections() throws {
        let report = try XCTUnwrap(AgentReport.parse(lastMessage: """
        {"status":"partial","summary":"Fast fertig.","filesChanged":["a.swift"],
         "commits":[{"sha":"abc1234","message":"feat: x"}],
         "testsRun":{"command":"swift test","passed":false},
         "openQuestions":["Edge-Case Y?"]}
        """))
        let text = report.promptText(shortId: "a3f81c2e")
        XCTAssertTrue(text.contains("Subagent-Report a3f81c2e"))
        XCTAssertTrue(text.contains("partial"))
        XCTAssertTrue(text.contains("a.swift"))
        XCTAssertTrue(text.contains("abc1234"))
        XCTAssertTrue(text.contains("FAILED"))
        XCTAssertTrue(text.contains("Edge-Case Y?"))
    }

    // MARK: - route: Ziel-PTY läuft schon

    func testRouteInjectsImmediatelyWhenControllerIsRunning() {
        let sessionID = UUID()
        let controller = FakeTerminal(running: true, started: true)

        var focused: [UUID] = []
        var sent: [String] = []
        let service = AgentPromptRoutingService(
            controllerResolver: { _ in controller },
            focusRequester: { focused.append($0) },
            sessionStarter: { _ in XCTFail("Start nicht nötig — PTY läuft") },
            textSender: { _, text in sent.append(text) },
            schedule: { _, _ in XCTFail("Kein Staging nötig") }
        )

        service.route(text: "der Report", toLocalSessionID: sessionID)

        XCTAssertEqual(focused, [sessionID])
        XCTAssertEqual(sent, ["der Report"])
    }

    // MARK: - route: Kaltstart mit Staging

    func testRouteStagesSendUntilControllerStarts() {
        let sessionID = UUID()
        let controller = FakeTerminal(running: false, started: false)

        var started: [UUID] = []
        var sent: [String] = []
        // Synchroner Fake-Scheduler: führt geplante Arbeit sofort aus und
        // lässt den Controller nach 2 "Ticks" hochkommen.
        var tick = 0
        var scheduledWork: [@MainActor () -> Void] = []
        let service = AgentPromptRoutingService(
            controllerResolver: { _ in controller },
            focusRequester: { _ in },
            sessionStarter: { started.append($0) },
            textSender: { _, text in sent.append(text) },
            schedule: { _, work in
                tick += 1
                if tick == 3 {
                    controller.isRunning = true
                    controller.hasStarted = true
                }
                scheduledWork.append(work)
            }
        )

        service.route(text: "später", toLocalSessionID: sessionID)
        // Geplante Arbeit sequenziell abspulen (max. Sicherheitsgrenze).
        var safety = 0
        while !scheduledWork.isEmpty, safety < 30 {
            let work = scheduledWork.removeFirst()
            work()
            safety += 1
        }

        XCTAssertEqual(started, [sessionID])
        XCTAssertEqual(sent, ["später"])
    }

    func testRouteGivesUpAfterMaxAttempts() {
        let sessionID = UUID()
        var sent: [String] = []
        var scheduledWork: [@MainActor () -> Void] = []
        let service = AgentPromptRoutingService(
            controllerResolver: { _ in nil }, // Controller kommt nie
            focusRequester: { _ in },
            sessionStarter: { _ in },
            textSender: { _, text in sent.append(text) },
            schedule: { _, work in scheduledWork.append(work) }
        )

        service.route(text: "verloren", toLocalSessionID: sessionID, maxAttempts: 3)
        var safety = 0
        while !scheduledWork.isEmpty, safety < 30 {
            scheduledWork.removeFirst()()
            safety += 1
        }

        XCTAssertTrue(sent.isEmpty)
        XCTAssertLessThanOrEqual(safety, 3)
    }

}

// MARK: - Fake

@MainActor
private final class FakeTerminal: PromptRoutableTerminal {
    var isRunning: Bool
    var hasStarted: Bool
    private(set) var sentTexts: [String] = []

    init(running: Bool, started: Bool) {
        self.isRunning = running
        self.hasStarted = started
    }

    func sendUserText(_ text: String) {
        sentTexts.append(text)
    }
}
