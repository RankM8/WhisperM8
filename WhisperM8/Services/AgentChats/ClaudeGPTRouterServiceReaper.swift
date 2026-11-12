import Darwin
import Foundation

/// Gibt den Router-Port frei, wenn ihn ein Router-Dienst hält, den die App
/// nicht mehr steuern kann: `router.sock` fehlt (Aufräumen von /private/tmp,
/// gelöschter Ordner) oder der Dienst hängt. Ohne das könnte nichts mehr auf
/// den Port binden, und das GPT-Backend fiele bis zum Neustart des Macs aus.
///
/// Beendet wird nur, was sicher unser Dienst ist: gleiche UID, Programmname
/// wie dieser Prozess und das Argument `gpt-router`. Erst SIGTERM (der Dienst
/// schließt seinen Lauscher sofort und lässt laufende Antworten auslaufen),
/// nach drei Sekunden SIGKILL.
enum ClaudeGPTRouterServiceReaper {
    struct PortHolder: Equatable {
        var pid: Int32
        var uid: uid_t
        /// Kommandozeile wie `ps -o args=`.
        var arguments: String
    }

    /// Reine Entscheidung — unit-getestet.
    static func isOrphanedRouterService(_ holder: PortHolder, ownExecutable: String, uid: uid_t = getuid()) -> Bool {
        guard holder.uid == uid, holder.pid > 1, holder.pid != getpid() else { return false }
        // Programmpfad = alles vor dem ersten „ gpt-router“ (Pfade dürfen
        // Leerzeichen enthalten); danach Ende oder ein weiteres Argument.
        let arguments = holder.arguments.trimmingCharacters(in: .whitespaces)
        guard let marker = arguments.range(of: " gpt-router") else { return false }
        let rest = arguments[marker.upperBound...]
        guard rest.isEmpty || rest.hasPrefix(" ") else { return false }
        let program = String(arguments[..<marker.lowerBound])
        return (program as NSString).lastPathComponent == (ownExecutable as NSString).lastPathComponent
    }

    /// `true`, wenn danach der Port frei ist.
    @discardableResult
    static func freePortIfHeldByOrphanedService(
        port: Int,
        ownExecutable: String = Bundle.main.executablePath ?? CommandLine.arguments[0],
        holderResolver: (Int) -> PortHolder? = ClaudeGPTRouterServiceReaper.portHolder,
        signaler: (Int32, Int32) -> Void = { _ = kill($0, $1) },
        isPortFree: (Int) -> Bool = ClaudeCodeProxyManager.isPortFree,
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) -> Bool {
        guard !isPortFree(port) else { return true }
        guard let holder = holderResolver(port),
              isOrphanedRouterService(holder, ownExecutable: ownExecutable) else { return false }
        Logger.claudeGPTRouter.error("gpt_router_service_orphan_terminated pid=\(holder.pid) port=\(port)")
        signaler(holder.pid, SIGTERM)
        for _ in 0..<60 {
            if isPortFree(port) { return true }
            sleep(0.05)
        }
        signaler(holder.pid, SIGKILL)
        for _ in 0..<40 {
            if isPortFree(port) { return true }
            sleep(0.05)
        }
        return isPortFree(port)
    }

    /// Lauschender Prozess auf 127.0.0.1:`port` (lsof) samt UID und Argumenten (ps).
    static func portHolder(port: Int) -> PortHolder? {
        guard let pidText = run("/usr/sbin/lsof", ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"])?
                .split(separator: "\n").first,
              let pid = Int32(pidText.trimmingCharacters(in: .whitespaces)),
              let info = run("/bin/ps", ["-o", "uid=,args=", "-p", String(pid)])?
                .trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        let parts = info.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, let uid = uid_t(parts[0]) else { return nil }
        return PortHolder(pid: pid, uid: uid, arguments: String(parts[1]))
    }

    private static func run(_ executable: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
