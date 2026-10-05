import Darwin
import Foundation

/// Laufzeit-Messung für Budget-Tests.
///
/// Gemessen wird die CPU-Zeit des aufrufenden Threads, nicht die Wandzeit:
/// Unter hoher Systemlast (Load Average 30–100, viele parallele Builds und
/// Agent-Chats) misst die Wandzeit vor allem, wie lange der Testprozess auf
/// einen freien Kern wartet. So rissen `testVollerTailOhneTrefferBleibtInnerhalbDesBudgets`
/// (21–30 ms bei 20 ms Budget) und `testSehrGrosserVerlaufBleibtInnerhalbDesBudgets`
/// (7,9 s bei 5 s) ihre Budgets, obwohl sich am Code nichts geändert hatte
/// (04.–05.10.2026). Die Thread-CPU-Zeit bleibt unter Last stabil und fängt
/// trotzdem jede echte Regression (quadratische Schleife, Voll-Parse).
///
/// Nur für Code, der auf dem aufrufenden Thread rechnet — Arbeit auf anderen
/// Threads zählt hier nicht mit.
enum TestTiming {
    /// CPU-Sekunden, die `body` auf dem aufrufenden Thread verbraucht.
    static func threadCPUSeconds<T>(_ body: () throws -> T) rethrows -> (result: T, seconds: TimeInterval) {
        let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        let result = try body()
        let end = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        return (result, TimeInterval(end &- start) / 1_000_000_000)
    }
}
