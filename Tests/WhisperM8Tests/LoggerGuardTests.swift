import XCTest

/// LR-SH-015: Der Datei-Logger nutzt kein `FileHandle.write(_:)` — das wirft bei
/// ENOSPC/EPIPE eine NSException, die Swift nicht fängt (App + alle Chats weg).
final class LoggerGuardTests: XCTestCase {
    func testLoggerSourcesDoNotUseThrowingFreeFileHandleWrite() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for file in ["Logger.swift", "LoggerFileSink.swift"] {
            let url = root.appendingPathComponent("WhisperM8/Services/Shared/\(file)")
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for (index, line) in text.components(separatedBy: "\n").enumerated() {
                let code = line.components(separatedBy: "//").first ?? line
                XCTAssertFalse(
                    code.contains("handle.write(data)"),
                    "\(file):\(index + 1) nutzt FileHandle.write(_:) statt write(contentsOf:)"
                )
            }
        }
    }
}
