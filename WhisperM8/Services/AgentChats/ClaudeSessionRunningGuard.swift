import Darwin
import Foundation

/// Sperre gegen einen zweiten Prozess auf derselben Claude-Sitzung.
///
/// Vor jedem `claude --resume` fragt der Builder Claudes Registry
/// (`<config-dir>/sessions/<pid>.json`, alle Konten), ob die Sitzung schon in
/// einem lebenden Vordergrund-Prozess läuft — etwa in einem Terminal außerhalb
/// der App oder weil ein Chat einen Neustart der App überlebt hat. Zwei
/// Prozesse auf einer Sitzung schreiben abwechselnd in denselben Verlauf; das
/// ist der Fehler, den das Vorhaben „Neustart ohne Chatverlust“ unter allen
/// Umständen ausschließen muss (`docs/plans/neustart-ohne-chatverlust.md`).
///
/// Hintergrund-Worker (`kind: "bg"`) sind ausgenommen, die erledigt schon der
/// Attach-Fallback des Builders. Ebenso Prozesse, die die App selbst gerade
/// beendet: Beim Neustart eines Tabs startet der neue Prozess, während der
/// alte nach dem SIGTERM noch ausläuft — so war es immer, und das darf die
/// Sperre nicht verhindern.
enum ClaudeSessionRunningGuard {
    /// Der lebende Vordergrund-Prozess, der `sessionID` führt, oder `nil`.
    /// Pur: Einträge und Ausnahmen kommen von außen.
    static func runningForegroundProcess(
        sessionID: String,
        records: [ClaudeSessionRecord],
        isBeingTerminated: (Int32) -> Bool
    ) -> ClaudeSessionRecord? {
        records.first { record in
            !record.isBackground
                && record.sessionID.caseInsensitiveCompare(sessionID) == .orderedSame
                && !isBeingTerminated(record.pid)
        }
    }

    /// Alle lebenden Vordergrund-Einträge der Registry aller Konten. Liest
    /// Dateien und fragt Prozess-Startzeiten ab — nicht auf dem Main Thread
    /// aufrufen. Nur im App-Prozess: Unter `swift test` und in der CLI leer,
    /// damit kein Test von zufällig laufenden Claude-Prozessen abhängt.
    static func liveForegroundRecords() -> [ClaudeSessionRecord] {
        guard AppInstance.isAppBundleProcess else { return [] }
        return ClaudeSessionRegistry.scan(roots: ClaudeSessionRegistry.roots()).filter { !$0.isBackground }
    }

    /// Prüfung gegen eine vorher (abseits des Main Threads) gelesene Liste.
    /// Ob die App einen Prozess gerade beendet, entscheidet sich erst jetzt —
    /// und nur der auslaufende Vorgänger DESSELBEN Chats (`localID`) ist
    /// ausgenommen: Der Prozess eines anderen, gerade geschlossenen Chats auf
    /// derselben Sitzung schreibt noch und sperrt weiter.
    static func runningForegroundProcess(
        sessionID: String, in records: [ClaudeSessionRecord], localID: UUID? = nil
    ) -> ClaudeSessionRecord? {
        runningForegroundProcess(
            sessionID: sessionID,
            records: records,
            isBeingTerminated: { ProcessTerminationLedger.shared.isBeingTerminated(pid: $0, forLocalID: localID) }
        )
    }

    /// Abfrage in einem Schritt, für Aufrufer ohne vorbereitete Liste.
    static func liveLookup(sessionID: String) -> ClaudeSessionRecord? {
        runningForegroundProcess(sessionID: sessionID, in: liveForegroundRecords())
    }
}

extension ProcessStartTime {
    /// Startzeit in µs seit 1970, `nil` wenn der Prozess nicht mehr lesbar
    /// ist. Unterscheidet einen Prozess von einem späteren mit derselben PID.
    static func microseconds(pid: Int32) -> UInt64? {
        guard pid > 0 else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        guard start.tv_sec > 0 else { return nil }
        return UInt64(start.tv_sec) * 1_000_000 + UInt64(start.tv_usec)
    }
}

/// Merkt sich Prozesse, denen die App gerade das Ende geschickt hat.
/// Ein Eintrag gilt für `window` Sekunden — genug für das Auslaufen nach
/// SIGTERM, kurz genug, dass eine wiederverwendete PID nicht dauerhaft als
/// „wird beendet“ durchgeht.
final class ProcessTerminationLedger: @unchecked Sendable {
    static let shared = ProcessTerminationLedger()

    private struct Entry {
        let at: Date
        let localID: UUID?
        /// Startzeit des Prozesses (µs seit 1970): Eine PID kann binnen 24 h
        /// neu vergeben werden, dann darf der Eintrag nicht mehr passen.
        let startTime: UInt64?

        func matches(_ other: UInt64?) -> Bool {
            guard let startTime, let other else { return true }
            return startTime == other
        }
    }

    private let lock = NSLock()
    private var entries: [Int32: Entry] = [:]
    /// Wer welchen Prozess beendet hat, länger als `window` (für Meldungen:
    /// „der vorige Lauf dieses Chats endet noch“). Sperrt nichts.
    private var history: [Int32: Entry] = [:]
    private let historyWindow: TimeInterval = 24 * 60 * 60
    private let window: TimeInterval
    private let now: () -> Date
    private let startTimeOf: (Int32) -> UInt64?

    init(window: TimeInterval = 30, now: @escaping () -> Date = Date.init,
         startTimeOf: @escaping (Int32) -> UInt64? = { ProcessStartTime.microseconds(pid: $0) }) {
        self.window = window
        self.now = now
        self.startTimeOf = startTimeOf
    }

    /// `localID`: der Chat, dessen Prozess endet (für die Frage „eigener Vorgänger?“).
    func noteTerminating(pid: Int32, localID: UUID? = nil) {
        guard pid > 0 else { return }
        // Vor dem SIGTERM gelesen: Danach kann der Prozess schon weg sein.
        let startTime = startTimeOf(pid)
        lock.lock()
        defer { lock.unlock() }
        let current = now()
        let entry = Entry(at: current, localID: localID, startTime: startTime)
        entries = entries.filter { current.timeIntervalSince($0.value.at) < window }
        entries[pid] = entry
        history = history.filter { current.timeIntervalSince($0.value.at) < historyWindow }
        history[pid] = entry
    }

    /// Der Chat, dessen Prozess die App irgendwann (bis 24 h) beendet hat —
    /// auch nach Ablauf von `window`. Nur für die Zuordnung in Meldungen.
    /// Mit `startTime`: nur, wenn es noch derselbe Prozess ist (PID nicht neu vergeben).
    func formerOwner(of pid: Int32, startTime: UInt64? = nil) -> UUID? {
        lock.lock()
        defer { lock.unlock() }
        guard let noted = history[pid], now().timeIntervalSince(noted.at) < historyWindow,
              noted.matches(startTime) else { return nil }
        return noted.localID
    }

    /// Der Chat, dessen Prozess die App gerade beendet (nur mit vermerktem Chat).
    func owner(ofTerminating pid: Int32, startTime: UInt64? = nil) -> UUID? {
        lock.lock()
        defer { lock.unlock() }
        guard let noted = entries[pid], now().timeIntervalSince(noted.at) < window,
              noted.matches(startTime) else { return nil }
        return noted.localID
    }

    /// Mit `forLocalID` zählt nur der Prozess desselben Chats (oder einer
    /// ohne vermerkten Chat) als auslaufend.
    func isBeingTerminated(pid: Int32, forLocalID localID: UUID? = nil) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let noted = entries[pid], now().timeIntervalSince(noted.at) < window else { return false }
        guard let localID, let owner = noted.localID else { return true }
        return owner == localID
    }
}

/// Reservierung der Sitzungen, die die App gerade startet.
///
/// Die Registry kennt einen Prozess erst kurz nach dem Start (gemessen
/// 0,2 bis 1,2 s, `scripts/measure-claude-registry.py`). Starten zwei Chats
/// mit derselben Sitzungs-ID im selben Augenblick (Absturz-Wiederaufnahme,
/// Grid, Wiederherstellen), sieht keiner den anderen in der Registry, und
/// beide liefen auf einer Sitzung. Deshalb merkt sich die App, welcher Chat
/// eine ID gerade fortsetzt: Ein zweiter Chat bekommt sie für `window`
/// Sekunden nicht — danach steht der Prozess des ersten längst in der
/// Registry, und die Sperre dort greift. Bewusst ohne Freigabe beim
/// Prozessende: Gesperrt wird nur ein ANDERER Chat mit derselben ID, und den
/// gibt es nur nach einer Fehlbindung. Eine Freigabe träfe dagegen beim
/// Tab-Neustart die frische Reservierung desselben Chats (das Ende des alten
/// Prozesses kommt nach dem neuen Start an).
final class ClaudeSessionLaunchReservations: @unchecked Sendable {
    static let shared = ClaudeSessionLaunchReservations()

    private struct Entry {
        let localID: UUID
        let at: Date
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private let window: TimeInterval
    private let now: () -> Date

    init(window: TimeInterval = 30, now: @escaping () -> Date = Date.init) {
        self.window = window
        self.now = now
    }

    /// Reserviert `sessionID` für `localID`. Hält ein anderer Chat die ID
    /// noch, bleibt dessen Reservierung, und seine ID kommt zurück. Derselbe
    /// Chat darf neu reservieren (Neustart des Tabs).
    func reserve(sessionID: String, for localID: UUID) -> UUID? {
        let key = sessionID.lowercased()
        lock.lock()
        defer { lock.unlock() }
        let current = now()
        entries = entries.filter { current.timeIntervalSince($0.value.at) < window }
        if let holder = entries[key], holder.localID != localID {
            return holder.localID
        }
        entries[key] = Entry(localID: localID, at: current)
        return nil
    }
}
