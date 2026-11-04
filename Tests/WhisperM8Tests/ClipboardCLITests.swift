import XCTest
@testable import WhisperM8

final class ClipboardCLITests: XCTestCase {
    // MARK: Argumente

    func testParseList() throws {
        XCTAssertEqual(try ClipboardCLIArguments.parse(["list"]), .list(limit: 20, json: false))
        XCTAssertEqual(try ClipboardCLIArguments.parse(["list", "--limit", "5", "--json"]), .list(limit: 5, json: true))
        XCTAssertEqual(try ClipboardCLIArguments.parse(["list", "--json", "-n", "999"]), .list(limit: 500, json: true))
    }

    func testParseGetSearchCopy() throws {
        XCTAssertEqual(try ClipboardCLIArguments.parse(["get", "3"]), .get(ref: "3", json: false))
        XCTAssertEqual(try ClipboardCLIArguments.parse(["get", "--json", "ab12cd"]), .get(ref: "ab12cd", json: true))
        XCTAssertEqual(try ClipboardCLIArguments.parse(["search", "stack", "trace"]), .search(query: "stack trace", limit: 20, json: false))
        XCTAssertEqual(try ClipboardCLIArguments.parse(["search", "x", "--limit", "3", "--json"]), .search(query: "x", limit: 3, json: true))
        XCTAssertEqual(try ClipboardCLIArguments.parse(["copy", "2"]), .copy(ref: "2"))
    }

    func testParseHelpAndErrors() {
        XCTAssertEqual(try ClipboardCLIArguments.parse([]), .help)
        XCTAssertEqual(try ClipboardCLIArguments.parse(["--help"]), .help)
        XCTAssertThrowsError(try ClipboardCLIArguments.parse(["get"]))
        XCTAssertThrowsError(try ClipboardCLIArguments.parse(["get", "1", "2"]))
        XCTAssertThrowsError(try ClipboardCLIArguments.parse(["list", "--limit", "x"]))
        XCTAssertThrowsError(try ClipboardCLIArguments.parse(["list", "--bogus"]))
        XCTAssertThrowsError(try ClipboardCLIArguments.parse(["search"]))
        XCTAssertThrowsError(try ClipboardCLIArguments.parse(["frobnicate"]))
    }

    // MARK: Ausführung

    private let directory = URL(fileURLWithPath: "/tmp/clipboard-cli-test", isDirectory: true)
    private let now = Date(timeIntervalSince1970: 10_000)

    private func entry(_ id: String, _ text: String, ago: TimeInterval, pinned: Bool = false, app: String? = "Safari") -> ClipboardEntry {
        let date = now.addingTimeInterval(-ago)
        return ClipboardEntry(
            id: id, kind: .text, createdAt: date, lastCopiedAt: date, copyCount: 1, isPinned: pinned,
            sourceBundleID: nil, sourceName: app, contentHash: ClipboardEntry.hash(text: text),
            preview: ClipboardEntry.makePreview(from: text), text: text
        )
    }

    private func environment(
        entries: [ClipboardEntry], settings: ClipboardSettings = ClipboardSettings(enabled: true),
        copy: @escaping (String) -> ClipboardCLIRunner.CopyOutcome = { _ in .copied(kind: "text") }
    ) -> ClipboardCLIEnvironment {
        ClipboardCLIEnvironment(
            settings: { settings }, directory: directory, loadEntries: { entries },
            fullText: { $0.text }, now: { self.now }, copyViaApp: copy
        )
    }

    private let sample: [ClipboardEntry] = []

    private func samples() -> [ClipboardEntry] {
        [
            entry("old00001", "alte Notiz", ago: 7200),
            entry("new00002", "TypeError: undefined is not a function", ago: 120),
            entry("mid00003", "Mittlerer Eintrag\nzweite Zeile", ago: 3600, pinned: true, app: nil),
        ]
    }

    func testListNumbersNewestFirstAndShowsMetadata() {
        let output = ClipboardCLIRunner.execute(.list(limit: 20, json: false), environment: environment(entries: samples()))
        XCTAssertEqual(output.exitCode, 0)
        let lines = output.stdout.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].hasPrefix("1 "), lines[0])
        XCTAssertTrue(lines[0].contains("TypeError"))
        XCTAssertTrue(lines[0].contains("2m"))
        XCTAssertTrue(lines[0].contains("Safari"))
        XCTAssertTrue(lines[1].hasPrefix("2 ") && lines[1].contains("*"), lines[1])
        XCTAssertTrue(lines[1].contains("Mittlerer Eintrag zweite Zeile"))
        XCTAssertTrue(lines[2].contains("2h"))
    }

    func testListLimitAndJSON() throws {
        let output = ClipboardCLIRunner.execute(.list(limit: 2, json: true), environment: environment(entries: samples()))
        let array = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.stdout.utf8)) as? [[String: Any]])
        XCTAssertEqual(array.count, 2)
        XCTAssertEqual(array[0]["number"] as? Int, 1)
        XCTAssertEqual(array[0]["id"] as? String, "new00002")
        XCTAssertEqual(array[0]["kind"] as? String, "text")
        XCTAssertEqual(array[1]["pinned"] as? Bool, true)
    }

    func testGetByNumberReturnsFullText() {
        let output = ClipboardCLIRunner.execute(.get(ref: "2", json: false), environment: environment(entries: samples()))
        XCTAssertEqual(output.exitCode, 0)
        XCTAssertEqual(output.stdout, "Mittlerer Eintrag\nzweite Zeile")
    }

    func testGetImageReturnsAbsolutePath() throws {
        var image = entry("img00001", "", ago: 10)
        image.kind = .image
        image.text = nil
        image.imageFile = "img00001.png"
        image.imageWidth = 10
        image.imageHeight = 5
        let plain = ClipboardCLIRunner.execute(.get(ref: "1", json: false), environment: environment(entries: [image]))
        XCTAssertEqual(plain.stdout, "/tmp/clipboard-cli-test/img00001.png")
        let json = ClipboardCLIRunner.execute(.get(ref: "img00001", json: true), environment: environment(entries: [image]))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.stdout.utf8)) as? [String: Any])
        XCTAssertEqual(object["imagePath"] as? String, "/tmp/clipboard-cli-test/img00001.png")
        XCTAssertEqual(object["width"] as? Int, 10)
    }

    func testGetFilesListsPaths() {
        var files = entry("fil00001", "", ago: 10)
        files.kind = .files
        files.text = nil
        files.filePaths = ["/a/b.txt", "/a/c.txt"]
        let output = ClipboardCLIRunner.execute(.get(ref: "1", json: false), environment: environment(entries: [files]))
        XCTAssertEqual(output.stdout, "/a/b.txt\n/a/c.txt")
    }

    func testGetUnknownReferenceExitsNotFound() {
        let output = ClipboardCLIRunner.execute(.get(ref: "9", json: false), environment: environment(entries: samples()))
        XCTAssertEqual(output.exitCode, ChatsCLIExit.notFound)
        XCTAssertTrue(output.stderr.contains("1 bis 3"))
    }

    func testSecretsAreMaskedByDefaultEverywhere() throws {
        let secret = entry("sec00001", "export KEY=sk-abcdefghijklmnopqrstuvwxyz0123", ago: 5)
        let env = environment(entries: [secret])
        let list = ClipboardCLIRunner.execute(.list(limit: 5, json: false), environment: env)
        XCTAssertFalse(list.stdout.contains("sk-abcdef"))
        XCTAssertTrue(list.stdout.contains("[REDACTED:api-key]"))
        let get = ClipboardCLIRunner.execute(.get(ref: "1", json: false), environment: env)
        XCTAssertEqual(get.stdout, "export KEY=[REDACTED:api-key]")
        XCTAssertTrue(get.stderr.contains("maskiert"))
        let json = ClipboardCLIRunner.execute(.get(ref: "1", json: true), environment: env)
        XCTAssertFalse(json.stdout.contains("sk-abcdef"))
        let found = ClipboardCLIRunner.execute(.search(query: "REDACTED", limit: 5, json: false), environment: env)
        XCTAssertTrue(found.stdout.contains("REDACTED"))
        // Die Suche nach dem echten Schlüssel findet nichts: kein Rätselraten Zeichen für Zeichen.
        let probe = ClipboardCLIRunner.execute(.search(query: "sk-abcdefghij", limit: 5, json: false), environment: env)
        XCTAssertEqual(probe.stdout, "(keine Einträge)")
    }

    func testMaskingCanBeSwitchedOff() {
        let secret = entry("sec00001", "sk-abcdefghijklmnopqrstuvwxyz0123", ago: 5)
        var settings = ClipboardSettings(enabled: true)
        settings.maskSecrets = false
        let output = ClipboardCLIRunner.execute(.get(ref: "1", json: false), environment: environment(entries: [secret], settings: settings))
        XCTAssertEqual(output.stdout, "sk-abcdefghijklmnopqrstuvwxyz0123")
        XCTAssertEqual(output.stderr, "")
    }

    func testSearchKeepsChronologicalNumbers() throws {
        let output = ClipboardCLIRunner.execute(.search(query: "eintrag", limit: 5, json: true), environment: environment(entries: samples()))
        let array = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.stdout.utf8)) as? [[String: Any]])
        XCTAssertEqual(array.count, 1)
        // „Mittlerer Eintrag“ ist der zweitneueste Eintrag, unabhängig vom Ranking.
        XCTAssertEqual(array[0]["number"] as? Int, 2)
    }

    func testSearchWithoutHitsSaysSo() {
        let output = ClipboardCLIRunner.execute(.search(query: "zzzz", limit: 5, json: false), environment: environment(entries: samples()))
        XCTAssertEqual(output.exitCode, 0)
        XCTAssertEqual(output.stdout, "(keine Einträge)")
    }

    func testDisabledFeatureRefusesWithClearMessage() {
        let output = ClipboardCLIRunner.execute(.list(limit: 5, json: false), environment: environment(entries: samples(), settings: ClipboardSettings(enabled: false)))
        XCTAssertEqual(output.exitCode, ChatsCLIExit.usage)
        XCTAssertEqual(output.stderr, ClipboardSettings.disabledMessage)
        XCTAssertEqual(output.stdout, "")
    }

    func testAgentAccessOffRefusesEveryCommand() {
        var settings = ClipboardSettings(enabled: true)
        settings.agentAccess = false
        for command in [ClipboardCLIArguments.list(limit: 5, json: false), .get(ref: "1", json: false),
                        .search(query: "a", limit: 5, json: false), .copy(ref: "1")] {
            let output = ClipboardCLIRunner.execute(command, environment: environment(entries: samples(), settings: settings))
            XCTAssertEqual(output.exitCode, ChatsCLIExit.usage, "\(command)")
            XCTAssertEqual(output.stderr, ClipboardSettings.agentAccessDeniedMessage)
        }
    }

    func testCopyGoesThroughTheAppWithResolvedID() {
        var received: String?
        let env = environment(entries: samples()) { id in
            received = id
            return .copied(kind: "text")
        }
        let output = ClipboardCLIRunner.execute(.copy(ref: "1"), environment: env)
        XCTAssertEqual(output.exitCode, 0)
        XCTAssertEqual(received, "new00002")
        XCTAssertTrue(output.stdout.contains("new00002"))
    }

    func testCopyReportsUnreachableApp() {
        let env = environment(entries: samples()) { _ in .failed(message: "App nicht erreichbar", exitCode: ChatsCLIExit.appUnreachable) }
        let output = ClipboardCLIRunner.execute(.copy(ref: "1"), environment: env)
        XCTAssertEqual(output.exitCode, ChatsCLIExit.appUnreachable)
        XCTAssertEqual(output.stderr, "App nicht erreichbar")
    }

    func testAgeLabels() {
        let base = Date(timeIntervalSince1970: 100_000)
        XCTAssertEqual(ClipboardCLIFormatter.ageLabel(from: base.addingTimeInterval(-5), now: base), "5s")
        XCTAssertEqual(ClipboardCLIFormatter.ageLabel(from: base.addingTimeInterval(-300), now: base), "5m")
        XCTAssertEqual(ClipboardCLIFormatter.ageLabel(from: base.addingTimeInterval(-7200), now: base), "2h")
        XCTAssertEqual(ClipboardCLIFormatter.ageLabel(from: base.addingTimeInterval(-172_800), now: base), "2d")
    }

    func testDoubleDashTreatsRestAsText() throws {
        XCTAssertEqual(try ClipboardCLIArguments.parse(["search", "--json", "--", "-v", "fehler"]),
                       .search(query: "-v fehler", limit: 20, json: true))
        XCTAssertEqual(try ClipboardCLIArguments.parse(["get", "--", "ab12cd"]), .get(ref: "ab12cd", json: false))
    }

    func testCLIModeRecognisesClipboardCommand() {
        XCTAssertTrue(CLIModeDetector.shouldRunCLI(["/x/WhisperM8", "clipboard", "list"]))
    }
}
