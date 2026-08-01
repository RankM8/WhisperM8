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
/// Feuert er spaeter, war der Main Thread in der Zwischenzeit blockiert. Kostet
/// zehn Timer-Ticks pro Sekunde — nichts. Deshalb laeuft er in Stufe 1, also
/// immer.
///
/// **Die gemessene Zahl ist eine Untergrenze, keine exakte Dauer.** Gemessen
/// wird die Verspaetung ab dem Solltermin des Ticks, nicht die Blockade selbst.
/// Beginnt eine Blockade kurz NACH einem Tick, faellt ein Teil von ihr in das
/// regulaere Intervall und wird nicht mitgezaehlt: eine 150-ms-Blockade, die
/// 1 ms nach einem Tick beginnt, erscheint als 51 ms. Der Monitor erfasst
/// deshalb je nach Phasenlage zuverlaessig erst Blockaden ab etwa 200 ms und
/// nennt sie um bis zu 100 ms zu kurz. Fuer den Zweck — „stand die App, und wie
/// schlimm" — reicht das; wer exakte Dauern braucht, misst mit Instruments.
///
/// **Uhr:** `DispatchTime` (mach_absolute_time), NICHT `Date`. Zwei Gruende:
/// Eine Wanduhr springt bei Zeitumstellung und NTP-Korrektur — vorwaerts ergaebe
/// das einen erfundenen Freeze, rueckwaerts eine negative Dauer, die jede
/// Meldung unterdrueckt. Und sie laeuft waehrend des Systemschlafs weiter: nach
/// 30 Minuten Deckel-zu meldete der Monitor brav ein „1.800.000 ms Einfrieren",
/// obwohl die App nichts blockiert hat. `DispatchTime` steht waehrend des
/// Schlafs still und misst genau das, was uns interessiert.
///
/// **Laufende Blockaden meldet ein zweiter Beobachter.** Der Timer oben kann
/// eine Blockade erst melden, wenn sie vorbei ist — er laeuft ja selbst auf dem
/// blockierten Thread. Bei einer Blockade, die NIE endet, schweigt er deshalb
/// vollstaendig. Genau das ist am 01.08.2026 passiert: Die App stand endlos im
/// SwiftUI-Layout, brannte 100 % CPU, und im Log fand sich zur Ursache keine
/// einzige Zeile. Deshalb setzt der Main-Timer zusaetzlich einen Herzschlag,
/// den ein `StallWatchdog` auf einer eigenen Queue beobachtet — der meldet,
/// WAEHREND die App steht, und eskaliert bei Verdopplung der Dauer.
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
    private var lastTick: TimeInterval?
    /// Beobachtet den Herzschlag von aussen — meldet WAEHREND einer Blockade.
    private let watchdog = StallWatchdog()
    /// Laengster Stillstand und deren Anzahl seit der letzten Zusammenfassung.
    private var worstStall: TimeInterval = 0
    private var stallCount = 0
    private var lastSummary: TimeInterval = 0
    /// Test-Hook: deterministische Uhr. Liefert Sekunden seit Systemstart
    /// (monoton, steht waehrend des Schlafs still) — nicht Wanduhrzeit.
    var now: () -> TimeInterval = {
        TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }
    /// Test-Hook: ersetzt das Logging. Parameter: Dauer in Sekunden.
    var onStall: ((TimeInterval) -> Void)?
    /// Test-Hook: Meldung einer noch LAUFENDEN Blockade (vom Watchdog).
    var onOngoingBlock: ((TimeInterval) -> Void)? {
        get { watchdog.onBlock }
        set { watchdog.onBlock = newValue }
    }

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
        watchdog.start()
        Logger.agentPerformance.info("main_thread_stall_monitor_started intervalMs=100 thresholdMs=100")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        lastTick = nil
        watchdog.stop()
    }

    /// Sichtbar fuer Tests — im Betrieb ruft nur der Timer.
    func tick() {
        let current = now()
        // Herzschlag fuer den Watchdog: Solange dieser Wert frisch bleibt,
        // reagiert der Main Thread. Bleibt er stehen, steht die App — und
        // zwar SICHTBAR, waehrend es passiert.
        watchdog.beat()
        defer { lastTick = current }
        guard let previous = lastTick else { return }

        // Verspaetung = tatsaechlicher Abstand minus Soll-Abstand. Untergrenze
        // der echten Blockade — Begruendung im Typ-Kommentar.
        let delay = (current - previous) - Self.interval
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
        guard current - lastSummary >= 60 else { return }
        lastSummary = current
        guard stallCount > 0 else { return }
        Logger.agentPerformance.info(
            "main_thread_stalls count=\(self.stallCount, privacy: .public) worstMs=\(Int(self.worstStall * 1000), privacy: .public) windowSec=60"
        )
        stallCount = 0
        worstStall = 0
    }
}
