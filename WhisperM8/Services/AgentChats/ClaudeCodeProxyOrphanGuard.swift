import Darwin
import Foundation

/// Räumt beim App-Start einen verwaisten, veralteten Proxy vom Port.
///
/// Befund 2026-09-23: `make kill`/`make dev` beendet die App per SIGTERM — dabei
/// läuft KEIN `willTerminate`, der selbst gestartete Proxy überlebt als Waise
/// (PPID 1). Die neue App findet den Port erreichbar und benutzt ihn weiter.
/// So lief nach dem Wechsel auf Upstream 0.1.42 weiter der alte Fork-Build, und
/// ein Auto-Update des verwalteten Binarys hätte nie gegriffen.
///
/// Ersetzt wird nur, was sicher unser Rest ist: eine Waise (PPID 1), deren
/// Programm `claude-code-proxy` heißt und die veraltet ist — anderes Binary als
/// das aufgelöste oder älter als dessen letzte Änderung. Ein vom User im
/// Terminal gestarteter Proxy hat eine Shell als Elternprozess und bleibt.
enum ClaudeCodeProxyOrphanGuard {
    struct ListenerProcess: Equatable {
        var pid: Int32
        var parentPID: Int32
        var executablePath: String
        var startedAt: Date?
    }

    /// Reine Entscheidung — unit-getestet.
    static func shouldReplace(
        _ listener: ListenerProcess,
        resolvedBinaryPath: String?,
        resolvedBinaryModifiedAt: Date?
    ) -> Bool {
        guard listener.parentPID == 1,
              (listener.executablePath as NSString).lastPathComponent == ClaudeCodeProxyBinaryInstaller.binaryName,
              let resolvedBinaryPath else { return false }
        if listener.executablePath != resolvedBinaryPath { return true }
        if let startedAt = listener.startedAt, let modified = resolvedBinaryModifiedAt {
            return modified > startedAt
        }
        return false
    }

    /// Beendet eine veraltete Waise auf `port` und wartet, bis der Port frei
    /// ist. Danach startet `ensureRunning` den Proxy mit dem aktuellen Binary.
    @discardableResult
    static func replaceIfOutdated(
        port: Int,
        resolvedBinaryPath: String?,
        listenerResolver: (Int) -> ListenerProcess? = ClaudeCodeProxyOrphanGuard.listener,
        terminator: (Int32) -> Void = { _ = kill($0, SIGTERM) },
        isReachable: (Int) -> Bool = { ClaudeCodeProxyManager.isReachable(port: $0) },
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) -> Bool {
        guard let listener = listenerResolver(port) else { return false }
        let modified = resolvedBinaryPath.flatMap {
            (try? FileManager.default.attributesOfItem(atPath: $0))?[.modificationDate] as? Date
        }
        guard shouldReplace(listener, resolvedBinaryPath: resolvedBinaryPath, resolvedBinaryModifiedAt: modified) else {
            return false
        }
        Logger.claudeGPTRouter.warning(
            "claude_code_proxy_orphan_replaced pid=\(listener.pid) path=\(listener.executablePath, privacy: .public) resolved=\(resolvedBinaryPath ?? "nil", privacy: .public)"
        )
        terminator(listener.pid)
        var attempts = 0
        while attempts < 30, isReachable(port) {
            attempts += 1
            sleep(0.1)
        }
        return true
    }

    /// PID des Listeners via `lsof`, Eltern-PID/Startzeit/Programm via `ps`.
    static func listener(port: Int) -> ListenerProcess? {
        guard let pidText = run("/usr/sbin/lsof", ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"])?
                .split(separator: "\n").first,
              let pid = Int32(pidText.trimmingCharacters(in: .whitespaces)),
              let info = run("/bin/ps", ["-o", "ppid=,lstart=,comm=", "-p", String(pid)])?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !info.isEmpty else { return nil }
        // Format: "<ppid> <Wochentag Monat Tag HH:MM:SS Jahr> <Pfad>"
        let parts = info.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 7, let ppid = Int32(parts[0]) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        let started = formatter.date(from: parts[1...5].joined(separator: " "))
        return ListenerProcess(
            pid: pid,
            parentPID: ppid,
            executablePath: parts[6...].joined(separator: " "),
            startedAt: started
        )
    }

    private static func run(_ executable: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
