import Foundation

// MARK: - `whisperm8 speak` (gesprochene Ansage über die laufende App)

/// Pure Argument-Auswertung — testbar ohne Socket.
enum SpeakCLIArguments: Equatable {
    case help
    /// `-` = Text von stdin.
    case speak(text: String?)

    enum ParseError: Error, Equatable {
        case usage(String)
    }

    static func parse(_ arguments: [String]) throws -> SpeakCLIArguments {
        guard let first = arguments.first else { throw ParseError.usage("Text fehlt") }
        if ["help", "--help", "-h"].contains(first), arguments.count == 1 { return .help }
        if arguments == ["-"] { return .speak(text: nil) }
        if let option = arguments.first(where: { $0.hasPrefix("--") }) {
            throw ParseError.usage("Unbekannte Option: \(option)")
        }
        return .speak(text: arguments.joined(separator: " "))
    }
}

enum SpeakCLICommand {
    static let help = """
    whisperm8 speak — kurze Ansage über die laufende App vorlesen

    VERWENDUNG
      whisperm8 speak "<text>"      höchstens zwei Sätze, ohne Pfade, Code oder IDs
      echo "<text>" | whisperm8 speak -

    Die App stellt den Namen des Chats voran („Jarvis: …“), spricht nie zwei
    Ansagen gleichzeitig und nie während einer Diktat-Aufnahme. Kehrt sofort
    zurück, ohne auf das Ende der Ansage zu warten.

    Ausgabe: JSON auf stdout, `status` = queued | replaced | muted | debounced.
    Exit: 0 angenommen (auch stumm/entprellt), 1 Aufruf oder abgeschaltet,
    5 App nicht erreichbar.
    """

    static func run(arguments: [String]) async -> Int32 {
        let parsed: SpeakCLIArguments
        do {
            parsed = try SpeakCLIArguments.parse(arguments)
        } catch SpeakCLIArguments.ParseError.usage(let message) {
            CLIIO.err("Fehler: \(message)")
            CLIIO.err("Hilfe: whisperm8 speak --help")
            return ChatsCLIExit.usage
        } catch {
            return ChatsCLIExit.usage
        }

        let text: String
        switch parsed {
        case .help:
            CLIIO.out(help)
            return ChatsCLIExit.ok
        case .speak(let given?):
            text = given
        case .speak(nil):
            text = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        }

        let response: ChatsControlResponse
        do {
            response = try ChatsControlClient.send(method: "speech.speak", params: ["text": text])
        } catch ChatsControlClient.ClientError.appUnreachable(let message) {
            CLIIO.err(message)
            return ChatsCLIExit.appUnreachable
        } catch {
            CLIIO.err("Fehler: \(error)")
            return ChatsCLIExit.appUnreachable
        }
        guard response.ok else {
            CLIIO.err("Fehler: \(response.error?.message ?? "unbekannt")")
            if response.error?.message.hasPrefix("Unbekannte Methode") == true {
                CLIIO.err("Die laufende App kennt `speak` noch nicht — App neu starten (make dev).")
            }
            return response.error.flatMap { ChatsControlErrorCode(rawValue: $0.code) }?.exitCode ?? ChatsCLIExit.conflict
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(response.result ?? .null) {
            CLIIO.out(String(decoding: data, as: UTF8.self))
        }
        return ChatsCLIExit.ok
    }
}
