import Darwin
import Foundation

/// Build-Kennung für den Vergleich App ↔ Router-Dienst: Version plus
/// Änderungszeit des Programms, einmal beim Prozessstart gelesen. So erkennt
/// die App nach `make dev` oder einem Update, dass der laufende Dienst aus
/// einem älteren Programm stammt, auch wenn die Versionsnummer gleich blieb.
enum ClaudeGPTRouterBuild {
    static let current: String = identifier(
        executable: Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]),
        info: Bundle.main.infoDictionary ?? [:]
    )

    static func identifier(executable: URL, info: [String: Any]) -> String {
        let version = info["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info["CFBundleVersion"] as? String ?? "0"
        var status = stat()
        let modified = stat(executable.path, &status) == 0 ? Int(status.st_mtimespec.tv_sec) : 0
        return "\(version)+\(build)@\(modified)"
    }
}

/// Resolver des Routers, wenn er als eigener Prozess läuft. In der App kommen
/// Profil-Ports, beförderte Profile und der Start fehlender Instanzen aus dem
/// Speicher des `ClaudeCodeProxyManager`; der Dienst liest dafür das
/// Proxy-Register und bittet die App über ihren Control-Socket um den Start.
enum ClaudeGPTRouterServiceEnvironment {
    /// Defaults-Domain der App (auch für die Test-Instanz mit eigener Bundle-ID).
    static func appPreferences() -> AppPreferences {
        AppPreferences(defaults: UserDefaults(suiteName: AppInstance.defaultsDomain) ?? .standard)
    }

    static func makeProductionRouter(
        register: ClaudeCodeProxyRegister = ClaudeCodeProxyRegister()
    ) -> ClaudeGPTMixRouter {
        let preferences = appPreferences()
        AppPreferences.shared = preferences
        let router = ClaudeGPTMixRouter(
            upstreamURLResolver: { upstream in
                switch upstream {
                case .codexProxy:
                    return URL(string: "http://127.0.0.1:\(AppPreferences.shared.claudeGPTBackendPort)")!
                case .anthropic:
                    return URL(string: "https://api.anthropic.com")!
                }
            },
            gptContextWindowResolver: { AppPreferences.shared.claudeGPTContextWindow },
            listenerKind: .bsdSockets
        )
        // Fehlt die Token-Datei noch, wird trotzdem erzwungen (ein Wert, den
        // niemand kennt) — `nil` hieße „kein Schutz“.
        let unmatchable = UUID().uuidString + UUID().uuidString
        router.authTokenResolver = {
            guard AppPreferences.shared.isGPTRouterAuthEnabled else { return nil }
            return ClaudeGPTRouterToken.shared.existing() ?? unmatchable
        }
        router.codexProxyURLResolver = { profile in
            guard let port = register.livePort(forProfile: profile) else { return nil }
            return URL(string: "http://127.0.0.1:\(port)")
        }
        router.promotedProfileResolver = { register.wasPromoted($0) }
        router.profileInstanceStarter = { requestProfileInstanceStart($0) }
        return router
    }

    // MARK: Start einer Profil-Instanz über die App

    private static let startLock = NSLock()
    nonisolated(unsafe) private static var lastStartRequest: [String: Date] = [:]
    static let startRequestInterval: TimeInterval = 5

    /// Bittet die App, die Proxy-Instanz eines Profils zu starten (503-Pfad).
    /// Je Profil höchstens alle fünf Sekunden, außerhalb der Router-Queue.
    static func requestProfileInstanceStart(_ profile: String) {
        startLock.lock()
        if let last = lastStartRequest[profile], Date().timeIntervalSince(last) < startRequestInterval {
            startLock.unlock()
            return
        }
        lastStartRequest[profile] = Date()
        startLock.unlock()
        DispatchQueue.global(qos: .utility).async {
            do {
                let response = try ChatsControlClient.send(
                    method: AgentControlRequestHandler.gptRouterStartProfileMethod,
                    params: ["profile": profile]
                )
                if !response.ok {
                    Logger.claudeGPTRouter.warning(
                        "gpt_router_service_profile_start_refused profile=\(profile, privacy: .public)"
                    )
                }
            } catch {
                Logger.claudeGPTRouter.warning(
                    "gpt_router_service_profile_start_unreachable profile=\(profile, privacy: .public)"
                )
            }
        }
    }

    // MARK: Modell-Liste des Proxys

    nonisolated(unsafe) private static var refreshTimer: DispatchSourceTimer?

    /// Der Dienst fragt die Modell-Liste des main-Proxys selbst ab (in der App
    /// macht das `ensureRunning`); danach alle fünf Minuten.
    static func startBackgroundRefresh(interval: TimeInterval = 300) {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now(), repeating: interval)
        timer.setEventHandler {
            ClaudeCodeProxyModelRegistry.shared.refresh(proxyPort: AppPreferences.shared.claudeGPTBackendPort)
        }
        timer.resume()
        refreshTimer = timer
    }
}
