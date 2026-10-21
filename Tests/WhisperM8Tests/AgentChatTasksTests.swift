import Combine
import XCTest
@testable import WhisperM8

/// Tasks der Claude-Chats in der Notiz-Karte: Lesen der Task-Dateien, Links,
/// Ordner der Task-Liste (Hook `TaskCreated` bzw. Vermutung) und der Store.
final class AgentChatTasksTests: XCTestCase {
    private var temp: URL!

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-chat-tasks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temp)
    }

    private func json(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    private func write(_ object: [String: Any], to dir: URL, name: String) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try json(object).write(to: dir.appendingPathComponent(name))
    }

    // MARK: Parser

    func testParsesClaudesTaskFile() throws {
        let task = try XCTUnwrap(AgentChatTaskParser.parse(json([
            "id": "3", "subject": "Snapshots rendern", "description": "", "status": "in_progress",
            "activeForm": "Rendert die Snapshots", "owner": "snapshot-agent", "blocks": [], "blockedBy": ["2"],
        ])))
        XCTAssertEqual(task.status, .inProgress)
        XCTAssertEqual(task.activeForm, "Rendert die Snapshots")
        XCTAssertEqual(task.owner, "snapshot-agent")
        XCTAssertEqual(task.blockedBy, ["2"])
        XCTAssertNil(AgentChatTaskParser.parse(Data("{".utf8)))
        XCTAssertNil(AgentChatTaskParser.parse(json(["id": "9", "subject": "weg", "status": "deleted"])))
        XCTAssertNil(AgentChatTaskParser.parse(json(["id": "9", "subject": "", "status": "pending", "owner": ""]))?.owner)
    }

    func testLinksFromMetadataAndText() {
        let links = AgentChatTaskParser.links(
            subject: "Seite prüfen https://listm8.test/campaigns/3799/setup.",
            description: "Design: https://www.figma.com/file/abc, nochmal https://listm8.test/campaigns/3799/setup",
            metadata: ["links": [
                ["label": "App", "url": "http://localhost:3000"],
                "file:///Users/g/plan.md",
                ["title": "PR", "href": "https://github.com/x/y/pull/7"],
                ["label": "kaputt", "url": "javascript:alert(1)"],
            ]])
        XCTAssertEqual(links.map(\.label), ["App", "plan.md", "PR", "listm8.test", "figma.com"])
        XCTAssertEqual(links.first?.url, URL(string: "http://localhost:3000"))
        XCTAssertEqual(AgentChatTaskParser.links(subject: "", description: "", metadata: ["links": ["Site": "https://rankm8.de"]]).map(\.label), ["Site"])
    }

    func testSortsNumerically() {
        let tasks = ["10", "2", "1"].map {
            AgentChatTask(id: $0, subject: $0, activeForm: nil, status: .pending, owner: nil, blockedBy: [], links: [])
        }
        XCTAssertEqual(AgentChatTaskParser.sorted(tasks).map(\.id), ["1", "2", "10"])
    }

    // MARK: Ordner

    func testDirectoryFromTranscriptAndTeamName() {
        let transcript = URL(fileURLWithPath: "/Users/g/.claude-profiles/ai/projects/-Users-g-repo/abc.jsonl")
        let config = AgentChatTaskDirectory.configDir(forTranscript: transcript)
        XCTAssertEqual(config.path, "/Users/g/.claude-profiles/ai")
        XCTAssertEqual(AgentChatTaskDirectory.listDirectory(configDir: config, teamName: "session-412eed50").path,
                       "/Users/g/.claude-profiles/ai/tasks/session-412eed50")
        XCTAssertEqual(AgentChatTaskDirectory.sanitize("team a/b"), "team-a-b")
        XCTAssertEqual(AgentChatTaskDirectory.guessedDirectories(configDir: config, externalSessionID: "A96985F9-025E").first?.lastPathComponent,
                       "session-a96985f9")
    }

    func testReadsOnlyJSONFilesSorted() throws {
        let dir = temp.appendingPathComponent("tasks/session-1", isDirectory: true)
        try write(["id": "2", "subject": "B", "status": "pending"], to: dir, name: "2.json")
        try write(["id": "1", "subject": "A", "status": "completed"], to: dir, name: "1.json")
        try Data().write(to: dir.appendingPathComponent(".lock"))
        XCTAssertEqual(AgentChatTaskDirectory.readTasks(in: dir).map(\.id), ["1", "2"])
        XCTAssertEqual(AgentChatTaskDirectory.readTasks(in: temp.appendingPathComponent("fehlt")), [])
    }

    func testResolvePrefersLearnedThenExistingGuess() throws {
        let config = temp.appendingPathComponent("cfg", isDirectory: true)
        let transcript = config.appendingPathComponent("projects/-repo/abcdef12-0000.jsonl")
        let index = AgentChatTaskListIndex(fileURL: temp.appendingPathComponent("index.json"))
        let source = AgentChatTasksStore.Source(externalSessionID: "abcdef12-0000", cwd: "/repo")

        // Ohne Transcript kein Ordner.
        XCTAssertNil(AgentChatTasksStore.resolveDirectory(source: source, index: index, locate: { _ in nil }))
        // Vermutung, auch wenn der Ordner noch fehlt.
        XCTAssertEqual(AgentChatTasksStore.resolveDirectory(source: source, index: index, locate: { _ in transcript })?.lastPathComponent,
                       "session-abcdef12")
        // Gelernt aus dem Hook: gewinnt und überlebt einen neuen Index (Datei).
        let learned = config.appendingPathComponent("tasks/session-412eed50", isDirectory: true)
        index.remember(learned, forExternalID: "abcdef12-0000")
        let reloaded = AgentChatTaskListIndex(fileURL: temp.appendingPathComponent("index.json"))
        XCTAssertEqual(AgentChatTasksStore.resolveDirectory(source: source, index: reloaded, locate: { _ in transcript }), learned)
    }

    func testAffectedSessionsMatchesDirectoryAndFilesInside() {
        let a = UUID(), b = UUID()
        let dirs = [a: temp.appendingPathComponent("tasks/session-a"), b: temp.appendingPathComponent("tasks/session-b")]
        let real = temp.resolvingSymlinksInPath().path
        let hit = AgentChatTasksStore.affectedSessions(paths: ["\(real)/tasks/session-a/3.json"], directories: dirs)
        XCTAssertEqual(hit, [a])
        XCTAssertEqual(AgentChatTasksStore.affectedSessions(paths: ["\(real)/tasks/session-ab/1.json"], directories: dirs), [])
    }

    // MARK: Hook und Sichtbarkeit

    func testHookEventCarriesTeamName() throws {
        let line = #"{"hook_event_name":"TaskCreated","session_id":"s1","transcript_path":"/c/projects/p/s1.jsonl","team_name":"session-412eed50","task_id":"1","task_subject":"A"}"#
        let event = try XCTUnwrap(ClaudeHookEventStore.parseLine(line))
        XCTAssertEqual(event.hookEventName, .taskCreated)
        XCTAssertTrue(event.hookEventName.isTaskEvent)
        XCTAssertEqual(event.teamName, "session-412eed50")
        XCTAssertNil(AgentSessionSignal(hookEvent: event), "Task-Hooks sind kein Status-Signal")
    }

    func testCardOnlyForNoteOrOpenTasks() {
        let done = AgentChatTask(id: "1", subject: "A", activeForm: nil, status: .completed, owner: nil, blockedBy: [], links: [])
        let open = AgentChatTask(id: "2", subject: "B", activeForm: nil, status: .pending, owner: nil, blockedBy: [], links: [])
        XCTAssertFalse(JarvisNoteContent.exists(note: nil, tasks: []))
        XCTAssertFalse(JarvisNoteContent.exists(note: nil, tasks: [done]), "lauter erledigte: keine Karte")
        XCTAssertTrue(JarvisNoteContent.exists(note: nil, tasks: [done, open]))
    }

    @MainActor
    func testStoreLearnsDirectoryFromHookAndPublishes() throws {
        let config = temp.appendingPathComponent("cfg", isDirectory: true)
        let transcript = config.appendingPathComponent("projects/-repo/s1.jsonl")
        let learned = config.appendingPathComponent("tasks/session-412eed50", isDirectory: true)
        try write(["id": "1", "subject": "Doku", "status": "in_progress", "activeForm": "Schreibt"], to: learned, name: "1.json")
        let store = AgentChatTasksStore(
            index: AgentChatTaskListIndex(fileURL: temp.appendingPathComponent("index.json")),
            isEnabled: { true },
            locateTranscript: { _ in transcript },
            watchesFileSystem: false)
        let sessionID = UUID()
        var received: [[AgentChatTask]] = []
        let cancellable = store.tasksPublisher(for: sessionID, source: .init(externalSessionID: "s1", cwd: "/repo"))
            .sink { received.append($0) }
        defer { cancellable.cancel() }

        // Vermutung `session-s1` gibt es nicht: noch keine Tasks.
        let guessed = expectation(description: "Vermutung gelesen")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { guessed.fulfill() }
        wait(for: [guessed], timeout: 2)
        XCTAssertEqual(store.tasks[sessionID] ?? [], [])

        var event = try XCTUnwrap(ClaudeHookEventStore.parseLine(
            #"{"hook_event_name":"TaskCreated","session_id":"s1","team_name":"session-412eed50","transcript_path":"\#(transcript.path)"}"#))
        event.transcriptPath = transcript.path
        store.handleHookEvent(localSessionID: sessionID, event: event)
        let loaded = expectation(description: "Hook-Ordner gelesen")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { loaded.fulfill() }
        wait(for: [loaded], timeout: 2)
        XCTAssertEqual(store.tasks[sessionID]?.map(\.subject), ["Doku"])
        XCTAssertEqual(received.last?.first?.activeForm, "Schreibt")
    }

    func testKillSwitchDefaultsOn() {
        let defaults = UserDefaults(suiteName: "agent-chat-tasks-\(UUID().uuidString)")!
        XCTAssertTrue(AppPreferences(defaults: defaults).isAgentChatTasksInNotesEnabled)
    }
}
