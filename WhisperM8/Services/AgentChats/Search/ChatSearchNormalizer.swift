import Foundation

/// Normalisierung für den Suchindex und die Query-Seite.
///
/// FTS5' `unicode61 remove_diacritics 2` faltet zwar `ö→o`, lässt `ß` aber
/// stehen — „grossen" findet damit kein „Größen". Deshalb wird ein eigener,
/// normalisierter Textstrom indexiert und die Query mit exakt derselben
/// Funktion behandelt. Beide Seiten MÜSSEN dieselbe Normalisierung
/// durchlaufen, sonst entstehen stille Nicht-Treffer.
///
/// Bewusst pur und ohne Locale-Abhängigkeit — die Ausgabe muss über
/// App-Neustarts und Systemsprachen hinweg byte-stabil sein, sonst passt ein
/// bestehender Index nicht mehr zur Query.
enum ChatSearchNormalizer {
    /// Version der Normalisierung. Änderungen hier machen bestehende Indizes
    /// ungültig → Reindex über `index_meta`.
    static let version = 1

    /// Deutsche Sonderfälle, die `remove_diacritics` nicht abdeckt.
    private static let expansions: [(Character, String)] = [
        ("ß", "ss"),
        ("æ", "ae"),
        ("ø", "o"),
        ("œ", "oe"),
        ("đ", "d"),
        ("ł", "l"),
    ]

    /// Klein, diakritikafrei, mit expandierten Sonderzeichen.
    static func normalize(_ text: String) -> String {
        let folded = text.folding(
            options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
            locale: nil
        )
        guard folded.contains(where: { char in expansions.contains { $0.0 == char } }) else {
            return folded
        }
        var result = ""
        result.reserveCapacity(folded.count + 8)
        for char in folded {
            if let expansion = expansions.first(where: { $0.0 == char }) {
                result.append(expansion.1)
            } else {
                result.append(char)
            }
        }
        return result
    }

    /// Übersetzt eine Nutzereingabe in einen sicheren FTS5-MATCH-Ausdruck.
    ///
    /// Nutzer tippen Suchbegriffe, keine FTS-Syntax — ein rohes Durchreichen
    /// würde bei `Lead-Kategorisierung` oder `"` mit einem SQL-Fehler
    /// abbrechen. Regeln: Wörter werden UND-verknüpft, `"…"` bleibt Phrase,
    /// alles andere wird als Literal gequotet.
    ///
    /// - Returns: `nil`, wenn die Query keine verwertbaren Token enthält.
    static func ftsExpression(for query: String) -> String? {
        var terms: [String] = []
        var current = ""
        var inPhrase = false

        func flushWord() {
            guard !current.isEmpty else { return }
            terms.append(quoted(current))
            current = ""
        }

        for char in normalize(query) {
            if char == "\"" {
                if inPhrase {
                    flushWord()
                } else {
                    flushWord()
                }
                inPhrase.toggle()
                continue
            }
            if inPhrase {
                current.append(char)
                continue
            }
            // Außerhalb von Phrasen trennt alles Nicht-Alphanumerische.
            if char.isLetter || char.isNumber {
                current.append(char)
            } else {
                flushWord()
            }
        }
        flushWord()

        let cleaned = terms.filter { $0 != "\"\"" }
        return cleaned.isEmpty ? nil : cleaned.joined(separator: " AND ")
    }

    /// FTS5-String-Literal: doppelte Anführungszeichen werden verdoppelt.
    /// Innerhalb eines Literals verlieren `-`, `*`, `:` und `NEAR` ihre
    /// Sonderbedeutung — genau das wollen wir für Nutzereingaben.
    private static func quoted(_ token: String) -> String {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\"" + trimmed.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
