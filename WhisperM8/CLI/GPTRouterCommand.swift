import Darwin
import Foundation

/// Interner Modus `WhisperM8 gpt-router --root <ordner> --port <port> [--take-over]`:
/// der GPT-Mix-Router als eigener Prozess (Plan neustart-ohne-chatverlust.md,
/// Paket 3). Gestartet nur von `ClaudeGPTRouterServiceSupervisor`, nie von Hand.
///
/// Nur für Tests: `--codex-url` und `--anthropic-url` setzen feste Upstreams
/// (ohne Konto-Profile und ohne Router-Token), wie der Test-Konstruktor des Routers.
enum GPTRouterCommand {
    struct Arguments: Equatable {
        var root: URL
        var port: Int
        var takeOver: Bool
        var codexURL: URL?
        var anthropicURL: URL?
    }

    static func parse(_ arguments: [String]) -> Arguments? {
        var root: URL?
        var port: Int?
        var takeOver = false
        var codexURL: URL?
        var anthropicURL: URL?
        var index = 0
        func value() -> String? {
            index += 1
            return index < arguments.count ? arguments[index] : nil
        }
        while index < arguments.count {
            switch arguments[index] {
            case "--root":
                guard let raw = value(), raw.hasPrefix("/") else { return nil }
                root = URL(fileURLWithPath: raw, isDirectory: true)
            case "--port":
                guard let raw = value(), let parsed = Int(raw), (0...65_535).contains(parsed) else { return nil }
                port = parsed
            case "--take-over":
                takeOver = true
            case "--codex-url":
                guard let raw = value(), let url = URL(string: raw) else { return nil }
                codexURL = url
            case "--anthropic-url":
                guard let raw = value(), let url = URL(string: raw) else { return nil }
                anthropicURL = url
            default:
                return nil
            }
            index += 1
        }
        guard let root, let port else { return nil }
        guard (codexURL == nil) == (anthropicURL == nil) else { return nil }
        return Arguments(root: root, port: port, takeOver: takeOver, codexURL: codexURL, anthropicURL: anthropicURL)
    }

    static func run(arguments: [String]) async -> Int32 {
        guard let parsed = parse(arguments) else {
            CLIIO.err("Usage: WhisperM8 gpt-router --root <ordner> --port <port> [--take-over] (interner Modus)")
            return 64
        }
        // Eigene Sitzung: kein SIGHUP vom Terminal oder von der App.
        setsid()
        signal(SIGHUP, SIG_IGN)
        // Sockets tragen SO_NOSIGPIPE; der leere Handler fängt den Rest ab
        // (kein SIG_IGN, siehe SigpipeGuard — hier gibt es zwar keine Kinder,
        // aber die Regel gilt im ganzen Binary).
        SigpipeGuard.install()

        let router: ClaudeGPTMixRouter
        if let codexURL = parsed.codexURL, let anthropicURL = parsed.anthropicURL {
            router = ClaudeGPTMixRouter(codexProxyURL: codexURL, anthropicURL: anthropicURL, listenerKind: .bsdSockets)
        } else {
            router = ClaudeGPTRouterServiceEnvironment.makeProductionRouter()
        }

        return await withCheckedContinuation { continuation in
            let service = ClaudeGPTRouterService(
                configuration: .init(
                    root: parsed.root,
                    port: parsed.port,
                    build: ClaudeGPTRouterBuild.current,
                    takeOver: parsed.takeOver
                ),
                router: router,
                onExit: { code in continuation.resume(returning: code) }
            )
            if case .failure(let error) = service.start() {
                CLIIO.err("gpt-router: \(error.localizedDescription)")
                ClaudeGPTRouterService.appendLog(
                    "\(ISO8601DateFormatter().string(from: Date())) [\(getpid())] start_failed \(error.localizedDescription)\n",
                    to: parsed.root.appendingPathComponent("gpt-router.log")
                )
                continuation.resume(returning: 1)
                return
            }
            if parsed.codexURL == nil {
                // Nur im echten Betrieb: Mit Test-Upstreams darf der Dienst den
                // Proxy der laufenden App nicht anfragen.
                ClaudeGPTRouterServiceEnvironment.startBackgroundRefresh()
            }
            // SIGTERM/SIGINT: geordnet auslaufen statt hart enden.
            for signalNumber in [SIGTERM, SIGINT] {
                signal(signalNumber, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global())
                source.setEventHandler { service.shutdown(reason: "signal \(signalNumber)") }
                source.resume()
                GPTRouterCommand.signalSources.append(source)
            }
            GPTRouterCommand.service = service
        }
    }

    // Lebt bis zum Prozessende.
    nonisolated(unsafe) private static var service: ClaudeGPTRouterService?
    nonisolated(unsafe) private static var signalSources: [DispatchSourceSignal] = []
}
