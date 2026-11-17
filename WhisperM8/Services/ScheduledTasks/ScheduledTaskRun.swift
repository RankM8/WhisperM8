import Foundation

// MARK: - Ein Lauf einer geplanten Aufgabe

/// Start-Eintrag eines Laufs (`run.json`). Die App schreibt ihn vor dem Start
/// und ergänzt PID und Prozess-Startzeit danach. Alles Weitere (Ergebnis,
/// Exit-Code) schreibt der Lauf selbst in seinen Ordner — so erkennt die App
/// ihn auch nach einem Neustart wieder.
struct ScheduledTaskRunRecord: Codable, Equatable {
    enum Trigger: String, Codable {
        /// Pünktlich zum Termin.
        case schedule
        /// Termin verpasst (Mac schlief, App war zu), nachgeholt.
        case catchUp
        /// Von Hand (`whisperm8 schedule run`).
        case manual
    }

    /// Warum ein Lauf nicht gestartet wurde. Dann gibt es keinen Chat.
    enum NotStarted: String, Codable {
        /// Termin zu lange her oder Nachholen aus.
        case missed
        /// Der vorige Lauf der Aufgabe arbeitete noch.
        case stillRunning
        case loginExpired
        case accountMissing
        case folderMissing
        case claudeMissing
        case launchFailed
    }

    var version: Int = 1
    var runID: String
    var taskID: UUID
    var taskName: String
    /// Sitzung des Laufs (`claude --session-id`), damit die App den Chat kennt,
    /// bevor er existiert.
    var sessionID: UUID?
    var account: String
    var directory: String
    var trigger: Trigger
    /// Termin, zu dem der Lauf gehört (bei `manual` keiner).
    var slot: Date?
    var createdAt: Date
    /// PID des Wrappers (`/bin/sh`), der `claude` startet und den Exit-Code schreibt.
    var pid: Int32?
    /// Startzeit des Wrappers — Schutz gegen eine wiederverwendete PID.
    var processStartedAt: Date?
    var notStarted: NotStarted?
    /// Klartext zu `notStarted` (etwa „Login von Zweitkonto abgelaufen“).
    var message: String?

    init(runID: String, taskID: UUID, taskName: String, sessionID: UUID?, account: String, directory: String,
         trigger: Trigger, slot: Date?, createdAt: Date, pid: Int32? = nil, processStartedAt: Date? = nil,
         notStarted: NotStarted? = nil, message: String? = nil) {
        self.runID = runID
        self.taskID = taskID
        self.taskName = taskName
        self.sessionID = sessionID
        self.account = account
        self.directory = directory
        self.trigger = trigger
        self.slot = slot
        self.createdAt = createdAt
        self.pid = pid
        self.processStartedAt = processStartedAt
        self.notStarted = notStarted
        self.message = message
    }

    /// Ordnername: UTC-Zeit plus Zufall, sortiert nach Zeit.
    static func makeRunID(now: Date, random: String = String(UUID().uuidString.lowercased().prefix(6))) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: now) + "-" + random
    }
}

/// Inhalt der Datei `exit`: „<Code> <Ende in Unix-Sekunden>“.
struct ScheduledTaskRunExit: Equatable {
    var code: Int32
    var endedAt: Date?

    init(code: Int32, endedAt: Date?) {
        self.code = code
        self.endedAt = endedAt
    }

    init?(parsing text: String) {
        let parts = text.split(whereSeparator: { $0.isWhitespace })
        guard let first = parts.first, let code = Int32(first) else { return nil }
        self.code = code
        endedAt = parts.count > 1 ? TimeInterval(parts[1]).map(Date.init(timeIntervalSince1970:)) : nil
    }
}

/// Was ein Lauf-Ordner enthält.
struct ScheduledTaskRunFiles: Equatable {
    static let recordName = "run.json"
    static let resultName = "result.json"
    static let stderrName = "stderr.log"
    static let exitName = "exit"

    var directory: URL
    var record: ScheduledTaskRunRecord
    var exit: ScheduledTaskRunExit?
    var result: Data?
    var stderrTail: String?
}

// MARK: - Ergebnis

/// Ergebnis eines Laufs, abgeleitet aus seinen Dateien.
enum ScheduledTaskRunOutcome: Equatable {
    /// Wird gerade gestartet (Login-Prüfung läuft).
    case starting
    case running
    case succeeded(summary: String?)
    /// Geklappt, aber Claude hat Werkzeuge verweigert, die nicht erlaubt waren.
    case succeededWithNotes(summary: String?, deniedTools: [String])
    case failed(message: String)
    /// Prozess weg ohne Exit-Datei (Mac neu gestartet, von Hand beendet).
    case aborted
    case notStarted(ScheduledTaskRunRecord.NotStarted, message: String?)

    var isActive: Bool {
        switch self {
        case .starting, .running: return true
        default: return false
        }
    }

    var isFailure: Bool {
        switch self {
        case .failed, .aborted: return true
        case .notStarted(let reason, _): return reason != .missed && reason != .stillRunning
        default: return false
        }
    }

    /// Kurztext für die CLI.
    var label: String {
        switch self {
        case .starting: return "startet"
        case .running: return "arbeitet"
        case .succeeded: return "geklappt"
        case .succeededWithNotes(_, let tools):
            return "geklappt mit Hinweis (\(tools.count) Werkzeug\(tools.count == 1 ? "" : "e") verweigert)"
        case .failed: return "fehlgeschlagen"
        case .aborted: return "abgebrochen"
        case .notStarted(let reason, _):
            switch reason {
            case .missed: return "verpasst"
            case .stillRunning: return "übersprungen, voriger Lauf arbeitete noch"
            case .loginExpired: return "nicht gestartet, Login abgelaufen"
            case .accountMissing: return "nicht gestartet, Konto fehlt"
            case .folderMissing: return "nicht gestartet, Ordner fehlt"
            case .claudeMissing: return "nicht gestartet, Claude nicht gefunden"
            case .launchFailed: return "nicht gestartet"
            }
        }
    }

    /// Zweite Zeile: letzter Satz, Fehlertext oder verweigerte Werkzeuge.
    var detail: String? {
        switch self {
        case .succeeded(let summary): return summary
        case .succeededWithNotes(let summary, let tools):
            return ["Verweigert: " + tools.joined(separator: ", "), summary].compactMap { $0 }.joined(separator: " · ")
        case .failed(let message): return message
        case .aborted: return "Der Prozess endete ohne Ergebnis (Mac neu gestartet oder beendet?)."
        case .notStarted(_, let message): return message
        case .starting, .running: return nil
        }
    }
}

enum ScheduledTaskRunEvaluator {
    /// Leitet das Ergebnis ab. `isProcessAlive` prüft PID samt Startzeit.
    static func outcome(of files: ScheduledTaskRunFiles,
                        isProcessAlive: (Int32, Date?) -> Bool) -> ScheduledTaskRunOutcome {
        let record = files.record
        if let reason = record.notStarted { return .notStarted(reason, message: record.message) }
        guard let exit = files.exit else {
            guard let pid = record.pid else { return .starting }
            return isProcessAlive(pid, record.processStartedAt) ? .running : .aborted
        }
        return finished(exitCode: exit.code, result: files.result, stderrTail: files.stderrTail)
    }

    /// Ein Lauf ohne PID, der älter ist als die Startfrist, ist beim Starten
    /// gestorben (App-Absturz zwischen Eintrag und Start).
    static func outcome(of files: ScheduledTaskRunFiles, now: Date, startGrace: TimeInterval = 120,
                        isProcessAlive: (Int32, Date?) -> Bool) -> ScheduledTaskRunOutcome {
        let base = outcome(of: files, isProcessAlive: isProcessAlive)
        if base == .starting, now.timeIntervalSince(files.record.createdAt) > startGrace { return .aborted }
        return base
    }

    static func finished(exitCode: Int32, result: Data?, stderrTail: String?) -> ScheduledTaskRunOutcome {
        let parsed = result.flatMap(parseResult)
        if exitCode == 0, let parsed, !parsed.isError {
            let summary = parsed.text.flatMap(lastSentence)
            return parsed.deniedTools.isEmpty
                ? .succeeded(summary: summary)
                : .succeededWithNotes(summary: summary, deniedTools: parsed.deniedTools)
        }
        if exitCode == 0, parsed == nil {
            // Exit 0 ohne lesbares JSON: kein Erfolg, den wir belegen können.
            return .failed(message: stderrTail.map(lastLine) ?? "Kein Ergebnis vom Lauf (Exit 0, result.json leer).")
        }
        let reason = parsed?.text.flatMap(lastSentence)
            ?? stderrTail.map(lastLine)
            ?? "Exit-Code \(exitCode)."
        return .failed(message: reason)
    }

    struct ParsedResult: Equatable {
        var isError: Bool
        var text: String?
        var deniedTools: [String]
    }

    /// Liest die Ausgabe von `claude -p --output-format json`. Steht mehr als
    /// ein JSON-Objekt in der Datei, zählt das letzte.
    static func parseResult(_ data: Data) -> ParsedResult? {
        let object: [String: Any]?
        if let whole = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            object = whole
        } else {
            object = String(decoding: data, as: UTF8.self)
                .split(whereSeparator: \.isNewline)
                .reversed()
                .lazy
                .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
                .first
        }
        guard let object else { return nil }
        let isError = (object["is_error"] as? Bool) ?? ((object["subtype"] as? String).map { $0 != "success" } ?? false)
        let denials = (object["permission_denials"] as? [Any]) ?? []
        var tools: [String] = []
        for denial in denials {
            let name = (denial as? [String: Any])?["tool_name"] as? String ?? "?"
            if !tools.contains(name) { tools.append(name) }
        }
        return ParsedResult(isError: isError, text: object["result"] as? String, deniedTools: tools)
    }

    /// Letzter Satz (höchstens 200 Zeichen), wie ihn die Übersicht zeigt.
    static func lastSentence(_ text: String) -> String? {
        let line = lastLine(text)
        guard !line.isEmpty else { return nil }
        return line.count > 200 ? String(line.prefix(199)) + "…" : line
    }

    static func lastLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last(where: { !$0.isEmpty }) ?? ""
    }

    /// PID lebt und gehört noch zum selben Prozess (Startzeit auf eine Sekunde).
    static func isProcessAlive(pid: Int32, startedAt: Date?) -> Bool {
        guard pid > 0, kill(pid, 0) == 0 || errno == EPERM else { return false }
        guard let startedAt else { return true }
        guard let actual = ProcessAncestry.startTime(for: pid) else { return false }
        return abs(actual.timeIntervalSince(startedAt)) < 1
    }
}
