import Foundation

// MARK: - Zuordnung Projekt ↔ Team

/// Welches Projekt zu welchem Team im Ticket-Werkzeug gehört. Liegt als
/// `tickets.json` bei den eigenen Daten der App. Geschrieben wird die Datei
/// von `whisperm8 tickets setup` und später von den Einstellungen; sie enthält
/// nichts Geheimes.
struct TicketConfig: Codable, Equatable {
    var version = 1
    /// Projektordner (absoluter Pfad) → Team-Kürzel, z. B. `WM8`.
    var teamsByProjectPath: [String: String] = [:]

    /// Team für ein Verzeichnis: das Projekt mit dem längsten passenden Pfad,
    /// damit auch Arbeitsordner unterhalb des Projekts (Worktrees) passen.
    func team(forDirectory directory: String) -> String? {
        let path = Self.normalized(directory)
        return teamsByProjectPath
            .filter { path == $0.key || path.hasPrefix($0.key + "/") }
            .max { $0.key.count < $1.key.count }?
            .value
    }

    /// Projektordner zu einem Verzeichnis (für „Chats dieses Projekts“).
    func projectPath(forDirectory directory: String) -> String? {
        let path = Self.normalized(directory)
        return teamsByProjectPath.keys
            .filter { path == $0 || path.hasPrefix($0 + "/") }
            .max { $0.count < $1.count }
    }

    /// Gibt es nur ein Team, gilt es überall.
    var onlyTeam: String? {
        let teams = Set(teamsByProjectPath.values)
        return teams.count == 1 ? teams.first : nil
    }

    func projectPaths(forTeam team: String) -> [String] {
        teamsByProjectPath.filter { $0.value.caseInsensitiveCompare(team) == .orderedSame }.map(\.key).sorted()
    }

    mutating func set(team: String, forProject directory: String) {
        teamsByProjectPath[Self.normalized(directory)] = team.uppercased()
    }

    static func normalized(_ path: String) -> String {
        let standardized = (path as NSString).standardizingPath
        return standardized.count > 1 && standardized.hasSuffix("/") ? String(standardized.dropLast()) : standardized
    }
}

struct TicketConfigStore {
    var fileURL: URL

    static var live: TicketConfigStore {
        TicketConfigStore(fileURL: AppInstance.applicationSupport
            .appendingPathComponent("WhisperM8", isDirectory: true)
            .appendingPathComponent("tickets.json"))
    }

    /// Fehlende oder unlesbare Datei: leere Zuordnung.
    func load() -> TicketConfig {
        guard let data = try? Data(contentsOf: fileURL),
              let config = try? JSONDecoder().decode(TicketConfig.self, from: data) else { return TicketConfig() }
        return config
    }

    func save(_ config: TicketConfig) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(config).write(to: fileURL, options: .atomic)
    }
}
