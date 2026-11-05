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

    /// `2.1.318`: Form zum Speichern, `init(parsing:)` liest sie zurück.
    var string: String { components.map(String.init).joined(separator: ".") }

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
///
/// Startrennen (Hook-Analyse 05.11.2026, Stufe 0): Chats, die direkt beim
/// App-Start wieder aufgehen, kamen vor dem ersten Abruf dran und bekamen für
/// ihre ganze Laufzeit den vollen Hook-Satz. Deshalb merkt sich die Probe die
/// zuletzt erkannte Version (`store`) und startet mit ihr als abgelaufenem
/// Wert: Der erste Launch nutzt sie, der Hintergrund-Abruf läuft trotzdem
/// sofort an. Ein Fehlschlag löscht den gemerkten Wert nicht, er überschreibt
/// ihn nur mit einer erfolgreich gelesenen Version.
///
/// Downgrade oder Austausch der Binary (Review H4): Gemerkt wird die Version
/// zusammen mit Pfad und Fingerabdruck der Binary (`Remembered`). Beim Start
/// gilt sie nur, wenn die Datei unter dem Pfad noch dieselbe ist — sonst
/// bekämen die ersten Chats den reduzierten Satz samt Event-Namen, die eine
/// ältere CLI nicht kennt, und keinen Registry-Status. Zeigt der `PATH`
/// inzwischen auf eine ganz andere Binary, merkt das erst der Abruf (den
/// `PATH` aufzulösen kann eine Login-Shell starten — nicht beim Start auf dem
/// Main Thread).
final class ClaudeCLIVersionProbe: @unchecked Sendable {
    /// Gemerkter Wert: Version plus Binary, von der sie gelesen wurde.
    struct Remembered: Equatable {
        var version: ClaudeCLIVersion
        var binaryPath: String
        var fingerprint: String

        /// Drei Zeilen: Version, Pfad, Fingerabdruck.
        var encoded: String { [version.string, binaryPath, fingerprint].joined(separator: "\n") }

        init(version: ClaudeCLIVersion, binaryPath: String, fingerprint: String) {
            self.version = version
            self.binaryPath = binaryPath
            self.fingerprint = fingerprint
        }

        /// Alte Werte (nur `2.1.318`) haben keine Binary und gelten nicht.
        init?(encoded: String) {
            let parts = encoded.split(separator: "\n", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, !parts[1].isEmpty, !parts[2].isEmpty,
                  let version = ClaudeCLIVersion(parsing: String(parts[0])) else { return nil }
            self.init(version: version, binaryPath: String(parts[1]), fingerprint: String(parts[2]))
        }
    }

    /// Aufgelöster Pfad, Änderungsdatum und Größe der Datei hinter `path`.
    /// Ein Update, Downgrade oder Umbiegen des Symlinks ändert ihn. Nur
    /// `stat`-Aufrufe, also auch beim Start auf dem Main Thread billig.
    static func binaryFingerprint(path: String) -> String? {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: resolved),
              let modified = attributes[.modificationDate] as? Date,
              let size = (attributes[.size] as? NSNumber)?.int64Value else { return nil }
        return "\(resolved)|\(modified.timeIntervalSince1970)|\(size)"
    }

    /// Speicher für den zuletzt erkannten Wert (`Remembered.encoded`).
    struct Store {
        var load: () -> String?
        var save: (String) -> Void
        /// `false`: nichts zu merken — dann wird auch die Binary nicht gesucht.
        var persists = true

        static let none = Store(load: { nil }, save: { _ in }, persists: false)

        static let userDefaults = Store(
            load: { UserDefaults.standard.string(forKey: PreferenceKeys.claudeCLILastKnownVersion) },
            save: { UserDefaults.standard.set($0, forKey: PreferenceKeys.claudeCLILastKnownVersion) })

        /// Nur die App selbst merkt sich die Version. Tests und CLI-Prozesse
        /// lesen und schreiben nichts in die Defaults.
        static func forProcess(isAppBundle: Bool) -> Store {
            isAppBundle ? .userDefaults : .none
        }
    }

    static let shared = ClaudeCLIVersionProbe(
        spawnEnabled: AppInstance.isAppBundleProcess,
        store: .forProcess(isAppBundle: AppInstance.isAppBundleProcess))

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
    private let store: Store
    private let binaryPath: () -> String?
    private let fingerprint: (String) -> String?

    /// - Parameter spawnEnabled: `false` in Tests und CLI-Prozessen — dort wird
    ///   nie `claude --version` gestartet.
    /// - Parameter binaryPath: Pfad der `claude`-Binary; nur im Hintergrund
    ///   nach einem Abruf gefragt (zum Merken).
    init(
        spawnEnabled: Bool,
        ttl: TimeInterval = 600,
        failureTTL: TimeInterval = 30,
        versionRunner: (() -> ClaudeCLIVersion?)? = nil,
        dispatch: ((@escaping @Sendable () -> Void) -> Void)? = nil,
        now: @escaping () -> Date = Date.init,
        store: Store = .none,
        binaryPath: @escaping () -> String? = { AgentCommandBuilder.commandPath("claude") },
        fingerprint: @escaping (String) -> String? = ClaudeCLIVersionProbe.binaryFingerprint(path:)
    ) {
        self.store = store
        self.binaryPath = binaryPath
        self.fingerprint = fingerprint
        // Gemerkte Version als abgelaufener Wert: sofort nutzbar, aber der
        // erste Zugriff stößt den echten Abruf an. Nur, wenn die Binary
        // dieselbe ist wie beim Merken.
        if let saved = store.load().flatMap(Remembered.init(encoded:)) {
            if fingerprint(saved.binaryPath) == saved.fingerprint {
                cached = (saved.version, .distantPast)
            } else {
                Logger.claudeBinding.notice(
                    "claude_version_remembered_ignored reason=binary_changed version=\(saved.version.string, privacy: .public)")
            }
        }
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
            // Ein Fehlschlag verdrängt eine bekannte Version nicht: Der volle
            // Hook-Satz wäre nur dann richtig, wenn Claude wirklich zu alt ist,
            // und das zeigt erst eine gelesene Version.
            if let version {
                cached = (version, now())
            } else if let previous = cached?.version {
                cached = (previous, now().addingTimeInterval(failureTTL - ttl))
            } else {
                cached = (nil, now())
            }
            refreshInFlight = false
            lock.unlock()
            if let version, store.persists, let path = binaryPath(), let print = fingerprint(path) {
                store.save(Remembered(version: version, binaryPath: path, fingerprint: print).encoded)
            }
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
