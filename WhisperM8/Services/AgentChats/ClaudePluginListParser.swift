import Foundation

/// Ein installiertes Claude-Code-Plugin aus `claude plugin list --json`.
/// Datums-Felder bleiben ISO-Strings (nur Anzeige, kein Rechnen) — lenient
/// gegenueber Format-Drift zwischen Claude-Versionen.
struct ClaudeInstalledPlugin: Decodable, Equatable, Identifiable {
    var id: String            // "doc-system@360-plugins"
    var version: String       // auch "unknown"
    var scope: String
    var enabled: Bool
    var installPath: String
    var installedAt: String?
    var lastUpdated: String?
    /// MCP-Server, die das Plugin mitbringt (Key = Servername). Nur die
    /// Namen interessieren (Vorschlaege fuer Context-Profile) — die Configs
    /// dahinter sind Claude-Interna.
    var mcpServers: [String: MCPServerStub]?

    struct MCPServerStub: Decodable, Equatable {
        var type: String?
        var url: String?
    }

    /// Anzeigename ohne Marketplace-Suffix ("doc-system").
    var displayName: String {
        id.split(separator: "@").first.map(String.init) ?? id
    }

    /// Marketplace-Teil der ID ("360-plugins"), leer wenn keiner.
    var marketplaceName: String {
        guard let at = id.firstIndex(of: "@") else { return "" }
        return String(id[id.index(after: at)...])
    }
}

/// Ein installierbares Plugin aus dem Marketplace-Katalog
/// (`claude plugin list --available --json`).
struct ClaudeAvailablePlugin: Decodable, Equatable, Identifiable {
    var pluginId: String
    var name: String
    var marketplaceName: String
    var description: String?
    var source: String?

    var id: String { pluginId }

    /// `source` ist je nach Marketplace ein String ("./plugins/x") oder ein
    /// strukturiertes Objekt (git/github-Quellen). Ein Objekt darf nicht den
    /// gesamten Katalog-Decode brechen → tolerant auf nil degradieren
    /// (Review-Befund 2026-07-19).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pluginId = try container.decode(String.self, forKey: .pluginId)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? pluginId
        marketplaceName = try container.decodeIfPresent(String.self, forKey: .marketplaceName) ?? ""
        description = try container.decodeIfPresent(String.self, forKey: .description)
        source = try? container.decodeIfPresent(String.self, forKey: .source)
    }

    private enum CodingKeys: String, CodingKey {
        case pluginId, name, marketplaceName, description, source
    }
}

/// Konfigurierter Marketplace aus `claude plugin marketplace list --json`.
/// Quelle variiert: git (url), github (repo), directory (path).
struct ClaudeMarketplace: Decodable, Equatable, Identifiable {
    var name: String
    var source: String
    var url: String?
    var repo: String?
    var path: String?
    var installLocation: String?

    var id: String { name }

    /// Menschlich lesbare Quelle, egal welche Variante.
    var sourceDetail: String {
        url ?? repo ?? path ?? source
    }
}

struct ClaudePluginList: Equatable {
    var installed: [ClaudeInstalledPlugin]
    var available: [ClaudeAvailablePlugin]
}

/// Pure Parser fuer die `claude plugin`-JSON-Outputs. Akzeptiert BEIDE
/// beobachteten Top-Level-Formen (verifiziert 2026-07-19, claude v2.x):
/// - `list --json`              → Top-Level-ARRAY (nur installed)
/// - `list --available --json`  → DICT `{"installed": […], "available": […]}`
/// Unbekannte Keys werden ignoriert; Format-Drift soll Anzeige-Luecken
/// erzeugen, nie Fehler in der Kern-Liste.
enum ClaudePluginListParser {
    static func parse(_ json: Data) throws -> ClaudePluginList {
        let decoder = JSONDecoder()
        if let installed = try? decoder.decode([ClaudeInstalledPlugin].self, from: json) {
            return ClaudePluginList(installed: installed, available: [])
        }
        let combined = try decoder.decode(CombinedList.self, from: json)
        return ClaudePluginList(
            installed: combined.installed ?? [],
            available: combined.available ?? []
        )
    }

    static func parseMarketplaces(_ json: Data) throws -> [ClaudeMarketplace] {
        try JSONDecoder().decode([ClaudeMarketplace].self, from: json)
    }

    private struct CombinedList: Decodable {
        var installed: [ClaudeInstalledPlugin]?
        var available: [ClaudeAvailablePlugin]?
    }
}
