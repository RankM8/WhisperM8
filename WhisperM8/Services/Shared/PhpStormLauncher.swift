import AppKit

/// Öffnet Dateien oder Projektordner in PhpStorm. Bevorzugt das gebündelte
/// JetBrains-CLI-Binary (`Contents/MacOS/phpstorm <pfad>`): bei mehreren offenen
/// Projekten weist es die laufende Instanz an, GENAU diesen Pfad zu öffnen bzw.
/// dessen Fenster zu fokussieren — `NSWorkspace.open` würde nur die App nach
/// vorne holen. Fällt auf `NSWorkspace.open(withApplicationAt:)` zurück.
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

    /// Öffnet `path` (Datei ODER Ordner) in PhpStorm.
    /// - Returns: `false`, wenn PhpStorm nicht verfügbar ist bzw. der Start
    ///   fehlschlug — dann sollte der Aufrufer auf die Standard-App ausweichen.
    @discardableResult
    @MainActor
    static func open(path: String) -> Bool {
        let appURL = applicationURL
        guard FileManager.default.fileExists(atPath: appURL.path) else { return false }

        // 1. Gebündeltes CLI-Binary (fokussiert das exakte Projekt/Fenster).
        let binaryURL = appURL.appendingPathComponent("Contents/MacOS/phpstorm")
        if FileManager.default.isExecutableFile(atPath: binaryURL.path) {
            let process = Process()
            process.executableURL = binaryURL
            process.arguments = [path]
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
