import Darwin
import Foundation

// Leerlauf-Frist des Router-Dienstes (Entscheidung des Users vom 13.11.2026):
// Er beendet sich geordnet, wenn `idleLimit` lang keine App verbunden war und
// keine Anfrage lief. „Verbunden“ heißt: Die Aufsicht der App hält eine
// `attach`-Verbindung zum Steuer-Socket offen. Stirbt oder endet die App,
// schließt der Kernel diese Verbindung, die Uhr beginnt zu laufen.
// Anfragen überlebender Chats (etwa während einer Übergabe) zählen als
// Betrieb und halten den Dienst am Leben.
extension ClaudeGPTRouterService {
    /// Hält eine `attach`-Verbindung, bis die Gegenseite sie schließt.
    func holdAttachment(on client: Int32) {
        let count: Int = stateQueue.sync {
            attachedClients += 1
            lastBusyAt = Date()
            return attachedClients
        }
        log("app_attached count=\(count)")
        try? ClaudeGPTRouterWire.send(client, ["ok": true, "op": "attached"])
        // Ohne Frist warten: Nur das Ende der Verbindung zählt.
        ClaudeGPTRouterWire.setTimeout(client, 0)
        var byte: UInt8 = 0
        while true {
            let count = read(client, &byte, 1)
            if count > 0 { continue }
            if count < 0, errno == EINTR || errno == EAGAIN { continue }
            break
        }
        let remaining: Int = stateQueue.sync {
            attachedClients = max(0, attachedClients - 1)
            lastBusyAt = Date()
            return attachedClients
        }
        log("app_detached count=\(remaining)")
    }

    func startIdleWatch() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        let interval = max(0.01, configuration.idleCheckInterval)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in self?.checkIdle() }
        stateQueue.sync {
            idleTimer?.cancel()
            idleTimer = timer
            lastBusyAt = Date()
        }
        timer.resume()
    }

    /// Reine Entscheidung — unit-getestet.
    static func isIdleExpired(
        attached: Int,
        activeRequests: Int,
        lastBusyAt: Date,
        now: Date,
        idleLimit: TimeInterval
    ) -> Bool {
        attached == 0 && activeRequests == 0 && now.timeIntervalSince(lastBusyAt) >= idleLimit
    }

    private func checkIdle() {
        let active = router.activeConnectionCount
        let now = Date()
        let expired: Bool = stateQueue.sync {
            guard state == .serving else { return false }
            if attachedClients > 0 || active > 0 {
                lastBusyAt = now
                return false
            }
            return Self.isIdleExpired(
                attached: attachedClients, activeRequests: active,
                lastBusyAt: lastBusyAt, now: now, idleLimit: configuration.idleLimit
            )
        }
        guard expired else { return }
        log("idle_limit_reached minutes=\(Int(configuration.idleLimit / 60))")
        shutdown(reason: "idle")
    }
}
