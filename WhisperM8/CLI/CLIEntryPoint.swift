import Foundation

// MARK: - Prozess-Entry-Point (Multiplex CLI ↔ GUI)

/// Einziger `@main`-Einstieg des Binaries. Wird das Binary als CLI aufgerufen
/// (Symlink `whisperm8` oder ein bekanntes Subcommand), läuft der CLI-Pfad und
/// `exit()`-et; andernfalls startet die normale SwiftUI-App.
///
/// **Warum ein gemeinsames Binary?** Der CLI-Symlink zeigt auf dasselbe,
/// identisch signierte App-Binary — dadurch liest die CLI denselben
/// Keychain-Eintrag (`groq_apikey`) ohne erneuten macOS-Prompt.
@main
enum WhisperM8EntryPoint {
    static func main() {
        let arguments = CommandLine.arguments
        guard CLIModeDetector.shouldRunCLI(arguments) else {
            WhisperM8App.main()
            return
        }
        let exitCode = CLIRuntime.runBlocking(arguments: Array(arguments.dropFirst()))
        exit(exitCode)
    }
}

// MARK: - CLI-Erkennung

enum CLIModeDetector {
    /// Erste-Token, die den CLI-Modus auslösen (auch ohne Symlink testbar via
    /// `.build/.../WhisperM8 transcribe …`).
    static let recognizedCommands: Set<String> = [
        "transcribe", "modes", "help", "--help", "-h", "--version", "-v"
    ]

    static func shouldRunCLI(_ arguments: [String]) -> Bool {
        guard let program = arguments.first else { return false }
        // Der Symlink heißt exakt "whisperm8" (klein), das App-Binary "WhisperM8".
        // Case-sensitiver Vergleich verhindert, dass ein normaler GUI-Launch
        // (argv0 = …/MacOS/WhisperM8) fälschlich als CLI erkannt wird.
        if (program as NSString).lastPathComponent == "whisperm8" {
            return true
        }
        guard arguments.count > 1 else { return false }
        return recognizedCommands.contains(arguments[1])
    }
}

// MARK: - Async-Bridge

enum CLIRuntime {
    /// Führt den async-CLI-Befehl aus und blockiert den Main-Thread bis zum
    /// Ende (Semaphore). Reiner CLI-Kontext — kein SwiftUI-RunLoop nötig.
    static func runBlocking(arguments: [String]) -> Int32 {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ExitCodeBox()
        Task {
            box.code = await CLICommand.run(arguments: arguments)
            semaphore.signal()
        }
        semaphore.wait()
        return box.code
    }

    private final class ExitCodeBox {
        var code: Int32 = 0
    }
}

// MARK: - Befehls-Dispatch

enum CLICommand {
    static func run(arguments: [String]) async -> Int32 {
        guard let first = arguments.first else {
            CLIIO.out(CLIHelp.text)
            return 0
        }
        switch first {
        case "help", "--help", "-h":
            CLIIO.out(CLIHelp.text)
            return 0
        case "--version", "-v":
            CLIIO.out("whisperm8 \(CLIHelp.version)")
            return 0
        case "modes":
            return CLIModesCommand.run()
        case "transcribe":
            return await CLITranscribeCommand.run(arguments: Array(arguments.dropFirst()))
        default:
            CLIIO.err("Unbekannter Befehl: \(first)")
            CLIIO.out(CLIHelp.text)
            return 64 // EX_USAGE
        }
    }
}

// MARK: - I/O

/// Strikte Trennung: Ergebnis (Transkript) nach stdout, alles andere
/// (Fortschritt, Warnungen, Fehler) nach stderr — so bleibt die Ausgabe für
/// Claude/Pipes sauber maschinenlesbar.
enum CLIIO {
    static func out(_ text: String) {
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
    }

    /// Ergebnis ohne abschließenden Zeilenumbruch (für exakte Datei-Inhalte
    /// nutzen wir `write(_:to:)`; stdout erhält genau einen Trailing-Newline).
    static func outRaw(_ text: String) {
        FileHandle.standardOutput.write(Data(text.utf8))
    }

    static func err(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }
}

// MARK: - Hilfetext

enum CLIHelp {
    static let version = "1.0"

    static let text = """
    whisperm8 — Audio/Video-Transkription (WhisperM8)

    VERWENDUNG
      whisperm8 transcribe <datei> [optionen]
      whisperm8 modes
      whisperm8 --help | --version

    TRANSCRIBE
      Transkribiert eine Audio- oder Videodatei. Aus Videos wird die Audiospur
      automatisch extrahiert; lange Dateien werden transparent in Stücke
      zerlegt und wieder zusammengefügt.

    OPTIONEN
      -o, --output <pfad>       Ausgabe in Datei schreiben (Format aus Endung
                                ableitbar). Default: stdout.
      -f, --format <txt|json|srt|vtt>
                                Ausgabeformat. Default: txt.
      -l, --language <code>     Sprach-Hinweis (z. B. de, en).
          --provider <groq|openai>
                                Default: groq.
          --model <name>        Modell-Override (z. B. whisper-large-v3-turbo,
                                whisper-large-v3, gpt-4o-transcribe).
          --mode <id>           Transkript durch einen WhisperM8-OutputMode
                                nachbearbeiten (siehe `whisperm8 modes`).
          --api-key <key>       API-Key explizit (sonst env bzw. Keychain).
          --chunk-seconds <n>   Ziel-Chunk-Länge erzwingen (v. a. für Tests).
          --dry-run             Nur Datei-Infos + Schätzung, keine API-Calls.

    BEISPIELE
      whisperm8 transcribe vortrag.mp4
      whisperm8 transcribe interview.mov -f srt -o interview.srt
      whisperm8 transcribe memo.m4a --mode clean
      whisperm8 transcribe call.mp3 -f json -l de

    KEYS
      Reihenfolge der Key-Auflösung: --api-key  >  Umgebungsvariable
      (GROQ_API_KEY / OPENAI_API_KEY)  >  WhisperM8-Keychain.
    """
}
