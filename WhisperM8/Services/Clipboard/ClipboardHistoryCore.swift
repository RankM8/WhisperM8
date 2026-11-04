import Foundation

// MARK: - Reine Entscheidungen des Verlaufs (ohne AppKit, ohne Dateien)

enum ClipboardHistoryCore {
    // MARK: Erfassen oder verwerfen

    enum SkipReason: String, Equatable, Sendable {
        case disabled
        case paused
        case internalWrite
        case confidential
        case excludedApp
        case empty
        case tooLarge
    }

    enum CaptureDecision: Equatable, Sendable {
        case store
        case skip(SkipReason)
    }

    /// Entscheidet, ob ein Inhalt in den Verlauf darf. Reihenfolge ist
    /// Absicht: Vertrauliches wird nie gespeichert, egal woher es kommt.
    static func decide(
        enabled: Bool,
        paused: Bool,
        isInternalWrite: Bool,
        types: [String],
        sourceBundleID: String?,
        excludedApps: Set<String>
    ) -> CaptureDecision {
        if !enabled { return .skip(.disabled) }
        if paused { return .skip(.paused) }
        if isInternalWrite || types.contains(ClipboardInternalMarker.typeName) { return .skip(.internalWrite) }
        if PasteboardPrivacy.isConfidential(types) { return .skip(.confidential) }
        if let id = sourceBundleID?.lowercased(), excludedApps.contains(where: { $0.lowercased() == id }) {
            return .skip(.excludedApp)
        }
        return .store
    }

    // MARK: Einfügen mit Duplikat-Erkennung

    /// Fügt `entry` oben ein. Gibt es den Inhalt schon, wandert der alte
    /// Eintrag nach oben (Pin, ID und erste Kopierzeit bleiben, die Zähler
    /// laufen weiter) und `entry` wird verworfen.
    /// `replacedBlobs` nennt Dateien des verworfenen neuen Eintrags, die nicht
    /// gebraucht werden.
    static func insert(
        _ entry: ClipboardEntry,
        into entries: [ClipboardEntry]
    ) -> (entries: [ClipboardEntry], merged: Bool, discardedBlobs: [String]) {
        var list = entries
        if let index = list.firstIndex(where: { $0.contentHash == entry.contentHash && $0.kind == entry.kind }) {
            var existing = list.remove(at: index)
            existing.lastCopiedAt = entry.lastCopiedAt
            existing.copyCount += 1
            if entry.sourceBundleID != nil {
                existing.sourceBundleID = entry.sourceBundleID
                existing.sourceName = entry.sourceName
            }
            list.insert(existing, at: 0)
            // Blob-Dateien des neuen Eintrags wären Dubletten der vorhandenen.
            return (list, true, entry.blobFiles.filter { !existing.blobFiles.contains($0) })
        }
        list.insert(entry, at: 0)
        return (list, false, [])
    }

    // MARK: Kürzen

    /// Hält höchstens `maxUnpinned` nicht angepinnte Einträge (die neuesten).
    /// Angepinnte zählen nicht mit und bleiben immer.
    static func trim(
        _ entries: [ClipboardEntry],
        maxUnpinned: Int
    ) -> (kept: [ClipboardEntry], removed: [ClipboardEntry]) {
        let limit = max(1, maxUnpinned)
        let newestFirst = entries.sorted { $0.lastCopiedAt > $1.lastCopiedAt }
        var seenUnpinned = 0
        var removedIDs = Set<String>()
        for entry in newestFirst where !entry.isPinned {
            seenUnpinned += 1
            if seenUnpinned > limit { removedIDs.insert(entry.id) }
        }
        let kept = entries.filter { !removedIDs.contains($0.id) }
        let removed = entries.filter { removedIDs.contains($0.id) }
        return (kept, removed)
    }

    // MARK: Reihenfolge

    /// Chronologisch, neuester zuerst: Grundlage der CLI-Nummern (1 = neuester).
    static func chronological(_ entries: [ClipboardEntry]) -> [ClipboardEntry] {
        entries.sorted {
            if $0.lastCopiedAt != $1.lastCopiedAt { return $0.lastCopiedAt > $1.lastCopiedAt }
            return $0.id < $1.id
        }
    }

    /// Anzeige im Fenster: Angepinnte oben, jeweils neuester zuerst.
    static func displayOrder(_ entries: [ClipboardEntry]) -> [ClipboardEntry] {
        let ordered = chronological(entries)
        return ordered.filter(\.isPinned) + ordered.filter { !$0.isPinned }
    }

    // MARK: Nummer oder ID auflösen

    enum ResolveError: Error, Equatable {
        case notFound(String)
        case ambiguous(String)
        case outOfRange(Int, Int)
    }

    /// `ref` ist eine Nummer (1 = neuester Eintrag) oder eine ID bzw. ein
    /// eindeutiges Präfix davon (ab vier Zeichen).
    static func resolve(_ ref: String, in entries: [ClipboardEntry]) -> Result<ClipboardEntry, ResolveError> {
        let ordered = chronological(entries)
        let trimmed = ref.trimmingCharacters(in: .whitespaces)
        let needle = trimmed.lowercased()
        // Reine Zahl im Bereich = Nummer. Eine Zahl außerhalb gilt nur als
        // ID-Präfix, wenn sie vier Zeichen oder länger ist (IDs sind Hex).
        if let number = Int(trimmed) {
            if number >= 1, number <= ordered.count { return .success(ordered[number - 1]) }
            if needle.count < 4 { return .failure(.outOfRange(number, ordered.count)) }
        }
        guard needle.count >= 4 else { return .failure(.notFound(ref)) }
        let matches = ordered.filter { $0.id.lowercased().hasPrefix(needle) }
        switch matches.count {
        case 0: return .failure(.notFound(ref))
        case 1: return .success(matches[0])
        default: return .failure(.ambiguous(ref))
        }
    }

    // MARK: Suche

    /// Suche beim Tippen: Groß/Klein und Diakritika egal, jedes Wort der
    /// Eingabe muss vorkommen. Treffer weiter vorn und auf Wortanfängen
    /// ranken höher, bei Gleichstand der neuere Eintrag.
    /// `fullText` liefert den vollen Text, falls er nicht im Index steht.
    static func search(
        _ entries: [ClipboardEntry],
        query: String,
        fullText: (ClipboardEntry) -> String? = { $0.text }
    ) -> [ClipboardEntry] {
        let terms = query
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard !terms.isEmpty else { return displayOrder(entries) }

        var scored: [(entry: ClipboardEntry, score: Int)] = []
        for entry in entries {
            let haystack = searchableText(of: entry, fullText: fullText)
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            var total = 0
            var matchedAll = true
            for term in terms {
                guard let range = haystack.range(of: term) else { matchedAll = false; break }
                let position = haystack.distance(from: haystack.startIndex, to: range.lowerBound)
                var score = 1000 - min(position, 900)
                if position == 0 { score += 200 }
                else {
                    let before = haystack[haystack.index(before: range.lowerBound)]
                    if !before.isLetter && !before.isNumber { score += 80 }
                }
                total += score
            }
            if matchedAll { scored.append((entry, total + (entry.isPinned ? 25 : 0))) }
        }
        return scored.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.entry.lastCopiedAt > $1.entry.lastCopiedAt
        }.map(\.entry)
    }

    static func searchableText(of entry: ClipboardEntry, fullText: (ClipboardEntry) -> String?) -> String {
        var parts: [String] = []
        switch entry.kind {
        case .text:
            parts.append(fullText(entry) ?? entry.preview)
        case .image:
            parts.append(entry.preview)
        case .files:
            parts.append(contentsOf: entry.filePaths ?? [])
            parts.append(entry.preview)
        }
        if let name = entry.sourceName { parts.append(name) }
        return parts.joined(separator: "\n")
    }
}

/// Marker, mit dem die App eigene Schreibvorgänge auf der Zwischenablage
/// kennzeichnet (Einfügen aus dem Verlauf, Diktat-Paste). Der Monitor ignoriert
/// solche Inhalte; andere Apps sehen nur einen unbekannten Typ.
enum ClipboardInternalMarker {
    static let typeName = "com.whisperm8.app.clipboard-internal"
}
