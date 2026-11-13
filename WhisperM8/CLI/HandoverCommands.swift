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

        // Das Einmal-Geheimnis der App kommt über stdin, nie als Argument.
        guard let secret = readSecret(from: STDIN_FILENO, timeout: 5) else {
            CLIIO.err("handover-keeper: kein Nachweis der App auf stdin (interner Modus)")
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
            peerPolicy: HandoverPeerPolicy(
                allowedExecutablePaths: allowed,
                requirement: HandoverPeerPolicy.ownRequirement()
            ),
            secret: secret
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

extension HandoverKeeperCommand {
    /// Liest eine Zeile (das Geheimnis) mit Gesamtfrist. `nil`, wenn nichts
    /// Brauchbares kommt — dann nimmt der Aufbewahrer keine Abgabe an.
    static func readSecret(from fd: Int32, timeout: TimeInterval) -> String? {
        let end = Date().addingTimeInterval(timeout)
        var data = [UInt8]()
        var byte: UInt8 = 0
        while data.count < 256 {
            let remaining = Int32(max(0, end.timeIntervalSinceNow * 1000))
            guard remaining > 0 else { return nil }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, remaining)
            if ready < 0, errno == EINTR { continue }
            guard ready > 0 else { return nil }
            let count = read(fd, &byte, 1)
            if count < 0, errno == EINTR { continue }
            if count <= 0 || byte == 0x0A { break }
            data.append(byte)
        }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        return HandoverSecret.isWellFormed(text) ? text : nil
    }
}

// MARK: - `whisperm8 app …`

/// `whisperm8 app handover-status [--json]` — Stand des Aufbewahrers dieser
/// Instanz (Phase, Frist, Chats mit PID und Ende-Status). Ohne Tokens.
///
/// `whisperm8 app handover [--json]` — Neustart, Chats laufen weiter: Die App
/// gibt ihre Chats an den Aufbewahrer ab und beendet sich selbst. Exit-Codes:
/// 0 abgegeben (App endet gleich), 2 keine Übergabe (heutiger Weg, App läuft
/// weiter; Grund auf stderr), 4 Abgabe gescheitert (alle Chats laufen weiter
/// in der App), 5 App nicht erreichbar.
enum AppCLICommand {
    static let usage = """
    Usage: whisperm8 app handover-status [--json]
           whisperm8 app handover-status --wait-take <runID> [--timeout <s>]
           whisperm8 app handover [--json]
    """

    enum HandoverExit {
        static let handedOver: Int32 = 0
        static let classic: Int32 = 2
        static let failed: Int32 = 4
        static let appUnreachable: Int32 = 5
    }

    static func run(arguments: [String], paths: HandoverPaths = .default) async -> Int32 {
        guard let sub = arguments.first else {
            CLIIO.err(usage)
            return 64
        }
        switch sub {
        case "handover-status":
            let rest = Array(arguments.dropFirst())
            if rest.first == "--wait-take" {
                guard rest.count >= 2 else { CLIIO.err(usage); return 64 }
                var timeout: TimeInterval = 30
                if rest.count == 4, rest[2] == "--timeout", let value = TimeInterval(rest[3]) { timeout = value }
                else if rest.count != 2 { CLIIO.err(usage); return 64 }
                return waitForTake(runID: rest[1], timeout: timeout, paths: paths)
            }
            guard rest.allSatisfy({ $0 == "--json" }) else {
                CLIIO.err(usage)
                return 64
            }
            return handoverStatus(json: rest.contains("--json"), paths: paths)
        case "handover":
            let rest = Array(arguments.dropFirst())
            guard rest.allSatisfy({ $0 == "--json" }) else {
                CLIIO.err(usage)
                return 64
            }
            return handover(json: rest.contains("--json"))
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

    /// Wartet, bis die neue App die Übernahme des Laufs `runID` abgeschlossen
    /// hat. Exit 0: alle übergebenen Chats übernommen (oder in der Lücke
    /// beendet); 3: Rückfall für mindestens einen Chat oder Frist abgelaufen.
    static func waitForTake(runID: String, timeout: TimeInterval, paths: HandoverPaths) -> Int32 {
        let end = Date().addingTimeInterval(timeout)
        repeat {
            if let report = HandoverTakeReport.read(paths: paths), report.runID == runID {
                let summary = "übernommen \(report.adopted.count), in der Lücke beendet \(report.endedInGap.count), Rückfall \(report.fallback.count)"
                if report.isComplete {
                    CLIIO.out(summary)
                    return 0
                }
                CLIIO.err(summary + ": " + report.fallback.joined(separator: ", "))
                return 3
            }
            usleep(200_000)
        } while Date() < end
        CLIIO.err("keine Übernahme von Lauf \(runID) binnen \(Int(timeout)) s")
        return 3
    }

    static func handover(json: Bool) -> Int32 {
        let response: ChatsControlResponse
        do {
            response = try ChatsControlClient.send(method: "app.handover", params: [:])
        } catch {
            CLIIO.err("App nicht erreichbar: \(error)")
            return HandoverExit.appUnreachable
        }
        guard response.ok, let result = response.result else {
            CLIIO.err("app handover: \(response.error?.message ?? "Fehler ohne Text")")
            return HandoverExit.failed
        }
        let outcome = result["outcome"]?.stringValue ?? ""
        let reason = result["reason"]?.stringValue
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            CLIIO.out(String(decoding: (try? encoder.encode(result)) ?? Data(), as: UTF8.self))
        }
        return exitCode(outcome: outcome, reason: reason, result: result, quiet: json)
    }

    static func exitCode(outcome: String, reason: String?, result: ChatsControlJSON, quiet: Bool) -> Int32 {
        switch outcome {
        case "handedOver":
            if !quiet {
                let count = result["handedOver"]?.arrayValue?.count ?? 0
                let skipped = result["notHandedOver"]?.arrayValue?.count ?? 0
                CLIIO.out("Übergeben: \(count) Chats" + (skipped > 0 ? ", \(skipped) enden wie bisher" : "") + ". Die App beendet sich.")
            }
            return HandoverExit.handedOver
        case "classic":
            CLIIO.err("Keine Übergabe: \(reason ?? "ohne Grund")")
            return HandoverExit.classic
        default:
            CLIIO.err("Übergabe gescheitert: \(reason ?? "ohne Grund")")
            return HandoverExit.failed
        }
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
