import Foundation

/// Geparste Ausgabe von `claude plugin details <name>` — das Kommando hat
/// kein `--json` (verifiziert 2026-07-19), deshalb Text-Parsing. Alle Felder
/// optional: Format-Drift zwischen Claude-Versionen darf nur Anzeige-Luecken
/// erzeugen, nie Fehler.
struct ClaudePluginDetails: Equatable {
    var name: String?
    var version: String?
    var descriptionText: String?
    var sourceID: String?
    var skillCount: Int?
    var agentCount: Int?
    var hookCount: Int?
    var mcpServerCount: Int?
    var lspServerCount: Int?
    /// "Always-on: ~15,070 tok" → 15070. Der Kern-Wert fuer die UI
    /// (Kontext-Kosten, die JEDE Session zahlt).
    var alwaysOnTokens: Int?
    var components: [Component]

    struct Component: Equatable {
        var name: String
        var alwaysOnTokens: Int?
        var onInvokeTokens: Int?
    }
}

/// Pure, nie werfender Text-Parser (Muster `SupervisorJobReader.parse`:
/// defensives Lesen von Claude-Implementierungsdetails).
enum ClaudePluginDetailsParser {
    static func parse(_ stdout: String) -> ClaudePluginDetails {
        var details = ClaudePluginDetails(components: [])
        var inComponentTable = false
        var sawHeaderLine = false

        for rawLine in stdout.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            // Kopfzeile: "leadgenjay 1.0.0" — erste nicht-leere Zeile.
            if !sawHeaderLine, !line.isEmpty {
                sawHeaderLine = true
                let parts = line.split(separator: " ")
                details.name = parts.first.map(String.init)
                if parts.count >= 2 {
                    details.version = String(parts[1])
                }
                continue
            }

            if line.hasPrefix("Source:") {
                details.sourceID = line.dropFirst("Source:".count)
                    .trimmingCharacters(in: .whitespaces)
                continue
            }

            // Beschreibung: erste eingerueckte Textzeile nach dem Header,
            // vor "Source:"/Inventar.
            if details.descriptionText == nil,
               details.sourceID == nil,
               !line.isEmpty,
               !line.hasPrefix("Component inventory") {
                details.descriptionText = line
                continue
            }

            if let (kind, count) = parseInventoryLine(line) {
                switch kind {
                case "Skills": details.skillCount = count
                case "Agents": details.agentCount = count
                case "Hooks": details.hookCount = count
                case "MCP servers": details.mcpServerCount = count
                case "LSP servers": details.lspServerCount = count
                default: break
                }
                continue
            }

            if line.hasPrefix("Always-on:") {
                // "Always-on:   ~15,070 tok   added to every session"
                let payload = line.dropFirst("Always-on:".count)
                let firstToken = payload.split(separator: " ").first.map(String.init)
                details.alwaysOnTokens = firstToken.flatMap(tokenValue)
                continue
            }

            if line.hasPrefix("Per-component") {
                inComponentTable = true
                continue
            }

            if inComponentTable {
                // Tabellen-Header ("component ... always-on  on-invoke") und
                // Leerzeilen ueberspringen; Ende der Tabelle = naechste
                // Sektion ohne Spalten.
                if line.isEmpty || line.hasPrefix("component") { continue }
                if let component = parseComponentRow(rawLine: String(rawLine)) {
                    details.components.append(component)
                } else {
                    inComponentTable = false
                }
            }
        }
        return details
    }

    /// "Skills (103)  foo, bar" → ("Skills", 103). Nil fuer andere Zeilen.
    private static func parseInventoryLine(_ line: String) -> (String, Int)? {
        for kind in ["Skills", "Agents", "Hooks", "MCP servers", "LSP servers"] {
            guard line.hasPrefix("\(kind) (") else { continue }
            let rest = line.dropFirst(kind.count + 2)
            guard let close = rest.firstIndex(of: ")"),
                  let count = Int(rest[..<close]) else { return nil }
            return (kind, count)
        }
        return nil
    }

    /// Tabellenzeile "youtube-thumbnail     ~120      ~8.3k" — Spalten sind
    /// durch >=2 Spaces getrennt. Mindestens Name + ein Token-Wert, sonst
    /// keine Tabellenzeile (beendet die Tabelle).
    private static func parseComponentRow(rawLine: String) -> ClaudePluginDetails.Component? {
        let columns = rawLine
            .components(separatedBy: "  ")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard columns.count >= 2 else { return nil }
        let name = columns[0]
        // Eine Sektion-Ueberschrift haette keinen ~Wert in Spalte 2.
        let alwaysOn = columns.count >= 2 ? tokenValue(columns[1]) : nil
        let onInvoke = columns.count >= 3 ? tokenValue(columns[2]) : nil
        guard alwaysOn != nil || onInvoke != nil else { return nil }
        return ClaudePluginDetails.Component(
            name: name,
            alwaysOnTokens: alwaysOn,
            onInvokeTokens: onInvoke
        )
    }

    /// "~1,625" → 1625 · "~2k" → 2000 · "~8.3k" → 8300 · "~120 tok" → 120 ·
    /// "—"/"-"/Unfug → nil.
    static func tokenValue(_ raw: String) -> Int? {
        var text = raw.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("~") { text.removeFirst() }
        if text.hasSuffix("tok") {
            text = String(text.dropLast(3)).trimmingCharacters(in: .whitespaces)
        }
        text = text.replacingOccurrences(of: ",", with: "")
        guard !text.isEmpty else { return nil }
        if text.hasSuffix("k") || text.hasSuffix("K") {
            guard let value = Double(text.dropLast()) else { return nil }
            return Int((value * 1000).rounded())
        }
        return Int(text)
    }
}
