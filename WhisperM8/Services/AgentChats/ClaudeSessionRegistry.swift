import Darwin
import Foundation

// MARK: - Claudes eigene Session-Registry

/// Status, den Claude Code selbst in `<config-dir>/sessions/<pid>.json`
/// schreibt — berechnet aus dem UI-Zustand seiner TUI, geschrieben nur bei
/// Änderung (belegt im Binary 2.1.302, Plan `claude-status-aus-registry.md`).
enum ClaudeRegistryStatus: String, Equatable, Sendable {
    /// Modell lädt/streamt ODER delegierte Arbeit läuft (Subagents,
    /// Hintergrund-Tasks).
    case busy
    /// Ein Dialog wartet auf den User; Grund in `waitingFor`.
    case waiting
    case idle
    /// Wie `idle`, aber eine Hintergrund-Shell läuft noch.
    case shell
}

/// Ein Eintrag der Registry, so wie Claude ihn schreibt. Unbekannte Felder
/// ignoriert der Parser, fehlende bleiben `nil` — das Format ist nicht
/// dokumentiert und darf sich unter uns bewegen.
struct ClaudeSessionRecord: Equatable, Sendable {
    /// WhisperM8-Profilname (`main` = `~/.claude`).
    var profileName: String
    var pid: Int32
    var sessionID: String
    var cwd: String?
    /// `interactive` | `bg` | … (roh).
    var kind: String?
    /// Nativer Name (`ListAgents`), z. B. `whisperm8-c6`.
    var name: String?
    /// Roh-Wert von `status` — `status` ist `nil`, wenn er unbekannt ist.
    var rawStatus: String?
    var status: ClaudeRegistryStatus?
    var waitingFor: String?
    var statusUpdatedAt: Date?
    var messagingSocketPath: String?
    /// Prozess-Startzeit in `ps -o lstart`-Form (`Sat Oct 17 10:12:17 2026`).
    var procStart: String?
    var version: String?
    /// `startedAt` (ms) — Start des Claude-Prozesses. Claude legt beim Start
    /// sein Team `session-<neue ID>` an, wenige Sekunden davor; darüber findet
    /// `AgentChatTaskDirectory.liveDirectory` den Task-Ordner.
    var startedAt: Date? = nil

    /// Adresse für `SendMessage({to: …})` über alle Konten.
    var messagingAddress: String? {
        guard let path = messagingSocketPath, !path.isEmpty else { return nil }
        return "uds:\(path)"
    }

    var isBackground: Bool { kind == "bg" }
}

/// Liest Claudes Registry aller Konten. Pur bis auf die injizierbaren
/// Datei- und Prozess-Zugriffe — dieselben Bausteine nutzen CLI
/// (`chats address`, `ChatsStatusProbe`) und App (`ClaudeRegistryStatusSource`).
enum ClaudeSessionRegistry {
    /// Ein Registry-Ordner samt Profil.
    struct Root: Equatable, Sendable {
        var profileName: String
        var url: URL
    }

    /// Prüft, ob die PID noch zu dem Prozess gehört, der den Eintrag schrieb.
    typealias LivenessCheck = @Sendable (_ pid: Int32, _ procStart: String?) -> Bool

    /// Registry-Dateien heißen `<pid>.json`; daneben liegen `<pid>.<hash>.key`.
    static func pid(fromFileName name: String) -> Int32? {
        guard name.hasSuffix(".json") else { return nil }
        let stem = name.dropLast(5)
        guard !stem.isEmpty, stem.allSatisfy(\.isNumber) else { return nil }
        return Int32(stem)
    }

    /// Alle Registry-Ordner: `main` (`~/.claude/sessions`) + jedes Profil.
    static func roots(profiles: ClaudeAccountProfiles = ClaudeAccountProfiles()) -> [Root] {
        profiles.profileNames().map { name in
            Root(profileName: name,
                 url: profiles.configDir(forProfile: name).appendingPathComponent("sessions", isDirectory: true))
        }
    }

    // MARK: Parser

    static func parse(data: Data, profileName: String) -> ClaudeSessionRecord? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let pid = (object["pid"] as? NSNumber)?.int32Value, pid > 0,
              let sessionID = object["sessionId"] as? String, !sessionID.isEmpty else { return nil }
        let rawStatus = object["status"] as? String
        return ClaudeSessionRecord(
            profileName: profileName,
            pid: pid,
            sessionID: sessionID,
            cwd: object["cwd"] as? String,
            kind: object["kind"] as? String,
            name: object["name"] as? String,
            rawStatus: rawStatus,
            status: rawStatus.flatMap(ClaudeRegistryStatus.init(rawValue:)),
            waitingFor: object["waitingFor"] as? String,
            statusUpdatedAt: (object["statusUpdatedAt"] as? NSNumber).map {
                Date(timeIntervalSince1970: $0.doubleValue / 1000)
            },
            messagingSocketPath: object["messagingSocketPath"] as? String,
            procStart: object["procStart"] as? String,
            version: object["version"] as? String,
            startedAt: (object["startedAt"] as? NSNumber).map {
                Date(timeIntervalSince1970: $0.doubleValue / 1000)
            }
        )
    }

    // MARK: Lesen

    /// Liest eine einzelne Registry-Datei; `nil` bei fehlender/kaputter Datei
    /// oder totem Besitzer.
    static func read(
        fileURL: URL,
        profileName: String,
        isAlive: LivenessCheck = ClaudeSessionRegistry.isProcessAlive
    ) -> ClaudeSessionRecord? {
        guard let data = try? Data(contentsOf: fileURL),
              let record = parse(data: data, profileName: profileName),
              isAlive(record.pid, record.procStart) else { return nil }
        return record
    }

    /// Alle lebenden Einträge aller Ordner.
    static func scan(
        roots: [Root],
        fileManager: FileManager = .default,
        isAlive: LivenessCheck = ClaudeSessionRegistry.isProcessAlive
    ) -> [ClaudeSessionRecord] {
        var records: [ClaudeSessionRecord] = []
        for root in roots {
            guard let names = try? fileManager.contentsOfDirectory(atPath: root.url.path) else { continue }
            for name in names where pid(fromFileName: name) != nil {
                if let record = read(fileURL: root.url.appendingPathComponent(name),
                                     profileName: root.profileName, isAlive: isAlive) {
                    records.append(record)
                }
            }
        }
        return records
    }

    /// Index Session-ID → Eintrag. Mehrere Prozesse mit derselben ID (kurz
    /// beim Resume) → der zuletzt aktualisierte gewinnt.
    static func indexBySessionID(_ records: [ClaudeSessionRecord]) -> [String: ClaudeSessionRecord] {
        var index: [String: ClaudeSessionRecord] = [:]
        for record in records {
            if let existing = index[record.sessionID],
               (existing.statusUpdatedAt ?? .distantPast) >= (record.statusUpdatedAt ?? .distantPast) {
                continue
            }
            index[record.sessionID] = record
        }
        return index
    }

    // MARK: Abbildung auf WhisperM8

    /// `busy` → working, `waiting` → awaitingInput, `idle`/`shell` → idle.
    /// Unbekannter oder fehlender Status → `nil` (keine Meinung).
    static func runtimeStatus(for record: ClaudeSessionRecord) -> AgentSessionRuntimeStatus? {
        switch record.status {
        case .busy: return .working
        case .waiting: return .awaitingInput
        case .idle, .shell: return .idle
        case nil: return nil
        }
    }

    // MARK: Prozess-Prüfung

    /// Lebt die PID, und ist es noch derselbe Prozess? Claude löscht seine
    /// Datei beim Beenden; nach SIGKILL bleibt sie liegen, und die PID kann
    /// später einem fremden Prozess gehören — deshalb der Startzeit-Vergleich,
    /// sobald `procStart` lesbar ist.
    @Sendable
    static func isProcessAlive(pid: Int32, procStart: String?) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) != 0 && errno != EPERM { return false }
        guard let procStart, let actual = processStartTime(pid: pid) else { return true }
        let candidates = parseProcStartCandidates(procStart)
        guard !candidates.isEmpty else { return true }
        // `lstart` hat Sekundenauflösung; großzügig gegen Rundung.
        return candidates.contains { abs(actual.timeIntervalSince($0)) < 2 }
    }

    /// Claude 2.1.302 schreibt `procStart` in UTC (gemessen 17.10.2026:
    /// `13:05:05` bei lokal `16:05:05` EEST). Weil das nirgends zugesagt ist,
    /// gelten UTC und lokale Zeit gleichermaßen als Treffer.
    static func parseProcStartCandidates(_ raw: String) -> [Date] {
        procStartLock.lock()
        defer { procStartLock.unlock() }
        // `procStart` ändert sich je Prozess nie — der DateFormatter ist der
        // teuerste Schritt des Scans, deshalb einmal je Wert.
        if let cached = procStartCache[raw] { return cached }
        let collapsed = raw.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        let dates = [TimeZone(identifier: "UTC")!, TimeZone.current].compactMap { zone in
            procStartFormatter.timeZone = zone
            return procStartFormatter.date(from: collapsed)
        }
        if procStartCache.count > 512 { procStartCache.removeAll() }
        procStartCache[raw] = dates
        return dates
    }
    nonisolated(unsafe) private static var procStartCache: [String: [Date]] = [:]

    private static let procStartFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return formatter
    }()
    private static let procStartLock = NSLock()

    /// Startzeit eines Prozesses per `sysctl` — kein Subprozess.
    static func processStartTime(pid: Int32) -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        guard start.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
    }
}
