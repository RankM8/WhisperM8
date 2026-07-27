import AppKit
import Foundation

// ==============================================================================
// Gate: Ist gerade ueberhaupt eine Codex-Sprachsitzung im Gange?
//
// Das ist der wirksamste Fehlalarm-Schutz — ausserhalb einer Voice-Session
// darf das Codewort gar nicht erst greifen.
//
// GRENZE, gemessen am 26.07.2026: Das Codex-Desktop-Log schreibt
// `realtime_session_started`, aber KEINEN Ende-Marker. Der Start ist damit
// zuverlaessig, das Ende nicht. Deshalb faellt die Schaerfe nach
// `maxSessionAge` von selbst ab, statt sich auf ein Ende zu verlassen.
// ==============================================================================

enum VoiceGateArmState: String, Equatable {
    /// Codex laeuft und eine Sprachsitzung ist plausibel aktiv.
    case armed
    case codexNotRunning
    case noRecentSession
    /// WhisperM8 nimmt gerade selbst auf — der Listener tritt zurueck, damit
    /// nicht zwei Engines um dasselbe Geraet konkurrieren.
    case pausedForDictation
}

/// Reine Entscheidung — ohne Dateizugriff, damit testbar.
struct CodexVoiceSessionGate {
    /// Wie lange ein `realtime_session_started` als „noch aktiv" gilt.
    ///
    /// Gemessen am 27.07.2026: Das Codex-Log schreibt WEDER einen Ende-Marker
    /// NOCH ein Lebenszeichen waehrend der Sitzung — zwischen Start (06:17) und
    /// laufendem Gespraech (06:55) steht nichts Realtime-Bezogenes. Eine kurze
    /// Frist laesst die Schaerfe deshalb mitten im Gespraech verfallen; genau
    /// das ist mit 30 Minuten passiert.
    ///
    /// Acht Stunden decken einen Arbeitstag ab. Geschlossen wird das Gate
    /// ohnehin zuverlaessig durch: Codex beendet, oder der Schalter in den
    /// Einstellungen — und der ist die eigentliche Kontrolle.
    var maxSessionAge: TimeInterval = 8 * 60 * 60

    func armState(codexRunning: Bool, lastSessionStart: Date?, now: Date) -> VoiceGateArmState {
        guard codexRunning else { return .codexNotRunning }
        guard let lastSessionStart else { return .noRecentSession }
        guard now.timeIntervalSince(lastSessionStart) <= maxSessionAge else {
            return .noRecentSession
        }
        return .armed
    }
}

/// Liest den Zustand von Platte und Prozessliste.
struct CodexVoiceSessionProbe {
    static let codexBundleIdentifier = "com.openai.codex"

    private let gate: CodexVoiceSessionGate
    private let logRoot: URL
    private let now: () -> Date
    private let codexRunningProvider: () -> Bool

    init(
        gate: CodexVoiceSessionGate = CodexVoiceSessionGate(),
        logRoot: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/\(CodexVoiceSessionProbe.codexBundleIdentifier)", isDirectory: true),
        now: @escaping () -> Date = Date.init,
        codexRunningProvider: (() -> Bool)? = nil
    ) {
        self.gate = gate
        self.logRoot = logRoot
        self.now = now
        self.codexRunningProvider = codexRunningProvider ?? {
            !NSRunningApplication.runningApplications(
                withBundleIdentifier: CodexVoiceSessionProbe.codexBundleIdentifier
            ).isEmpty
        }
    }

    /// Laeuft alle paar Sekunden — deshalb erst der billige Prozess-Check,
    /// und nur bei laufendem Codex ueberhaupt ins Log schauen.
    func currentArmState() -> VoiceGateArmState {
        guard codexRunningProvider() else { return .codexNotRunning }
        return gate.armState(
            codexRunning: true,
            lastSessionStart: lastRealtimeSessionStart(),
            now: now()
        )
    }

    // MARK: - Log-Auswertung

    /// Juengster `realtime_session_started`-Eintrag aus dem heutigen Log-Ordner.
    func lastRealtimeSessionStart() -> Date? {
        guard let directory = todaysLogDirectory() else { return nil }
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return nil }

        let logs = files
            .filter { $0.pathExtension == "log" }
            .sorted { lhs, rhs in
                (modificationDate(of: lhs) ?? .distantPast) > (modificationDate(of: rhs) ?? .distantPast)
            }
            .prefix(4)

        var newest: Date?
        for log in logs {
            guard let tail = Self.readTail(of: log) else { continue }
            if let candidate = Self.lastSessionStartTimestamp(inLogTail: tail) {
                if newest == nil || candidate > newest! { newest = candidate }
            }
        }
        return newest
    }

    private func todaysLogDirectory() -> URL? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.year, .month, .day], from: now())
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return nil }
        let path = String(format: "%04d/%02d/%02d", year, month, day)
        let directory = logRoot.appendingPathComponent(path, isDirectory: true)
        return FileManager.default.fileExists(atPath: directory.path) ? directory : nil
    }

    private func modificationDate(of url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    /// Nur das Ende der Datei lesen — die Logs werden mehrere hundert KB gross.
    static func readTail(of url: URL, maxBytes: Int = 64 * 1024) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        guard let size = try? handle.seekToEnd() else { return nil }
        let offset = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd() else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Sucht `realtime_session_started` und liest den ISO-Zeitstempel am
    /// Zeilenanfang (`2026-07-26T16:34:19.785Z info [AppServerConnection] …`).
    static func lastSessionStartTimestamp(inLogTail tail: String) -> Date? {
        var newest: Date?
        for line in tail.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.contains("realtime_session_started") else { continue }
            guard let stamp = line.split(separator: " ", maxSplits: 1).first else { continue }
            guard let date = isoFormatter.date(from: String(stamp)) else { continue }
            if newest == nil || date > newest! { newest = date }
        }
        return newest
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
