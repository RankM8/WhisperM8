import Foundation
import os

/// Zaehler fuer Ereignisse, die zu dicht fuer einen Signpost sind.
///
/// **Warum es das braucht:** Ein os_signpost-Intervall kostet ~686 ns (Messung
/// 01.08.2026, M-Serie) — unabhaengig davon, ob Instruments laeuft. An einem
/// Pfad, der zehntausendmal pro Sekunde durchlaufen wird, waeren das Prozente
/// an CPU-Last, und die Messung verfaelschte genau das, was sie messen soll.
/// Ein Zaehler-Inkrement kostet dagegen ~1 ns.
///
/// Die Zaehler werden **einmal pro Sekunde** gesammelt ausgegeben. Aus 10.000
/// Ereignissen wird so ein einziger Log-Eintrag.
///
/// Alles hier ist an die Detail-Stufe gebunden (`PerfDetailGate`): ist sie aus
/// — der Normalfall —, kostet ein `count`-Aufruf einen Bool-Vergleich und
/// nichts weiter. Der periodische Timer laeuft dann gar nicht erst an.
///
/// **Thread-Sicherheit:** Inkremente sind mit einem `OSAllocatedUnfairLock`
/// serialisiert. Das ist der Grund, warum hier keine `os_signpost`-Emission
/// stattfindet: die Sperre soll so kurz wie irgend moeglich gehalten werden.
final class PerformanceCounters: Sendable {
    static let shared = PerformanceCounters()

    /// Was gezaehlt wird. Bewusst eine geschlossene Liste statt freier
    /// Strings — so kostet das Nachschlagen nichts und es gibt keine Tippfehler
    /// in Auswertungen.
    enum Event: Int, CaseIterable {
        /// Ein PTY-Datenpaket ist eingetroffen (vor der Buendelung).
        case terminalFeedChunk
        /// Ein gebuendelter Flush wurde an SwiftTerm durchgereicht.
        case terminalFeedFlush
        /// Eine Terminal-Pane wurde neu aufgebaut.
        case paneMounted
        /// Eine Terminal-Pane wurde abgebaut.
        case paneDismantled
        /// Das Grid hat sein Layout neu berechnet.
        case layoutSolved

        var label: String {
            switch self {
            case .terminalFeedChunk: return "feed.chunks"
            case .terminalFeedFlush: return "feed.flushes"
            case .paneMounted: return "pane.mounted"
            case .paneDismantled: return "pane.dismantled"
            case .layoutSolved: return "layout.solved"
            }
        }
    }

    /// Der gesamte veraenderliche Zustand liegt IN der Sperre — so ist er von
    /// jedem Thread aus erreichbar, ohne dass die Klasse an einen Actor
    /// gebunden werden muss. Genau das braucht ein Zaehler, der aus
    /// PTY-Callbacks ebenso gerufen wird wie aus dem Main Thread.
    private struct State {
        /// Summe pro Ereignis seit der letzten Ausgabe.
        var counts = [Int](repeating: 0, count: Event.allCases.count)
        /// Zusaetzliche Byte-Summen (nur fuer die Feed-Ereignisse sinnvoll).
        var bytes = [Int](repeating: 0, count: Event.allCases.count)
        /// Hoechststand des Rueckstaus, den die Buendelung gesehen hat.
        var pendingHighWaterMark = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    /// Der Timer gehoert dem Main Thread und wird nur dort angefasst.
    @MainActor private static var timer: Timer?

    private init() {}

    /// Startet die periodische Ausgabe — no-op, wenn die Detail-Stufe aus ist.
    /// Aufruf beim App-Start; mehrfacher Aufruf ist unschaedlich.
    @MainActor
    func startIfEnabled() {
        guard PerfDetailGate.isEnabled, Self.timer == nil else { return }
        let timer = Timer(timeInterval: 1.0, repeats: true) { _ in
            PerformanceCounters.shared.flush()
        }
        RunLoop.main.add(timer, forMode: .common)
        Self.timer = timer
        Logger.agentPerformance.info("perf_counters_started interval=1s")
    }

    @MainActor
    func stop() {
        Self.timer?.invalidate()
        Self.timer = nil
    }

    /// Zaehlt ein Ereignis. Im Normalbetrieb (Detail-Stufe aus) ist das ein
    /// Bool-Vergleich und ein Return — deshalb darf das hier auch in wirklich
    /// heissen Pfaden stehen.
    func count(_ event: Event, bytes byteCount: Int = 0) {
        guard PerfDetailGate.isEnabled else { return }
        state.withLock {
            $0.counts[event.rawValue] &+= 1
            $0.bytes[event.rawValue] &+= byteCount
        }
    }

    /// Meldet den aktuellen Rueckstau der Feed-Buendelung; behalten wird nur
    /// der Hoechststand seit der letzten Ausgabe.
    func reportPending(bytes pendingBytes: Int) {
        guard PerfDetailGate.isEnabled else { return }
        state.withLock {
            if pendingBytes > $0.pendingHighWaterMark {
                $0.pendingHighWaterMark = pendingBytes
            }
        }
    }

    /// Gibt die Summen der letzten Sekunde aus und setzt sie zurueck.
    /// Schweigt, wenn nichts passiert ist — sonst flutet ein ruhendes Fenster
    /// das Log mit Nullzeilen.
    private func flush() {
        let (snapshot, byteSnapshot, pending) = state.withLock { current -> ([Int], [Int], Int) in
            let result = (current.counts, current.bytes, current.pendingHighWaterMark)
            current = State()
            return result
        }

        guard snapshot.contains(where: { $0 > 0 }) else { return }

        var parts: [String] = []
        for event in Event.allCases where snapshot[event.rawValue] > 0 {
            let n = snapshot[event.rawValue]
            let b = byteSnapshot[event.rawValue]
            parts.append(b > 0 ? "\(event.label)=\(n) \(event.label).bytes=\(b)" : "\(event.label)=\(n)")
        }
        if pending > 0 {
            parts.append("feed.pendingPeak=\(pending)")
        }
        Logger.agentPerformance.info("perf_counters \(parts.joined(separator: " "), privacy: .public)")
    }
}
