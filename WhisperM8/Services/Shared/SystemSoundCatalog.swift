import AppKit

/// Katalog der macOS-System-Sounds (`/System/Library/Sounds/*.aiff`) für den
/// Agent-Fertig-Ton-Picker. Rein lesend; das Abspielen läuft über `NSSound`.
enum SystemSoundCatalog {
    static let defaultDirectory = URL(fileURLWithPath: "/System/Library/Sounds", isDirectory: true)
    static let fallbackSoundName = "Glass"

    /// Alphabetisch sortierte Sound-Namen (Datei-Stems). Leere Liste, wenn das
    /// Verzeichnis fehlt — der Picker fällt dann auf den Default zurück.
    static func availableSoundNames(directory: URL = defaultDirectory) -> [String] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        let names = entries
            .filter { ["aiff", "aif", "caf"].contains($0.pathExtension.lowercased()) }
            .map { $0.deletingPathExtension().lastPathComponent }
        return Array(Set(names)).sorted()
    }

    /// Spielt einen System-Sound; unbekannte Namen fallen auf „Glass" zurück,
    /// damit ein verwaister Preference-Wert nie stummschaltet.
    static func play(_ name: String) {
        let sound = NSSound(named: name) ?? NSSound(named: fallbackSoundName)
        sound?.play()
    }
}
