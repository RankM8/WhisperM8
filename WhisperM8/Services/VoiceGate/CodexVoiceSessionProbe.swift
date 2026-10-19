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
    private let logScanner: CodexVoiceLogScanner

    init(
        gate: CodexVoiceSessionGate = CodexVoiceSessionGate(),
        logRoot: URL = AppInstance.home
            .appendingPathComponent("Library/Logs/\(CodexVoiceSessionProbe.codexBundleIdentifier)", isDirectory: true),
        now: @escaping () -> Date = Date.init,
        codexRunningProvider: (() -> Bool)? = nil,
        logScanner: CodexVoiceLogScanner = CodexVoiceLogScanner()
    ) {
        self.gate = gate
        self.logScanner = logScanner
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

    /// Juengster `realtime_session_started`-Eintrag aus den aktuellen
    /// Log-Ordnern.
    ///
    /// Codex benennt die Tagesordner nach UTC, waehrend WhisperM8 bisher nur
    /// das lokale Kalenderdatum geprueft hat. In positiven Zeitzonen war das
    /// Gate dadurch nach lokaler Mitternacht mehrere Stunden lang blind.
    /// Aktueller und vorheriger lokaler Tag decken beide UTC-Rollover ab.
    func lastRealtimeSessionStart() -> Date? {
        let logs = candidateLogDirectories()
            .flatMap { directory -> [URL] in
                guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
                    return []
                }
                return names.map { directory.appendingPathComponent($0, isDirectory: false) }
            }
            .filter { $0.pathExtension == "log" }
            .sorted { lhs, rhs in
                (modificationDate(of: lhs) ?? .distantPast) > (modificationDate(of: rhs) ?? .distantPast)
            }
            .prefix(12)

        var newest: Date?
        for log in logs {
            if let candidate = logScanner.newestSessionStart(in: log) {
                if newest == nil || candidate > newest! { newest = candidate }
            }
        }
        return newest
    }

    private func candidateLogDirectories() -> [URL] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let current = now()

        return [0, -1].compactMap { dayOffset in
            guard let date = calendar.date(byAdding: .day, value: dayOffset, to: current) else {
                return nil
            }
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            guard let year = parts.year, let month = parts.month, let day = parts.day else {
                return nil
            }
            let path = String(format: "%04d/%02d/%02d", year, month, day)
            let directory = logRoot.appendingPathComponent(path, isDirectory: true)
            return FileManager.default.fileExists(atPath: directory.path) ? directory : nil
        }
    }

    private func modificationDate(of url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    /// Nur das Ende der Datei lesen (Rückfall ohne Cache, siehe `CodexVoiceLogScanner`).
    /// Verlustfrei dekodiert: Ein am Schnitt geteiltes Umlaut-Zeichen machte mit
    /// `String(data:encoding:)` den ganzen Ausschnitt zu `nil` (LR-VG-002).
    static func readTail(of url: URL, maxBytes: Int = CodexVoiceLogScanner.maxTailBytes) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        guard let size = try? handle.seekToEnd() else { return nil }
        let offset = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd() else { return nil }
        return String(decoding: data, as: UTF8.self)
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

    fileprivate static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

/// Inkrementelle Log-Auswertung mit Cache je Datei (LR-VG-002): Die
/// Scharfschaltung prüft alle 10 s bis zu 12 Logs. Früher las jede Prüfung je
/// Datei bis zu 8 MiB neu und zerlegte sie in Zeilen. Jetzt gilt:
/// - unveränderte Datei (Größe und Änderungsdatum gleich): kein Lesezugriff;
/// - gewachsene Datei: nur der Zuwachs ab der letzten Größe, mit kleiner
///   Überlappung, damit eine beim letzten Mal halb geschriebene Zeile nicht verloren geht;
/// - geschrumpft oder neu: das Ende bis 8 MiB.
/// Gelesen wird als Bytes und verlustfrei dekodiert.
final class CodexVoiceLogScanner: @unchecked Sendable {
    /// 8 MiB halten den Session-Start auch dann im Fenster, wenn während eines
    /// langen Voice-Chats viele normale App-Logs folgen (64 KiB verloren ihn
    /// nach rund 50 Minuten).
    static let maxTailBytes = 8 * 1024 * 1024
    static let overlapBytes: UInt64 = 4 * 1024

    private struct Entry {
        var size: UInt64
        var modified: Date?
        var newest: Date?
    }

    private let readRange: (URL, UInt64) -> Data?
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    /// `readRange(url, offset)` liefert die Bytes ab `offset` bis zum Ende (Test-Naht).
    init(readRange: @escaping (URL, UInt64) -> Data? = CodexVoiceLogScanner.readFile) {
        self.readRange = readRange
    }

    func newestSessionStart(in url: URL) -> Date? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let rawSize = values.fileSize else { return nil }
        let size = UInt64(rawSize)
        let modified = values.contentModificationDate

        lock.lock()
        let cached = entries[url.path]
        lock.unlock()

        if let cached, cached.size == size, cached.modified == modified {
            return cached.newest
        }

        let tailStart = size > UInt64(Self.maxTailBytes) ? size - UInt64(Self.maxTailBytes) : 0
        var offset = tailStart
        var previous: Date?
        if let cached, size > cached.size {
            offset = max(tailStart, cached.size > Self.overlapBytes ? cached.size - Self.overlapBytes : 0)
            previous = cached.newest
        }

        guard let data = readRange(url, offset) else { return cached?.newest }
        let found = CodexVoiceSessionProbe.lastSessionStartTimestamp(inLogTail: String(decoding: data, as: UTF8.self))
        let newest = [previous, found].compactMap { $0 }.max()

        lock.lock()
        entries[url.path] = Entry(size: size, modified: modified, newest: newest)
        lock.unlock()
        return newest
    }

    static func readFile(_ url: URL, _ offset: UInt64) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        return try? handle.readToEnd()
    }
}
