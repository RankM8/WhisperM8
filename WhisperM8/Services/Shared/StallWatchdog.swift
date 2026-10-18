import Foundation
import os

/// Beobachtet den Herzschlag des Main Threads von einer EIGENEN Queue aus und
/// meldet eine Blockade, **waehrend** sie laeuft.
///
/// **Warum es das braucht:** `MainThreadStallMonitor` misst mit einem Timer auf
/// dem Main Thread. Der kann eine Blockade erst melden, wenn sie vorbei ist —
/// vorher kommt er ja nicht dran. Endet sie nie, schweigt er fuer immer. Genau
/// dieser Fall trat am 01.08.2026 ein: Die App stand endlos im SwiftUI-Layout
/// (100 % CPU, keine Reaktion), und im Log stand ab dem Zeitpunkt der Blockade
/// keine Zeile mehr — ausgerechnet das Messgeraet fuer Blockaden hat den
/// schlimmstmoeglichen Fall nicht erfasst.
///
/// **Verfahren:** Der Main Thread stempelt bei jedem Tick `beat()`. Ein
/// `DispatchSourceTimer` auf einer Hintergrund-Queue prueft viermal pro
/// Sekunde, wie alt der Stempel ist. Ueberschreitet das Alter die Schwelle,
/// wird gemeldet — und danach erst wieder bei VERDOPPLUNG der Dauer
/// (1 s, 2 s, 4 s, 8 s …). Ohne diese Staffelung wuerde eine endlose Blockade
/// das Log im Viertelsekundentakt fluten; mit ihr bleiben es rund zehn
/// Zeilen fuer zwei Minuten Stillstand.
///
/// Kosten: vier Timer-Ticks pro Sekunde auf einer Utility-Queue, die je einen
/// Zahlenvergleich unter einem Lock machen. Er laeuft deshalb immer mit.
final class StallWatchdog: @unchecked Sendable {
    /// Ab hier gilt eine laufende Blockade als meldenswert. Bewusst hoeher
    /// als die 100-ms-Ruckler-Schwelle des Monitors: Der Watchdog ist fuer
    /// „die App steht", nicht fuer „es hakt kurz".
    private static let threshold: TimeInterval = 1.0
    /// Pruefabstand. Feiner als die Schwelle, damit die erste Meldung nahe an
    /// der Sekunde liegt.
    private static let checkInterval: TimeInterval = 0.25

    private let lock = NSLock()
    private var lastBeat: TimeInterval = 0
    /// Dauer der letzten Meldung dieser Blockade — Grundlage der Staffelung.
    private var lastReported: TimeInterval?
    /// Stand beim LETZTEN Herzschlag: war die App verdeckt + inaktiv (App-Nap-
    /// Kandidat)? Der Main Thread stempelt das mit; während einer Blockade
    /// bleibt der letzte bekannte Zustand gültig (LR-SH-014).
    private var throttled = false
    private var timer: DispatchSourceTimer?

    /// Test-Hook: ersetzt das Logging. Parameter: bisherige Dauer in Sekunden.
    var onBlock: ((TimeInterval) -> Void)?
    /// Test-Hook: Meldung einer Verzögerung, während die App gedrosselt sein darf
    /// (verdeckt + inaktiv, App Nap) — KEIN Fehler, nur Hinweis.
    var onThrottledBlock: ((TimeInterval) -> Void)?
    /// Test-Hook: monotone Uhr (Sekunden seit Systemstart).
    var now: () -> TimeInterval = {
        TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    /// Entscheidet, ob eine laufende Blockade gemeldet wird. Rein und
    /// testbar: erste Meldung ab der Schwelle, danach bei jeder Verdopplung.
    static func shouldReport(elapsed: TimeInterval, lastReported: TimeInterval?) -> Bool {
        guard elapsed >= threshold else { return false }
        guard let lastReported else { return true }
        return elapsed >= lastReported * 2
    }

    /// Wie ein Fehlalarm-freier Alarm eingestuft wird: im gedrosselten Zustand
    /// (App verdeckt und inaktiv) zählt eine verspätete Timer-Zustellung nicht als
    /// Blockade, weil macOS Timer dann bewusst zusammenfasst. Pur + getestet.
    enum Severity: Equatable { case error, throttledHint }

    static func severity(appThrottled: Bool) -> Severity {
        appThrottled ? .throttledHint : .error
    }

    func beat(throttled: Bool = false) {
        let stamp = now()
        lock.lock()
        lastBeat = stamp
        self.throttled = throttled
        // Der Main Thread lebt wieder — die naechste Blockade meldet von vorn.
        lastReported = nil
        lock.unlock()
    }

    func start() {
        guard timer == nil else { return }
        beat()
        let queue = DispatchQueue(label: "com.whisperm8.stall-watchdog", qos: .utility)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.checkInterval, repeating: Self.checkInterval)
        timer.setEventHandler { [weak self] in self?.check() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
        lock.lock()
        lastReported = nil
        lock.unlock()
    }

    /// Sichtbar fuer Tests — im Betrieb ruft nur der Timer.
    func check() {
        let current = now()
        lock.lock()
        let elapsed = current - lastBeat
        let previous = lastReported
        let report = Self.shouldReport(elapsed: elapsed, lastReported: previous)
        if report { lastReported = elapsed }
        let severity = Self.severity(appThrottled: throttled)
        lock.unlock()

        guard report else { return }
        if severity == .throttledHint {
            if let onThrottledBlock {
                onThrottledBlock(elapsed)
            } else {
                // Kein Fehler-Level: sonst verfälscht App Nap die Messung
                // „kein main_thread_blocked_ongoing" (LR-SH-014).
                Logger.agentPerformance.notice(
                    "main_thread_delayed_throttled durationMs=\(Int(elapsed * 1000), privacy: .public)"
                )
            }
        } else if let onBlock {
            onBlock(elapsed)
        } else {
            // `error`-Level, weil genau diese Zeile im Nachhinein die Frage
            // beantwortet „ab wann stand die App?" — sie muss im Log stehen,
            // auch wenn niemand vorher Debug-Logging eingeschaltet hat.
            Logger.agentPerformance.error(
                "main_thread_blocked_ongoing durationMs=\(Int(elapsed * 1000), privacy: .public)"
            )
        }
    }
}
