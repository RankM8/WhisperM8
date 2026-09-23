import Darwin
import Foundation

/// Hält die App am Leben, wenn irgendwo in eine Pipe oder einen Socket
/// geschrieben wird, dessen Gegenseite schon weg ist.
///
/// **Vorfall 23.09.2026, 20:45:** Die App verschwand mitten im Betrieb — kein
/// Crashreport, keine Logzeile, alle Chats weg. runningboardd meldete
/// `termination reported by launchd (2, 13, 13)`: Namespace 2 = Signal,
/// Code 13 = SIGPIPE. Die Default-Aktion von SIGPIPE beendet den Prozess
/// wortlos (kein Report, kein Backtrace); welcher Write es war, lässt sich
/// deshalb nachträglich nicht belegen. Kandidaten gibt es genug — jeder
/// stdin-Write an einen früh beendeten Kindprozess, jede Socket-Bibliothek
/// ohne `SO_NOSIGPIPE`. Einzelne Stellen abzusichern (so wie der Control-Server
/// es tut) schützt nur die bekannten.
///
/// **Warum ein Handler statt `SIG_IGN`:** Ein ignoriertes Signal bleibt über
/// `execve` ignoriert. SwiftTerm spawnt die Chats per `forkpty` + `execve`
/// ohne die Signale zurückzusetzen — jede Shell im Chat-Terminal liefe dann mit
/// ignoriertem SIGPIPE, und `yes | head` beendete `yes` nicht mehr per Signal,
/// sondern mit „Broken pipe"-Fehlern. Ein *abgefangenes* Signal setzt `execve`
/// dagegen auf Default zurück. Der Write selbst liefert in beiden Fällen
/// `EPIPE`, das die Aufrufer ohnehin behandeln.
///
/// Zusätzlich zählt eine Dispatch-Signalquelle (kqueue sieht jede Zustellung,
/// auch abgefangene) und schreibt `sigpipe_suppressed` ins Log — damit ist
/// beim nächsten Mal wenigstens der Zeitpunkt belegt.
enum SigpipeGuard {
    private static var source: DispatchSourceSignal?

    /// Einmal ganz am Anfang des GUI-Pfads aufrufen. Der CLI-Pfad bleibt
    /// bewusst beim Default: `whisperm8 chats list | head` soll wie jedes
    /// Unix-Tool per SIGPIPE enden.
    static func install() {
        guard source == nil else { return }
        installNoOpHandler()

        let signalSource = DispatchSource.makeSignalSource(
            signal: SIGPIPE,
            queue: .global(qos: .utility)
        )
        signalSource.setEventHandler { [weak signalSource] in
            let count = signalSource?.data ?? 0
            Logger.agentStore.error("sigpipe_suppressed count=\(count)")
        }
        signalSource.resume()
        source = signalSource
    }

    /// Nur der Handler, ohne Log-Quelle — für Tests und als eigentlicher Schutz.
    static func installNoOpHandler() {
        var action = sigaction()
        // Leerer Handler: nichts darin muss async-signal-safe sein.
        action.__sigaction_u.__sa_handler = { _ in }
        sigemptyset(&action.sa_mask)
        action.sa_flags = SA_RESTART
        sigaction(SIGPIPE, &action, nil)
    }
}
