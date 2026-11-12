import Darwin
import Foundation

/// Registerdatei `gpt-proxies.json`: welche GPT-Proxys (main und Profile) die
/// App gestartet hat, mit PID, Startzeit, Port und Programm (Plan
/// neustart-ohne-chatverlust.md, Paket 3).
///
/// Zwei Leser: der Router-Dienst (Profil-Ports und beförderte Profile, er hat
/// keinen Zugriff auf den Speicher der App) und die App nach einem Neustart,
/// die laufende Proxys übernimmt statt sie neu zu starten. Geschrieben wird
/// nur im Dienst-Modus (Labs-Schalter `restartKeepsChatsEnabled`).
/// Felder werden nur ergänzt, nie umbenannt.
struct ClaudeCodeProxyRegisterFile: Codable, Equatable {
    struct Entry: Codable, Equatable {
        /// `main` oder Name des GPT-Konto-Profils.
        var profile: String
        var pid: Int32
        /// Startzeit des Prozesses (Sekunden seit 1970) gegen wiederverwendete PIDs.
        var startTime: Double
        var port: Int
        var binary: String
    }

    static let currentVersion = 1

    var version: Int = currentVersion
    var updatedAt: Double
    var proxies: [Entry]
    /// Profile, die in einem früheren App-Lauf zum Hauptkonto wurden
    /// (`GPTPromotedProfiles`). Überlebende Chats tragen noch den alten Header.
    var promotedProfiles: [String]
}

final class ClaudeCodeProxyRegister: @unchecked Sendable {
    static let fileName = "gpt-proxies.json"

    static var defaultFileURL: URL {
        AppInstance.applicationSupport
            .appendingPathComponent("WhisperM8", isDirectory: true)
            .appendingPathComponent(fileName)
    }

    let fileURL: URL
    private let lock = NSLock()
    private var cache: (modified: Date, file: ClaudeCodeProxyRegisterFile)?

    init(fileURL: URL = ClaudeCodeProxyRegister.defaultFileURL) {
        self.fileURL = fileURL
    }

    func read() -> ClaudeCodeProxyRegisterFile? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(ClaudeCodeProxyRegisterFile.self, from: data)
    }

    /// Wie `read`, aber nur neu gelesen, wenn sich die Datei geändert hat
    /// (der Router-Dienst fragt je Request).
    func cachedRead() -> ClaudeCodeProxyRegisterFile? {
        let modified = (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.modificationDate] as? Date
        lock.lock()
        if let modified, let cache, cache.modified == modified {
            lock.unlock()
            return cache.file
        }
        lock.unlock()
        let file = read()
        lock.lock()
        if let modified, let file { cache = (modified, file) } else { cache = nil }
        lock.unlock()
        return file
    }

    /// Schreibt atomar mit 0600.
    func write(_ file: ClaudeCodeProxyRegisterFile) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(file)
            let temporary = fileURL.appendingPathExtension("tmp-\(getpid())")
            let fd = open(temporary.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
            guard fd >= 0 else { return }
            let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            close(fd)
            guard written == data.count, rename(temporary.path, fileURL.path) == 0 else {
                unlink(temporary.path)
                return
            }
        } catch {
            Logger.claudeGPTRouter.error("gpt_proxy_register_write_failed \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Prüfung

    /// Lebt der Prozess des Eintrags noch, und ist es derselbe (Startzeit)?
    static func isAlive(
        _ entry: ClaudeCodeProxyRegisterFile.Entry,
        startTime: (pid_t) -> Date? = ProcessStartTime.of(pid:)
    ) -> Bool {
        guard entry.pid > 1 else { return false }
        guard kill(entry.pid, 0) == 0 || errno == EPERM else { return false }
        guard let actual = startTime(entry.pid) else { return false }
        return abs(actual.timeIntervalSince1970 - entry.startTime) < 1
    }

    /// Port der Instanz eines Profils laut Register, wenn sie lebt.
    func livePort(forProfile profile: String, startTime: (pid_t) -> Date? = ProcessStartTime.of(pid:)) -> Int? {
        guard let entry = cachedRead()?.proxies.first(where: { $0.profile == profile }),
              Self.isAlive(entry, startTime: startTime) else { return nil }
        return entry.port
    }

    func wasPromoted(_ profile: String) -> Bool {
        cachedRead()?.promotedProfiles.contains(profile) == true
    }
}
