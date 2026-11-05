import Foundation

// MARK: - `whisperm8 clipboard …` (Zwischenablage-Verlauf für Agents)

/// Pure Argument-Auswertung, testbar ohne Dateien und Socket.
enum ClipboardCLIArguments: Equatable {
    case help
    case status(json: Bool)
    case list(limit: Int, json: Bool)
    case get(ref: String, json: Bool, maxChars: Int = defaultMaxChars, from: Int = 0, original: Bool = false)
    case search(query: String, limit: Int, json: Bool)
    case copy(ref: String)

    static let defaultLimit = 20
    /// `get` liefert höchstens so viele Zeichen am Stück (`--max-chars 0` = alles).
    static let defaultMaxChars = 50_000

    enum ParseError: Error, Equatable {
        case usage(String)
    }

    static func parse(_ arguments: [String]) throws -> ClipboardCLIArguments {
        guard let command = arguments.first else { return .help }
        var rest = Array(arguments.dropFirst())
        // Alles nach `--` ist Text, auch wenn er mit `-` beginnt.
        var literal: [String] = []
        if let separator = rest.firstIndex(of: "--") {
            literal = Array(rest[(separator + 1)...])
            rest = Array(rest[..<separator])
        }

        func takeFlag(_ names: Set<String>) -> Bool {
            guard let index = rest.firstIndex(where: names.contains) else { return false }
            rest.remove(at: index)
            return true
        }
        func takeLimit() throws -> Int {
            guard let index = rest.firstIndex(where: { $0 == "--limit" || $0 == "-n" }) else { return defaultLimit }
            guard index + 1 < rest.count, let value = Int(rest[index + 1]), value >= 1 else {
                throw ParseError.usage("--limit braucht eine Zahl ab 1")
            }
            rest.removeSubrange(index...(index + 1))
            return min(value, 500)
        }
        func takeNumber(_ name: String, default value: Int) throws -> Int {
            guard let index = rest.firstIndex(of: name) else { return value }
            guard index + 1 < rest.count, let number = Int(rest[index + 1]), number >= 0 else {
                throw ParseError.usage("\(name) braucht eine Zahl ab 0")
            }
            rest.removeSubrange(index...(index + 1))
            return number
        }
        func rejectOptions() throws {
            if let option = rest.first(where: { $0.hasPrefix("-") && Int($0) == nil }) {
                throw ParseError.usage("Unbekannte Option: \(option)")
            }
        }

        switch command {
        case "help", "--help", "-h":
            return .help
        case "status":
            let json = takeFlag(["--json"])
            try rejectOptions()
            if let extra = (rest + literal).first { throw ParseError.usage("Unbekanntes Argument: \(extra)") }
            return .status(json: json)
        case "list", "ls":
            let json = takeFlag(["--json"])
            let limit = try takeLimit()
            try rejectOptions()
            if let extra = (rest + literal).first { throw ParseError.usage("Unbekanntes Argument: \(extra)") }
            return .list(limit: limit, json: json)
        case "get", "show":
            let json = takeFlag(["--json"])
            let original = takeFlag(["--original"])
            let maxChars = try takeNumber("--max-chars", default: defaultMaxChars)
            let from = try takeNumber("--from", default: 0)
            try rejectOptions()
            let refs = rest + literal
            guard refs.count == 1 else { throw ParseError.usage("get braucht genau eine Nummer oder ID") }
            return .get(ref: refs[0], json: json, maxChars: maxChars, from: from, original: original)
        case "search", "find":
            let json = takeFlag(["--json"])
            let limit = try takeLimit()
            try rejectOptions()
            let query = (rest + literal).joined(separator: " ").trimmingCharacters(in: .whitespaces)
            guard !query.isEmpty else { throw ParseError.usage("search braucht einen Suchtext") }
            return .search(query: query, limit: limit, json: json)
        case "copy":
            try rejectOptions()
            let refs = rest + literal
            guard refs.count == 1 else { throw ParseError.usage("copy braucht genau eine Nummer oder ID") }
            return .copy(ref: refs[0])
        default:
            throw ParseError.usage("Unbekannter Befehl: \(command)")
        }
    }
}

/// Meldungstexte, auch vom Server (`clipboard.copy`) genutzt.
enum ClipboardCLIText {
    static func message(for error: ClipboardHistoryCore.ResolveError) -> String {
        switch error {
        case .notFound(let ref): return "Kein Eintrag „\(ref)“. `whisperm8 clipboard list` zeigt die Nummern."
        case .ambiguous(let ref): return "„\(ref)“ passt auf mehrere Einträge. Mehr Zeichen der ID angeben oder die Nummer nehmen."
        case .outOfRange(let number, let count):
            return count == 0 ? "Der Verlauf ist leer." : "Nummer \(number) gibt es nicht (1 bis \(count))."
        }
    }
}

// MARK: - Ausgabe (rein)

/// Alles, was `list`, `get` und `search` ausgeben. Rein, damit Maskierung und
/// Formate ohne Dateien getestet werden.
enum ClipboardCLIFormatter {
    struct Context {
        var settings: ClipboardSettings
        var directory: URL
        var fullText: (ClipboardEntry) -> String?
        var now: Date
    }

    static func ageLabel(from date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        switch seconds {
        case ..<60: return "\(seconds)s"
        case ..<3600: return "\(seconds / 60)m"
        case ..<86_400: return "\(seconds / 3600)h"
        default: return "\(seconds / 86_400)d"
        }
    }

    private static func masked(_ text: String, _ context: Context) -> (text: String, count: Int) {
        guard context.settings.maskSecrets else { return (text, 0) }
        let result = ClipboardSecretMasker.mask(text)
        return (result.text, result.maskedCount)
    }

    /// Vorschau für Agents: erst maskieren, dann kürzen. Die gespeicherte
    /// Vorschau ist schon nach 240 Zeichen abgeschnitten und könnte ein
    /// Geheimnis halbieren, das die Maskierung dann nicht mehr erkennt.
    static func maskedPreview(_ entry: ClipboardEntry, _ context: Context) -> String {
        guard context.settings.maskSecrets, entry.kind == .text else { return entry.preview }
        let source = context.fullText(entry) ?? entry.preview
        return ClipboardEntry.makePreview(from: masked(String(source.prefix(4_000)), context).text)
    }

    private static func oneLine(_ text: String, limit: Int = 100) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }

    private static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        return formatter.string(from: date)
    }

    /// JSON-Objekt eines Eintrags (ohne vollen Text).
    static func summary(_ entry: ClipboardEntry, number: Int, context: Context) -> [String: Any] {
        var object: [String: Any] = [
            "number": number,
            "id": entry.id,
            "kind": entry.kind.rawValue,
            "pinned": entry.isPinned,
            "copiedAt": isoString(entry.lastCopiedAt),
            "preview": maskedPreview(entry, context),
        ]
        if let name = entry.sourceName { object["sourceApp"] = name }
        if let id = entry.sourceBundleID { object["sourceBundleID"] = id }
        // Schnellaktionen (⇧⌘K) tragen ihren Modus unter eigenem Namen, damit
        // ein Agent sie nicht für Diktate hält; ihr Original ist der Text davor.
        if let mode = entry.dictationMode {
            object[entry.isQuickActionResult ? "quickActionMode" : "dictationMode"] = mode
        }
        if entry.dictationOriginal != nil { object["hasOriginal"] = true }
        switch entry.kind {
        case .text:
            object["chars"] = entry.textLength
        case .image:
            if let file = entry.imageFile {
                object["imagePath"] = ClipboardHistoryStore.blobURL(file, directory: context.directory).path
            }
            if let w = entry.imageWidth { object["width"] = w }
            if let h = entry.imageHeight { object["height"] = h }
        case .files:
            object["files"] = entry.filePaths ?? []
        }
        return object
    }

    static func jsonString(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted])
        else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Zeilen für `list` und `search`; Nummer = Platz in der Zeitreihe (1 = neuester).
    static func listing(_ rows: [(number: Int, entry: ClipboardEntry)], json: Bool, context: Context) -> String {
        if json {
            return jsonString(rows.map { summary($0.entry, number: $0.number, context: context) })
        }
        if rows.isEmpty { return "(keine Einträge)" }
        return rows.map { row in
            let entry = row.entry
            let pin = entry.isPinned ? "*" : " "
            let app = entry.dictationMode.map { entry.isQuickActionResult ? "Aktion \($0)" : "Diktat \($0)" }
                ?? entry.sourceName ?? "-"
            let text = oneLine(maskedPreview(entry, context))
            return "\(String(row.number).padding(toLength: 4, withPad: " ", startingAt: 0))\(pin) \(entry.kind.rawValue.padding(toLength: 5, withPad: " ", startingAt: 0)) \(ageLabel(from: entry.lastCopiedAt, now: context.now).padding(toLength: 4, withPad: " ", startingAt: 0)) \(app.padding(toLength: 14, withPad: " ", startingAt: 0)) \(text)"
        }.joined(separator: "\n")
    }

    struct GetOutput: Equatable {
        var stdout: String
        var note: String?
    }

    /// `get`: Text (maskiert, dann ausgeschnitten), bei Bildern der Dateipfad,
    /// bei Dateien die Pfade. Lange Texte kommen in Stücken von `maxChars`
    /// Zeichen ab `from`; `maxChars == 0` heißt alles. `original` liefert bei
    /// Diktaten das Roh-Transkript statt des Ergebnisses.
    static func detail(
        _ entry: ClipboardEntry, number: Int, json: Bool, context: Context,
        maxChars: Int = ClipboardCLIArguments.defaultMaxChars, from: Int = 0, original: Bool = false
    ) -> GetOutput {
        var notes: [String] = []
        var object = summary(entry, number: number, context: context)
        var plain = ""
        if original, entry.dictationOriginal == nil {
            notes.append("Kein Roh-Transkript: der Eintrag ist kein nachbearbeitetes Diktat. Ausgabe ist der Eintrag selbst.")
        } else if !original, entry.dictationOriginal != nil {
            notes.append(entry.isQuickActionResult
                ? "Ergebnis einer Schnellaktion (markierter Text umgearbeitet, nichts gesprochen). Der Text davor: --original."
                : "Diktat mit Nachbearbeitung. Das Gesagte vor der Umformulierung: --original.")
        }
        switch entry.kind {
        case .text:
            let useOriginal = original && entry.dictationOriginal != nil
            object["source"] = useOriginal ? "original" : "result"
            let full = useOriginal ? (entry.dictationOriginal ?? "") : (context.fullText(entry) ?? entry.preview)
            let result = masked(full, context)
            let slice = slice(result.text, maxChars: maxChars, from: from)
            plain = slice.text
            object["text"] = slice.text
            object["totalChars"] = slice.total
            object["from"] = slice.from
            object["truncated"] = slice.nextFrom != nil
            if let next = slice.nextFrom {
                object["nextFrom"] = next
                notes.append("Gekürzt: Zeichen \(slice.from) bis \(next) von \(slice.total). Weiter mit --from \(next), alles mit --max-chars 0.")
            }
            object["secretsMasked"] = result.count
            if result.count > 0 { notes.append("\(result.count) Geheimnis(se) maskiert (Einstellung „Mask secrets for agents“).") }
        case .image:
            plain = (object["imagePath"] as? String) ?? ""
        case .files:
            plain = (entry.filePaths ?? []).joined(separator: "\n")
        }
        return GetOutput(stdout: json ? jsonString(object) : plain, note: notes.isEmpty ? nil : notes.joined(separator: "\n"))
    }

    struct Slice: Equatable {
        var text: String
        var from: Int
        var total: Int
        var nextFrom: Int?
    }

    static func slice(_ text: String, maxChars: Int, from: Int) -> Slice {
        let total = text.count
        let start = min(max(0, from), total)
        guard maxChars > 0 else {
            return Slice(text: String(text.dropFirst(start)), from: start, total: total, nextFrom: nil)
        }
        let end = min(total, start + maxChars)
        let lower = text.index(text.startIndex, offsetBy: start)
        let upper = text.index(lower, offsetBy: end - start)
        return Slice(text: String(text[lower..<upper]), from: start, total: total, nextFrom: end < total ? end : nil)
    }

    static func status(_ settings: ClipboardSettings, entryCount: Int?, json: Bool) -> String {
        if json {
            var object: [String: Any] = [
                "enabled": settings.enabled,
                "paused": settings.paused,
                "agentAccess": settings.agentAccess,
                "maskSecrets": settings.maskSecrets,
            ]
            if let entryCount { object["entries"] = entryCount }
            return jsonString(object)
        }
        func onOff(_ value: Bool) -> String { value ? "an" : "aus" }
        var lines = [
            "Verlauf: \(onOff(settings.enabled))\(settings.paused ? " (pausiert)" : "")",
            "Zugriff für Agents: \(onOff(settings.agentAccess))",
            "Geheimnisse maskieren: \(onOff(settings.maskSecrets))",
        ]
        if let entryCount { lines.append("Einträge: \(entryCount)") }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Ausführung

struct ClipboardCLIEnvironment {
    var settings: () -> ClipboardSettings
    var directory: URL
    var loadEntries: () -> [ClipboardEntry]
    var fullText: (ClipboardEntry) -> String?
    var now: () -> Date
    /// Legt einen Eintrag über die App in die Zwischenablage (Control-Socket).
    var copyViaApp: (String) -> ClipboardCLIRunner.CopyOutcome

    static var live: ClipboardCLIEnvironment {
        let directory = ClipboardHistoryStore.defaultDirectory()
        return ClipboardCLIEnvironment(
            settings: { ClipboardSettings.readLive() },
            directory: directory,
            loadEntries: { ClipboardHistoryStore.loadIndex(directory: directory) },
            fullText: { ClipboardHistoryStore.fullText(of: $0, directory: directory) },
            now: Date.init,
            copyViaApp: ClipboardCLIRunner.copyViaControlSocket
        )
    }
}

enum ClipboardCLIRunner {
    struct Output: Equatable {
        var exitCode: Int32
        var stdout: String = ""
        var stderr: String = ""
    }

    enum CopyOutcome: Equatable {
        case copied(kind: String)
        case failed(message: String, exitCode: Int32)
    }

    static func execute(_ arguments: ClipboardCLIArguments, environment env: ClipboardCLIEnvironment) -> Output {
        if case .help = arguments { return Output(exitCode: ChatsCLIExit.ok, stdout: ClipboardCLICommand.help) }

        let settings = env.settings()
        // Status verrät keinen Inhalt und geht deshalb immer.
        if case .status(let json) = arguments {
            let count = settings.enabled ? env.loadEntries().count : nil
            return Output(exitCode: ChatsCLIExit.ok, stdout: ClipboardCLIFormatter.status(settings, entryCount: count, json: json))
        }
        guard settings.enabled else {
            return Output(exitCode: ChatsCLIExit.usage, stderr: ClipboardSettings.disabledMessage)
        }
        guard settings.agentAccess else {
            return Output(exitCode: ChatsCLIExit.usage, stderr: ClipboardSettings.agentAccessDeniedMessage)
        }
        let entries = env.loadEntries()
        let ordered = ClipboardHistoryCore.chronological(entries)
        let numbers = Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($1.id, $0 + 1) })
        let context = ClipboardCLIFormatter.Context(
            settings: settings, directory: env.directory, fullText: env.fullText, now: env.now()
        )

        switch arguments {
        case .help, .status:
            return Output(exitCode: ChatsCLIExit.ok, stdout: ClipboardCLICommand.help)
        case .list(let limit, let json):
            let rows = ordered.prefix(limit).enumerated().map { (number: $0 + 1, entry: $1) }
            return Output(exitCode: ChatsCLIExit.ok, stdout: ClipboardCLIFormatter.listing(rows, json: json, context: context))
        case .search(let query, let limit, let json):
            // Suchtext komplett aus maskiertem Text (Inhalt, Original, Herkunft),
            // sonst ließe sich ein Geheimnis per Suche Zeichen für Zeichen erraten.
            // Lange Texte zählen wie im Fenster nur mit Anfang und Ende: Die Maskierung
            // läuft sonst bei jedem Aufruf über jedes Megabyte-Log (Zeitlimit im Plugin).
            let limits = ClipboardSearchIndex.Limits()
            let found = ClipboardHistoryCore.search(entries, query: query) { (entry: ClipboardEntry) -> [UInt8] in
                var parts: [String] = []
                switch entry.kind {
                case .text:
                    parts.append(ClipboardSearchIndex.wordBoundaryExcerpt(
                        env.fullText(entry) ?? entry.preview, head: limits.headBytes, tail: limits.tailBytes))
                case .image: parts.append(entry.preview)
                case .files: parts.append(contentsOf: entry.filePaths ?? []); parts.append(entry.preview)
                }
                if let original = entry.dictationOriginal {
                    parts.append(ClipboardSearchIndex.wordBoundaryExcerpt(
                        original, head: limits.headBytes, tail: limits.tailBytes))
                }
                if let name = entry.sourceName { parts.append(name) }
                let text = parts.joined(separator: "\n")
                let searchable = settings.maskSecrets ? ClipboardSecretMasker.mask(text).text : text
                return Array(ClipboardSearchIndex.fold(searchable).utf8)
            }
            let rows = found.prefix(limit).map { (number: numbers[$0.id] ?? 0, entry: $0) }
            return Output(exitCode: ChatsCLIExit.ok, stdout: ClipboardCLIFormatter.listing(rows, json: json, context: context))
        case .get(let ref, let json, let maxChars, let from, let original):
            switch ClipboardHistoryCore.resolve(ref, in: entries) {
            case .failure(let error):
                return Output(exitCode: ChatsCLIExit.notFound, stderr: ClipboardCLIText.message(for: error))
            case .success(let entry):
                let detail = ClipboardCLIFormatter.detail(
                    entry, number: numbers[entry.id] ?? 0, json: json, context: context,
                    maxChars: maxChars, from: from, original: original
                )
                return Output(exitCode: ChatsCLIExit.ok, stdout: detail.stdout, stderr: detail.note ?? "")
            }
        case .copy(let ref):
            switch ClipboardHistoryCore.resolve(ref, in: entries) {
            case .failure(let error):
                return Output(exitCode: ChatsCLIExit.notFound, stderr: ClipboardCLIText.message(for: error))
            case .success(let entry):
                switch env.copyViaApp(entry.id) {
                case .copied(let kind):
                    let result: [String: Any] = ["copied": entry.id, "kind": kind, "number": numbers[entry.id] ?? 0]
                    return Output(exitCode: ChatsCLIExit.ok, stdout: ClipboardCLIFormatter.jsonString(result))
                case .failed(let message, let code):
                    return Output(exitCode: code, stderr: message)
                }
            }
        }
    }

    /// Kopieren ist eine Änderung: nur die App schreibt die Zwischenablage.
    static func copyViaControlSocket(id: String) -> CopyOutcome {
        let response: ChatsControlResponse
        do {
            response = try ChatsControlClient.send(method: "clipboard.copy", params: ["ref": id])
        } catch ChatsControlClient.ClientError.appUnreachable(let message) {
            return .failed(
                message: "\(message)\nDie App muss laufen, um in die Zwischenablage zu kopieren. `whisperm8 clipboard get` liest ohne App.",
                exitCode: ChatsCLIExit.appUnreachable
            )
        } catch {
            return .failed(message: "Fehler: \(error)", exitCode: ChatsCLIExit.appUnreachable)
        }
        guard response.ok else {
            var message = "Fehler: \(response.error?.message ?? "unbekannt")"
            if response.error?.message.hasPrefix("Unbekannte Methode") == true {
                message += "\nDie laufende App kennt `clipboard` noch nicht, App neu starten."
            }
            let code = response.error.flatMap { ChatsControlErrorCode(rawValue: $0.code) }?.exitCode ?? ChatsCLIExit.conflict
            return .failed(message: message, exitCode: code)
        }
        return .copied(kind: response.result?["kind"]?.stringValue ?? "text")
    }
}

enum ClipboardCLICommand {
    static let help = """
    whisperm8 clipboard: Zwischenablage-Verlauf lesen (WhisperM8 ersetzt Maccy)

    VERWENDUNG
      whisperm8 clipboard status [--json]
      whisperm8 clipboard list [--limit N] [--json]
      whisperm8 clipboard search <text> [--limit N] [--json]
      whisperm8 clipboard get <nr|id> [--json] [--max-chars N] [--from N] [--original]
      whisperm8 clipboard copy <nr|id>

    Nummer 1 ist der neueste Eintrag (Zeitreihe, Angepinnte zählen mit).
    `get` liefert Text, bei Bildern den absoluten Pfad der PNG-Datei (der
    Agent kann sie lesen), bei Dateien die Pfade. Lange Texte kommen in
    Stücken von 50.000 Zeichen: `--from N` liest weiter, `--max-chars 0`
    liefert alles. `copy` legt den Eintrag über die App wieder in die
    Zwischenablage. `status` zeigt die Schalter und geht immer.

    Diktate: Fertige Diktate stehen mit im Verlauf (Feld `dictationMode`).
    Hat der Modus nachbearbeitet, liefert `get <nr> --original` das
    Roh-Transkript, also das Gesagte vor der Umformulierung (`hasOriginal`).
    Schnellaktionen (etwa ⇧⌘K „Korrigieren“) haben stattdessen
    `quickActionMode`; ihr `--original` ist der markierte Text davor, nichts
    Gesagtes.

    Schutz: Typische Geheimnisse (API-Keys, Tokens, JWTs, private Schlüssel,
    Passwörter in Zuweisungen) werden maskiert ([REDACTED:…]). Passwort-
    Manager-Kopien und ausgeschlossene Apps landen gar nicht erst im Verlauf.
    Beides steht in den Einstellungen (Seite Clipboard); ist „Let agents
    read the history“ aus, verweigert die CLI.

    Exit: 0 ok, 1 Aufruf falsch, Verlauf aus oder Zugriff gesperrt, 3 Eintrag
    nicht gefunden, 4 Kopieren fehlgeschlagen, 5 App nicht erreichbar (4 und
    5 nur bei `copy`).
    """

    static func run(arguments: [String]) async -> Int32 {
        let parsed: ClipboardCLIArguments
        do {
            parsed = try ClipboardCLIArguments.parse(arguments)
        } catch ClipboardCLIArguments.ParseError.usage(let message) {
            CLIIO.err("Fehler: \(message)")
            CLIIO.err("Hilfe: whisperm8 clipboard --help")
            return ChatsCLIExit.usage
        } catch {
            return ChatsCLIExit.usage
        }
        let output = ClipboardCLIRunner.execute(parsed, environment: .live)
        if !output.stdout.isEmpty { CLIIO.out(output.stdout) }
        if !output.stderr.isEmpty { CLIIO.err(output.stderr) }
        return output.exitCode
    }
}
