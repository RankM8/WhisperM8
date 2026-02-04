import Foundation
import os.log

enum Logger {
    private static let subsystem = "com.whisperm8.app"

    static let paste = os.Logger(subsystem: subsystem, category: "AutoPaste")
    static let focus = os.Logger(subsystem: subsystem, category: "Focus")
    static let permission = os.Logger(subsystem: subsystem, category: "Permission")
    static let transcription = os.Logger(subsystem: subsystem, category: "Transcription")

    // MARK: - File Logging (for debugging)

    private static let logFileURL: URL = {
        let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        return desktop.appendingPathComponent("WhisperM8-debug.log")
    }()

    /// Write debug message to file on Desktop for easy viewing
    static func debug(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let logLine = "[\(timestamp)] \(message)\n"

        // Also print to console (visible when running from Terminal)
        print("[WhisperM8] \(message)")

        // Append to file
        if let data = logLine.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logFileURL.path) {
                if let handle = try? FileHandle(forWritingTo: logFileURL) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                try? data.write(to: logFileURL)
            }
        }
    }

    /// Clear the debug log file
    static func clearDebugLog() {
        try? FileManager.default.removeItem(at: logFileURL)
        debug("=== Log cleared ===")
    }
}
