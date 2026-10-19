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

/// Fragt `claude --version` ab und cached das Ergebnis (pfadbezogen, 10 min —
/// Claude aktualisiert sich selbst).
final class ClaudeCLIVersionProbe: @unchecked Sendable {
    static let shared = ClaudeCLIVersionProbe()

    private let lock = NSLock()
    private var cached: (path: String, version: ClaudeCLIVersion?, at: Date)?
    private let ttl: TimeInterval = 600

    /// Im Hintergrund vorwärmen, damit der erste Launch nicht auf den
    /// Subprozess wartet.
    func prewarm() {
        DispatchQueue.global(qos: .utility).async { [self] in _ = installedVersion() }
    }

    func installedVersion() -> ClaudeCLIVersion? {
        guard let path = AgentCommandBuilder.commandPath("claude") else { return nil }
        lock.lock()
        if let cached, cached.path == path, Date().timeIntervalSince(cached.at) < ttl {
            lock.unlock()
            return cached.version
        }
        lock.unlock()

        let version = Self.run(path)
        lock.lock()
        cached = (path, version, Date())
        lock.unlock()
        return version
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
