import XCTest
@testable import WhisperM8

/// LR-ONB-017: Das Login-Skript quotiert den aufgelösten Binary-Pfad.
final class CodexLoginScriptTests: XCTestCase {
    func testPathWithSpacesIsSingleQuoted() {
        let script = CodexStatusProbe.loginScript(codexPath: "/Volumes/Tools Suite/bin/codex")
        XCTAssertTrue(script.contains("'/Volumes/Tools Suite/bin/codex' login"), script)
    }

    func testApostropheIsEscaped() {
        let script = CodexStatusProbe.loginScript(codexPath: "/Users/o'brien/bin/codex")
        XCTAssertTrue(script.contains("'/Users/o'\\''brien/bin/codex' login"), script)
    }

    func testPlainPathStaysCallable() {
        let script = CodexStatusProbe.loginScript(codexPath: "/opt/homebrew/bin/codex")
        XCTAssertTrue(script.hasPrefix("#!/bin/zsh\n'/opt/homebrew/bin/codex' login"), script)
    }

    /// Das quotierte Skript führt den Pfad mit Leerzeichen und Apostroph wirklich aus.
    func testQuotedPathExecutesInRealShell() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("o'brien tools \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = dir.appendingPathComponent("codex")
        try "#!/bin/sh\necho ARGS:$@\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", "\(CodexStatusProbe.shellSingleQuoted(fake.path)) login"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertTrue(output.contains("ARGS:login"), output)
    }
}
