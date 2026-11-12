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
    /// Ob die App einen Prozess gerade beendet, entscheidet sich erst jetzt.
    static func runningForegroundProcess(sessionID: String, in records: [ClaudeSessionRecord]) -> ClaudeSessionRecord? {
        runningForegroundProcess(
            sessionID: sessionID,
            records: records,
            isBeingTerminated: { ProcessTerminationLedger.shared.isBeingTerminated(pid: $0) }
        )
    }

    /// Abfrage in einem Schritt, für Aufrufer ohne vorbereitete Liste.
    static func liveLookup(sessionID: String) -> ClaudeSessionRecord? {
        runningForegroundProcess(sessionID: sessionID, in: liveForegroundRecords())
    }
}

/// Merkt sich Prozesse, denen die App gerade das Ende geschickt hat.
/// Ein Eintrag gilt für `window` Sekunden — genug für das Auslaufen nach
/// SIGTERM, kurz genug, dass eine wiederverwendete PID nicht dauerhaft als
/// „wird beendet“ durchgeht.
final class ProcessTerminationLedger: @unchecked Sendable {
    static let shared = ProcessTerminationLedger()

    private let lock = NSLock()
    private var entries: [Int32: Date] = [:]
    private let window: TimeInterval
    private let now: () -> Date

    init(window: TimeInterval = 30, now: @escaping () -> Date = Date.init) {
        self.window = window
        self.now = now
    }

    func noteTerminating(pid: Int32) {
        guard pid > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        let current = now()
        entries = entries.filter { current.timeIntervalSince($0.value) < window }
        entries[pid] = current
    }

    func isBeingTerminated(pid: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let noted = entries[pid] else { return false }
        return now().timeIntervalSince(noted) < window
    }
}
