import Foundation

// MARK: - `whisperm8 debug …` (Debug-Steuerkanal, docs/features/ui-testing.md)

/// Pure Argument-Auswertung — testbar ohne Socket.
enum DebugCLIArguments: Equatable {
    case help
    case state
    case open(target: String)
    case snapshot(window: String?, outputDir: String?)
    case dictate(audioPath: String, provider: String?, language: String?, timeoutSeconds: Int)
    case job(id: String)

    static let defaultDictateTimeout = 300

    enum ParseError: Error, Equatable {
        case usage(String)
    }

    /// Relative Pfade werden gegen `cwd` aufgelöst — die App kennt das
    /// Arbeitsverzeichnis der CLI nicht.
    static func parse(_ arguments: [String], cwd: String) throws -> DebugCLIArguments {
        guard let command = arguments.first else { return .help }
        var rest = Array(arguments.dropFirst())

        func takeOption(_ names: Set<String>) throws -> String? {
            guard let index = rest.firstIndex(where: names.contains) else { return nil }
            guard index + 1 < rest.count else { throw ParseError.usage("\(rest[index]) braucht einen Wert") }
            let value = rest[index + 1]
            rest.removeSubrange(index...(index + 1))
            return value
        }
        func absolute(_ path: String) -> String {
            let expanded = (path as NSString).expandingTildeInPath
            if expanded.hasPrefix("/") { return (expanded as NSString).standardizingPath }
            return ((cwd as NSString).appendingPathComponent(expanded) as NSString).standardizingPath
        }
        func noRest() throws {
            if let extra = rest.first { throw ParseError.usage("Unbekanntes Argument: \(extra)") }
        }

        switch command {
        case "help", "--help", "-h":
            return .help
        case "state":
            try noRest()
            return .state
        case "open":
            guard rest.count == 1, DebugControl.OpenTarget.parse(rest[0]) != nil else {
                throw ParseError.usage("open braucht genau ein gültiges Ziel: \(DebugControl.OpenTarget.usage)")
            }
            return .open(target: rest[0])
        case "snapshot":
            let window = try takeOption(["--window", "-w"])
            let out = try takeOption(["--out", "-o"]).map(absolute)
            try noRest()
            return .snapshot(window: window, outputDir: out)
        case "dictate":
            let provider = try takeOption(["--provider"])
            let language = try takeOption(["--language", "-l"])
            let timeoutRaw = try takeOption(["--timeout"])
            var timeout = defaultDictateTimeout
            if let timeoutRaw {
                guard let value = Int(timeoutRaw), value > 0 else { throw ParseError.usage("--timeout braucht Sekunden > 0") }
                timeout = value
            }
            guard rest.count == 1 else { throw ParseError.usage("dictate braucht genau eine Audiodatei") }
            return .dictate(audioPath: absolute(rest[0]), provider: provider, language: language, timeoutSeconds: timeout)
        case "job":
            guard rest.count == 1 else { throw ParseError.usage("job braucht eine Auftrags-ID") }
            return .job(id: rest[0])
        default:
            throw ParseError.usage("Unbekannter debug-Befehl: \(command)")
        }
    }
}

enum DebugCLICommand {
    static let help = """
    whisperm8 debug — Debug-Steuerkanal der laufenden App (UI-Tests ohne Computer Use)

    Voraussetzung (einmalig, wirkt sofort):
      defaults write com.whisperm8.app debugControlEnabled -bool YES

    BEFEHLE
      state                         App-Zustand als JSON (Fenster, Diktat, Einstellungen)
      open <ziel>                   Fenster öffnen: settings[/<seite>] | agent-chats | onboarding
                                    (bringt die App nach vorn)
      snapshot [--window <name>]    Offene Fenster als PNG fotografieren
               [--out <ordner>]     <name>: Teil von Titel/Identifier, key oder all (Default)
                                    Default-Ordner: ~/Library/Application Support/WhisperM8/debug-snapshots
      dictate <audiodatei>          Audio durch den echten Transkriptions-Weg schicken —
              [--provider groq|openai|chatgpt] [--language de|en|auto] [--timeout <s>]
                                    ohne Einfügen, ohne Zwischenablage, ohne Nachbearbeitung
      job <id>                      Stand eines Diktat-Auftrags

    Ausgabe: JSON auf stdout. Exit: 0 ok, 1 Aufruf/Parameter, 3 nicht gefunden,
    4 Konflikt/Auftrag gescheitert, 5 App nicht erreichbar, 124 Timeout.
    """

    static func run(arguments: [String]) async -> Int32 {
        let parsed: DebugCLIArguments
        do {
            parsed = try DebugCLIArguments.parse(arguments, cwd: FileManager.default.currentDirectoryPath)
        } catch DebugCLIArguments.ParseError.usage(let message) {
            CLIIO.err("Fehler: \(message)")
            CLIIO.err("Hilfe: whisperm8 debug help")
            return ChatsCLIExit.usage
        } catch {
            return ChatsCLIExit.usage
        }

        switch parsed {
        case .help:
            CLIIO.out(help)
            return ChatsCLIExit.ok
        case .state:
            return call("debug.state", [:])
        case .open(let target):
            return call("debug.open", ["target": target])
        case .snapshot(let window, let outputDir):
            var params: [String: Any] = [:]
            if let window { params["window"] = window }
            if let outputDir { params["outputDir"] = outputDir }
            return call("debug.snapshot", params)
        case .job(let id):
            return call("debug.job", ["jobID": id])
        case .dictate(let audioPath, let provider, let language, let timeout):
            var params: [String: Any] = ["audioPath": audioPath]
            if let provider { params["provider"] = provider }
            if let language { params["language"] = language }
            return await dictate(params: params, timeoutSeconds: timeout)
        }
    }

    // MARK: Ablauf

    /// Startet den Auftrag und pollt `debug.job`, bis er fertig ist.
    private static func dictate(params: [String: Any], timeoutSeconds: Int) async -> Int32 {
        let started: ChatsControlResponse
        switch send("debug.dictate", params) {
        case .failure(let code): return code
        case .success(let response): started = response
        }
        guard started.ok, let jobID = started.result?["jobID"]?.stringValue else {
            return printFailure(started)
        }
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard case .success(let response) = send("debug.job", ["jobID": jobID]) else {
                return ChatsCLIExit.appUnreachable
            }
            guard response.ok else { return printFailure(response) }
            switch response.result?["state"]?.stringValue {
            case "running":
                continue
            case "done":
                printJSON(response.result ?? .null)
                return ChatsCLIExit.ok
            default:
                printJSON(response.result ?? .null)
                return ChatsCLIExit.conflict
            }
        }
        CLIIO.err("Timeout nach \(timeoutSeconds) s — Auftrag läuft weiter: whisperm8 debug job \(jobID)")
        return ChatsCLIExit.timeout
    }

    private static func call(_ method: String, _ params: [String: Any]) -> Int32 {
        switch send(method, params) {
        case .failure(let code):
            return code
        case .success(let response):
            guard response.ok else { return printFailure(response) }
            printJSON(response.result ?? .null)
            return ChatsCLIExit.ok
        }
    }

    private enum SendOutcome {
        case success(ChatsControlResponse)
        case failure(Int32)
    }

    private static func send(_ method: String, _ params: [String: Any]) -> SendOutcome {
        do {
            return .success(try ChatsControlClient.send(method: method, params: params))
        } catch ChatsControlClient.ClientError.appUnreachable(let message) {
            CLIIO.err(message)
            return .failure(ChatsCLIExit.appUnreachable)
        } catch {
            CLIIO.err("Fehler: \(error)")
            return .failure(ChatsCLIExit.appUnreachable)
        }
    }

    private static func printFailure(_ response: ChatsControlResponse) -> Int32 {
        let code = response.error.flatMap { ChatsControlErrorCode(rawValue: $0.code) }
        CLIIO.err("Fehler: \(response.error?.message ?? "unbekannt")")
        // Eine App ohne debug.*-Methoden antwortet mit „Unbekannte Methode".
        if response.error?.message.hasPrefix("Unbekannte Methode") == true {
            CLIIO.err("Die laufende App kennt den Debug-Steuerkanal noch nicht — App neu starten (make dev).")
        }
        return code?.exitCode ?? ChatsCLIExit.conflict
    }

    private static func printJSON(_ value: ChatsControlJSON) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return }
        CLIIO.out(String(decoding: data, as: UTF8.self))
    }
}
