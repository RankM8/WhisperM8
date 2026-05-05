import Foundation

enum TextNormalizer {
    static func normalizeTranscriptionText(_ text: String) -> String {
        let extendedWhitespace = CharacterSet.whitespacesAndNewlines
            .union(.controlCharacters)
            .union(CharacterSet(charactersIn: "\u{00A0}\u{200B}\u{200C}\u{200D}\u{2060}\u{FEFF}"))

        return text.trimmingCharacters(in: extendedWhitespace)
    }
}
