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
