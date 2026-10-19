import Foundation

// Werttypen und Prozessgriff des `ClaudeCodeProxyManager` — ausgelagert, damit
// die Manager-Datei unter der 1.500-Zeilen-Grenze bleibt (SourceSizeGuard).

/// Herkunft der Proxy-Instanz eines Profils (fuer die Fehlermeldung bei
/// fehlender Transkriptions-Route).
enum ClaudeCodeProxyInstanceOrigin: Equatable {
    /// Von dieser App gestartet — das Flag ist gesetzt; fehlt die Route
    /// trotzdem, ist das Binary zu alt.
    case selfStarted
    /// Antwortet auf dem Port, wurde aber nicht von dieser App gestartet
    /// (Terminal, Waise eines frueheren App-Laufs).
    case external
    case notRunning
}

/// Befund der Route-Probe auf `/v1/audio/transcriptions`.
enum ClaudeCodeProxyTranscriptionRoute: Equatable {
    case available
    case missing
    /// Keine eindeutige Antwort (Timeout, anderer Status) — zaehlt nie als
    /// „fehlt", damit nichts auf Verdacht ersetzt wird.
    case unknown
}

enum ClaudeCodeProxyAuthStatus: Equatable {
    case authenticated(account: String, expires: String)
    case notAuthenticated
    case unknown
}

struct ClaudeCodeProxyCommandResult: Equatable {
    var exitCode: Int32
    var stdout: String
    var stderr: String
}

struct ClaudeCodeProxyDeviceCodeInfo: Equatable {
    var visitURL: String
    var code: String
}

enum ClaudeCodeProxyBinarySource: Equatable {
    /// Ueber `which` im Login-Shell-PATH gefunden (Homebrew, manuell).
    case path
    /// Managed Download in `~/Library/Application Support/WhisperM8/bin/`.
    case managed
}

/// Ein Proxy-Binary-Kandidat samt dem, was ueber ihn entscheidet: Version
/// (aus `--version`, mtime-gecacht) und ob er die Mindestversion erfuellt.
struct ClaudeCodeProxyBinaryCandidate: Equatable {
    var path: String
    var source: ClaudeCodeProxyBinarySource
    var version: String?
    var meetsMinimumVersion: Bool

    var sourceLabel: String {
        switch source {
        case .path: return "PATH"
        case .managed: return "verwaltet"
        }
    }
}

/// Abstrakter Prozessgriff fuer den langlebigen Proxy. Tests koennen damit
/// Start und Stop beobachten, ohne einen echten Subprozess zu erzeugen.
final class ClaudeCodeProxyProcessHandle {
    private let isRunningResolver: () -> Bool
    private let terminateAction: () -> Void

    init(
        isRunning: @escaping () -> Bool,
        terminate: @escaping () -> Void
    ) {
        self.isRunningResolver = isRunning
        self.terminateAction = terminate
    }

    var isRunning: Bool { isRunningResolver() }

    func terminate() {
        terminateAction()
    }
}

/// Eine von WhisperM8 gestartete Proxy-Instanz fuer ein GPT-Konto-Profil.
struct ClaudeCodeProxyProfileInstance {
    var port: Int
    var process: ClaudeCodeProxyProcessHandle
}
