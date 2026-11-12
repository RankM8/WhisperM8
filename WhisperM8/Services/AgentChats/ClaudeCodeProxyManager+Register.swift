import Darwin
import Foundation

// Proxy-Register und Beenden im Dienst-Modus (Labs `restartKeepsChatsEnabled`,
// Plan neustart-ohne-chatverlust.md, Paket 3). Im Modus `.inApp` ist hier
// alles ein No-op und `willTerminate` beendet wie bisher.
extension ClaudeCodeProxyManager {
    var isRouterServiceMode: Bool { routerModeResolver() == .service }

    /// `willTerminate`: Bei einer Übergabe (Paket 4, nur im Dienst-Modus)
    /// laufen Proxys und Router-Dienst weiter, das Register hält sie fest.
    /// Sonst wie bisher, und im Dienst-Modus endet zusätzlich der Router-Dienst
    /// (echtes Beenden: er soll die App nicht überleben).
    func handleWillTerminate() {
        if isRouterServiceMode, handoverRequestedResolver() {
            persistProxyRegisterIfServiceMode()
            stopDeviceLogin()
            Logger.claudeGPTRouter.notice("gpt_backend_kept_for_handover")
            return
        }
        stopIfSelfStarted()
        stopAllProfileInstances()
        stopDeviceLogin()
        if isRouterServiceMode {
            // stopIfSelfStarted stoppt den Router nur mit selbst gestartetem
            // Proxy; der Dienst endet bei echtem Beenden immer.
            routerStopper()
        }
    }

    // MARK: Bitte des Router-Dienstes

    /// Nur der Profilpfad: kein Rückfall auf main (den `ensureRunning(profile:)`
    /// bei ausgeschalteten Profilen nähme) und damit nie ein Start von
    /// main-Proxy oder Router auf Zuruf von außen. `false` = abgelehnt.
    @discardableResult
    func startProfileInstanceForRouterService(profile: String) -> Bool {
        guard isRouterServiceMode, profilesEnabledResolver(), !Self.isMainProfile(profile) else {
            return false
        }
        startInstanceInBackground(profile: profile)
        return true
    }

    // MARK: Register schreiben

    /// Schreibt main- und Profil-Instanzen samt PID und Startzeit. Nur im
    /// Dienst-Modus; nie unter `processLock` aufrufen.
    func persistProxyRegisterIfServiceMode() {
        guard isRouterServiceMode else { return }
        processLock.lock()
        let main = selfStartedProcess
        let profiles = profileInstances
        processLock.unlock()

        var entries: [ClaudeCodeProxyRegisterFile.Entry] = []
        if let main, let entry = registerEntry(profile: GPTAccountProfiles.mainProfileName, port: mainPortResolver(), process: main) {
            entries.append(entry)
        }
        for (profile, instance) in profiles.sorted(by: { $0.key < $1.key }) {
            if let entry = registerEntry(profile: profile, port: instance.port, process: instance.process) {
                entries.append(entry)
            }
        }
        proxyRegister.write(ClaudeCodeProxyRegisterFile(
            updatedAt: Date().timeIntervalSince1970,
            proxies: entries,
            promotedProfiles: GPTPromotedProfiles.shared.allNames().sorted()
        ))
    }

    private func registerEntry(
        profile: String,
        port: Int,
        process: ClaudeCodeProxyProcessHandle
    ) -> ClaudeCodeProxyRegisterFile.Entry? {
        guard let pid = process.pid, process.isRunning,
              let started = registerStartTimeResolver(pid) else { return nil }
        return ClaudeCodeProxyRegisterFile.Entry(
            profile: profile,
            pid: pid,
            startTime: started.timeIntervalSince1970,
            port: port,
            binary: process.executablePath ?? ""
        )
    }

    // MARK: Register übernehmen

    /// Einmal je App-Lauf im Dienst-Modus: Proxys, die laut Register noch
    /// leben (PID und Startzeit stimmen, Port antwortet), gelten als selbst
    /// gestartet. So funktionieren „Proxy stoppen“ und „Zum Hauptkonto
    /// machen“ weiter, und keine Profil-Instanz startet doppelt.
    func adoptRegisteredProxiesIfNeeded() {
        guard isRouterServiceMode else { return }
        processLock.lock()
        guard !didAdoptRegister else {
            processLock.unlock()
            return
        }
        didAdoptRegister = true
        processLock.unlock()

        guard let file = proxyRegister.read() else { return }
        let startTime = registerStartTimeResolver
        var adoptedMain: ClaudeCodeProxyProcessHandle?
        var adoptedProfiles: [String: ClaudeCodeProxyProfileInstance] = [:]
        var pids: Set<Int32> = []
        for entry in file.proxies {
            guard ClaudeCodeProxyRegister.isAlive(entry, startTime: startTime),
                  reachabilityResolver(entry.port) else { continue }
            let handle = Self.adoptedHandle(for: entry, startTime: startTime)
            if entry.profile == GPTAccountProfiles.mainProfileName {
                guard entry.port == mainPortResolver() else { continue }
                adoptedMain = handle
            } else {
                adoptedProfiles[entry.profile] = ClaudeCodeProxyProfileInstance(port: entry.port, process: handle)
            }
            pids.insert(entry.pid)
        }
        file.promotedProfiles.forEach { GPTPromotedProfiles.shared.markPromoted($0) }

        processLock.lock()
        if selfStartedProcess == nil, let adoptedMain { selfStartedProcess = adoptedMain }
        for (profile, instance) in adoptedProfiles where profileInstances[profile] == nil {
            profileInstances[profile] = instance
        }
        adoptedProxyPIDStorage = pids
        processLock.unlock()
        if !pids.isEmpty {
            Logger.claudeGPTRouter.notice("gpt_proxies_adopted count=\(pids.count)")
        }
    }

    /// Prozesse, die aus dem Register übernommen wurden. Der Waisen-Guard
    /// ersetzt sie nie (Invariante: der GPT-Proxy wird zur Laufzeit nicht neu
    /// gestartet, laufende GPT-Chats hängen an ihm).
    func adoptedProxyPIDs() -> Set<Int32> {
        adoptRegisteredProxiesIfNeeded()
        processLock.lock()
        defer { processLock.unlock() }
        return adoptedProxyPIDStorage
    }

    static func adoptedHandle(
        for entry: ClaudeCodeProxyRegisterFile.Entry,
        startTime: @escaping (pid_t) -> Date?
    ) -> ClaudeCodeProxyProcessHandle {
        ClaudeCodeProxyProcessHandle(
            isRunning: { ClaudeCodeProxyRegister.isAlive(entry, startTime: startTime) },
            terminate: {
                // Nur derselbe Prozess (Startzeit), nie eine wiederverwendete PID.
                if ClaudeCodeProxyRegister.isAlive(entry, startTime: startTime) {
                    kill(entry.pid, SIGTERM)
                }
            },
            pid: entry.pid,
            executablePath: entry.binary
        )
    }
}
