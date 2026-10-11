import XCTest
@testable import WhisperM8

final class ClaudeMemoryMigrationTests: XCTestCase {
    private var home: URL!
    private var backup: URL!
    private let project = "-Users-x-repos-app"

    override func setUpWithError() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("memory-migration-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        backup = root.appendingPathComponent("backup", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home.deletingLastPathComponent())
    }

    private var migration: ClaudeMemoryMigration {
        ClaudeMemoryMigration(profiles: ClaudeAccountProfiles(homeDirectory: home), backupRoot: backup)
    }

    // MARK: Ablauf

    func testCopiesNewFilesKeepsIdenticalAndRenamesConflicts() throws {
        try write("main", "MEMORY.md", "# Memory Index\n\n- [Gleich](gleich.md) — schon da\n- [Konflikt](konflikt.md) — main-Fassung\n")
        try write("main", "gleich.md", "gleich")
        try write("main", "konflikt.md", "main")
        try write("ai2", "MEMORY.md", "# Memory Index\n\n- [Gleich](gleich.md) — schon da\n- [Konflikt](konflikt.md) — ai2-Fassung\n- [Neu](neu.md) — nur in ai2\n")
        try write("ai2", "gleich.md", "gleich")
        try write("ai2", "konflikt.md", "ai2")
        try write("ai2", "neu.md", "neu")

        let report = try migration.run()

        XCTAssertEqual(report, .init(projects: 1, copied: 1, skippedIdentical: 1, renamed: 1, indexLinesAdded: 2))
        XCTAssertEqual(try read("main", "neu.md"), "neu")
        XCTAssertEqual(try read("main", "konflikt.md"), "main", "main-Datei wird nie überschrieben")
        XCTAssertEqual(try read("main", "konflikt.ai2.md"), "ai2")
        XCTAssertEqual(try read("main", "MEMORY.md"), """
            # Memory Index

            - [Gleich](gleich.md) — schon da
            - [Konflikt](konflikt.md) — main-Fassung
            - [Konflikt](konflikt.ai2.md) — ai2-Fassung
            - [Neu](neu.md) — nur in ai2

            """)
        // Quelle unverändert, Backups von Quelle und Ziel vorhanden
        XCTAssertEqual(try read("ai2", "konflikt.md"), "ai2")
        XCTAssertTrue(exists(backup.appendingPathComponent("ai2/\(project)/memory/neu.md")))
        XCTAssertEqual(
            try String(contentsOf: backup.appendingPathComponent("main/\(project)/memory/MEMORY.md"), encoding: .utf8),
            "# Memory Index\n\n- [Gleich](gleich.md) — schon da\n- [Konflikt](konflikt.md) — main-Fassung\n")
    }

    func testSecondRunChangesNothing() throws {
        try write("ai2", "MEMORY.md", "- [A](a.md) — x\n")
        try write("ai2", "a.md", "a")
        try write("main", "a.md", "anders")
        _ = try migration.run()
        let indexAfterFirst = try read("main", "MEMORY.md")

        let second = try migration.run()

        XCTAssertEqual(second.copied + second.renamed + second.indexLinesAdded, 0)
        XCTAssertEqual(try read("main", "MEMORY.md"), indexAfterFirst)
    }

    func testCreatesMainMemoryWhenMissing() throws {
        try write("ai2", "MEMORY.md", "# Memory Index\n\n- [A](a.md) — x\n")
        try write("ai2", "a.md", "a")

        let report = try migration.run()

        XCTAssertEqual(report.copied, 1)
        XCTAssertEqual(try read("main", "MEMORY.md"), "# Memory Index\n\n- [A](a.md) — x\n")
        XCTAssertFalse(exists(backup.appendingPathComponent("main")), "leeres Ziel braucht kein Backup")
    }

    func testTwoProfilesWithSameFileName() throws {
        try write("ai", "notiz.md", "von ai")
        try write("ai2", "notiz.md", "von ai2")

        _ = try migration.run()

        // Profile laufen alphabetisch: `ai` legt an, `ai2` kollidiert
        XCTAssertEqual(try read("main", "notiz.md"), "von ai")
        XCTAssertEqual(try read("main", "notiz.ai2.md"), "von ai2")
    }

    func testIgnoresSymlinkedMemoryAndHiddenFiles() throws {
        try write("ai2", ".DS_Store", "x")
        let elsewhere = home.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try "fremd".write(to: elsewhere.appendingPathComponent("f.md"), atomically: true, encoding: .utf8)
        let linkedProject = profileDir("ai").appendingPathComponent("projects/-linked", isDirectory: true)
        try FileManager.default.createDirectory(at: linkedProject, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: linkedProject.appendingPathComponent("memory"), withDestinationURL: elsewhere)

        let report = try migration.run()

        XCTAssertEqual(report, .init())
    }

    func testRunOnceRespectsFlagAndKillSwitch() throws {
        let suite = "memory-migration-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)

        preferences.isClaudeSharedMemoryEnabled = false
        ClaudeMemoryMigration.runOnceIfNeeded(preferences: preferences)
        XCTAssertFalse(preferences.claudeSharedMemoryMigrationDone, "Kill-Switch aus → kein Lauf")
    }

    // MARK: Index (pur)

    func testMergedIndexSkipsKnownLinksAndHeadings() {
        let merged = ClaudeMemoryMigration.mergedIndex(
            target: "# Memory Index\n\n- [A](a.md) — main\n",
            source: "# Memory Index\n\n- [A](a.md) — andere Beschreibung\n- [B](b.md) — neu\n",
            renamedLinks: [:])
        XCTAssertEqual(merged.addedLines, 1)
        XCTAssertEqual(merged.text, "# Memory Index\n\n- [A](a.md) — main\n- [B](b.md) — neu\n")
    }

    func testRenamedFileName() {
        XCTAssertEqual(ClaudeMemoryMigration.renamedFileName("notiz.md", profileName: "ai2"), "notiz.ai2.md")
        XCTAssertEqual(ClaudeMemoryMigration.renamedFileName("README", profileName: "ai2"), "README.ai2")
    }

    func testLinkTargets() {
        XCTAssertEqual(ClaudeMemoryMigration.linkTargets(in: "- [A](a.md) und [B](b.md)"), ["a.md", "b.md"])
        XCTAssertEqual(ClaudeMemoryMigration.linkTargets(in: "kein Link"), [])
    }

    // MARK: Helfer

    private func profileDir(_ profile: String) -> URL {
        profile == "main"
            ? home.appendingPathComponent(".claude", isDirectory: true)
            : home.appendingPathComponent(".claude-profiles/\(profile)", isDirectory: true)
    }

    private func memoryDir(_ profile: String) -> URL {
        profileDir(profile).appendingPathComponent("projects/\(project)/memory", isDirectory: true)
    }

    private func write(_ profile: String, _ name: String, _ content: String) throws {
        let dir = memoryDir(profile)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try content.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func read(_ profile: String, _ name: String) throws -> String {
        try String(contentsOf: memoryDir(profile).appendingPathComponent(name), encoding: .utf8)
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
}
