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
    /// Codewort-Steuerung der Codex-Sprachsitzung („Anna Pause"/„Anna weiter").
    /// Filter im `log stream` mit `category == "voice.gate"`. Erkannte Woerter
    /// werden nur mit dem ausdruecklichen Diagnose-Schalter protokolliert.
    static let voiceGate = os.Logger(subsystem: subsystem, category: "voice.gate")
    /// Gesprochene Ansagen der Agent-Chats (`whisperm8 speak`). Texte werden
    /// nie protokolliert, nur Längen und Entscheidungen.
    static let speechCallouts = os.Logger(subsystem: subsystem, category: "speech.callouts")

    // MARK: - Optional File Logging

    /// Rotiert ab 10 MB (eine Vorversion `.1`), schreibt nur per `write(contentsOf:)`.
    private static let fileSink: LoggerFileSink = {
        let logsDirectory = AppInstance.home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("WhisperM8", isDirectory: true)
        return LoggerFileSink(url: logsDirectory.appendingPathComponent("WhisperM8-debug.log"))
    }()

    private static var isFileLoggingEnabled: Bool {
        AppPreferences.shared.isDebugFileLoggingEnabled
    }

    /// Wie `debug`, aber auf `.info` — und damit im persistenten Log-Store,
    /// nicht nur im laufenden `log stream`.
    ///
    /// Der Unterschied ist im Ernstfall entscheidend: Nach dem Absturz vom
    /// 01.08.2026 (`installTapOnBus`, Format-Mismatch) liess sich nicht
    /// nachvollziehen, welches Format der Recorder geprueft hatte — die
    /// gesamte Spur lag auf `.debug` und war nach dem Absturz nicht mehr
    /// abrufbar. Fuer die wenigen Ereignisse, die einen Absturz erklaeren
    /// koennen, gehoert deshalb `info` genommen.
    /// Test-Naht: sammelt jede Meldung von `info`/`debug` (Guard-Tests „keine
    /// Inhalte im Log“). Nur in Tests gesetzt.
    nonisolated(unsafe) static var testSink: ((String) -> Void)?

    static func info(_ message: String) {
        testSink?(message)
        debugLog.info("\(message, privacy: .public)")

        #if DEBUG
        print("[WhisperM8] \(message)")
        #endif
    }

    static func debug(_ message: String) {
        testSink?(message)
        debugLog.debug("\(message, privacy: .public)")

        #if DEBUG
        print("[WhisperM8] \(message)")
        #endif

        guard isFileLoggingEnabled else { return }

        let timestamp = ISO8601DateFormatter().string(from: Date())
        fileSink.append("[\(timestamp)] \(message)\n")
    }

    static func clearDebugLog() {
        fileSink.clear()
        debug("=== Log cleared ===")
    }
}
