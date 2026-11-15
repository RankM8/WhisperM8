import Foundation
import os

/// Merkt sich, welche gemessenen Intervalle zuletzt auf dem Main Thread liefen
/// und welche gerade offen sind (WM8-101).
///
/// **Warum:** `main_thread_freeze` sagt nur, DASS der Main Thread stand, nicht
/// womit. Bisher musste man die Ursache aus den Zeilen davor erraten; am
/// 15.11.2026 blieben so 8 % der Hängerzeit ohne erkennbaren Anlass, und für
/// den größten Brocken (54 %, Chatwechsel) gab es nur Indizien. Mit diesem
/// Register nennt jede Hänger-Meldung die Intervalle, die in ihr Zeitfenster
/// fallen, und der Watchdog nennt, was während einer laufenden Blockade offen
/// ist.
///
/// **Kosten:** Ein Eintrag entsteht nur für Intervalle, die auf dem Main
/// Thread begannen. Je Intervall ein `Thread.isMainThread` und zwei kurze
/// Lock-Abschnitte (zusammen deutlich unter den ~686 ns des Signposts selbst).
/// Gespeichert werden nur Intervalle ab `minimumDuration`, in einem Ring fester
/// Größe; Namen bleiben `StaticString`, Strings entstehen erst beim Melden.
final class MainThreadIntervalLedger: @unchecked Sendable {
    static let shared = MainThreadIntervalLedger()

    struct Entry {
        let name: StaticString
        /// Sekunden seit Systemstart (dieselbe Uhr wie `MainThreadStallMonitor`).
        let start: TimeInterval
        let end: TimeInterval
        var duration: TimeInterval { end - start }
    }

    /// Kürzere Intervalle erklären keinen Hänger ab 1 s und würden den Ring
    /// nur mit Rauschen füllen (etwa `sidebar.modelBuild` bei jedem Body).
    static let minimumDuration: TimeInterval = 0.05
    /// Ein Hänger dauert selten länger als ein paar Sekunden; 32 Einträge
    /// reichen auch, wenn viele mittlere Intervalle hineinfallen.
    static let capacity = 32

    private let lock = OSAllocatedUnfairLock()
    private var ring: [Entry] = []
    private var nextSlot = 0
    private var open: [StaticString] = []

    func didBegin(_ name: StaticString) {
        lock.lock()
        open.append(name)
        lock.unlock()
    }

    /// Schließt ein offenes Intervall; `start`/`end` nur bei `end`, nicht bei
    /// `cancel` — ein verworfenes Intervall erklärt nichts.
    func didEnd(_ name: StaticString, start: TimeInterval?, end: TimeInterval?) {
        lock.lock()
        defer { lock.unlock() }
        if let index = open.lastIndex(where: { Self.same($0, name) }) {
            open.remove(at: index)
        }
        guard let start, let end, end - start >= Self.minimumDuration else { return }
        let entry = Entry(name: name, start: start, end: end)
        if ring.count < Self.capacity {
            ring.append(entry)
        } else {
            ring[nextSlot] = entry
        }
        nextSlot = (nextSlot + 1) % Self.capacity
    }

    /// Einträge, die sich mit dem Zeitfenster `[from, to]` überschneiden,
    /// längste zuerst.
    func entries(overlapping from: TimeInterval, _ to: TimeInterval) -> [Entry] {
        lock.lock()
        let snapshot = ring
        lock.unlock()
        return snapshot
            .filter { $0.end >= from && $0.start <= to }
            .sorted { $0.duration > $1.duration }
    }

    /// Namen der gerade offenen Intervalle, ältestes zuerst.
    func openNames() -> [String] {
        lock.lock()
        let snapshot = open
        lock.unlock()
        return snapshot.map { "\($0)" }
    }

    func reset() {
        lock.lock()
        ring = []
        nextSlot = 0
        open = []
        lock.unlock()
    }

    /// `name:ms,name:ms` für das Log; höchstens fünf Einträge, `-` wenn leer.
    static func describe(_ entries: [Entry]) -> String {
        guard !entries.isEmpty else { return "-" }
        return entries.prefix(5)
            .map { "\($0.name):\(Int(($0.duration * 1000).rounded()))" }
            .joined(separator: ",")
    }

    static func describe(openNames names: [String]) -> String {
        names.isEmpty ? "-" : names.joined(separator: ",")
    }

    private static func same(_ lhs: StaticString, _ rhs: StaticString) -> Bool {
        guard lhs.hasPointerRepresentation, rhs.hasPointerRepresentation else {
            return "\(lhs)" == "\(rhs)"
        }
        // Ein Budget lebt als `static let`, Begin und End teilen also denselben
        // Zeiger; der Vergleich bleibt damit ohne Allokation.
        return lhs.utf8Start == rhs.utf8Start
    }
}
