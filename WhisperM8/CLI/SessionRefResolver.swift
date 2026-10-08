import Foundation

// MARK: - Referenz-Auflösung für `whisperm8 chats <ref>`

/// Kandidat für Fehlermeldungen bei Mehrdeutigkeit — genug Kontext, damit der
/// Aufrufer (Mensch oder Agent) im nächsten Versuch präzisieren kann.
struct SessionRefCandidate: Equatable {
    var id: UUID
    var title: String
    var projectName: String
    var lastActivityAt: Date
}

enum SessionRefError: Error, Equatable {
    case notFound(ref: String)
    case ambiguous(ref: String, candidates: [SessionRefCandidate])
    /// `@self` ohne `WHISPERM8_SESSION_ID` in der Umgebung.
    case noSelfContext
}

/// Purer Resolver — tmux-Prinzip: Fuzzy ist erlaubt, aber nie heuristisch.
/// Mehrdeutigkeit ist IMMER ein Fehler (Exit 3), für Lese- wie für
/// Schreib-Befehle. Fünf Stufen, erste treffende gewinnt:
///
/// 1. `@self` → UUID aus der Aufrufer-Identität
/// 2. Voll-UUID (case-insensitiv, exakt) — WhisperM8-ID, sonst die
///    Session-ID der CLI (`externalSessionID`)
/// 3. Hex-Präfix ≥ 8 Zeichen (Bindestriche optional) auf beide IDs
///
/// Die CLI-Session-ID gehört dazu, weil Agenten Chats oft über das Transcript
/// finden (`~/.claude*/projects/…/<id>.jsonl`) und nur diese ID kennen — ohne
/// sie meldete `show`/`resume` „nicht gefunden" für Chats, die existieren.
/// 4. `projekt/titel-fragment` — beide Seiten fuzzy, Ergebnis muss eindeutig sein
/// 5. Titel-Fragment global — muss eindeutig sein
enum SessionRefResolver {
    static let minimumHexPrefixLength = 8
    static let maxCandidatesInError = 5

    static func resolve(
        ref: String,
        entries: [ChatsSessionEntry],
        selfID: UUID?,
        includeArchived: Bool = false
    ) -> Result<ChatsSessionEntry, SessionRefError> {
        let scope = entries.filter { includeArchived || $0.session.status != .archived }
        let trimmed = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.notFound(ref: ref)) }

        // Stufe 1: @self
        if trimmed == "@self" {
            guard let selfID else { return .failure(.noSelfContext) }
            guard let entry = scope.first(where: { $0.session.id == selfID }) else {
                return .failure(.notFound(ref: ref))
            }
            return .success(entry)
        }

        // Stufe 2: Voll-UUID. Die WhisperM8-ID gewinnt; erst ohne Treffer
        // zählt die CLI-Session-ID. Die kann nach Kontowechsel/Fork an mehr
        // als einer Session hängen — dann mehrdeutig statt erste Wahl.
        if let uuid = UUID(uuidString: trimmed) {
            if let entry = scope.first(where: { $0.session.id == uuid }) {
                return .success(entry)
            }
            let wanted = compactID(uuid.uuidString)
            let external = scope.filter { $0.session.externalSessionID.map(compactID) == wanted }
            if external.count == 1 { return .success(external[0]) }
            if external.count > 1 { return .failure(ambiguity(ref: ref, matches: external)) }
            return .failure(.notFound(ref: ref))
        }

        // Stufe 3: Hex-Präfix ≥ 8. Gewinnt bewusst VOR dem Titel-Match —
        // ein 8-Zeichen-Hex-String, der zufällig ein Wort ist („cafebabe"),
        // wird als UUID-Präfix interpretiert; trifft er keine UUID, fällt er
        // auf die Titel-Stufen durch.
        let hexCandidate = trimmed.replacingOccurrences(of: "-", with: "").lowercased()
        if hexCandidate.count >= minimumHexPrefixLength,
           hexCandidate.allSatisfy({ $0.isHexDigit }) {
            let matches = scope.filter {
                compactID($0.session.id.uuidString).hasPrefix(hexCandidate)
                    || ($0.session.externalSessionID.map(compactID)?.hasPrefix(hexCandidate) ?? false)
            }
            if matches.count == 1 { return .success(matches[0]) }
            if matches.count > 1 { return .failure(ambiguity(ref: ref, matches: matches)) }
            // 0 Treffer → weiter mit Titel-Stufen.
        }

        // Stufe 4: projekt/titel
        if trimmed.contains("/") {
            let parts = trimmed.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return .failure(.notFound(ref: ref)) }
            let projectFragment = normalize(parts[0])
            let titleFragment = normalize(parts[1])
            let inProject = scope.filter { entry in
                let lastPathSegment = (entry.projectPath as NSString).lastPathComponent
                return normalize(entry.projectName).contains(projectFragment)
                    || normalize(lastPathSegment).contains(projectFragment)
            }
            return uniqueTitleMatch(ref: ref, fragment: titleFragment, in: inProject)
        }

        // Stufe 5: Titel global (Titel, dann Gruppenname)
        return uniqueTitleMatch(ref: ref, fragment: normalize(trimmed), in: scope)
    }

    // MARK: - Matching

    /// IDs ohne Bindestriche, lowercased — Vergleichsform für Voll- und Präfix-Match.
    private static func compactID(_ raw: String) -> String {
        raw.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private static func uniqueTitleMatch(
        ref: String,
        fragment: String,
        in scope: [ChatsSessionEntry]
    ) -> Result<ChatsSessionEntry, SessionRefError> {
        guard !fragment.isEmpty else { return .failure(.notFound(ref: ref)) }
        var matches = scope.filter { normalize($0.session.title).contains(fragment) }
        if matches.isEmpty {
            matches = scope.filter { entry in
                guard let group = entry.session.groupName else { return false }
                return normalize(group).contains(fragment)
            }
        }
        if matches.isEmpty {
            // Subsequenz-Fallback: „pillre" trifft „pill-redesign".
            matches = scope.filter { isSubsequence(fragment, of: normalize($0.session.title)) }
        }
        switch matches.count {
        case 0: return .failure(.notFound(ref: ref))
        case 1: return .success(matches[0])
        default: return .failure(ambiguity(ref: ref, matches: matches))
        }
    }

    private static func ambiguity(ref: String, matches: [ChatsSessionEntry]) -> SessionRefError {
        let candidates = matches
            .sorted { $0.session.lastActivityAt > $1.session.lastActivityAt }
            .prefix(maxCandidatesInError)
            .map {
                SessionRefCandidate(
                    id: $0.session.id,
                    title: $0.session.title,
                    projectName: $0.projectName,
                    lastActivityAt: $0.session.lastActivityAt
                )
            }
        return .ambiguous(ref: ref, candidates: Array(candidates))
    }

    /// Normalisierung für Fuzzy-Matching: lowercased, Diakritika gefaltet
    /// („ü" → „u"), jede Nicht-Alphanumerik zu einem Leerzeichen kollabiert.
    static func normalize(_ raw: String) -> String {
        let folded = raw.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        var result = ""
        var lastWasSeparator = true
        for char in folded {
            if char.isLetter || char.isNumber {
                result.append(char)
                lastWasSeparator = false
            } else if !lastWasSeparator {
                result.append(" ")
                lastWasSeparator = true
            }
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    private static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        // Leerzeichen der normalisierten Fragmente ignorieren — Subsequenz
        // arbeitet auf den Sichtzeichen.
        let compactNeedle = needle.filter { !$0.isWhitespace }
        guard !compactNeedle.isEmpty else { return false }
        var iterator = compactNeedle.makeIterator()
        var current = iterator.next()
        for char in haystack where char == current {
            current = iterator.next()
            if current == nil { return true }
        }
        return current == nil
    }
}
