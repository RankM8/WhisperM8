import Foundation
import os

/// Misst, wie lange der Main Thread am Stueck NICHT reagiert hat.
///
/// **Warum das der wichtigste Messpunkt ist:** Alle anderen Budgets beantworten
/// „war diese Operation langsam?". Sie koennen aber nur melden, was jemand
/// vorher instrumentiert hat. Was ein Nutzer tatsaechlich spuert — „das Fenster
/// steht", „das Tippen hakt", „der Zug ruckelt" — ist immer dasselbe: Der Main
/// Thread war mit irgendetwas beschaeftigt und hat in der Zeit nicht gezeichnet.
/// Dieser Monitor misst genau das, unabhaengig davon, WER blockiert hat. Er
/// findet also auch Verursacher, an die niemand gedacht hat.
///
/// **Verfahren:** Ein Timer, der alle 100 ms auf dem Main Thread feuern soll.
/// Feuert er spaeter, war der Main Thread in der Zwischenzeit blockiert; die
/// Verspaetung IST die Blockadedauer. Kostet zehn Timer-Ticks pro Sekunde —
/// nichts. Deshalb laeuft er in Stufe 1, also immer.
///
/// **Was er nicht kann:** Er sagt nicht, WOMIT der Main Thread beschaeftigt
/// war. Dafuer sind die Signposts der einzelnen Budgets da — faellt beides in
/// dieselbe Zeitspanne, hat man Ursache und Wirkung beisammen. Bleibt ein
/// langer Stillstand ohne begleitende Budget-Warnung, ist das der Hinweis auf
/// eine Stelle, die noch niemand gemessen hat.
@MainActor
final class MainThreadStallMonitor {
    static let shared = MainThreadStallMonitor()

    /// Soll-Abstand der Ticks.
    private static let interval: TimeInterval = 0.1
    /// Ab dieser Verspaetung gilt es als Stillstand. 100 ms sind rund sechs
    /// ausgelassene Bilder bei 60 Hz — darunter faellt es nicht auf, darueber
    /// sichtbar.
    private static let stallThreshold: TimeInterval = 0.1
    /// Ab hier ist es kein Ruckler mehr, sondern ein Einfrieren.
    private static let freezeThreshold: TimeInterval = 1.0

    private var timer: Timer?
    private var lastTick: Date?
    /// Laengster Stillstand und deren Anzahl seit der letzten Zusammenfassung.
    private var worstStall: TimeInterval = 0
    private var stallCount = 0
    private var lastSummary = Date()
    /// Test-Hook: deterministische Uhr.
    var now: () -> Date = Date.init
    /// Test-Hook: ersetzt das Logging. Parameter: Dauer in Sekunden.
    var onStall: ((TimeInterval) -> Void)?

    private init() {}

    func start() {
        guard timer == nil else { return }
        lastTick = now()
        lastSummary = now()
        let timer = Timer(timeInterval: Self.interval, repeats: true) { _ in
            Task { @MainActor in MainThreadStallMonitor.shared.tick() }
        }
        // `.common` ist Pflicht: im Default-Mode schweigt der Timer waehrend
        // eines Menue- oder Fenster-Drags — also genau dann, wenn ein
        // Stillstand am ehesten auffaellt.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        Logger.agentPerformance.info("main_thread_stall_monitor_started intervalMs=100 thresholdMs=100")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        lastTick = nil
    }

    /// Sichtbar fuer Tests — im Betrieb ruft nur der Timer.
    func tick() {
        let current = now()
        defer { lastTick = current }
        guard let previous = lastTick else { return }

        // Verspaetung = tatsaechlicher Abstand minus Soll-Abstand.
        let delay = current.timeIntervalSince(previous) - Self.interval
        if delay >= Self.stallThreshold {
            stallCount += 1
            worstStall = max(worstStall, delay)

            // Ein Einfrieren wird sofort gemeldet, nicht erst in der
            // Zusammenfassung — sonst geht der Zusammenhang zu dem verloren,
            // was gerade davor im Log stand.
            if delay >= Self.freezeThreshold {
                if let onStall {
                    onStall(delay)
                } else {
                    Logger.agentPerformance.error(
                        "main_thread_freeze durationMs=\(Int(delay * 1000), privacy: .public)"
                    )
                }
            } else if let onStall {
                onStall(delay)
            }
        }

        // Einmal pro Minute zusammenfassen — nur wenn es etwas zu sagen gibt.
        guard current.timeIntervalSince(lastSummary) >= 60 else { return }
        lastSummary = current
        guard stallCount > 0 else { return }
        Logger.agentPerformance.info(
            "main_thread_stalls count=\(self.stallCount, privacy: .public) worstMs=\(Int(self.worstStall * 1000), privacy: .public) windowSec=60"
        )
        stallCount = 0
        worstStall = 0
    }
}
