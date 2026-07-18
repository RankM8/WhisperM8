import Foundation
import Observation

/// Persistenter Bestand der Context-Profile (`ClaudeContextProfile`).
///
/// Eigene JSON-Datei `claude-context-profiles.json` im App-Support —
/// bewusst NICHT AppPreferences (strukturierte CRUD-Liste, von Services
/// ohne UserDefaults-Kopplung lesbar) und NICHT die Workspace-JSON
/// (Profile sind app-weit, nicht workspace-gebunden). Die Datei ist klein;
/// jede Mutation persistiert sofort atomisch.
///
/// `@MainActor .shared`-Singleton wie `AgentWorkspaceUIModel`: alle Fenster
/// sehen denselben Stand, SwiftUI observiert `profiles` direkt.
@MainActor
@Observable
final class ClaudeContextProfileStore {
    static let shared = ClaudeContextProfileStore()

    private(set) var profiles: [ClaudeContextProfile] = []

    private let fileURL: URL

    /// Datei-Container mit Schema-Version fuer spaetere Migrationen.
    /// Dekodierung lenient (fehlende Keys → Defaults), damit weder aeltere
    /// App-Versionen noch Hand-Edits den Bestand verwerfen.
    private struct FileContainer: Codable {
        static let currentSchemaVersion = 1
        var schemaVersion: Int
        var profiles: [ClaudeContextProfile]

        init(profiles: [ClaudeContextProfile]) {
            self.schemaVersion = Self.currentSchemaVersion
            self.profiles = profiles
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
            profiles = try container.decodeIfPresent([ClaudeContextProfile].self, forKey: .profiles) ?? []
        }
    }

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        self.profiles = Self.load(from: self.fileURL)
    }

    static func defaultFileURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WhisperM8", isDirectory: true)
            .appendingPathComponent("claude-context-profiles.json")
    }

    // MARK: - CRUD

    /// Legt an oder aktualisiert (per ID) und persistiert sofort.
    func upsert(_ profile: ClaudeContextProfile) throws {
        var updated = profile
        updated.updatedAt = Date()
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = updated
        } else {
            profiles.append(updated)
        }
        try persist()
    }

    func delete(id: UUID) throws {
        profiles.removeAll { $0.id == id }
        try persist()
    }

    // MARK: - Aufloesung

    /// Lenient: unbekannte/geloeschte ID → nil (Launch ohne Overlay).
    func profile(id: UUID?) -> ClaudeContextProfile? {
        guard let id else { return nil }
        return profiles.first { $0.id == id }
    }

    /// Aufgeloestes Profil einer Session: Session-Stempel > Projekt-Default
    /// > nil. Ein gestempeltes, aber inzwischen geloeschtes Profil faellt
    /// bewusst NICHT auf den Projekt-Default zurueck — die Session wurde
    /// explizit mit diesem Profil gestartet; still ein anderes anzuwenden
    /// waere ueberraschender als gar keins.
    func resolvedProfile(sessionStamp: UUID?, projectDefault: UUID?) -> ClaudeContextProfile? {
        if let sessionStamp {
            let resolved = profile(id: sessionStamp)
            if resolved == nil {
                Logger.agentStore.warning("context_profile_missing id=\(sessionStamp.uuidString, privacy: .public)")
            }
            return resolved
        }
        return profile(id: projectDefault)
    }

    // MARK: - Persistenz

    private static func load(from fileURL: URL) -> [ClaudeContextProfile] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(FileContainer.self, from: data).profiles
        } catch {
            Logger.agentStore.warning("context_profiles_load_failed error=\(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    private func persist() throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(FileContainer(profiles: profiles))
        try data.write(to: fileURL, options: .atomic)
    }
}
