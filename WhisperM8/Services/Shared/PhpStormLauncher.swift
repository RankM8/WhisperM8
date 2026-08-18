import AppKit

/// Öffnet Dateien oder Projektordner in PhpStorm. Bevorzugt das gebündelte
/// JetBrains-CLI-Binary (`Contents/MacOS/phpstorm <pfad>`): bei mehreren offenen
/// Projekten weist es die laufende Instanz an, GENAU diesen Pfad zu öffnen bzw.
/// dessen Fenster zu fokussieren — `NSWorkspace.open` würde nur die App nach
/// vorne holen. Fällt auf `NSWorkspace.open(withApplicationAt:)` zurück.
///
/// **Dateien immer mit Projekt-Kontext öffnen:** Ein nackter Dateipfad lässt
/// PhpStorm ein NEUES Projekt im Ordner der Datei anlegen, wenn kein offenes
/// Projekt sie enthält (Befund 2026-08-19 aus dem Changes-Panel). Deshalb
/// stellt `launchArguments` der Datei das Projekt-Root voran
/// (`phpstorm <projekt> <datei>`) — PhpStorm öffnet/fokussiert dann das
/// richtige Projektfenster und die Datei darin. Das Root wird per
/// `.git`-Aufwärtssuche bestimmt (reiner Dateisystem-Check, kein Spawn).
enum PhpStormLauncher {
    static let bundleIdentifier = "com.jetbrains.PhpStorm"

    /// App-URL über die Bundle-ID, sonst der konventionelle Pfad.
    static var applicationURL: URL {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
            ?? URL(fileURLWithPath: "/Applications/PhpStorm.app")
    }

    /// `true`, wenn PhpStorm installiert ist (App-Bundle existiert).
    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: applicationURL.path)
    }

    /// Pure, testbar: die argv für das CLI-Binary. Regeln:
    /// - Projektpfad == Dateipfad (Projekt selbst öffnen) → ein Argument.
    /// - Hint gültig (enthält die Datei UND ist Git-Root) → `[hint, datei]`.
    /// - Sonst Git-Root aufwärts ab der Datei suchen → `[root, datei]`.
    /// - Kein Root auffindbar → nur die Datei (bisheriges Verhalten).
    static func launchArguments(
        filePath: String,
        projectPathHint: String?,
        hasGitDirectory: (String) -> Bool
    ) -> [String] {
        func contains(_ directory: String, _ path: String) -> Bool {
            let prefix = directory.hasSuffix("/") ? directory : directory + "/"
            return path.hasPrefix(prefix)
        }

        if let hint = projectPathHint, hint == filePath {
            return [filePath]
        }
        if let hint = projectPathHint, contains(hint, filePath), hasGitDirectory(hint) {
            return [hint, filePath]
        }
        // Aufwärtssuche ab dem Ordner der Datei (begrenzt — Endlosschleifen
        // bei kaputten Pfaden ausgeschlossen).
        var directory = (filePath as NSString).deletingLastPathComponent
        for _ in 0..<24 {
            guard directory.count > 1 else { break }
            if hasGitDirectory(directory) {
                return [directory, filePath]
            }
            directory = (directory as NSString).deletingLastPathComponent
        }
        return [filePath]
    }

    /// Öffnet `path` (Datei ODER Ordner) in PhpStorm; `projectPath` ist der
    /// bevorzugte Projekt-Kontext (z. B. das WhisperM8-Projekt der Session).
    /// - Returns: `false`, wenn PhpStorm nicht verfügbar ist bzw. der Start
    ///   fehlschlug — dann sollte der Aufrufer auf die Standard-App ausweichen.
    @discardableResult
    @MainActor
    static func open(path: String, projectPath: String? = nil) -> Bool {
        let appURL = applicationURL
        guard FileManager.default.fileExists(atPath: appURL.path) else { return false }

        // 1. Gebündeltes CLI-Binary (fokussiert das exakte Projekt/Fenster).
        let binaryURL = appURL.appendingPathComponent("Contents/MacOS/phpstorm")
        if FileManager.default.isExecutableFile(atPath: binaryURL.path) {
            let process = Process()
            process.executableURL = binaryURL
            process.arguments = launchArguments(
                filePath: path,
                projectPathHint: projectPath,
                hasGitDirectory: { directory in
                    FileManager.default.fileExists(atPath: directory + "/.git")
                }
            )
            if (try? process.run()) != nil { return true }
        }

        // 2. Fallback: App da, aber Binary-Start ging nicht → via NSWorkspace.
        NSWorkspace.shared.open(
            [URL(fileURLWithPath: path)],
            withApplicationAt: appURL,
            configuration: NSWorkspace.OpenConfiguration(),
            completionHandler: nil
        )
        return true
    }
}
