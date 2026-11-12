import Darwin
import Foundation

// BSD-Socket-Lauscher des Mix-Routers (`ListenerKind.bsdSockets`), genutzt vom
// Router-Dienst `WhisperM8 gpt-router`. Die HTTP-Logik ist dieselbe wie beim
// Router in der App; dazu kommen Anhalten, Übernahme eines lauschenden
// Deskriptors und Auslaufen (Plan neustart-ohne-chatverlust.md, Paket 3).
extension ClaudeGPTMixRouter {
    /// Bindet 127.0.0.1:`port` und nimmt an.
    func startSocketListener(port: Int) -> Result<Void, Error> {
        if let running = lifecycleQueue.sync(execute: { socketListener != nil ? (requestedPort ?? port) : nil }) {
            return running == port || port == 0
                ? .success(())
                : .failure(ClaudeGPTMixRouterError.alreadyRunning(port: running))
        }
        let fd: Int32
        do {
            fd = try ClaudeGPTRouterSocketListener.bind(port: port)
        } catch {
            return .failure(ClaudeGPTMixRouterError.listenerFailed(error.localizedDescription))
        }
        return adoptListeningSocket(fd, requestedPort: port)
    }

    /// Übernimmt einen schon lauschenden Socket (Generationsübergabe). Der
    /// Deskriptor gehört danach dem Router, auch im Fehlerfall.
    func adoptListeningSocket(_ fd: Int32, requestedPort: Int? = nil) -> Result<Void, Error> {
        guard let boundPort = ClaudeGPTRouterSocketListener.listeningPort(of: fd) else {
            close(fd)
            return .failure(ClaudeGPTMixRouterError.listenerFailed(
                ClaudeGPTRouterSocketListener.ListenerError.notAListeningSocket.localizedDescription
            ))
        }
        let result: Result<ClaudeGPTRouterSocketListener, Error> = lifecycleQueue.sync {
            guard socketListener == nil else {
                return .failure(ClaudeGPTMixRouterError.alreadyRunning(port: self.requestedPort ?? boundPort))
            }
            generation &+= 1
            let startGeneration = generation
            var created: ClaudeGPTRouterSocketListener?
            let newListener = ClaudeGPTRouterSocketListener(
                fileDescriptor: fd,
                queue: DispatchQueue(label: "com.whisperm8.claude-gpt-router.socket-listener")
            ) { [weak self] clientFD in
                guard let self else {
                    close(clientFD)
                    return
                }
                let accepted = self.accept(
                    transport: ClaudeGPTRouterSocketTransport(fileDescriptor: clientFD)
                ) {
                    self.generation == startGeneration && self.socketListener === created
                }
                if !accepted {
                    // Der Transport schließt den Deskriptor in deinit.
                    Logger.claudeGPTRouter.notice("gpt_router_connection_rejected_stale_listener")
                }
            }
            created = newListener
            socketListener = newListener
            self.requestedPort = requestedPort ?? boundPort
            boundPortStorage = boundPort
            return .success(newListener)
        }
        switch result {
        case .success(let listener):
            listener.resume()
            return .success(())
        case .failure(let error):
            close(fd)
            return .failure(error)
        }
    }

    /// Deskriptor des lauschenden Sockets zum Weiterreichen per `SCM_RIGHTS`.
    /// Bleibt im Besitz des Routers; geschlossen wird er über
    /// `closeListenerKeepingConnections()`, erst nach dem `ACK` der Gegenseite.
    var listeningSocketDescriptor: Int32? {
        lifecycleQueue.sync { socketListener?.fileDescriptor }
    }

    /// Nimmt keine neuen Verbindungen mehr an, der Socket bleibt offen
    /// (wartende Verbindungen bleiben in der Warteschlange des Kernels).
    func pauseAccepting() {
        lifecycleQueue.sync { socketListener }?.pause()
    }

    func resumeAccepting() {
        lifecycleQueue.sync { socketListener }?.resume()
    }

    /// Schließt den lauschenden Socket, laufende Antworten laufen weiter
    /// (Auslaufen nach Übergabe oder beim Beenden des Dienstes).
    func closeListenerKeepingConnections() {
        let listener: ClaudeGPTRouterSocketListener? = lifecycleQueue.sync {
            generation &+= 1
            let current = socketListener
            socketListener = nil
            requestedPort = nil
            boundPortStorage = nil
            return current
        }
        listener?.close()
    }

    /// Angenommene, noch nicht beendete Client-Verbindungen.
    var activeConnectionCount: Int {
        lifecycleQueue.sync { connections.count }
    }
}
