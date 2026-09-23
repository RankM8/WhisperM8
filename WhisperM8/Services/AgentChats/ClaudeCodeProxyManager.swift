import AppKit
import Foundation

enum ClaudeCodeProxyError: LocalizedError, Equatable {
    case binaryMissing
    case startFailed(String)
    case notReachable(port: Int)
    case routerStartFailed(String)
    /// Das GPT-Konto-Profil hat keine eigene Auth-Datei — eine Instanz liefe
    /// sonst still auf dem Default-Konto (Fallback des Proxys).
    case profileNotLoggedIn(String)
    case noFreePort

    var errorDescription: String? {
        switch self {
        case .binaryMissing:
            return "Das Binary claude-code-proxy wurde nicht gefunden. Bitte den Proxy installieren und den PATH pruefen."
        case .startFailed(let reason):
            return "Der GPT-Proxy konnte nicht gestartet werden: \(reason)"
        case .notReachable(let port):
            return "Der GPT-Proxy ist nach dem Start auf 127.0.0.1:\(port) nicht erreichbar."
        case .routerStartFailed(let reason):
            return "Der GPT-Mix-Router konnte nicht gestartet werden: \(reason)"
        case .profileNotLoggedIn(let name):
            return "GPT-Konto „\(name)“ ist nicht angemeldet — bitte zuerst in den Einstellungen (GPT-Backend) anmelden."
        case .noFreePort:
            return "Kein freier Port fuer eine weitere GPT-Proxy-Instanz gefunden."
        }
    }
}

private final class ClaudeCodeProxyProbeDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // Eine Umleitung ist keine lokale Proxy-Signatur und darf die Probe
        // insbesondere nicht zu einem fremden HTTP-Ziel weitertragen.
        completionHandler(nil)
    }
}

private final class ClaudeCodeProxyProbeResult {
    private let lock = NSLock()
    private var storage = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func store(_ value: Bool) {
        lock.lock()
        storage = value
        lock.unlock()
    }
}

private final class ClaudeCodeProxyCommandOutput {
    private let lock = NSLock()
    private var storage = Data()

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func store(_ data: Data) {
        lock.lock()
        storage = data
        lock.unlock()
    }
}

/// Traegt einen Prozess-Handle in Completion-Closures, die vor dem Launch
/// erzeugt werden. Zugriff ausschliesslich unter dem processLock des Managers.
private final class ClaudeCodeProxyHandleBox {
    var value: ClaudeCodeProxyProcessHandle?
}

/// Ergebnis-Box fuer die Semaphore-Bruecke der Managed-Installation.
private final class ClaudeCodeProxyInstallOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Result<String, Error> = .failure(ClaudeCodeProxyError.binaryMissing)

    var value: Result<String, Error> {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func store(_ value: Result<String, Error>) {
        lock.lock()
        storage = value
        lock.unlock()
    }
}

enum ClaudeCodeProxyAuthStatus: Equatable {
    case authenticated(account: String, expires: String)
    case notAuthenticated
    case unknown
}

struct ClaudeCodeProxyCommandResult: Equatable {
    var exitCode: Int32
    var stdout: String
    var stderr: String
}

struct ClaudeCodeProxyDeviceCodeInfo: Equatable {
    var visitURL: String
    var code: String
}

enum ClaudeCodeProxyBinarySource: Equatable {
    /// Ueber `which` im Login-Shell-PATH gefunden (Homebrew, manuell).
    case path
    /// Managed Download in `~/Library/Application Support/WhisperM8/bin/`.
    case managed
}

/// Ein Proxy-Binary-Kandidat samt dem, was ueber ihn entscheidet: Version
/// (aus `--version`, mtime-gecacht) und ob er die Katalog-Allowlist kann.
struct ClaudeCodeProxyBinaryCandidate: Equatable {
    var path: String
    var source: ClaudeCodeProxyBinarySource
    var version: String?
    var supportsCatalogAllowlist: Bool

    var sourceLabel: String {
        switch source {
        case .path: return "PATH"
        case .managed: return "verwaltet"
        }
    }
}

/// Abstrakter Prozessgriff fuer den langlebigen Proxy. Tests koennen damit
/// Start und Stop beobachten, ohne einen echten Subprozess zu erzeugen.
final class ClaudeCodeProxyProcessHandle {
    private let isRunningResolver: () -> Bool
    private let terminateAction: () -> Void

    init(
        isRunning: @escaping () -> Bool,
        terminate: @escaping () -> Void
    ) {
        self.isRunningResolver = isRunning
        self.terminateAction = terminate
    }

    var isRunning: Bool { isRunningResolver() }

    func terminate() {
        terminateAction()
    }
}

/// Eine von WhisperM8 gestartete Proxy-Instanz fuer ein GPT-Konto-Profil.
struct ClaudeCodeProxyProfileInstance {
    var port: Int
    var process: ClaudeCodeProxyProcessHandle
}

/// Verwaltet ausschliesslich den von WhisperM8 gestarteten GPT-Proxy. Bereits
/// extern laufende Instanzen werden erkannt, aber niemals uebernommen/beendet.
/// Seit den GPT-Konto-Profilen zusaetzlich eine Instanz je Zusatzprofil
/// (`ensureRunning(profile:)`), jede mit eigenem `CCP_CONFIG_DIR` und Port.
final class ClaudeCodeProxyManager {
    static let shared = ClaudeCodeProxyManager()

    typealias ProcessLauncher = (
        _ executable: String,
        _ arguments: [String],
        _ environment: [String: String]
    ) throws -> ClaudeCodeProxyProcessHandle
    typealias CommandRunner = (
        _ executable: String,
        _ arguments: [String],
        _ environment: [String: String]
    ) throws -> ClaudeCodeProxyCommandResult
    typealias DeviceLoginLauncher = (
        _ executable: String,
        _ arguments: [String],
        _ environment: [String: String],
        _ onOutput: @escaping (String) -> Void,
        _ onCompletion: @escaping (Int32) -> Void
    ) throws -> ClaudeCodeProxyProcessHandle
    typealias RouterStarter = (_ port: Int) -> Result<Void, Error>
    typealias RouterStopper = () -> Void

    private let commandResolver: (String) -> String?

    private let managedBinaryResolver: () -> String?
    private let managedInstaller: () throws -> String
    private let reachabilityResolver: (Int) -> Bool
    private let processLauncher: ProcessLauncher
    private let commandRunner: CommandRunner
    private let deviceLoginLauncher: DeviceLoginLauncher
    private let routerStarter: RouterStarter
    private let routerStopper: RouterStopper
    private let routerPortResolver: () -> Int
    private let agentDefinitionSyncer: () -> Void
    private let environmentResolver: () -> [String: String]
    private let sleepResolver: (TimeInterval) -> Void
    private let retryAttempts: Int
    private let retryDelay: TimeInterval
    private let notificationCenter: NotificationCenter
    private let ensureLock = NSLock()
    private let processLock = NSLock()
    private var selfStartedProcess: ClaudeCodeProxyProcessHandle?
    private var deviceLoginProcess: ClaudeCodeProxyProcessHandle?
    private var terminateObserver: NSObjectProtocol?
    /// `--version`-Ergebnis pro Binary-Pfad, gueltig solange die mtime gleich
    /// bleibt — resolvedBinary() laeuft bei jedem Status-Refresh, Chat-Start
    /// und Auth-Check; ein Subprozess pro Aufruf waere zu teuer.
    private let versionCacheLock = NSLock()
    private var versionCache: [String: (modified: Date?, version: String?)] = [:]
    /// Die automatische Fork-Installation laeuft hoechstens einmal pro
    /// App-Lauf — ein blockierter Download darf nicht jeden Chat-Start
    /// erneut Sekunden kosten. Der Setup-Wizard installiert unabhaengig davon.
    private var didAttemptManagedInstall = false
    private(set) var lastManagedInstallError: String?

    /// Env-Overrides eines GPT-Konto-Profils (`CCP_CONFIG_DIR`) fuer
    /// Auth-Status, Device-Login und (ab Slice 2) den Proxy-Start. `nil`/main
    /// → leeres Dict, der Proxy nimmt seinen Default-Store. Injizierbar, damit
    /// Tests ohne `~/.gpt-profiles` auskommen.
    var profileEnvironmentResolver: (String?) -> [String: String] = { profile in
        // Kill-Switch aus → main laeuft wie frueher ohne Variable (Keychain-
        // Modus des Proxys); Zusatzprofile gibt es dann ohnehin nicht.
        if ClaudeCodeProxyManager.isMainProfile(profile), !AppPreferences.shared.isGPTAccountProfilesEnabled {
            return [:]
        }
        return GPTAccountProfiles().environmentOverrides(forProfile: profile)
    }

    /// Die im Profil gespeicherte `accountId` (Datei-Beleg) — Grundlage des
    /// Fallback-Guards in `authStatus(profile:)`. `nil` = keine eigene
    /// Auth-Datei. Fuer main nicht benoetigt (Default-Store ist der Fallback
    /// selbst).
    var storedAccountIDResolver: (String?) -> String? = { profile in
        guard let profile, profile != GPTAccountProfiles.mainProfileName else { return nil }
        return GPTAccountProfiles().storedAccountID(forProfile: profile)
    }

    /// Kill-Switch der Konto-Profile: aus → jedes Profil wird wie main
    /// behandelt (ein Proxy, ein Konto).
    var profilesEnabledResolver: () -> Bool = { AppPreferences.shared.isGPTAccountProfilesEnabled }

    /// Port des main-Proxys (Default-Store). Zusatzprofile bekommen Ports
    /// oberhalb davon (`profilePortRangeStart`).
    var mainPortResolver: () -> Int = { AppPreferences.shared.claudeGPTBackendPort }

    /// Ist der Port lokal noch frei? Default: Bind-Probe auf 127.0.0.1.
    var portAvailabilityResolver: (Int) -> Bool = { ClaudeCodeProxyManager.isPortFree($0) }

    /// Abstand zum main-Port, ab dem Profil-Instanzen Ports bekommen — genug
    /// Luft fuer den Router (main + 1) und manuelle Zweitinstanzen.
    static let profilePortOffset = 10
    static let profilePortSearchWidth = 40

    /// Laufende Instanzen je Zusatzprofil (main lebt in `selfStartedProcess`
    /// bzw. extern). Zugriff nur unter `processLock`; der Start selbst ist
    /// ueber `ensureLock` serialisiert wie bei main.
    private var profileInstances: [String: ClaudeCodeProxyProfileInstance] = [:]

    init(
        commandResolver: @escaping (String) -> String? = { AgentCommandBuilder.commandPath($0) },
        managedBinaryResolver: @escaping () -> String? = {
            let managed = ClaudeCodeProxyBinaryInstaller().binaryURL
            return FileManager.default.isExecutableFile(atPath: managed.path) ? managed.path : nil
        },
        managedInstaller: @escaping () throws -> String = {
            try ClaudeCodeProxyManager.installKnownGoodBlocking()
        },
        reachabilityResolver: @escaping (Int) -> Bool = { ClaudeCodeProxyManager.isReachable(port: $0) },
        processLauncher: @escaping ProcessLauncher = ClaudeCodeProxyManager.launchProcess,
        commandRunner: @escaping CommandRunner = {
            try ClaudeCodeProxyManager.runCommand(executable: $0, arguments: $1, environment: $2)
        },
        deviceLoginLauncher: @escaping DeviceLoginLauncher = ClaudeCodeProxyManager.launchDeviceLogin,
        routerStarter: @escaping RouterStarter = { ClaudeGPTMixRouter.shared.start(port: $0) },
        routerStopper: @escaping RouterStopper = { ClaudeGPTMixRouter.shared.stop() },
        routerPortResolver: @escaping () -> Int = { AppPreferences.shared.claudeGPTRouterPort },
        agentDefinitionSyncer: @escaping () -> Void = {
            ClaudeGPTAgentDefinitionInstaller().syncFromPreferences()
        },
        environmentResolver: @escaping () -> [String: String] = {
            LoginShellEnvironment.shared.processEnvironment()
        },
        sleepResolver: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        retryAttempts: Int = 30,
        retryDelay: TimeInterval = 0.1,
        notificationCenter: NotificationCenter = .default
    ) {
        self.commandResolver = commandResolver
        self.managedBinaryResolver = managedBinaryResolver
        self.managedInstaller = managedInstaller
        self.reachabilityResolver = reachabilityResolver
        self.processLauncher = processLauncher
        self.commandRunner = commandRunner
        self.deviceLoginLauncher = deviceLoginLauncher
        self.routerStarter = routerStarter
        self.routerStopper = routerStopper
        self.routerPortResolver = routerPortResolver
        self.agentDefinitionSyncer = agentDefinitionSyncer
        self.environmentResolver = environmentResolver
        self.sleepResolver = sleepResolver
        self.retryAttempts = retryAttempts
        self.retryDelay = retryDelay
        self.notificationCenter = notificationCenter

        terminateObserver = notificationCenter.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.stopIfSelfStarted()
            self?.stopAllProfileInstances()
            self?.stopDeviceLogin()
        }
    }

    deinit {
        if let terminateObserver {
            notificationCenter.removeObserver(terminateObserver)
        }
    }

    func isReachable(port: Int) -> Bool {
        reachabilityResolver(port)
    }

    func ensureRunning(port: Int) -> Result<Void, ClaudeCodeProxyError> {
        // Zwei gleichzeitige Chat-Starts duerfen nicht zwei Proxy-Prozesse
        // oder Router-Listener erzeugen. Beide Lifecycle-Schritte werden als
        // atomare Startsequenz serialisiert: zuerst Proxy, dann Router.
        ensureLock.lock()
        defer { ensureLock.unlock() }

        var processStartedForThisAttempt: ClaudeCodeProxyProcessHandle?
        if !isReachable(port: port) {
            // Ein registrierter, aber nicht mehr gesunder Prozess darf weder
            // weiterleben noch durch einen neuen Handle verdeckt werden.
            replaceSelfStartedProcess(with: nil)

            guard let binary = catalogCapableBinaryInstallingIfNeeded() else {
                return .failure(.binaryMissing)
            }
            let executable = binary.path

            let process: ClaudeCodeProxyProcessHandle
            do {
                // main mit CCP_CONFIG_DIR auf dem Default-Store (Datei-Modus,
                // siehe GPTAccountProfiles.environmentOverrides).
                var environment = environment(forProfile: nil)
                // Die Tier-Env des Proxy hat Vorrang vor jedem Modell-Alias
                // und wuerde damit Toggle, plain /model sowie den guenstigen
                // Haiku-Ersatz global ueberstimmen. Ein bewusster Override in
                // der Proxy-Konfiguration oder einem externen Prozess bleibt.
                if environment.removeValue(forKey: "CCP_CODEX_SERVICE_TIER") != nil {
                    Logger.agentStore.warning(
                        "claude_code_proxy_inherited_service_tier_removed key=CCP_CODEX_SERVICE_TIER"
                    )
                }
                // Die echte Loopback-Garantie liefert das Binary selbst: der
                // raine-Proxy bindet hart auf 127.0.0.1 (verifiziert per lsof;
                // `serve` kennt keinen --host/--bind-Flag). CCP_BIND_ADDRESS
                // setzen wir nur als Defense-in-Depth — falls eine kuenftige
                // Version oder ein alternativer Proxy die Variable auswertet,
                // erzwingt sie ebenfalls loopback statt 0.0.0.0.
                environment["CCP_BIND_ADDRESS"] = "127.0.0.1"
                process = try processLauncher(
                    executable,
                    ["serve", "--no-monitor", "--port", String(port)],
                    environment
                )
            } catch {
                return .failure(.startFailed(error.localizedDescription))
            }

            replaceSelfStartedProcess(with: process)
            processStartedForThisAttempt = process

            var becameReachable = false
            for _ in 0..<max(0, retryAttempts) {
                if isReachable(port: port) {
                    becameReachable = true
                    break
                }
                sleepResolver(retryDelay)
            }

            if !becameReachable, !isReachable(port: port) {
                discardSelfStartedProcess(process)
                return .failure(.notReachable(port: port))
            }
        }

        switch routerStarter(routerPortResolver()) {
        case .success:
            // Backend ist einsatzbereit → verwaltete `gpt`-Agent-Definition
            // abgleichen (idempotent; ein Read + Vergleich im Normalfall).
            agentDefinitionSyncer()
            return .success(())
        case .failure(let error):
            if let processStartedForThisAttempt {
                discardSelfStartedProcess(processStartedForThisAttempt)
            }
            return .failure(.routerStartFailed(error.localizedDescription))
        }
    }

    // MARK: - Instanz je GPT-Konto-Profil

    /// Stellt sicher, dass fuer das Profil einer Session ein Proxy laeuft und
    /// der Router steht. `nil`/main (oder Kill-Switch aus) → der bekannte
    /// main-Pfad. Zusatzprofil → eigene Instanz mit `CCP_CONFIG_DIR` auf einem
    /// eigenen Port; laeuft sie schon und antwortet, wird sie wiederverwendet.
    /// Ein Profil ohne eigene Auth-Datei wird NIE gestartet — die Instanz
    /// liefe sonst still auf dem Default-Konto.
    func ensureRunning(profile: String?) -> Result<Void, ClaudeCodeProxyError> {
        guard profilesEnabledResolver(), !Self.isMainProfile(profile), let profile else {
            return ensureRunning(port: mainPortResolver())
        }

        ensureLock.lock()
        defer { ensureLock.unlock() }

        guard storedAccountIDResolver(profile) != nil else {
            return .failure(.profileNotLoggedIn(profile))
        }
        let profileEnvironment = profileEnvironmentResolver(profile)
        guard profileEnvironment[GPTAccountProfiles.configDirEnvironmentKey] != nil else {
            // Verzeichnis weg (Profil entfernt) — kein stiller main-Fallback.
            return .failure(.profileNotLoggedIn(profile))
        }

        processLock.lock()
        let existing = profileInstances[profile]
        processLock.unlock()

        var processStartedForThisAttempt: ClaudeCodeProxyProcessHandle?
        if let existing, existing.process.isRunning, isReachable(port: existing.port) {
            // wiederverwenden
        } else {
            if let existing {
                // Registriert, aber nicht mehr gesund: weg damit, bevor ein
                // neuer Handle ihn verdeckt.
                discardProfileInstance(profile, expecting: existing.process)
            }
            guard let binary = catalogCapableBinaryInstallingIfNeeded() else {
                return .failure(.binaryMissing)
            }
            guard let port = allocateProfilePort() else {
                return .failure(.noFreePort)
            }

            let process: ClaudeCodeProxyProcessHandle
            do {
                var environment = environment(forProfile: profile)
                if environment.removeValue(forKey: "CCP_CODEX_SERVICE_TIER") != nil {
                    Logger.agentStore.warning(
                        "claude_code_proxy_inherited_service_tier_removed key=CCP_CODEX_SERVICE_TIER profile=\(profile, privacy: .public)"
                    )
                }
                environment["CCP_BIND_ADDRESS"] = "127.0.0.1"
                process = try processLauncher(
                    binary.path,
                    ["serve", "--no-monitor", "--port", String(port)],
                    environment
                )
            } catch {
                return .failure(.startFailed(error.localizedDescription))
            }

            processLock.lock()
            profileInstances[profile] = ClaudeCodeProxyProfileInstance(port: port, process: process)
            processLock.unlock()
            processStartedForThisAttempt = process

            var becameReachable = false
            for _ in 0..<max(0, retryAttempts) {
                if isReachable(port: port) {
                    becameReachable = true
                    break
                }
                sleepResolver(retryDelay)
            }
            if !becameReachable, !isReachable(port: port) {
                discardProfileInstance(profile, expecting: process)
                return .failure(.notReachable(port: port))
            }
            Logger.agentStore.info(
                "gpt_profile_proxy_started profile=\(profile, privacy: .public) port=\(port)"
            )
        }

        switch routerStarter(routerPortResolver()) {
        case .success:
            agentDefinitionSyncer()
            return .success(())
        case .failure(let error):
            if let processStartedForThisAttempt {
                discardProfileInstance(profile, expecting: processStartedForThisAttempt)
            }
            return .failure(.routerStartFailed(error.localizedDescription))
        }
    }

    /// Port, ueber den Requests fuer dieses Profil laufen: main → Backend-Port
    /// (auch extern gestartet), Zusatzprofil → nur wenn die Instanz laeuft.
    func port(forProfile profile: String?) -> Int? {
        guard profilesEnabledResolver(), !Self.isMainProfile(profile), let profile else {
            return mainPortResolver()
        }
        processLock.lock()
        defer { processLock.unlock() }
        guard let instance = profileInstances[profile], instance.process.isRunning else {
            return nil
        }
        return instance.port
    }

    /// Alle laufenden Profil-Instanzen (fuer Status-Anzeigen).
    func runningProfileInstances() -> [String: Int] {
        processLock.lock()
        defer { processLock.unlock() }
        return profileInstances
            .filter { $0.value.process.isRunning }
            .mapValues(\.port)
    }

    func stopInstance(profile: String) {
        processLock.lock()
        let instance = profileInstances.removeValue(forKey: profile)
        processLock.unlock()
        if let instance, instance.process.isRunning {
            instance.process.terminate()
        }
    }

    func stopAllProfileInstances() {
        processLock.lock()
        let instances = profileInstances
        profileInstances = [:]
        processLock.unlock()
        for instance in instances.values where instance.process.isRunning {
            instance.process.terminate()
        }
    }

    /// `codex auth logout` im Store des Profils; die laufende Instanz wird
    /// vorher beendet, weil sie den Grant sonst im Speicher weiterbenutzt.
    func logout(profile: String?) -> Result<Void, ClaudeCodeProxyError> {
        guard let executable = resolvedBinaryPath() else {
            return .failure(.binaryMissing)
        }
        if let profile, !Self.isMainProfile(profile) {
            stopInstance(profile: profile)
        }
        do {
            let result = try commandRunner(
                executable,
                ["codex", "auth", "logout"],
                environment(forProfile: profile)
            )
            guard result.exitCode == 0 else {
                return .failure(.startFailed(result.stderr.isEmpty ? result.stdout : result.stderr))
            }
            return .success(())
        } catch {
            return .failure(.startFailed(error.localizedDescription))
        }
    }

    private func discardProfileInstance(_ profile: String, expecting process: ClaudeCodeProxyProcessHandle) {
        processLock.lock()
        if profileInstances[profile]?.process === process {
            profileInstances.removeValue(forKey: profile)
        }
        processLock.unlock()
        if process.isRunning {
            process.terminate()
        }
    }

    /// Erster freier Port oberhalb von main + Offset, der weder von einer
    /// registrierten Instanz belegt noch lokal gebunden ist. Muss unter
    /// `ensureLock` laufen (Aufrufer), damit zwei Starts nicht denselben Port
    /// waehlen.
    private func allocateProfilePort() -> Int? {
        processLock.lock()
        let taken = Set(profileInstances.values.map(\.port))
        processLock.unlock()
        let start = mainPortResolver() + Self.profilePortOffset
        for port in start..<(start + Self.profilePortSearchWidth)
        where !taken.contains(port) && port != routerPortResolver() && port != mainPortResolver() {
            if portAvailabilityResolver(port) {
                return port
            }
        }
        return nil
    }

    /// Bind-Probe: gelingt ein Bind auf 127.0.0.1:<port>, ist er frei.
    static func isPortFree(_ port: Int) -> Bool {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { return false }
        defer { close(socketFD) }
        var reuse: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(socketFD, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    func stopIfSelfStarted() {
        // Der In-Process-Router versorgt bereits laufende PTY-Sessions
        // (ANTHROPIC_BASE_URL ist beim Spawn eingefroren). Er faellt deshalb
        // nur zusammen mit einem tatsaechlich selbst gestarteten Proxy —
        // laeuft der Proxy extern, bleibt der Router unangetastet, wie es
        // der Settings-Button verspricht.
        processLock.lock()
        let hasSelfStartedProcess = selfStartedProcess != nil
        processLock.unlock()

        if hasSelfStartedProcess {
            routerStopper()
        }
        replaceSelfStartedProcess(with: nil)
    }

    func authStatus() -> ClaudeCodeProxyAuthStatus {
        authStatus(profile: nil)
    }

    /// Auth-Status des Proxy-Stores eines GPT-Konto-Profils (`nil` = main).
    ///
    /// Fallback-Guard: Der Proxy meldet fuer ein Config-Dir OHNE eigene
    /// Auth-Datei nicht „Not authenticated", sondern still das Konto des
    /// Default-Stores bzw. der Codex-CLI (reproduziert 2026-09-16). Ein
    /// Zusatzprofil gilt deshalb nur als angemeldet, wenn seine Datei eine
    /// `accountId` traegt UND der Statusbefehl genau diese meldet.
    func authStatus(profile: String?) -> ClaudeCodeProxyAuthStatus {
        guard let executable = resolvedBinaryPath() else {
            return .unknown
        }
        let isMain = Self.isMainProfile(profile)
        let storedAccountID = storedAccountIDResolver(profile)
        if !isMain, storedAccountID == nil {
            return .notAuthenticated
        }
        do {
            let result = try commandRunner(
                executable,
                ["codex", "auth", "status"],
                environment(forProfile: profile)
            )
            let reported = Self.parseAuthStatus(result.stdout)
            let reconciled = Self.reconcileAuthStatus(
                reported,
                storedAccountID: storedAccountID,
                isMain: isMain
            )
            if reconciled != reported, case .authenticated(let account, _) = reported {
                Logger.agentStore.warning(
                    "gpt_profile_auth_fallback_detected profile=\(profile ?? "main", privacy: .public) reported=\(account, privacy: .public) stored=\(storedAccountID ?? "nil", privacy: .public) — Proxy antwortet mit fremdem Konto, Profil gilt als nicht angemeldet"
                )
            }
            return reconciled
        } catch {
            return .unknown
        }
    }

    /// Pure Entscheidung des Fallback-Guards: fuer main gilt die Meldung des
    /// Proxys unveraendert; ein Zusatzprofil ist nur angemeldet, wenn die
    /// gemeldete `Account:`-ID mit der Datei uebereinstimmt.
    static func reconcileAuthStatus(
        _ reported: ClaudeCodeProxyAuthStatus,
        storedAccountID: String?,
        isMain: Bool
    ) -> ClaudeCodeProxyAuthStatus {
        guard !isMain, case .authenticated(let account, _) = reported else {
            return reported
        }
        guard let storedAccountID, account == storedAccountID else {
            return .notAuthenticated
        }
        return reported
    }

    static func isMainProfile(_ profile: String?) -> Bool {
        guard let profile else { return true }
        let trimmed = profile.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == GPTAccountProfiles.mainProfileName
    }

    /// Login-Shell-Env plus Profil-Overrides. Ein geerbtes `CCP_CONFIG_DIR`
    /// wird IMMER ueberschrieben bzw. entfernt — Routing laeuft nur ueber
    /// explizite Per-Aufruf-Overrides, nie ueber Vererbung (Regel wie bei
    /// `CLAUDE_CONFIG_DIR` in `LoginShellEnvironment`).
    private func environment(forProfile profile: String?) -> [String: String] {
        var environment = environmentResolver()
        environment.removeValue(forKey: GPTAccountProfiles.configDirEnvironmentKey)
        environment.merge(profileEnvironmentResolver(profile)) { _, override in override }
        return environment
    }

    /// Pfad des gewaehlten Binarys — fuer Auth-Status und Device-Login, die
    /// mit jeder Version auskommen. Reihenfolge siehe `resolvedBinary()`.
    func resolvedBinaryPath() -> String? {
        resolvedBinary()?.path
    }

    /// Auswahl des Proxy-Binarys. Ein PATH-Binary bleibt der Power-User-
    /// Override, aber nur, wenn es die Katalog-Allowlist beherrscht — sonst
    /// gewinnt das verwaltete Binary. Vorfall 2026-09-08: Homebrew 0.1.21
    /// (Juli) hatte Vorrang vor allem, kannte aber nur seine einkompilierte
    /// Modell-Liste bis gpt-5.6; Router und `gpt.md` boten aus dem Katalog
    /// laengst gpt-6-astra an, jeder `gpt`-Spawn starb mit „Unknown model".
    /// Gibt es nur veraltete Binaries, kommt das PATH-Binary zurueck
    /// (`supportsCatalogAllowlist == false`) — `ensureRunning` versucht dann
    /// zuerst die Installation des verwalteten Binarys.
    func resolvedBinary() -> ClaudeCodeProxyBinaryCandidate? {
        let pathCandidate = commandResolver("claude-code-proxy").map {
            candidate(path: $0, source: .path)
        }
        if let pathCandidate, pathCandidate.supportsCatalogAllowlist {
            return pathCandidate
        }
        if let managed = managedBinaryResolver() {
            let managedCandidate = candidate(path: managed, source: .managed)
            if managedCandidate.supportsCatalogAllowlist || pathCandidate == nil {
                return managedCandidate
            }
        }
        return pathCandidate
    }

    /// Liefert ein katalog-faehiges Binary; ist keins da, wird EINMAL pro
    /// App-Lauf das verwaltete Fork-Release installiert. Schlaegt das fehl,
    /// laeuft der Proxy mit dem veralteten Binary weiter (aeltere Modelle
    /// funktionieren dann noch) — mit Warnung im Log und in den Settings.
    private func catalogCapableBinaryInstallingIfNeeded() -> ClaudeCodeProxyBinaryCandidate? {
        guard let binary = resolvedBinary() else { return nil }
        guard !binary.supportsCatalogAllowlist else { return binary }

        Logger.claudeGPTRouter.warning(
            "claude_code_proxy_binary_outdated path=\(binary.path, privacy: .public) version=\(binary.version ?? "unbekannt", privacy: .public) required=\(ClaudeCodeProxyBinaryInstaller.minimumCatalogVersion, privacy: .public)"
        )
        guard !didAttemptManagedInstall else { return binary }
        didAttemptManagedInstall = true

        do {
            let installedPath = try managedInstaller()
            lastManagedInstallError = nil
            invalidateVersionCache(for: installedPath)
            Logger.claudeGPTRouter.info(
                "claude_code_proxy_managed_installed path=\(installedPath, privacy: .public)"
            )
        } catch {
            lastManagedInstallError = error.localizedDescription
            Logger.claudeGPTRouter.error(
                "claude_code_proxy_managed_install_failed error=\(error.localizedDescription, privacy: .public) — Proxy laeuft mit veraltetem Binary weiter"
            )
            return binary
        }
        // Neu aufloesen: jetzt sollte das verwaltete Binary gewinnen.
        return resolvedBinary() ?? binary
    }

    private func candidate(path: String, source: ClaudeCodeProxyBinarySource) -> ClaudeCodeProxyBinaryCandidate {
        let version = binaryVersion(at: path)
        return ClaudeCodeProxyBinaryCandidate(
            path: path,
            source: source,
            version: version,
            supportsCatalogAllowlist: ClaudeCodeProxyBinaryInstaller.supportsCatalogAllowlist(version: version)
        )
    }

    /// `claude-code-proxy --version`, gecacht pro (Pfad, mtime).
    func binaryVersion(at path: String) -> String? {
        let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        versionCacheLock.lock()
        if let cached = versionCache[path], cached.modified == modified {
            versionCacheLock.unlock()
            return cached.version
        }
        versionCacheLock.unlock()

        var version: String?
        if let result = try? commandRunner(path, ["--version"], environmentResolver()),
           result.exitCode == 0 {
            version = ClaudeCodeProxyBinaryInstaller.parseVersionOutput(result.stdout)
        }
        versionCacheLock.lock()
        versionCache[path] = (modified, version)
        versionCacheLock.unlock()
        return version
    }

    private func invalidateVersionCache(for path: String) {
        versionCacheLock.lock()
        versionCache.removeValue(forKey: path)
        versionCacheLock.unlock()
    }

    /// Bruecke fuer die synchrone Startsequenz: `installKnownGood()` ist
    /// async (URLSession), `ensureRunning` laeuft blockierend auf einem
    /// Hintergrund-Thread unter `ensureLock`. Nie auf dem Main Thread rufen.
    static func installKnownGoodBlocking() throws -> String {
        let done = DispatchSemaphore(value: 0)
        let outcome = ClaudeCodeProxyInstallOutcome()
        Task.detached(priority: .userInitiated) {
            do {
                outcome.store(.success(try await ClaudeCodeProxyBinaryInstaller().installKnownGood().path))
            } catch {
                outcome.store(.failure(error))
            }
            done.signal()
        }
        done.wait()
        return try outcome.value.get()
    }

    /// Startet den Device-Code-Flow als langlebigen Prozess. Der Manager
    /// puffert Chunks, weil URL und Code auch mitten in einer Pipe-Lieferung
    /// getrennt werden koennen.
    @discardableResult
    func startDeviceLogin(
        onCodeInfo: @escaping (ClaudeCodeProxyDeviceCodeInfo) -> Void,
        onCompletion: @escaping (Int32) -> Void
    ) -> Result<Void, ClaudeCodeProxyError> {
        startDeviceLogin(profile: nil, onCodeInfo: onCodeInfo, onCompletion: onCompletion)
    }

    /// Device-Code-Login in den Store eines GPT-Konto-Profils (`nil` = main).
    /// Der Proxy schreibt den Grant nach `<CCP_CONFIG_DIR>/codex/auth.json`;
    /// das Verzeichnis muss existieren (`GPTAccountProfiles.createProfile`).
    @discardableResult
    func startDeviceLogin(
        profile: String?,
        onCodeInfo: @escaping (ClaudeCodeProxyDeviceCodeInfo) -> Void,
        onCompletion: @escaping (Int32) -> Void
    ) -> Result<Void, ClaudeCodeProxyError> {
        guard let executable = resolvedBinaryPath() else {
            return .failure(.binaryMissing)
        }
        let loginEnvironment = environment(forProfile: profile)

        // Ein noch laufender frueherer Login-Prozess wird zuerst beendet —
        // sonst liefe er verwaist weiter und ueberlebte den App-Quit.
        stopDeviceLogin()

        let outputLock = NSLock()
        var accumulatedOutput = ""
        var didPublishCode = false
        var didComplete = false
        // Identifiziert den Prozess, zu dem der Completion-Callback gehoert.
        // Spaete Callbacks alter Prozesse duerfen den Nachfolger nicht aus
        // dem Tracking werfen. Zugriff ausschliesslich unter processLock.
        let registeredHandle = ClaudeCodeProxyHandleBox()

        do {
            let process = try deviceLoginLauncher(
                executable,
                ["codex", "auth", "device"],
                loginEnvironment,
                { chunk in
                    outputLock.lock()
                    accumulatedOutput += chunk
                    let info = didPublishCode ? nil : Self.parseDeviceCodeInfo(accumulatedOutput)
                    if info != nil { didPublishCode = true }
                    outputLock.unlock()

                    if let info {
                        onCodeInfo(info)
                    }
                },
                { [weak self] exitCode in
                    guard let self else { return }
                    self.processLock.lock()
                    didComplete = true
                    if let handle = registeredHandle.value, self.deviceLoginProcess === handle {
                        self.deviceLoginProcess = nil
                    }
                    self.processLock.unlock()
                    onCompletion(exitCode)
                }
            )
            processLock.lock()
            registeredHandle.value = process
            if !didComplete {
                deviceLoginProcess = process
            }
            processLock.unlock()
            return .success(())
        } catch {
            return .failure(.startFailed(error.localizedDescription))
        }
    }

    /// Der Parser bleibt bewusst tolerant gegen zusaetzliche Statuszeilen des
    /// externen Tools; Account und Ablauf muessen jedoch beide vorhanden sein.
    static func parseAuthStatus(_ output: String) -> ClaudeCodeProxyAuthStatus {
        if output.localizedCaseInsensitiveContains("Not authenticated") {
            return .notAuthenticated
        }

        var account: String?
        var expires: String?
        for line in output.split(whereSeparator: \.isNewline) {
            let value = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("Account:") {
                account = String(value.dropFirst("Account:".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } else if value.hasPrefix("Expires:") {
                expires = String(value.dropFirst("Expires:".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        guard let account, !account.isEmpty, let expires, !expires.isEmpty else {
            return .unknown
        }
        return .authenticated(account: account, expires: expires)
    }

    static func parseDeviceCodeInfo(_ output: String) -> ClaudeCodeProxyDeviceCodeInfo? {
        var visitURL: String?
        var code: String?

        for line in output.split(whereSeparator: \.isNewline) {
            let value = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("Visit:") {
                visitURL = String(value.dropFirst("Visit:".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } else if value.hasPrefix("Enter code:") {
                code = String(value.dropFirst("Enter code:".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        guard let visitURL, !visitURL.isEmpty, let code, !code.isEmpty else {
            return nil
        }
        return ClaudeCodeProxyDeviceCodeInfo(visitURL: visitURL, code: code)
    }

    private func stopDeviceLogin() {
        processLock.lock()
        let process = deviceLoginProcess
        deviceLoginProcess = nil
        processLock.unlock()

        if process?.isRunning == true {
            process?.terminate()
        }
    }

    /// Registriert genau einen von WhisperM8 gestarteten Prozess. Ein alter
    /// Handle wird vor dem Vergessen beendet, damit App-Quit nichts verliert.
    private func replaceSelfStartedProcess(with replacement: ClaudeCodeProxyProcessHandle?) {
        processLock.lock()
        let previous = selfStartedProcess
        selfStartedProcess = replacement
        processLock.unlock()

        if previous !== replacement, previous?.isRunning == true {
            previous?.terminate()
        }
    }

    private func discardSelfStartedProcess(_ process: ClaudeCodeProxyProcessHandle) {
        processLock.lock()
        if selfStartedProcess === process {
            selfStartedProcess = nil
        }
        processLock.unlock()

        if process.isRunning {
            process.terminate()
        }
    }

    /// Der raine-Proxy besitzt mit `/healthz` eine eindeutige Probe. Nur die
    /// dokumentierte Kombination aus 200, JSON und `{ "ok": true }` gilt als
    /// gesund; ein beliebiger Listener auf dem Port reicht nicht mehr aus.
    static func isReachable(port: Int) -> Bool {
        guard
            (1...65_535).contains(port),
            let url = URL(string: "http://127.0.0.1:\(port)/healthz")
        else { return false }

        var request = URLRequest(url: url, timeoutInterval: 0.4)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 0.4
        configuration.timeoutIntervalForResource = 0.4
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let delegate = ClaudeCodeProxyProbeDelegate()
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        let session = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: delegateQueue
        )
        let result = ClaudeCodeProxyProbeResult()
        let finished = DispatchSemaphore(value: 0)
        let task = session.dataTask(with: request) { data, response, error in
            let response = response as? HTTPURLResponse
            result.store(error == nil && isHealthyProbeResponse(
                statusCode: response?.statusCode,
                contentType: response?.value(forHTTPHeaderField: "Content-Type"),
                body: data ?? Data()
            ))
            finished.signal()
        }
        task.resume()

        guard finished.wait(timeout: .now() + 0.5) == .success else {
            task.cancel()
            session.invalidateAndCancel()
            return false
        }
        session.finishTasksAndInvalidate()
        return result.value
    }

    static func isHealthyProbeResponse(
        statusCode: Int?,
        contentType: String?,
        body: Data
    ) -> Bool {
        guard statusCode == 200 else { return false }
        let mediaType = contentType?
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard mediaType?.caseInsensitiveCompare("application/json") == .orderedSame else {
            return false
        }
        guard
            let object = try? JSONSerialization.jsonObject(with: body),
            let dictionary = object as? [String: Any],
            dictionary["ok"] as? Bool == true
        else {
            return false
        }
        return true
    }

    private static func launchProcess(
        executable: String,
        arguments: [String],
        environment: [String: String]
    ) throws -> ClaudeCodeProxyProcessHandle {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()

        return ClaudeCodeProxyProcessHandle(
            isRunning: { process.isRunning },
            terminate: { process.terminate() }
        )
    }

    static func runCommand(
        executable: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval = 30
    ) throws -> ClaudeCodeProxyCommandResult {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()

        let stdout = ClaudeCodeProxyCommandOutput()
        let stderr = ClaudeCodeProxyCommandOutput()
        let readers = DispatchGroup()
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            stdout.store(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
            readers.leave()
        }
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            stderr.store(stderrPipe.fileHandleForReading.readDataToEndOfFile())
            readers.leave()
        }

        // Haengende CLIs hart begrenzen (erst SIGTERM, dann SIGKILL):
        // waitUntilExit kennt keine Frist, und ein blockierter Status-Check
        // hielte sonst z. B. den Settings-Refresh dauerhaft fest.
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                exited.wait()
            }
        }
        // Nach Prozessende schliessen sich die Pipes normalerweise sofort;
        // haelt ein vererbtes Kind sie offen, liefern wir, was bereits da ist.
        _ = readers.wait(timeout: .now() + 2)

        return ClaudeCodeProxyCommandResult(
            exitCode: process.terminationStatus,
            stdout: String(data: stdout.data, encoding: .utf8) ?? "",
            stderr: String(data: stderr.data, encoding: .utf8) ?? ""
        )
    }

    private static func launchDeviceLogin(
        executable: String,
        arguments: [String],
        environment: [String: String],
        onOutput: @escaping (String) -> Void,
        onCompletion: @escaping (Int32) -> Void
    ) throws -> ClaudeCodeProxyProcessHandle {
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            if let chunk = String(data: data, encoding: .utf8) {
                onOutput(chunk)
            }
        }
        process.terminationHandler = { completedProcess in
            outputPipe.fileHandleForReading.readabilityHandler = nil
            onCompletion(completedProcess.terminationStatus)
        }
        do {
            try process.run()
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            throw error
        }

        return ClaudeCodeProxyProcessHandle(
            isRunning: { process.isRunning },
            terminate: { process.terminate() }
        )
    }
}
