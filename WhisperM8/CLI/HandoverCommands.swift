import Darwin
import Foundation

// MARK: - Interner Modus `handover-keeper`

/// `WhisperM8 handover-keeper --root <ordner> --run <id> [--hold-seconds N]
/// [--deposit-seconds N] [--app-binary <pfad>]…`
///
/// Interner Modus, nie von Hand: Die App startet ihn beim „Neustart ohne
/// Chatverlust“ (ab Paket 4). Läuft ohne AppKit, löst sich per `setsid()`
/// vom Starter und endet von selbst (siehe `HandoverKeeper`).
enum HandoverKeeperCommand {
    struct Options: Equatable {
        var root: URL = HandoverPaths.defaultDirectory()
        var runID: String = UUID().uuidString
        var holdSeconds: TimeInterval = 600
        var depositSeconds: TimeInterval = 30
        var appBinaries: [String] = []
    }

    /// EX_TEMPFAIL: ein anderer Aufbewahrer hält den Lock dieser Instanz.
    static let busyExitCode: Int32 = 75

    struct ParseError: Error, Equatable {
        let message: String
    }

    static func parse(_ arguments: [String]) -> Result<Options, ParseError> {
        var options = Options()
        var index = 0
        func value() -> String? {
            index += 1
            return index < arguments.count ? arguments[index] : nil
        }
        while index < arguments.count {
            switch arguments[index] {
            case "--root":
                guard let raw = value(), raw.hasPrefix("/") else { return .failure(ParseError(message: "--root braucht einen absoluten Pfad")) }
                options.root = URL(fileURLWithPath: raw, isDirectory: true).standardizedFileURL
            case "--run":
                guard let raw = value(), !raw.isEmpty else { return .failure(ParseError(message: "--run braucht eine Kennung")) }
                options.runID = raw
            case "--hold-seconds":
                guard let raw = value(), let seconds = TimeInterval(raw), seconds > 0 else {
                    return .failure(ParseError(message: "--hold-seconds braucht eine positive Zahl"))
                }
                // Entscheidung 2: höchstens 10 Minuten, auch per Argument nicht mehr.
                options.holdSeconds = min(seconds, 600)
            case "--deposit-seconds":
                guard let raw = value(), let seconds = TimeInterval(raw), seconds > 0 else {
                    return .failure(ParseError(message: "--deposit-seconds braucht eine positive Zahl"))
                }
                options.depositSeconds = seconds
            case "--app-binary":
                guard let raw = value(), raw.hasPrefix("/") else { return .failure(ParseError(message: "--app-binary braucht einen absoluten Pfad")) }
                options.appBinaries.append(raw)
            default:
                return .failure(ParseError(message: "unbekanntes Argument \(arguments[index])"))
            }
            index += 1
        }
        return .success(options)
    }

    static func run(arguments: [String]) async -> Int32 {
        let options: Options
        switch parse(arguments) {
        case .success(let parsed): options = parsed
        case .failure(let error):
            CLIIO.err("handover-keeper: \(error.message) (interner Modus)")
            return 64
        }

        // Eigene Sitzung: Das Beenden der App (oder eines Terminals, aus dem
        // jemand das Binary startet) erreicht den Aufbewahrer nicht.
        setsid()
        signal(SIGHUP, SIG_IGN)
        SigpipeGuard.install()
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)

        // Erlaubt ist das Binary, aus dem der Aufbewahrer selbst läuft — nach
        // rsync liegt die neue App unter demselben Pfad.
        var allowed = options.appBinaries
        if allowed.isEmpty, let own = HandoverPeer.executablePath(of: getpid()) { allowed = [own] }

        let keeper = HandoverKeeper(configuration: .init(
            paths: HandoverPaths(directory: options.root),
            runID: options.runID,
            holdSeconds: options.holdSeconds,
            depositSeconds: options.depositSeconds,
            peerPolicy: HandoverPeerPolicy(allowedExecutablePaths: allowed)
        ))

        var signalSources: [DispatchSourceSignal] = []
        for number in [SIGTERM, SIGINT] {
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global(qos: .userInitiated))
            source.setEventHandler { keeper.terminate() }
            source.resume()
            signalSources.append(source)
        }
        defer { signalSources.forEach { $0.cancel() } }

        return await withCheckedContinuation { (continuation: CheckedContinuation<Int32, Never>) in
            do {
                try keeper.start { _ in continuation.resume(returning: 0) }
            } catch HandoverKeeper.StartError.busy {
                CLIIO.err("handover-keeper: belegt, ein anderer Aufbewahrer läuft für \(options.root.path)")
                continuation.resume(returning: busyExitCode)
            } catch {
                CLIIO.err("handover-keeper: Start gescheitert (\(error))")
                continuation.resume(returning: 1)
            }
        }
    }
}

// MARK: - `whisperm8 app …`

/// `whisperm8 app handover-status [--json]` — Stand des Aufbewahrers dieser
/// Instanz (Phase, Frist, Chats mit PID und Ende-Status). Ohne Tokens.
/// `app handover` (Übergabe anstoßen) kommt mit Paket 4.
enum AppCLICommand {
    static let usage = "Usage: whisperm8 app handover-status [--json]"

    static func run(arguments: [String], paths: HandoverPaths = .default) async -> Int32 {
        guard let sub = arguments.first else {
            CLIIO.err(usage)
            return 64
        }
        switch sub {
        case "handover-status":
            let rest = Array(arguments.dropFirst())
            guard rest.allSatisfy({ $0 == "--json" }) else {
                CLIIO.err(usage)
                return 64
            }
            return handoverStatus(json: rest.contains("--json"), paths: paths)
        case "help", "--help", "-h":
            CLIIO.out(usage)
            return 0
        default:
            CLIIO.err("Unbekannter Befehl: app \(sub)")
            CLIIO.err(usage)
            return 64
        }
    }

    static func handoverStatus(json: Bool, paths: HandoverPaths) -> Int32 {
        let status: HandoverKeeperStatus?
        do {
            let client = try HandoverClient.connect(paths: paths, timeout: 0.5)
            defer { client.close() }
            client.timeout = 3
            status = try client.status()
        } catch HandoverWireError.io(let code) where code == ENOENT || code == ECONNREFUSED {
            status = nil
        } catch {
            CLIIO.err("Aufbewahrer antwortet nicht: \(error)")
            return 1
        }
        if json {
            CLIIO.out(renderJSON(status))
        } else {
            CLIIO.out(renderText(status, now: Date()))
        }
        return 0
    }

    static func renderJSON(_ status: HandoverKeeperStatus?) -> String {
        struct Envelope: Encodable {
            var schema = "wm8.handover-status/1"
            var active: Bool
            var keeper: HandoverKeeperStatus?
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = (try? encoder.encode(Envelope(active: status != nil, keeper: status))) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    static func renderText(_ status: HandoverKeeperStatus?, now: Date) -> String {
        guard let status else { return "Kein Aufbewahrer aktiv." }
        var lines = ["Aufbewahrer aktiv: PID \(status.pid), Lauf \(status.runID), Phase \(status.phase), Build \(status.build)"]
        if let deadline = status.deadline {
            let seconds = max(0, Int(deadline - now.timeIntervalSince1970))
            lines.append("Frist: noch \(seconds / 60) min \(seconds % 60) s")
        }
        if status.chats.isEmpty {
            lines.append("Keine Chats.")
        }
        for chat in status.chats {
            let state: String
            if chat.exited {
                state = "beendet" + (chat.exitStatus.map { " (Status \($0))" } ?? "")
            } else if chat.inTransfer {
                state = "wird übergeben"
            } else {
                state = "läuft"
            }
            lines.append("  \(chat.chatID.prefix(8))  \(chat.kind)  PID \(chat.pid)  \(state)  \(chat.gapBytes) Byte in der Lücke")
        }
        return lines.joined(separator: "\n")
    }
}
