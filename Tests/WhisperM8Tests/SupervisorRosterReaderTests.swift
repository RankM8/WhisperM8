import Foundation
import XCTest
@testable import WhisperM8

final class SupervisorRosterReaderTests: XCTestCase {
    /// Reales Roster-Format (gekuerzt): `workers` keyed by Short-ID, je mit
    /// `pid`, `sessionId`, `cwd` und weiteren Feldern, die wir ignorieren.
    private let rosterJSON = """
    {
      "proto": 1,
      "supervisorPid": 68475,
      "updatedAt": 1784447007689,
      "workers": {
        "607d545a": {
          "pid": 4242,
          "sessionId": "607d545a-01fa-4569-a4a7-72fe6072a1b7",
          "cwd": "/Users/x/repos/ListM8",
          "cliVersion": "2.1.209"
        },
        "b23b489e": {
          "pid": 74986,
          "sessionId": "b23b489e-aced-4c6a-a7ae-4f2315972a30",
          "cwd": "/Users/x/repos/whisperm8"
        },
        "kaputt-ohne-session": {
          "pid": 99
        }
      }
    }
    """

    func testWorkersDecodeSkipsBrokenEntriesAndKeepsFields() {
        let workers = SupervisorRosterReader.workers(fromRosterData: Data(rosterJSON.utf8))

        XCTAssertEqual(workers.count, 2, "Eintrag ohne sessionId wird uebersprungen")
        let worker = workers.first { $0.shortID == "607d545a" }
        XCTAssertEqual(worker?.sessionID, "607d545a-01fa-4569-a4a7-72fe6072a1b7")
        XCTAssertEqual(worker?.pid, 4242)
        XCTAssertEqual(worker?.cwd, "/Users/x/repos/ListM8")
    }

    func testWorkersDecodeReturnsEmptyForGarbage() {
        XCTAssertEqual(SupervisorRosterReader.workers(fromRosterData: Data("kein json".utf8)), [])
        XCTAssertEqual(SupervisorRosterReader.workers(fromRosterData: Data("{}".utf8)), [])
    }

    func testActiveWorkerShortIDMatchesCaseInsensitiveAndChecksPid() throws {
        let configDir = try makeConfigDir(rosterJSON: rosterJSON)
        defer { try? FileManager.default.removeItem(at: configDir) }

        // Session-IDs koennen im Store uppercase gestempelt sein — der
        // Roster schreibt lowercase.
        let found = SupervisorRosterReader.activeWorkerShortID(
            forSessionID: "607D545A-01FA-4569-A4A7-72FE6072A1B7",
            configDir: configDir,
            isProcessAlive: { _ in true }
        )
        XCTAssertEqual(found, "607d545a")

        // Toter Worker-Prozess = stale Roster-Eintrag → kein Attach.
        let stale = SupervisorRosterReader.activeWorkerShortID(
            forSessionID: "607d545a-01fa-4569-a4a7-72fe6072a1b7",
            configDir: configDir,
            isProcessAlive: { _ in false }
        )
        XCTAssertNil(stale)

        let unknown = SupervisorRosterReader.activeWorkerShortID(
            forSessionID: "ffffffff-0000-0000-0000-000000000000",
            configDir: configDir,
            isProcessAlive: { _ in true }
        )
        XCTAssertNil(unknown)
    }

    /// Review-Befund 11.11.2026: Lebt der Worker im Roster, wird angehaengt,
    /// auch ohne Registry-Eintrag. Fehlt der Roster-Eintrag, zaehlt ein
    /// lebender Registry-Eintrag mit `kind: "bg"` ueber seinen `jobId`.
    func testAttachTargetPrefersRosterAndFallsBackToRegistryJob() throws {
        let configDir = try makeConfigDir(rosterJSON: rosterJSON)
        defer { try? FileManager.default.removeItem(at: configDir) }
        let rostered = "607d545a-01fa-4569-a4a7-72fe6072a1b7"
        let onlyInRegistry = "1f353dce-783f-407c-a2d4-402c5e884d59"

        // Roster lebt, Registry fehlt → trotzdem attach.
        XCTAssertEqual(SupervisorRosterReader.attachTarget(
            forSessionID: rostered, configDir: configDir, isProcessAlive: { _ in true },
            registryJobID: { _ in nil }), "607d545a")

        // Kein Roster-Eintrag, keine Registry → nil (= --resume frei).
        XCTAssertNil(SupervisorRosterReader.attachTarget(
            forSessionID: onlyInRegistry, configDir: configDir, isProcessAlive: { _ in true }))

        // Registry-Eintrag: interaktiv zaehlt nicht, bg mit jobId schon.
        let sessions = configDir.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let pid = ProcessInfo.processInfo.processIdentifier
        func writeRecord(kind: String) throws {
            let json = #"{"pid":\#(pid),"sessionId":"\#(onlyInRegistry)","kind":"\#(kind)","jobId":"1f353dce","status":"idle"}"#
            try Data(json.utf8).write(to: sessions.appendingPathComponent("\(pid).json"))
        }
        try writeRecord(kind: "interactive")
        XCTAssertNil(SupervisorRosterReader.attachTarget(
            forSessionID: onlyInRegistry, configDir: configDir, isProcessAlive: { _ in true }))
        try writeRecord(kind: "bg")
        XCTAssertEqual(SupervisorRosterReader.attachTarget(
            forSessionID: onlyInRegistry, configDir: configDir, isProcessAlive: { _ in true }), "1f353dce")
    }

    func testActiveWorkerShortIDReturnsNilWithoutRosterFile() throws {
        let configDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("roster-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: configDir) }

        XCTAssertNil(SupervisorRosterReader.activeWorkerShortID(
            forSessionID: "607d545a-01fa-4569-a4a7-72fe6072a1b7",
            configDir: configDir,
            isProcessAlive: { _ in true }
        ))
    }

    func testDefaultIsProcessAlive() {
        XCTAssertFalse(SupervisorRosterReader.defaultIsProcessAlive(0))
        XCTAssertFalse(SupervisorRosterReader.defaultIsProcessAlive(-1))
        XCTAssertTrue(SupervisorRosterReader.defaultIsProcessAlive(ProcessInfo.processInfo.processIdentifier))
    }

    private func makeConfigDir(rosterJSON: String) throws -> URL {
        let configDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("roster-test-\(UUID().uuidString)", isDirectory: true)
        let daemonDir = configDir.appendingPathComponent("daemon", isDirectory: true)
        try FileManager.default.createDirectory(at: daemonDir, withIntermediateDirectories: true)
        try Data(rosterJSON.utf8).write(to: daemonDir.appendingPathComponent("roster.json"))
        return configDir
    }
}
