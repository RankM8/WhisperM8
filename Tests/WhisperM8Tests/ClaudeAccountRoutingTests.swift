import Foundation
import XCTest
@testable import WhisperM8

/// Slice 5: Das in den Einstellungen aktive Account-Profil ist der Default
/// fuer NEUE Claude-Chats — auf jedem Erstellungsweg. Vorher setzte nur der
/// GUI-Pfad den Stempel, der CLI-Pfad landete still im Haupt-Account
/// (docs/plans/claude-account-routing.md, Befund 1).
final class ClaudeProfileSelectionStoreTests: XCTestCase {
    private func makeStore(
        activeProfile: String?,
        fileURL: URL
    ) -> AgentSessionStore {
        var store = AgentSessionStore(fileURL: fileURL)
        store.activeClaudeProfileResolver = { activeProfile }
        return store
    }

    private func tempStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperM8AccountRouting-\(UUID().uuidString)")
            .appendingPathExtension("json")
    }

    func testClaudeSessionWithoutSelectionInheritsActiveProfile() throws {
        let fileURL = tempStoreURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let store = makeStore(activeProfile: "ai3", fileURL: fileURL)

        let session = try store.createSession(
            provider: .claude,
            projectPath: FileManager.default.temporaryDirectory.path,
            title: "Ohne Angabe"
        )

        XCTAssertEqual(session.claudeProfileName, "ai3")
    }

    func testExplicitMainWinsOverActiveProfile() throws {
        let fileURL = tempStoreURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let store = makeStore(activeProfile: "ai3", fileURL: fileURL)

        let session = try store.createSession(
            provider: .claude,
            projectPath: FileManager.default.temporaryDirectory.path,
            title: "Ausdruecklich main",
            claudeProfile: .explicit(nil)
        )

        // Genau der Fall, den ein blosses `String? = nil` nicht ausdruecken
        // konnte: „ausdruecklich Haupt-Account" trotz aktivem Zusatzprofil.
        XCTAssertNil(session.claudeProfileName)
    }

    func testExplicitProfileWinsOverActiveProfile() throws {
        let fileURL = tempStoreURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let store = makeStore(activeProfile: "ai3", fileURL: fileURL)

        let session = try store.createSession(
            provider: .claude,
            projectPath: FileManager.default.temporaryDirectory.path,
            title: "Ausdruecklich PowerUser",
            claudeProfile: .explicit("PowerUser")
        )

        XCTAssertEqual(session.claudeProfileName, "PowerUser")
    }

    func testCodexNeverCarriesAccountProfile() throws {
        let fileURL = tempStoreURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let store = makeStore(activeProfile: "ai3", fileURL: fileURL)

        let session = try store.createSession(
            provider: .codex,
            projectPath: FileManager.default.temporaryDirectory.path,
            title: "Codex"
        )

        XCTAssertNil(session.claudeProfileName, "Codex kennt keine Claude-Account-Profile")
    }

    func testActiveProfileMainYieldsNilStamp() throws {
        let fileURL = tempStoreURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let store = makeStore(activeProfile: nil, fileURL: fileURL)

        let session = try store.createSession(
            provider: .claude,
            projectPath: FileManager.default.temporaryDirectory.path,
            title: "Main aktiv"
        )

        XCTAssertNil(session.claudeProfileName)
    }
}

/// Validierung AUSDRUECKLICHER Profilangaben (`chats new --account`).
/// Anders als beim Resume faellt hier bewusst nichts auf main zurueck.
final class ClaudeAccountSelectionValidationTests: XCTestCase {
    private func makeProfiles(home: URL) -> ClaudeAccountProfiles {
        var profiles = ClaudeAccountProfiles()
        profiles.homeDirectory = home
        return profiles
    }

    private func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperM8AccountHome-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    private func createProfile(_ name: String, loggedIn: Bool, in home: URL) throws {
        let dir = home
            .appendingPathComponent(".claude-profiles", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let payload: [String: Any] = loggedIn
            ? ["oauthAccount": ["emailAddress": "\(name)@example.com"]]
            : [:]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try data.write(to: dir.appendingPathComponent(".claude.json"))
    }

    func testEmptyAndMainNormalizeToNil() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let profiles = makeProfiles(home: home)

        XCTAssertNil(try profiles.validatedProfileName(""))
        XCTAssertNil(try profiles.validatedProfileName("   "))
        XCTAssertNil(try profiles.validatedProfileName("main"))
    }

    func testLoggedInProfileIsAccepted() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try createProfile("ai3", loggedIn: true, in: home)

        XCTAssertEqual(try makeProfiles(home: home).validatedProfileName(" ai3 "), "ai3")
    }

    func testUnknownProfileThrowsInsteadOfFallingBackToMain() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let profiles = makeProfiles(home: home)

        XCTAssertThrowsError(try profiles.validatedProfileName("gibtesnicht")) { error in
            XCTAssertEqual(
                error as? ClaudeAccountProfiles.SelectionError,
                .unknownProfile("gibtesnicht")
            )
        }
    }

    func testLoggedOutProfileThrows() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try createProfile("leer", loggedIn: false, in: home)

        XCTAssertThrowsError(try makeProfiles(home: home).validatedProfileName("leer")) { error in
            XCTAssertEqual(
                error as? ClaudeAccountProfiles.SelectionError,
                .notLoggedIn("leer")
            )
        }
    }
}

/// Argument-Vertrag von `whisperm8 chats new`.
final class ChatsNewArgumentsTests: XCTestCase {
    func testParsesAccountFlag() {
        let result = ChatsNewArguments.parse(["--project", "whisperm8", "--account", "ai3"])
        guard case .success(let args) = result else { return XCTFail("Parsing fehlgeschlagen") }
        XCTAssertEqual(args.account, "ai3")
        XCTAssertEqual(args.provider, "claude")
        XCTAssertEqual(args.controlParams["account"] as? String, "ai3")
    }

    func testAccountIsOmittedWhenNotGiven() {
        let result = ChatsNewArguments.parse(["--project", "whisperm8"])
        guard case .success(let args) = result else { return XCTFail("Parsing fehlgeschlagen") }
        XCTAssertNil(args.account)
        // Kein leerer String im Payload — der Handler unterscheidet „nicht
        // angegeben" (aktives Profil) von einer ausdruecklichen Wahl.
        XCTAssertNil(args.controlParams["account"])
    }

    func testAccountWithoutValueIsRejected() {
        let result = ChatsNewArguments.parse(["--project", "x", "--account"])
        guard case .failure(let error) = result else { return XCTFail("Fehler erwartet") }
        XCTAssertEqual(error, .missingValue("--account"))
    }

    func testUnknownOptionIsRejected() {
        let result = ChatsNewArguments.parse(["--project", "x", "--nope"])
        guard case .failure(let error) = result else { return XCTFail("Fehler erwartet") }
        XCTAssertEqual(error, .unknownOption("--nope"))
    }

    func testProjectIsRequired() {
        guard case .failure(let error) = ChatsNewArguments.parse(["--title", "x"]) else {
            return XCTFail("Fehler erwartet")
        }
        XCTAssertEqual(error, .projectMissing)
    }

    func testInvalidProviderIsRejected() {
        guard case .failure(let error) = ChatsNewArguments.parse(["--project", "x", "--provider", "gemini"]) else {
            return XCTFail("Fehler erwartet")
        }
        XCTAssertEqual(error, .invalidProvider("gemini"))
    }
}

/// Der Transcript-Umzug selbst — gegen ein echtes Dateisystem in einem
/// Temp-Root. Kollisionen und der Rollback des zweistufigen Moves sind die
/// Faelle, in denen ein halber Umzug stiller Datenversatz waere.
final class ClaudeTranscriptMoveTests: XCTestCase {
    private var home: URL!
    private var profiles: ClaudeAccountProfiles!
    /// Muss zum Encoding von `AgentTranscriptLocator.encodeClaudeCwd` passen.
    private let cwd = "/tmp/whisperm8-move-test"

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperM8MoveHome-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        profiles = ClaudeAccountProfiles()
        profiles.homeDirectory = home
        // Zielprofil anlegen, sonst greift der Missing-Profile-Guard.
        try FileManager.default.createDirectory(
            at: profiles.configDir(forProfile: "ai3"), withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func projectsDir(_ profile: String) -> URL {
        profiles.configDir(forProfile: profile)
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(AgentTranscriptLocator.encodeClaudeCwd(cwd), isDirectory: true)
    }

    @discardableResult
    private func writeTranscript(_ id: String, in profile: String, contents: String = "{}") throws -> URL {
        let dir = projectsDir(profile)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(id).jsonl")
        try contents.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    func testMovesTranscriptIntoTargetRoot() throws {
        try writeTranscript("sess-1", in: "main", contents: "verlauf")

        let moved = try profiles.moveTranscript(externalSessionID: "sess-1", cwd: cwd, toProfile: "ai3")

        XCTAssertTrue(moved)
        let target = projectsDir("ai3").appendingPathComponent("sess-1.jsonl")
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "verlauf")
        // Genau EIN Treffer ueber alle Roots — eine zurueckgebliebene Kopie
        // wuerde der Multi-Root-Indexer doppelt adoptieren.
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: projectsDir("main").appendingPathComponent("sess-1.jsonl").path
        ))
    }

    func testSubagentFolderMovesWithTranscript() throws {
        try writeTranscript("sess-2", in: "main")
        let subagents = projectsDir("main").appendingPathComponent("sess-2", isDirectory: true)
        try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
        try "sub".write(to: subagents.appendingPathComponent("a.jsonl"), atomically: true, encoding: .utf8)

        _ = try profiles.moveTranscript(externalSessionID: "sess-2", cwd: cwd, toProfile: "ai3")

        let movedSub = projectsDir("ai3").appendingPathComponent("sess-2/a.jsonl")
        XCTAssertEqual(try String(contentsOf: movedSub, encoding: .utf8), "sub")
        XCTAssertFalse(FileManager.default.fileExists(atPath: subagents.path))
    }

    func testCollisionInTargetMovesNothing() throws {
        try writeTranscript("sess-3", in: "main", contents: "quelle")
        try writeTranscript("sess-3", in: "ai3", contents: "ziel-bestand")

        XCTAssertThrowsError(
            try profiles.moveTranscript(externalSessionID: "sess-3", cwd: cwd, toProfile: "ai3")
        )
        // Beide Seiten unveraendert — kein halber Umzug.
        XCTAssertEqual(
            try String(contentsOf: projectsDir("main").appendingPathComponent("sess-3.jsonl"), encoding: .utf8),
            "quelle"
        )
        XCTAssertEqual(
            try String(contentsOf: projectsDir("ai3").appendingPathComponent("sess-3.jsonl"), encoding: .utf8),
            "ziel-bestand"
        )
    }

    func testSubagentCollisionRollsBackTheTranscript() throws {
        try writeTranscript("sess-4", in: "main", contents: "quelle")
        let sourceSub = projectsDir("main").appendingPathComponent("sess-4", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceSub, withIntermediateDirectories: true)
        // Im Ziel liegt bereits ein gleichnamiger Subagent-Ordner.
        let targetSub = projectsDir("ai3").appendingPathComponent("sess-4", isDirectory: true)
        try FileManager.default.createDirectory(at: targetSub, withIntermediateDirectories: true)

        XCTAssertThrowsError(
            try profiles.moveTranscript(externalSessionID: "sess-4", cwd: cwd, toProfile: "ai3")
        )
        // Das JSONL muss zurueckgerollt sein: JSONL im Ziel + Subagents in der
        // Quelle waere stiller Datenversatz.
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: projectsDir("main").appendingPathComponent("sess-4.jsonl").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: projectsDir("ai3").appendingPathComponent("sess-4.jsonl").path
        ))
    }

    func testMoveIsReversible() throws {
        try writeTranscript("sess-5", in: "main", contents: "verlauf")

        _ = try profiles.moveTranscript(externalSessionID: "sess-5", cwd: cwd, toProfile: "ai3")
        _ = try profiles.moveTranscript(externalSessionID: "sess-5", cwd: cwd, toProfile: nil)

        XCTAssertEqual(
            try String(contentsOf: projectsDir("main").appendingPathComponent("sess-5.jsonl"), encoding: .utf8),
            "verlauf"
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: projectsDir("ai3").appendingPathComponent("sess-5.jsonl").path
        ))
    }

    func testMissingTranscriptIsNoOpNotAnError() throws {
        // Eine Session ohne Transcript (noch nie gestartet) wird nur gestempelt.
        XCTAssertFalse(try profiles.moveTranscript(externalSessionID: "gibtsnicht", cwd: cwd, toProfile: "ai3"))
    }

    func testConflictPreviewMatchesActualMove() throws {
        try writeTranscript("sess-6", in: "main")
        XCTAssertFalse(profiles.transcriptConflictExists(
            externalSessionID: "sess-6", cwd: cwd, toProfile: "ai3"
        ))

        try writeTranscript("sess-6", in: "ai3")
        XCTAssertTrue(profiles.transcriptConflictExists(
            externalSessionID: "sess-6", cwd: cwd, toProfile: "ai3"
        ))
    }

    func testSessionAlreadyInTargetIsNotAConflict() throws {
        try writeTranscript("sess-7", in: "ai3")
        // Liegt die Datei schon im Ziel, ist das ein No-op, kein Konflikt —
        // sonst meldete die Vorschau einen Fehler, wo nichts zu tun ist.
        XCTAssertFalse(profiles.transcriptConflictExists(
            externalSessionID: "sess-7", cwd: cwd, toProfile: "ai3"
        ))
    }
}
