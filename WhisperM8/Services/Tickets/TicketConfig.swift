import Foundation

// MARK: - Zuordnung Projekt ↔ Team ↔ Workspace

/// Welches Projekt zu welchem Team im Ticket-Werkzeug gehört und in welchem
/// Workspace das Team liegt. Liegt als `tickets.json` bei den eigenen Daten
/// der App. Geschrieben wird die Datei von `whisperm8 tickets setup` und
/// später von den Einstellungen; sie enthält nichts Geheimes.
///
/// Ein Workspace ist ein eigener Mandant mit eigenem Zugang (bei Linear das
/// Kürzel aus `linear.app/<Kürzel>`). Mehrere Workspaces sind der Normalfall,
/// sobald jemand für mehr als eine Firma arbeitet.
struct TicketConfig: Codable, Equatable {
    var version = 1
    /// Projektordner (absoluter Pfad) → Team-Kürzel, z. B. `WM8`.
    var teamsByProjectPath: [String: String] = [:]
    /// Team-Kürzel → Workspace, z. B. `WM8` → `whisperm8`.
    var workspacesByTeam: [String: String] = [:]
    /// Workspaces, für die ein Zugang hinterlegt wurde.
    var workspaces: [String] = []
    /// Projektordner → Datei mit der Tabelle Bereich, Ordner, Projekt (relativ
    /// zum Projektordner). `tickets doctor` prüft sie gegen das Ticket-Werkzeug.
    var areasFileByProjectPath: [String: String] = [:]

    init() {}

    /// Dateien aus der Zeit vor den Workspaces kennen die neuen Felder nicht.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        teamsByProjectPath = try container.decodeIfPresent([String: String].self, forKey: .teamsByProjectPath) ?? [:]
        workspacesByTeam = try container.decodeIfPresent([String: String].self, forKey: .workspacesByTeam) ?? [:]
        workspaces = try container.decodeIfPresent([String].self, forKey: .workspaces) ?? []
        areasFileByProjectPath = try container.decodeIfPresent([String: String].self, forKey: .areasFileByProjectPath) ?? [:]
    }

    /// Team für ein Verzeichnis: das Projekt mit dem längsten passenden Pfad,
    /// damit auch Arbeitsordner unterhalb des Projekts (Worktrees) passen.
    func team(forDirectory directory: String) -> String? {
        let path = Self.normalized(directory)
        return teamsByProjectPath
            .filter { Self.contains($0.key, path) }
            .max { $0.key.count < $1.key.count }?
            .value
    }

    /// Liegt `path` im Projektordner `project`? Ohne Groß/Klein: Das Dateisystem
    /// von macOS unterscheidet nicht, und ein Ordner, der wegen `ListM8` statt
    /// `listm8` als „kein Projekt“ gälte, hätte auch keine Schreibsperre.
    private static func contains(_ project: String, _ path: String) -> Bool {
        let project = project.lowercased(), path = path.lowercased()
        return path == project || path.hasPrefix(project + "/")
    }

    /// Projektordner zu einem Verzeichnis (für „Chats dieses Projekts“).
    func projectPath(forDirectory directory: String) -> String? {
        let path = Self.normalized(directory)
        return teamsByProjectPath.keys
            .filter { Self.contains($0, path) }
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

    // MARK: Workspaces

    /// Alle bekannten Workspaces, sortiert.
    var knownWorkspaces: [String] {
        Set(workspaces + workspacesByTeam.values).sorted()
    }

    /// Alle Teams, die die Einrichtung kennt, sortiert.
    var knownTeams: [String] {
        Set(Array(teamsByProjectPath.values) + Array(workspacesByTeam.keys)).sorted()
    }

    /// Workspace eines Teams. Gibt es nur einen Workspace, liegt jedes Team
    /// dort; bei mehreren muss das Team zugeordnet sein, es wird nie geraten.
    func workspace(forTeam team: String) -> String? {
        if let mapped = workspacesByTeam[team.uppercased()] { return mapped }
        let known = knownWorkspaces
        return known.count == 1 ? known[0] : nil
    }

    /// Workspace, zu dem ein Verzeichnis über sein Projekt gehört.
    func workspace(forDirectory directory: String) -> String? {
        team(forDirectory: directory).flatMap(workspace(forTeam:))
    }

    mutating func add(workspace: String) {
        let name = workspace.lowercased()
        if !workspaces.contains(name) { workspaces = (workspaces + [name]).sorted() }
    }

    mutating func set(workspace: String, forTeam team: String) {
        add(workspace: workspace)
        workspacesByTeam[team.uppercased()] = workspace.lowercased()
    }

    mutating func removeProject(_ directory: String) {
        teamsByProjectPath[Self.normalized(directory)] = nil
        areasFileByProjectPath[Self.normalized(directory)] = nil
    }

    /// Kürzel eines Workspaces, wie Linear es in der Adresse führt. Es wandert
    /// in eine Befehlszeile von `security -i`, also nur harmlose Zeichen.
    static func isWorkspaceName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 64 && name.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") }
    }

    /// Team-Kürzel aus einer Ticket-Nummer: `WM8-12` → `WM8`.
    static func team(ofKey key: String) -> String {
        String(key.uppercased().split(separator: "-").first ?? "")
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

    struct Unreadable: Error {}

    /// Änderungen aus der App nacheinander: lesen, ändern, schreiben.
    static let changeQueue = DispatchQueue(label: "com.whisperm8.tickets.config")

    /// Für Änderungen: Eine vorhandene, aber unlesbare Datei ist ein Fehler.
    /// `load()` gäbe dafür eine leere Zuordnung zurück, und das nächste
    /// Speichern überschriebe alles, was in der Datei stand.
    func loadForChange() throws -> TicketConfig {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return TicketConfig() }
        guard let data = try? Data(contentsOf: fileURL),
              let config = try? JSONDecoder().decode(TicketConfig.self, from: data) else { throw Unreadable() }
        return config
    }

    func save(_ config: TicketConfig) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(config).write(to: fileURL, options: .atomic)
    }
}
