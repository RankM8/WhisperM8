import Foundation

/// Wo der GPT-Router läuft.
enum ClaudeGPTRouterMode: Equatable {
    /// Wie bisher: `ClaudeGPTMixRouter.shared` im Prozess der App (`NWListener`).
    case inApp
    /// Eigener Prozess `WhisperM8 gpt-router`, überlebt App-Neustarts.
    case service

    static func resolve(restartKeepsChatsEnabled: Bool) -> ClaudeGPTRouterMode {
        restartKeepsChatsEnabled ? .service : .inApp
    }

    /// Einmal je App-Lauf festgelegt: Ein Umschalten des Labs-Schalters wirkt
    /// ab dem nächsten Start. Mitten im Lauf hielten sonst Router in App und
    /// Dienst denselben Port.
    static let current: ClaudeGPTRouterMode = resolve(
        restartKeepsChatsEnabled: AppPreferences.shared.isRestartKeepsChatsEnabled
    )
}

/// Weiche zwischen den beiden Router-Varianten für `ClaudeCodeProxyManager`.
/// Mit Modus `.inApp` ruft sie genau das, was der Manager vorher direkt rief.
final class ClaudeGPTRouterHost: @unchecked Sendable {
    static let shared = ClaudeGPTRouterHost()

    let mode: ClaudeGPTRouterMode
    private let inAppStart: (Int) -> Result<Void, Error>
    private let inAppStop: () -> Void
    private let supervisor: ClaudeGPTRouterServiceSupervisor
    private let portReaper: (Int) -> Bool
    private let deadControlSocket: (URL) -> Bool
    private let lock = NSLock()
    private var didRetireLeftoverService = false

    init(
        mode: ClaudeGPTRouterMode = .current,
        inAppStart: @escaping (Int) -> Result<Void, Error> = { ClaudeGPTMixRouter.shared.start(port: $0) },
        inAppStop: @escaping () -> Void = { ClaudeGPTMixRouter.shared.stop() },
        supervisor: ClaudeGPTRouterServiceSupervisor = .shared,
        portReaper: @escaping (Int) -> Bool = { ClaudeGPTRouterServiceReaper.freePortIfHeldByOrphanedService(port: $0) },
        deadControlSocket: @escaping (URL) -> Bool = { ClaudeGPTRouterServiceClient.controlSocketIsDead(root: $0) }
    ) {
        self.mode = mode
        self.inAppStart = inAppStart
        self.inAppStop = inAppStop
        self.supervisor = supervisor
        self.portReaper = portReaper
        self.deadControlSocket = deadControlSocket
    }

    func start(port: Int) -> Result<Void, Error> {
        switch mode {
        case .inApp:
            retireLeftoverServiceOnce(port: port)
            return inAppStart(port)
        case .service:
            return supervisor.ensureRunning(port: port)
        }
    }

    func stop() {
        switch mode {
        case .inApp: inAppStop()
        case .service: supervisor.stop()
        }
    }

    /// Schalter wieder aus, aber ein Dienst aus einem früheren Lauf hält den
    /// Port: Er schließt seinen Lauscher sofort (laufende Antworten laufen in
    /// ihm aus), dann bindet der Router in der App. Ohne Dienst kostet das
    /// einen Blick auf einen nicht vorhandenen Socket-Pfad, einmal je Lauf.
    private func retireLeftoverServiceOnce(port: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard !didRetireLeftoverService else { return }
        didRetireLeftoverService = true
        let root = supervisor.root
        guard ClaudeGPTRouterServiceClient.status(root: root) != nil else {
            // Dienst ohne erreichbaren Steuer-Socket (Ordner weg, hängt)?
            // Nur dann etwas tun, wenn der Port belegt ist.
            if !ClaudeCodeProxyManager.isPortFree(port), deadControlSocket(root) { _ = portReaper(port) }
            return
        }
        Logger.claudeGPTRouter.notice("gpt_router_service_retired_for_in_app_router")
        ClaudeGPTRouterServiceClient.shutdown(root: root)
        for _ in 0..<60 where !ClaudeCodeProxyManager.isPortFree(port) {
            Thread.sleep(forTimeInterval: 0.05)
        }
    }
}

/// Paket 4 setzt das vor einem Beenden mit Übergabe der Chats: Dann beendet
/// `willTerminate` weder Proxys noch Router-Dienst, sondern schreibt das
/// Proxy-Register, damit die neue App alles übernimmt. Nur im Dienst-Modus
/// wirksam (ein Router in der App stirbt ohnehin mit ihr).
enum ClaudeGPTBackendHandover {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var requested = false

    static var isRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return requested
    }

    static func setRequested(_ value: Bool) {
        lock.lock()
        requested = value
        lock.unlock()
    }
}
