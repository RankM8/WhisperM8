import XCTest
@testable import WhisperM8

final class CLIAudioExtractorTests: XCTestCase {
    private func makeExecutableScript(_ body: String, in directory: URL) throws -> URL {
        let script = directory.appendingPathComponent("fake-ffmpeg.sh")
        try ("#!/bin/sh\n" + body).write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    func testFFmpegFallbackDoesNotDeadlockOnLargeStdout() throws {
        let directory = try makeTempProjectDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = try makeExecutableScript("yes x | head -c 200000\nexit 0\n", in: directory)
        let source = directory.appendingPathComponent("input.bin")
        let destination = directory.appendingPathComponent("output.m4a")
        try Data().write(to: source)

        XCTAssertNoThrow(
            try FFmpegAudioExtractor.extract(
                ffmpegPath: script.path,
                from: source,
                to: destination
            )
        )
    }

    func testFFmpegRunnerDrainsCompleteLargeStderr() throws {
        let result = try FFmpegAudioExtractor.runProcess(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "yes e | head -c 200000 >&2; exit 7"]
        )

        XCTAssertEqual(result.exitCode, 7)
        XCTAssertEqual(result.stderr.utf8.count, 200_000)
    }

    func testFFmpegRunnerTerminatesAfterDeadline() throws {
        let started = Date()
        let result = try FFmpegAudioExtractor.runProcess(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["5"],
            timeout: 0.05
        )

        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }
}
