import Foundation

/// Installierte Claude-Code-Version (`claude --version`), einmal gecacht.
///
/// Grund (LR-AK-035): Der reduzierte Hook-Satz (nur SessionStart/SessionEnd)
/// ist nur sicher, wenn die CLI die Status-Registry
/// (`<config>/sessions/<pid>.json`) schreibt. Ältere oder angepinnte Versionen
/// tun das nicht — dort würde der Chat weder Status noch Permission-Erkennung
/// noch ID-Nachbindung bekommen. Die Hook-Datei ist beim Launch fixiert, ein
/// späteres Erkennen hilft nicht; also entscheidet die Version VOR dem Launch.
struct ClaudeCLIVersion: Comparable, Equatable {
    let components: [Int]

    /// Erste Version, für die die Registry belegt ist (Messung 17.10.2026,
    /// Plan `claude-status-aus-registry.md`). Die kleinste tatsächlich
    /// funktionierende Version ist nicht ermittelt — bewusst konservativ.
    static let minimumRegistryVersion = ClaudeCLIVersion(components: [2, 1, 302])

    /// Liest die erste Zahlenfolge `x.y.z` aus einer Ausgabe wie
    /// `2.1.303 (Claude Code)`.
    init?(parsing output: String) {
        guard let range = output.range(of: #"\d+(\.\d+)+"#, options: .regularExpression) else { return nil }
        let parts = output[range].split(separator: ".").compactMap { Int($0) }
        guard !parts.isEmpty else { return nil }
        components = parts
    }

    init(components: [Int]) { self.components = components }

    static func < (lhs: ClaudeCLIVersion, rhs: ClaudeCLIVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let l = index < lhs.components.count ? lhs.components[index] : 0
            let r = index < rhs.components.count ? rhs.components[index] : 0
            if l != r { return l < r }
        }
        return false
    }

    /// Schreibt diese Version die Status-Registry? Unbekannte Version = nein
    /// (dann gilt der volle Hook-Satz — der sichere Weg).
    static func supportsRegistry(_ version: ClaudeCLIVersion?) -> Bool {
        guard let version else { return false }
        return version >= minimumRegistryVersion
    }
}

/// Fragt `claude --version` ab und cached das Ergebnis (10 min — Claude
/// aktualisiert sich selbst).
///
/// Blockiert NIE: `installedVersion()` läuft im Launch-Pfad auf dem Main Thread
/// (`prepareLaunchSettings`). Stale-while-revalidate: ein abgelaufener Wert wird
/// sofort geliefert und im Hintergrund erneuert; ohne jeden Wert kommt `nil`
/// (→ voller Hook-Satz, der sichere Weg) und der erste Abruf läuft im
/// Hintergrund. Ein Fehlschlag (`nil`) wird nur kurz gecacht (LR-AK-035).
final class ClaudeCLIVersionProbe: @unchecked Sendable {
    static let shared = ClaudeCLIVersionProbe(spawnEnabled: AppInstance.isAppBundleProcess)

    private let lock = NSLock()
    private var cached: (version: ClaudeCLIVersion?, at: Date)?
    private var refreshInFlight = false
    private var loggedUnknown = false
    private let ttl: TimeInterval
    private let failureTTL: TimeInterval
    private let spawnEnabled: Bool
    private let versionRunner: () -> ClaudeCLIVersion?
    private let dispatch: (@escaping @Sendable () -> Void) -> Void
    private let now: () -> Date

    /// - Parameter spawnEnabled: `false` in Tests und CLI-Prozessen — dort wird
    ///   nie `claude --version` gestartet.
    init(
        spawnEnabled: Bool,
        ttl: TimeInterval = 600,
        failureTTL: TimeInterval = 30,
        versionRunner: (() -> ClaudeCLIVersion?)? = nil,
        dispatch: ((@escaping @Sendable () -> Void) -> Void)? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.spawnEnabled = spawnEnabled
        self.ttl = ttl
        self.failureTTL = failureTTL
        self.versionRunner = versionRunner ?? {
            guard let path = AgentCommandBuilder.commandPath("claude") else { return nil }
            return Self.run(path)
        }
        self.dispatch = dispatch ?? { work in DispatchQueue.global(qos: .utility).async(execute: work) }
        self.now = now
    }

    /// Im Hintergrund vorwärmen, damit der erste Launch den Wert schon hat.
    func prewarm() {
        guard spawnEnabled else { return }
        startRefreshIfNeeded()
    }

    /// Nie blockierend. `nil` = (noch) unbekannt.
    func installedVersion() -> ClaudeCLIVersion? {
        guard spawnEnabled else { return nil }
        lock.lock()
        let snapshot = cached
        lock.unlock()
        guard let snapshot else {
            startRefreshIfNeeded()
            logUnknownOnce()
            return nil
        }
        let limit = snapshot.version == nil ? failureTTL : ttl
        if now().timeIntervalSince(snapshot.at) >= limit {
            startRefreshIfNeeded()
        }
        if snapshot.version == nil { logUnknownOnce() }
        return snapshot.version
    }

    private func logUnknownOnce() {
        lock.lock()
        let first = !loggedUnknown
        loggedUnknown = true
        lock.unlock()
        if first {
            Logger.claudeBinding.notice("claude_version_unknown reason=not_yet_probed_using_full_hooks")
        }
    }

    private func startRefreshIfNeeded() {
        lock.lock()
        if refreshInFlight { lock.unlock(); return }
        refreshInFlight = true
        lock.unlock()
        dispatch { [self] in
            let version = versionRunner()
            lock.lock()
            cached = (version, now())
            refreshInFlight = false
            lock.unlock()
        }
    }

    private static func run(_ path: String) -> ClaudeCLIVersion? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--version"]
        process.environment = LoginShellEnvironment.shared.processEnvironment()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning { process.terminate(); return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return ClaudeCLIVersion(parsing: String(decoding: data, as: UTF8.self))
    }
}
