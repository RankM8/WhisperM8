import Foundation

/// Legt beim App-Start einen Symlink `~/.local/bin/whisperm8` auf das aktuelle
/// App-Binary an. Dadurch ist die CLI sofort auf dem PATH (dort liegt bei
/// Claude-Code-Nutzern typischerweise auch `claude`) und nutzt — weil es
/// dasselbe signierte Binary ist — denselben Keychain-Eintrag ohne Prompt.
enum CLISymlinkInstaller {
    static let linkName = "whisperm8"

    static func installIfNeeded() {
        guard let target = currentExecutableURL() else { return }

        let binDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin", isDirectory: true)
        let linkURL = binDir.appendingPathComponent(linkName)
        let fileManager = FileManager.default

        do {
            try fileManager.createDirectory(at: binDir, withIntermediateDirectories: true)

            if let existing = try? fileManager.destinationOfSymbolicLink(atPath: linkURL.path) {
                // Symlink existiert bereits.
                let resolvedExisting = URL(fileURLWithPath: existing).resolvingSymlinksInPath().path
                if resolvedExisting == target.resolvingSymlinksInPath().path {
                    return // schon korrekt verlinkt
                }
                try fileManager.removeItem(at: linkURL)
            } else if fileManager.fileExists(atPath: linkURL.path) {
                // Reguläre Datei am Zielpfad — nicht überschreiben (könnte ein
                // vom User platziertes Binary sein).
                Logger.debug("[CLI] \(linkURL.path) ist eine reguläre Datei — Symlink nicht angelegt.")
                return
            }

            try fileManager.createSymbolicLink(at: linkURL, withDestinationURL: target)
            Logger.debug("[CLI] Symlink angelegt: \(linkURL.path) → \(target.path)")
        } catch {
            Logger.debug("[CLI] Symlink-Install fehlgeschlagen: \(error.localizedDescription)")
        }
    }

    /// Pfad zum laufenden Binary (im Bundle: …/Contents/MacOS/WhisperM8).
    private static func currentExecutableURL() -> URL? {
        if let executableURL = Bundle.main.executableURL {
            return executableURL.resolvingSymlinksInPath()
        }
        if let first = CommandLine.arguments.first {
            return URL(fileURLWithPath: first).resolvingSymlinksInPath()
        }
        return nil
    }
}
