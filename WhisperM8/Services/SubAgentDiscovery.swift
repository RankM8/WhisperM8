import Foundation

/// Ein Sub-Agent (Custom Agent) — Markdown-File mit YAML-Frontmatter unter
/// `~/.claude/agents/<name>.md` (User-Scope) oder `<project>/.claude/agents/<name>.md`
/// (Projekt-Scope). Anthropics offizielle Schema-Felder die wir aus dem
/// Frontmatter ausschneiden: `name`, `description`, `tools`, `model`, `color`,
/// `permissionMode`, `isolation`.
///
/// Wir parsen das Frontmatter **nicht** als generisches YAML — das Format
/// ist eng genug, dass wir Top-Level-Keys per Zeilen-Match extrahieren
/// koennen. Das vermeidet eine YAML-Dependency und ist robust genug fuer
/// die Discovery-Anzeige im Dispatch-Modal.
struct SubAgent: Identifiable, Equatable, Hashable {
    enum Scope: String, Equatable {
        case user      // ~/.claude/agents/
        case project   // <project>/.claude/agents/
    }

    /// Der `name`-Frontmatter-Eintrag (oder der File-Stem als Fallback).
    /// Wird in der CLI als `@<name>` referenziert.
    let name: String
    /// `description` aus dem Frontmatter (zeigt das Modal als Sub-Title).
    let description: String?
    /// `color` (hex oder palette name) fuer den UI-Indicator.
    let color: String?
    /// Tools-Liste aus dem Frontmatter (z. B. `[Read, Glob, Grep]`). Roh als
    /// String — wir machen daraus erst Anzeige-Text.
    let toolsRaw: String?
    /// `model`-Override, falls gesetzt.
    let model: String?
    /// `permissionMode` aus dem Frontmatter (Override fuer Dispatch).
    let permissionMode: String?
    /// `isolation: worktree` → erzwingt Worktree-Spawn.
    let isolationWorktree: Bool
    /// Absoluter File-Pfad der Markdown-Datei.
    let fileURL: URL
    /// Wo der Sub-Agent definiert wurde.
    let scope: Scope

    /// Identifier fuer SwiftUI — `name` plus Scope, damit gleichnamige
    /// User-/Project-Agents sich nicht ueberschreiben.
    var id: String { "\(scope.rawValue):\(name)" }

    /// `true` wenn der Frontmatter-Eintrag eine Tools-Beschraenkung definiert.
    var hasToolsRestriction: Bool {
        guard let raw = toolsRaw?.trimmingCharacters(in: .whitespaces) else { return false }
        return !raw.isEmpty && raw.lowercased() != "default"
    }
}

/// Discovery-Service der `~/.claude/agents/` und `<project>/.claude/agents/`
/// nach `*.md`-Dateien scannt und die wichtigsten Frontmatter-Felder
/// extrahiert. Lazily — kein Caching auf Disk; das File-System ist schnell
/// genug und Sub-Agent-Listen sind klein (typisch <20).
enum SubAgentDiscovery {
    /// Default-Suchpfade: zuerst Projekt-Scope (gewinnt bei Namensgleichheit),
    /// dann User-Scope.
    static func discover(projectPath: String?) -> [SubAgent] {
        var seen: Set<String> = []
        var result: [SubAgent] = []

        if let projectPath {
            let projectDir = URL(fileURLWithPath: projectPath)
                .appendingPathComponent(".claude", isDirectory: true)
                .appendingPathComponent("agents", isDirectory: true)
            for agent in scan(directory: projectDir, scope: .project) {
                if !seen.contains(agent.name) {
                    seen.insert(agent.name)
                    result.append(agent)
                }
            }
        }

        let userDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("agents", isDirectory: true)
        for agent in scan(directory: userDir, scope: .user) {
            if !seen.contains(agent.name) {
                seen.insert(agent.name)
                result.append(agent)
            }
        }

        return result.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    private static func scan(directory: URL, scope: SubAgent.Scope) -> [SubAgent] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var result: [SubAgent] = []
        for url in entries where url.pathExtension.lowercased() == "md" {
            if let agent = parse(fileURL: url, scope: scope) {
                result.append(agent)
            }
        }
        return result
    }

    /// Public fuer Tests — parsed ein einzelnes File. Liest die ersten ~16 KB
    /// um Multi-MB-Files mit YAML-Header nicht voll in den Speicher zu laden.
    static func parse(fileURL: URL, scope: SubAgent.Scope) -> SubAgent? {
        guard let data = try? Data(contentsOf: fileURL),
              let content = String(data: data.prefix(16 * 1024), encoding: .utf8)
        else {
            return nil
        }
        let fallbackName = fileURL.deletingPathExtension().lastPathComponent
        let parsed = parseFrontmatter(in: content)
        let name = (parsed["name"]?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 } ?? fallbackName
        return SubAgent(
            name: name,
            description: parsed["description"].map(stripQuotes),
            color: parsed["color"].map(stripQuotes),
            toolsRaw: parsed["tools"].map(stripQuotes),
            model: parsed["model"].map(stripQuotes),
            permissionMode: parsed["permissionMode"].map(stripQuotes)
                ?? parsed["permission_mode"].map(stripQuotes),
            isolationWorktree: (parsed["isolation"].map(stripQuotes)?.lowercased() == "worktree"),
            fileURL: fileURL,
            scope: scope
        )
    }

    /// Extrahiert Top-Level-Key/Value-Paare aus einem YAML-Frontmatter-Block
    /// (zwischen den ersten beiden `---`-Linien). Wir behandeln nur einfache
    /// `key: value`-Zeilen — keine verschachtelten Maps, keine Multi-Line-
    /// Werte. Anthropics Sub-Agent-Schema nutzt nur Single-Line-Felder, das
    /// reicht uns.
    static func parseFrontmatter(in source: String) -> [String: String] {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = lines.first, first.trimmingCharacters(in: .whitespaces) == "---" else {
            return [:]
        }
        var result: [String: String] = [:]
        var inFrontmatter = true
        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" {
                inFrontmatter = false
                break
            }
            guard inFrontmatter else { break }
            // Ignoriere Leerzeilen + Kommentare.
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            // Splitte beim ERSTEN `:` — Values koennen weitere `:` enthalten.
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = trimmed[..<colon].trimmingCharacters(in: .whitespaces)
            let value = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            // Skippe Block-Mappings ("description:" auf eigener Zeile ohne Wert).
            // Wir nehmen den Wert nur wenn er auf derselben Zeile steht.
            if value.isEmpty { continue }
            result[String(key)] = value
        }
        return result
    }

    /// Entfernt `"..."` oder `'...'` um einen YAML-Wert.
    static func stripQuotes(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else { return trimmed }
        let first = trimmed.first!
        let last = trimmed.last!
        if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            return String(trimmed.dropFirst().dropLast())
        }
        return trimmed
    }
}
