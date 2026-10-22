import Foundation

// MARK: - Tasks eines Claude-Chats (TaskCreate/TaskUpdate)
//
// Claude Code legt jede Task als `<config-dir>/tasks/<liste>/<id>.json` ab.
// Die App liest sie nur (fremde Daten unter ~/.claude*) und zeigt sie in der
// Notiz-Karte am Kachelkopf: Links aus `metadata.links` (die Mod
// `hooks/tasks.tsx` erklärt sie dem Modell) oder URLs im Text, Liste nach ID.
// Doku: docs/features/jarvis-board.md § Tasks in der Notiz-Karte.

struct AgentChatTask: Equatable, Identifiable, Sendable {
    enum Status: String, Sendable {
        case pending
        case inProgress = "in_progress"
        case completed
    }

    struct Link: Equatable, Hashable, Sendable {
        let label: String
        let url: URL
    }

    let id: String
    let subject: String
    /// Tätigkeit im Verlauf („Rendert die Snapshots“), nur bei laufenden gezeigt.
    let activeForm: String?
    let status: Status
    /// Agent oder Teammate, der die Task übernommen hat.
    let owner: String?
    let blockedBy: [String]
    let links: [Link]
}

enum AgentChatTaskParser {
    static let maxLinks = 6

    /// Eine Task-Datei; `nil` für kaputte oder gelöschte (`deleted`) Einträge.
    static func parse(_ data: Data) -> AgentChatTask? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"] as? String,
              let subject = object["subject"] as? String,
              let status = (object["status"] as? String).flatMap(AgentChatTask.Status.init(rawValue:)) else {
            return nil
        }
        let description = object["description"] as? String ?? ""
        return AgentChatTask(
            id: id,
            subject: subject,
            activeForm: nonEmpty(object["activeForm"] as? String),
            status: status,
            owner: nonEmpty(object["owner"] as? String),
            blockedBy: (object["blockedBy"] as? [Any])?.compactMap { $0 as? String } ?? [],
            links: links(subject: subject, description: description, metadata: object["metadata"])
        )
    }

    /// `metadata.links` als `[{label, url}]`, `{label: url}` oder Liste von
    /// URLs, dazu http(s)- und file-URLs aus Titel und Beschreibung. Doppelte
    /// fallen weg, andere Schemata (javascript:, …) ebenso.
    static func links(subject: String, description: String, metadata: Any?) -> [AgentChatTask.Link] {
        var found: [AgentChatTask.Link] = []
        func add(_ label: String?, _ raw: String?) {
            guard let raw = raw?.trimmingCharacters(in: .whitespaces), isAllowed(raw),
                  let url = URL(string: raw), !found.contains(where: { $0.url == url }) else { return }
            let text = nonEmpty(label?.trimmingCharacters(in: .whitespaces)) ?? shortLabel(for: url)
            found.append(.init(label: String(text.prefix(40)), url: url))
        }
        let links = (metadata as? [String: Any])?["links"]
        if let list = links as? [Any] {
            for item in list {
                if let raw = item as? String {
                    add(nil, raw)
                } else if let link = item as? [String: Any] {
                    add((link["label"] ?? link["title"]) as? String, (link["url"] ?? link["href"]) as? String)
                }
            }
        } else if let map = links as? [String: Any] {
            for key in map.keys.sorted() { add(key, map[key] as? String) }
        }
        for text in [subject, description] {
            for raw in urls(in: text) { add(nil, raw) }
        }
        return Array(found.prefix(maxLinks))
    }

    /// Laufende und offene vor erledigten? Nein: nach ID wie Claudes Liste,
    /// die Karte trennt die erledigten selbst ab. Numerisch („2“ vor „10“).
    static func sorted(_ tasks: [AgentChatTask]) -> [AgentChatTask] {
        tasks.sorted { a, b in
            if let x = Int(a.id), let y = Int(b.id) { return x < y }
            return a.id.localizedStandardCompare(b.id) == .orderedAscending
        }
    }

    private static func isAllowed(_ raw: String) -> Bool {
        let lower = raw.lowercased()
        return lower.hasPrefix("https://") || lower.hasPrefix("http://") || lower.hasPrefix("file://")
    }

    private static func shortLabel(for url: URL) -> String {
        if url.isFileURL { return url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent }
        let host = url.host ?? url.absoluteString
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private static let urlPattern = try! NSRegularExpression(pattern: #"\b(?:https?|file)://[^\s<>"'`)\]]+"#)

    private static func urls(in text: String) -> [String] {
        let range = NSRange(text.startIndex..., in: text)
        return urlPattern.matches(in: text, range: range).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?")) }
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}

/// Wo die Task-Liste eines Chats liegt. Claude Code nimmt den Teamnamen der
/// Session — der folgt nicht immer der Session-ID (mit `--session-id`
/// gestartet ein anderer) und steht nur im Hook `TaskCreated`/`TaskCompleted`
/// (`team_name`). Ohne Hook bleibt die Vermutung `session-<erste 8 Zeichen>`.
enum AgentChatTaskDirectory {
    /// Claudes Dateiname der Liste: alles außer `[A-Za-z0-9_-]` wird `-`.
    static func sanitize(_ name: String) -> String {
        String(name.unicodeScalars.map { scalar -> Character in
            let allowed = CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII
            return allowed || scalar == "_" || scalar == "-" ? Character(scalar) : "-"
        })
    }

    /// `<config>/projects/<cwd>/<id>.jsonl` → `<config>`.
    static func configDir(forTranscript url: URL) -> URL {
        url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    static func tasksRoot(configDir: URL) -> URL {
        configDir.appendingPathComponent("tasks", isDirectory: true)
    }

    static func listDirectory(configDir: URL, teamName: String) -> URL {
        tasksRoot(configDir: configDir).appendingPathComponent(sanitize(teamName), isDirectory: true)
    }

    /// Vermutete Ordner, wahrscheinlichster zuerst.
    static func guessedDirectories(configDir: URL, externalSessionID: String) -> [URL] {
        let id = externalSessionID.lowercased()
        return [
            listDirectory(configDir: configDir, teamName: "session-\(id.prefix(8))"),
            listDirectory(configDir: configDir, teamName: id),
        ]
    }

    /// Alle Tasks eines Ordners; fehlt er, keine.
    static func readTasks(in directory: URL, fileManager: FileManager = .default) -> [AgentChatTask] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return [] }
        let tasks = names
            .filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }
            .compactMap { name -> AgentChatTask? in
                guard let data = fileManager.contents(atPath: directory.appendingPathComponent(name).path) else { return nil }
                return AgentChatTaskParser.parse(data)
            }
        return AgentChatTaskParser.sorted(tasks)
    }
}

/// Zahlen und Sichtbarkeit für Karte und Pfeil.
enum AgentChatTaskSummary {
    /// Die Karte erscheint für Tasks nur, solange etwas läuft oder offen ist —
    /// ein Chat mit lauter erledigten Tasks soll das Grid nicht zustellen.
    static func hasOpen(_ tasks: [AgentChatTask]) -> Bool {
        tasks.contains { $0.status != .completed }
    }

    static func count(_ tasks: [AgentChatTask], _ status: AgentChatTask.Status) -> Int {
        tasks.reduce(0) { $0 + ($1.status == status ? 1 : 0) }
    }
}
