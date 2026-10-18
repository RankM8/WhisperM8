import XCTest
@testable import WhisperM8

/// LR-SH-015: Rotation (eine Vorversion) und fehlerfreies Schreiben ohne Ziel.
final class LoggerFileSinkTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("logger-sink-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        // Schreibschutz aufheben, sonst bleibt das Verzeichnis liegen.
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        try? FileManager.default.removeItem(at: directory)
    }

    func testAppendCreatesAndAppends() throws {
        let sink = LoggerFileSink(url: directory.appendingPathComponent("a.log"), maxBytes: 1_000)
        sink.append("eins\n")
        sink.append("zwei\n")
        XCTAssertEqual(try String(contentsOf: sink.url, encoding: .utf8), "eins\nzwei\n")
    }

    func testRotatesAtLimitKeepingOnePreviousVersion() throws {
        let sink = LoggerFileSink(url: directory.appendingPathComponent("a.log"), maxBytes: 20)
        sink.append("0123456789012345678901234\n") // 26 Byte, über dem Limit
        sink.append("zweite\n")                     // löst Rotation aus
        XCTAssertEqual(try String(contentsOf: sink.url, encoding: .utf8), "zweite\n")
        XCTAssertEqual(try String(contentsOf: sink.rotatedURL, encoding: .utf8), "0123456789012345678901234\n")

        // Nochmal über das Limit: die Vorversion wird ersetzt, es gibt nie .2
        sink.append("0123456789012345678901234\n")
        sink.append("dritte\n")
        XCTAssertEqual(try String(contentsOf: sink.rotatedURL, encoding: .utf8), "zweite\n0123456789012345678901234\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sink.url.appendingPathExtension("2").path))
    }

    func testWriteToReadOnlyTargetDoesNotCrash() throws {
        let file = directory.appendingPathComponent("ro.log")
        try "alt\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: file.path)
        let sink = LoggerFileSink(url: file, maxBytes: 1_000)
        sink.append("neu\n") // darf weder abstürzen noch eine NSException werfen
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "alt\n")
    }

    func testWriteToUnwritableDirectoryDoesNotCrash() throws {
        let sub = directory.appendingPathComponent("ro-dir", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: sub.path)
        let sink = LoggerFileSink(url: sub.appendingPathComponent("x.log"), maxBytes: 1_000)
        sink.append("neu\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sub.path)
    }
}
