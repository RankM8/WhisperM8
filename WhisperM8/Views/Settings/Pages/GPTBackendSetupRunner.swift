import Foundation

/// Orchestriert die Ein-Klick-Einrichtung des GPT-Backends als Schrittfolge
/// Binary → Proxy/Router → ChatGPT-Login. Pure Logik mit Closure-DI
/// (Projektkonvention) — die Settings-Seite liefert die echten Manager-Calls,
/// Tests liefern Spies. Der Device-Code-Login selbst bleibt beim Aufrufer:
/// er braucht User-Interaktion (Code + URL) und läuft asynchron weiter.
struct GPTBackendSetupRunner {
    enum Step: CaseIterable, Equatable {
        case binary
        case proxy
        case auth

        var title: String {
            switch self {
            case .binary: return "Proxy-Binary"
            case .proxy: return "Proxy & Router starten"
            case .auth: return "ChatGPT-Konto"
            }
        }
    }

    enum StepState: Equatable {
        case pending
        case running
        case ok(String)
        case failed(String)
    }

    /// Gesamtergebnis eines Durchlaufs.
    enum Outcome: Equatable {
        /// Alles läuft und der Account ist angemeldet.
        case ready
        /// Binary und Proxy laufen, aber der Device-Code-Login fehlt —
        /// der Aufrufer startet ihn und ruft danach erneut `run` auf.
        case needsDeviceLogin
        /// Ein Schritt ist gescheitert; Details stehen im StepState.
        case failed(Step)
    }

    var binaryResolver: () -> String? = {
        ClaudeCodeProxyManager.shared.resolvedBinaryPath()
    }
    /// Managed Download der known-good-Version, wenn kein Binary gefunden
    /// wird — liefert den installierten Pfad.
    var binaryInstaller: () async throws -> String = {
        try await ClaudeCodeProxyBinaryInstaller().installKnownGood().path
    }
    var proxyStarter: (Int) -> Result<Void, ClaudeCodeProxyError> = { port in
        ClaudeCodeProxyManager.shared.ensureRunning(port: port)
    }
    var authChecker: () -> ClaudeCodeProxyAuthStatus = {
        ClaudeCodeProxyManager.shared.authStatus()
    }

    /// Führt die Schritte sequenziell aus. `onStep` wird für jede
    /// Zustandsänderung gerufen (running → ok/failed) — die UI spiegelt
    /// das 1:1 als Schrittliste.
    func run(port: Int, onStep: (Step, StepState) -> Void) async -> Outcome {
        onStep(.binary, .running)
        let binaryPath: String
        if let resolved = binaryResolver() {
            binaryPath = resolved
        } else {
            // Kein PATH- und kein verwaltetes Binary → Managed Download der
            // gepinnten known-good-Version (Checksummen-verifiziert).
            do {
                binaryPath = try await binaryInstaller()
            } catch {
                onStep(.binary, .failed(
                    "Automatische Installation fehlgeschlagen: \(error.localizedDescription)"
                ))
                return .failed(.binary)
            }
        }
        onStep(.binary, .ok(binaryPath))

        onStep(.proxy, .running)
        if case .failure(let error) = proxyStarter(port) {
            onStep(.proxy, .failed(error.localizedDescription))
            return .failed(.proxy)
        }
        onStep(.proxy, .ok("Erreichbar auf Port \(port)"))

        onStep(.auth, .running)
        switch authChecker() {
        case .authenticated(let account, let expires):
            onStep(.auth, .ok("Angemeldet: \(account), Ablauf: \(expires)"))
            return .ready
        case .notAuthenticated:
            onStep(.auth, .failed("Nicht angemeldet — Device-Code-Login erforderlich."))
            return .needsDeviceLogin
        case .unknown:
            onStep(.auth, .failed("Auth-Status nicht ermittelbar (`codex auth status` prüfen)."))
            return .failed(.auth)
        }
    }
}
