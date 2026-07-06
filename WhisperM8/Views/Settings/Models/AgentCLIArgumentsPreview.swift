import Foundation

enum AgentCLIArgumentsPreview {
    static func preview(binary: String, extraArguments: String) -> String {
        ([binary] + parseArguments(extraArguments))
            .map(renderArgument)
            .joined(separator: " ")
    }

    /// Gleiche kleine Parser-Semantik wie `AgentCommandBuilder.parseArguments`.
    /// Die Funktion ist hier nachgebaut, weil das Settings-Modell rein und
    /// separat testbar bleiben soll.
    private static func parseArguments(_ raw: String) -> [String] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var result: [String] = []
        var current = ""
        var quote: Character?

        for character in trimmed {
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else {
                    current.append(character)
                }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character.isWhitespace {
                if !current.isEmpty {
                    result.append(current)
                    current = ""
                }
            } else {
                current.append(character)
            }
        }

        if !current.isEmpty {
            result.append(current)
        }

        return result
    }

    private static func renderArgument(_ argument: String) -> String {
        guard argument.contains(where: { $0.isWhitespace }) else {
            return argument
        }

        let escaped = argument
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
