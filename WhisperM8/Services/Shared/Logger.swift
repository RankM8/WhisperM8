import Foundation
import os.log

enum Logger {
    private static let subsystem = "com.whisperm8.app"

    static let paste = os.Logger(subsystem: subsystem, category: "AutoPaste")
    static let focus = os.Logger(subsystem: subsystem, category: "Focus")
    static let permission = os.Logger(subsystem: subsystem, category: "Permission")
    static let transcription = os.Logger(subsystem: subsystem, category: "Transcription")
    static let audio = os.Logger(subsystem: subsystem, category: "Audio")
    static let debugLog = os.Logger(subsystem: subsystem, category: "Debug")
    static let agentPerformance = os.Logger(subsystem: subsystem, category: "AgentPerformance")
    /// Persistenz-Telemetrie der Agent-Workspace-Datei (Datenverlust-Diagnose):
    /// Session-Erstellung, Flush, Load, Pruning. Filter im `log stream` mit
    /// `category == "agent.store"`.
    static let agentStore = os.Logger(subsystem: subsystem, category: "agent.store")
    static let terminalSnapshot = os.Logger(subsystem: subsystem, category: "terminal.snapshot")
    static let claudeBinding = os.Logger(subsystem: subsystem, category: "claude.binding")
    static let claudeRecovery = os.Logger(subsystem: subsystem, category: "claude.recovery")
    static let claudeGPTRouter = os.Logger(subsystem: subsystem, category: "claude.gpt-router")

    // MARK: - Optional File Logging

    private static let logFileURL: URL = {
        let logsDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("WhisperM8", isDirectory: true)
        return logsDirectory.appendingPathComponent("WhisperM8-debug.log")
    }()

    private static var isFileLoggingEnabled: Bool {
        AppPreferences.shared.isDebugFileLoggingEnabled
    }

    static func debug(_ message: String) {
        debugLog.debug("\(message, privacy: .public)")

        #if DEBUG
        print("[WhisperM8] \(message)")
        #endif

        guard isFileLoggingEnabled else { return }

        let timestamp = ISO8601DateFormatter().string(from: Date())
        let logLine = "[\(timestamp)] \(message)\n"

        if let data = logLine.data(using: .utf8) {
            try? FileManager.default.createDirectory(
                at: logFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

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

    static func clearDebugLog() {
        try? FileManager.default.removeItem(at: logFileURL)
        debug("=== Log cleared ===")
    }
}
