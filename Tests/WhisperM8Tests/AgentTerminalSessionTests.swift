import Foundation
import XCTest
@testable import WhisperM8

/// Tests für `.terminal`-Sessions: Command-Bau (Login-Shell statt Agent-CLI),
/// Shell-Auflösung, Plain-Shell-Keyboard-Profil, Kind-Decoding und die
/// Store-Gates, die verhindern, dass ein Terminal-Tab eine fremde
/// Claude-/Codex-Session adoptiert.
final class AgentTerminalSessionTests: XCTestCase {
    // MARK: - Command-Builder

    func testCommandBuilderBuildsLoginShellForTerminalSessions() throws {
        let project = AgentProject(name: "Repo", path: FileManager.default.temporaryDirectory.path)
        var builder = AgentCommandBuilder(commandResolver: { _ in
            XCTFail("Terminal-Launch darf keine Agent-CLI auflösen")
            return nil
        })
        builder.shellResolver = { "/opt/homebrew/bin/fish" }
        let session = AgentChatSession(
            provider: .claude,
            projectID: project.id,
            title: "Terminal",
            kind: .terminal
        )

        let command = try builder.command(for: session, project: project)

        XCTAssertEqual(command.executablePath, "/opt/homebrew/bin/fish")
        XCTAssertEqual(command.arguments, ["-i", "-l"])
        XCTAssertEqual(command.workingDirectory, project.path)
        XCTAssertEqual(command.keyboardProfile, .plainShell)
    }

    func testResolveLoginShellPrefersExecutableAbsoluteShellValue() {
        XCTAssertEqual(
            AgentCommandBuilder.resolveLoginShell(fromEnvironment: "/bin/bash", isExecutable: { $0 == "/bin/bash" }),
            "/bin/bash"
        )
        // Fehlende Variable → zsh-Default.
        XCTAssertEqual(
            AgentCommandBuilder.resolveLoginShell(fromEnvironment: nil, isExecutable: { _ in true }),
            "/bin/zsh"
        )
        // Nicht-absoluter Wert → zsh-Default.
        XCTAssertEqual(
            AgentCommandBuilder.resolveLoginShell(fromEnvironment: "fish", isExecutable: { _ in true }),
            "/bin/zsh"
        )
        // Zeigt auf kein ausführbares Binary → zsh-Default.
        XCTAssertEqual(
            AgentCommandBuilder.resolveLoginShell(fromEnvironment: "/nope/shell", isExecutable: { _ in false }),
            "/bin/zsh"
        )
    }

    // MARK: - Keyboard-Profil .plainShell

    func testPlainShellShiftEnterIsNotIntercepted() {
        // In der Shell ist Shift+Enter ein normales Enter — keine
        // Backslash-Continuation, kein CSI-u.
        let bytes = TerminalShortcut.bytes(
            keyCode: TerminalShortcut.KeyCode.returnKey,
            modifiers: [.shift],
            characters: nil,
            profile: .plainShell
        )
        XCTAssertNil(bytes)
    }

    func testPlainShellOptionPIsNotIntercepted() {
        // Alt+P ist Claude Codes Model-Switch — in der Shell muss Option+P
        // das macOS-Sonderzeichen liefern (Event durchreichen).
        let bytes = TerminalShortcut.bytes(
            keyCode: TerminalShortcut.KeyCode.p,
            modifiers: [.option],
            characters: nil,
            profile: .plainShell
        )
        XCTAssertNil(bytes)
    }

    func testPlainShellKeepsReadlineEditingShortcuts() {
        // Word-Kill, Line-Discard und Word-Move sind Readline/ZLE-Standard
        // und gelten auch in der normalen Shell.
        XCTAssertEqual(
            TerminalShortcut.bytes(keyCode: TerminalShortcut.KeyCode.delete, modifiers: [.option], characters: nil, profile: .plainShell),
            [0x17]
        )
        XCTAssertEqual(
            TerminalShortcut.bytes(keyCode: TerminalShortcut.KeyCode.delete, modifiers: [.command], characters: nil, profile: .plainShell),
            [0x15]
        )
        XCTAssertEqual(
            TerminalShortcut.bytes(keyCode: TerminalShortcut.KeyCode.leftArrow, modifiers: [.option], characters: nil, profile: .plainShell),
            [0x1b, 0x62]
        )
    }

    // MARK: - Model / Decoding

    func testAgentSessionKindDecodesTerminal() {
        XCTAssertEqual(AgentSessionKind.lenientDecode("terminal"), .terminal)
        // Unbekannte Kinds bleiben lenient nil (Downgrade-Sicherheit).
        XCTAssertNil(AgentSessionKind.lenientDecode("hologram"))
    }

    func testTerminalSessionModelFlagsAndRuntimeText() throws {
        let session = AgentChatSession(
            provider: .claude,
            projectID: UUID(),
            title: "Terminal",
            kind: .terminal
        )
        XCTAssertTrue(session.isTerminal)
        XCTAssertFalse(session.isForkable)
        XCTAssertEqual(session.runtimeDisplayText, "Terminal · Login-Shell")

        // Round-Trip: kind übersteht Encode/Decode.
        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(AgentChatSession.self, from: data)
        XCTAssertEqual(decoded.effectiveKind, .terminal)
    }

    // MARK: - Store-Gates (kein Session-Kapern)

    func testBindLatestIndexedSessionSkipsTerminalSessions() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperM8TerminalBind-\(UUID().uuidString)")
            .appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let projectPath = FileManager.default.temporaryDirectory.path
        let store = AgentSessionStore(fileURL: fileURL)
        var session = try store.createSession(
            provider: .codex,
            projectPath: projectPath,
            title: "Terminal",
            kind: .terminal
        )
        session.hasLaunchedInitialPrompt = true
        _ = try store.upsertSession(session)

        let indexed = IndexedAgentSession(
            provider: .codex,
            externalSessionID: "foreign-session",
            cwd: projectPath,
            title: "Fremder Chat",
            model: "gpt-5.5",
            reasoningEffort: "medium",
            createdAt: Date(),
            lastActivityAt: Date()
        )

        let updated = try store.bindLatestIndexedSession(
            localSessionID: session.id,
            provider: .codex,
            projectPath: projectPath,
            indexedSessions: [indexed]
        )

        XCTAssertNil(updated)
        let stored = store.loadWorkspace().sessions.first(where: { $0.id == session.id })
        XCTAssertNil(stored?.externalSessionID)
    }

    func testMergeIndexedSessionsDoesNotAdoptIntoTerminalSessions() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperM8TerminalMerge-\(UUID().uuidString)")
            .appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let projectPath = FileManager.default.temporaryDirectory.path
        let store = AgentSessionStore(fileURL: fileURL)
        var terminal = try store.createSession(
            provider: .codex,
            projectPath: projectPath,
            title: "Terminal",
            kind: .terminal
        )
        // Genau das Adoption-Fenster: gelauncht + externalSessionID nil +
        // createdAt ±5s um die indizierte Session.
        terminal.hasLaunchedInitialPrompt = true
        _ = try store.upsertSession(terminal)

        let indexed = IndexedAgentSession(
            provider: .codex,
            externalSessionID: "external-codex",
            cwd: projectPath,
            title: "Echter Codex Chat",
            model: "gpt-5.5",
            reasoningEffort: "medium",
            createdAt: terminal.createdAt,
            lastActivityAt: Date()
        )

        try store.mergeIndexedSessions([indexed])

        let sessions = store.loadWorkspace().sessions
        let storedTerminal = sessions.first(where: { $0.id == terminal.id })
        XCTAssertNil(storedTerminal?.externalSessionID, "Terminal darf keine fremde JSONL adoptieren")
        XCTAssertEqual(storedTerminal?.title, "Terminal")
        // Die indizierte Session muss stattdessen als EIGENE Session ankommen.
        XCTAssertTrue(
            sessions.contains(where: { $0.externalSessionID == "external-codex" && $0.id != terminal.id }),
            "Indizierte Session muss als separate Session angelegt werden"
        )
    }
}
