import Foundation
import XCTest
@testable import WhisperM8

/// WM8-60: je Chat anzeigen, ob er im Hauptordner oder in einer Arbeitskopie
/// arbeitet und auf welchem Branch.
final class AgentWorkingCopyTests: XCTestCase {
    private let project = "/Users/demo/repos/whisperm8"

    // MARK: - Einordnung

    func testMainFolderAndItsSubfolders() {
        for cwd in [project, project + "/", project + "/WhisperM8/Views"] {
            let copy = AgentWorkingCopyClassifier.classify(cwd: cwd, projectPath: project, branch: "main")
            XCTAssertEqual(copy.kind, .mainFolder, cwd)
            XCTAssertNil(copy.name)
            XCTAssertEqual(copy.branch, "main")
        }
    }

    func testClaudeWorktreeAndItsSubfolders() {
        let base = project + "/.claude/worktrees/bindung-fremdes-transcript"
        for cwd in [base, base + "/Tests/WhisperM8Tests"] {
            let copy = AgentWorkingCopyClassifier.classify(cwd: cwd, projectPath: project, branch: "feat/x")
            XCTAssertEqual(copy.kind, .worktree, cwd)
            XCTAssertEqual(copy.name, "bindung-fremdes-transcript")
            XCTAssertEqual(copy.branch, "feat/x")
        }
    }

    func testOtherFolder() {
        let copy = AgentWorkingCopyClassifier.classify(cwd: "/tmp/skizze", projectPath: project, branch: nil)
        XCTAssertEqual(copy.kind, .otherFolder)
        XCTAssertEqual(copy.name, "skizze")
        // Ein Nachbarordner mit gleichem Präfix ist kein Unterordner.
        XCTAssertEqual(AgentWorkingCopyClassifier.classify(
            cwd: project + "-feature", projectPath: project, branch: nil).kind, .otherFolder)
    }

    func testPrivateTmpCountsAsTmpAndDetachedHeadHasNoBranch() {
        let copy = AgentWorkingCopyClassifier.classify(cwd: "/private/tmp/p/sub", projectPath: "/tmp/p", branch: "HEAD")
        XCTAssertEqual(copy.kind, .mainFolder)
        XCTAssertNil(copy.branch)
        XCTAssertNil(AgentWorkingCopyClassifier.classify(cwd: project, projectPath: project, branch: "").branch)
    }

    // MARK: - Ableitung aus dem Verlauf

    func testClaudeUsesTheLastLineWithAFolder() {
        let tail = [
            #"{"type":"user","cwd":"\#(project)","gitBranch":"main","message":{"content":"a"}}"#,
            #"{"type":"assistant","cwd":"\#(project)/.claude/worktrees/wt","gitBranch":"feat/y","message":{}}"#,
            // Zeilen ohne Ordner (Claudes Meta-Zeilen) zählen nicht.
            #"{"type":"mode","mode":"default"}"#,
            #"{"type":"atis-latch","sessionId":"s"}"#,
        ].joined(separator: "\n")
        XCTAssertEqual(AgentWorkingLocationExtractor.location(in: tail, provider: .claude),
                       AgentWorkingLocation(cwd: project + "/.claude/worktrees/wt", branch: "feat/y"))
    }

    func testClaudeIgnoresAFolderMentionedInsideText() {
        // Ein Tool-Ergebnis, das von „cwd“ spricht, ist escaped und kein Feld.
        let tail = [
            #"{"type":"user","cwd":"/a","gitBranch":"main"}"#,
            #"{"type":"user","message":{"content":"{\"cwd\":\"/falsch\"}"}}"#,
        ].joined(separator: "\n")
        XCTAssertEqual(AgentWorkingLocationExtractor.location(in: tail, provider: .claude)?.cwd, "/a")
    }

    func testCodexUsesTurnContextAndSessionMeta() {
        let meta = #"{"type":"session_meta","payload":{"cwd":"/r","git":{"branch":"main","commit_hash":"abc"}}}"#
        let turn = #"{"type":"turn_context","payload":{"turn_id":"t","cwd":"/r/.claude/worktrees/w"}}"#
        let item = #"{"type":"response_item","payload":{"type":"reasoning","id":"rs"}}"#
        XCTAssertEqual(AgentWorkingLocationExtractor.location(in: [meta, turn, item].joined(separator: "\n"), provider: .codex),
                       AgentWorkingLocation(cwd: "/r/.claude/worktrees/w", branch: nil))
        XCTAssertEqual(AgentWorkingLocationExtractor.location(in: [meta, item].joined(separator: "\n"), provider: .codex),
                       AgentWorkingLocation(cwd: "/r", branch: "main"))
        XCTAssertNil(AgentWorkingLocationExtractor.location(in: item, provider: .codex))
    }

    func testWatcherKeepsTheLastKnownLocationWhenTheTailHasNone() {
        let previous = AgentWorkingLocation(cwd: "/a", branch: "main")
        XCTAssertEqual(AgentSessionRuntimeWatcher.workingLocation(
            in: #"{"type":"mode"}"#, provider: .claude, previous: previous), previous)
    }

    func testPollSnapshotCarriesTheLocation() {
        let url = URL(fileURLWithPath: "/tmp/whisperm8-wm8-60.jsonl")
        let tail = #"{"type":"user","cwd":"/a/.claude/worktrees/w","gitBranch":"feat/z"}"#
        var entry = WatchedSession(id: UUID(), provider: .claude, cwd: "/a", externalSessionID: "x",
                                   transcriptURL: url, lastTurnFinishedAt: nil)
        let stat = AgentTranscriptFileStat(mtime: Date(), size: 10)
        let read = AgentSessionRuntimeWatcher.pollSnapshot(
            for: entry, now: Date(), statProvider: { _ in stat }, tailProvider: { _, _ in tail }, urlResolver: { _ in url })
        XCTAssertEqual(read.location, AgentWorkingLocation(cwd: "/a/.claude/worktrees/w", branch: "feat/z"))
        // Stat-first: unveränderte Datei → gecachter Ort, kein Tail-Read.
        entry.lastStat = stat
        entry.cachedLocation = read.location
        let cached = AgentSessionRuntimeWatcher.pollSnapshot(
            for: entry, now: Date(), statProvider: { _ in stat },
            tailProvider: { _, _ in XCTFail("kein Tail-Read"); return nil }, urlResolver: { _ in url })
        XCTAssertEqual(cached.location, read.location)
    }

    // MARK: - Branch aus .git/HEAD (Codex)

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wm8-60-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testGitHeadOfAMainCheckoutAndItsSubfolder() throws {
        let repo = try tempDir()
        let git = repo.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        try "ref: refs/heads/feat/WM8-60\n".write(to: git.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        let sub = repo.appendingPathComponent("a/b")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        XCTAssertEqual(GitHeadReader.branch(at: repo.path), "feat/WM8-60")
        XCTAssertEqual(GitHeadReader.branch(at: sub.path), "feat/WM8-60")
    }

    func testGitHeadOfAWorktreeFollowsTheGitdirFile() throws {
        let root = try tempDir()
        let gitDir = root.appendingPathComponent("main/.git/worktrees/wt")
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        try "ref: refs/heads/fix/x\n".write(to: gitDir.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        let worktree = root.appendingPathComponent("wt")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try "gitdir: ../main/.git/worktrees/wt\n".write(
            to: worktree.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        XCTAssertEqual(GitHeadReader.branch(at: worktree.path), "fix/x")
    }

    func testDetachedHeadAndNoRepository() throws {
        XCTAssertNil(GitHeadReader.branch(fromHead: "3f2a9c0d1e\n"))
        XCTAssertEqual(GitHeadReader.branch(fromHead: "ref: refs/heads/main"), "main")
        XCTAssertNil(GitHeadReader.branch(at: try tempDir().path))
    }

    // MARK: - Speichern

    func testStoreWritesOnlyOnChangeAndKeepsTheActivityTime() throws {
        let dir = try tempDir()
        let store = AgentSessionStore(fileURL: dir.appendingPathComponent("ws.json"),
                                      uiStateFileURL: dir.appendingPathComponent("ui.json"))
        let created = try store.createSession(provider: .claude, projectPath: dir.path, title: "t",
                                              model: "m", reasoningEffort: "medium")
        let before = try XCTUnwrap(store.loadWorkspace().sessions.first { $0.id == created.id })
        let copy = AgentWorkingCopy(kind: .worktree, path: dir.path + "/.claude/worktrees/w", name: "w", branch: "b")
        try store.setWorkingCopy(copy, for: created.id)
        let after = try XCTUnwrap(store.loadWorkspace().sessions.first { $0.id == created.id })
        XCTAssertEqual(after.workingCopy, copy)
        XCTAssertEqual(after.lastActivityAt, before.lastActivityAt, "Ortswechsel darf die Sortierung nicht verschieben")
    }

    func testDecodingIsLenientAndRoundTrips() throws {
        var session = AgentChatSession(provider: .codex, projectID: UUID(), title: "t")
        session.workingCopy = AgentWorkingCopy(kind: .mainFolder, path: "/a", name: nil, branch: "main")
        let data = try JSONEncoder().encode(session)
        XCTAssertEqual(try JSONDecoder().decode(AgentChatSession.self, from: data).workingCopy, session.workingCopy)

        // Unbekannte Art einer neueren Version: Feld fällt weg, Chat bleibt.
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["workingCopy"] = ["kind": "kuenftig", "path": "/a"]
        let decoded = try JSONDecoder().decode(
            AgentChatSession.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.workingCopy)
        XCTAssertEqual(decoded.title, "t")
    }

    // MARK: - CLI

    func testCLIShortFormsAndJSON() {
        let main = AgentWorkingCopy(kind: .mainFolder, path: "/a", name: nil, branch: "main")
        let tree = AgentWorkingCopy(kind: .worktree, path: "/a/.claude/worktrees/w", name: "w", branch: "feat/x")
        let other = AgentWorkingCopy(kind: .otherFolder, path: "/tmp/s", name: "s", branch: nil)
        XCTAssertEqual(ChatsOutput.workingCopyShort(nil), "-")
        XCTAssertEqual(ChatsOutput.workingCopyShort(main), "main@main")
        XCTAssertEqual(ChatsOutput.workingCopyShort(tree), "wt:w@feat/x")
        XCTAssertEqual(ChatsOutput.workingCopyShort(other), "dir:s")
        XCTAssertEqual(ChatsOutput.workingCopyLine(tree), "Arbeitskopie w · Branch feat/x  (/a/.claude/worktrees/w)")
        let json = ChatsOutput.workingCopyJSON(other)
        XCTAssertEqual(json["kind"] as? String, "otherFolder")
        XCTAssertEqual(json["name"] as? String, "s")
        XCTAssertTrue(json["branch"] is NSNull)
    }

    func testSessionJSONAlwaysHasTheField() {
        var session = AgentChatSession(provider: .claude, projectID: UUID(), title: "t")
        let entry = ChatsSessionEntry(session: session, projectName: "p", projectPath: "/a")
        let runtime = ChatsRuntimeInfo(status: nil, source: "transcriptEstimate", since: nil, revision: nil,
                                       transcriptPath: nil, transcriptSizeBytes: nil, availability: .missingTranscript)
        XCTAssertTrue(ChatsOutput.sessionJSON(entry: entry, runtime: runtime, selfID: nil, live: false)["workingCopy"] is NSNull)
        session.workingCopy = AgentWorkingCopy(kind: .mainFolder, path: "/a", name: nil, branch: "main")
        let withCopy = ChatsSessionEntry(session: session, projectName: "p", projectPath: "/a")
        let dict = ChatsOutput.sessionJSON(entry: withCopy, runtime: runtime, selfID: nil, live: false)["workingCopy"]
        XCTAssertEqual((dict as? [String: Any])?["kind"] as? String, "mainFolder")
    }
}
