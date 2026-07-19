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
    /// Dekodierung lenient (fehlende Keys → Defaults) und pro Profil
    /// verlusttolerant: EIN unlesbares Profil (kaputte UUID, Hand-Edit)
    /// verwirft nur sich selbst, nie den ganzen Bestand — sonst wuerde der
    /// naechste upsert die Datei mit dem leeren Bestand ueberschreiben
    /// (Review-Befund 2026-07-19).
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
            let lossy = try container.decodeIfPresent([FailableProfile].self, forKey: .profiles) ?? []
            profiles = lossy.compactMap(\.profile)
        }
    }

    /// Wrapper fuer element-weises tolerantes Dekodieren.
    private struct FailableProfile: Decodable {
        let profile: ClaudeContextProfile?

        init(from decoder: Decoder) throws {
            profile = try? ClaudeContextProfile(from: decoder)
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

    /// Legt an oder aktualisiert (per ID) und persistiert sofort. Schlaegt
    /// die Persistenz fehl, wird die In-Memory-Aenderung zurueckgerollt —
    /// sonst zeigte die UI einen Stand, den die Platte nie gesehen hat
    /// (Review-Befund 2026-07-19).
    func upsert(_ profile: ClaudeContextProfile) throws {
        let snapshot = profiles
        var updated = profile
        updated.updatedAt = Date()
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = updated
        } else {
            profiles.append(updated)
        }
        do {
            try persist()
        } catch {
            profiles = snapshot
            throw error
        }
    }

    func delete(id: UUID) throws {
        let snapshot = profiles
        profiles.removeAll { $0.id == id }
        do {
            try persist()
        } catch {
            profiles = snapshot
            throw error
        }
    }

    // MARK: - MCP-Sperren (vom MCP-Tab der Context-&-Plugins-Seite genutzt)

    /// Sperrt bzw. entsperrt einen MCP-Server in einem Profil. Connectoren
    /// wandern nach `deniedMcpServers`, config-basierte Server nach
    /// `disabledMcpjsonServers` — dieselbe Semantik wie der Settings-Overlay.
    func setServerBlocked(
        _ blocked: Bool,
        serverName: String,
        isConnector: Bool,
        profileID: UUID
    ) throws {
        guard var profile = profile(id: profileID) else { return }
        if isConnector {
            profile.deniedMcpServers.removeAll { $0 == serverName }
            if blocked { profile.deniedMcpServers.append(serverName) }
        } else {
            profile.disabledMcpjsonServers.removeAll { $0 == serverName }
            if blocked { profile.disabledMcpjsonServers.append(serverName) }
        }
        try upsert(profile)
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
            // Komplett unlesbare Datei (kein JSON): quarantaenisieren, damit
            // der naechste persist() den Bestand nicht endgueltig plattmacht
            // — der User kann das Backup von Hand retten.
            let quarantine = fileURL.deletingLastPathComponent()
                .appendingPathComponent("\(fileURL.lastPathComponent).decode-failed.bak")
            try? FileManager.default.removeItem(at: quarantine)
            try? FileManager.default.copyItem(at: fileURL, to: quarantine)
            Logger.agentStore.warning("context_profiles_load_failed error=\(error.localizedDescription, privacy: .public) quarantined=\(quarantine.lastPathComponent, privacy: .public)")
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
