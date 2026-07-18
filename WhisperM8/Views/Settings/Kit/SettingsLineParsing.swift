import Foundation

/// Pure Parser fuer "eine Zeile pro Eintrag"-Textfelder in den Settings
/// (Context-Profil-Editor, Plugin-Install-Config): Zeilenlisten und
/// KEY=value-Paare. Leerzeilen und Whitespace werden verworfen.
enum SettingsLineParsing {
    static func parseLines(_ raw: String) -> [String] {
        raw.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func parseKeyValueLines(_ raw: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in parseLines(raw) {
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            result[key] = value
        }
        return result
    }
}
