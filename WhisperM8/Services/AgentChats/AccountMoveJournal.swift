import Foundation

/// Protokoll aller Konto-Umzuege, append-only als JSONL neben dem Workspace.
///
/// Ein Bulk-Umzug ist NICHT atomar — Dateibewegungen ueber mehrere
/// Verzeichnisse kennen keine Transaktion, und ein automatischer Rollback nach
/// halber Strecke kann selbst scheitern und einen schlechteren Zustand
/// hinterlassen als ein sauber berichteter Teilerfolg. Deshalb bleiben
/// Teilerfolge stehen und das Zurueckrollen ist eine ausdrueckliche Aktion.
/// Weil `ClaudeAccountProfiles.moveTranscript` symmetrisch ist, ist
/// „Rueckgaengig" derselbe Aufruf mit vertauschten Argumenten — kein
/// Sonderpfad, der eigenes Fehlerverhalten haette.
struct AccountMoveJournal {
    struct Entry: Codable, Equatable {
        /// Klammert die Eintraege eines Bedienvorgangs zusammen.
        var batchID: UUID
        var sessionID: UUID
        var sessionTitle: String
        /// `nil` = Haupt-Account.
        var fromProfile: String?
        var toProfile: String?
        /// Wurde wirklich eine Datei bewegt? `false` heisst: die Session hatte
        /// (noch) kein Transcript, nur der Stempel wurde gesetzt. Beim
        /// Zuruecknehmen darf dann ebenfalls nur gestempelt werden.
        var movedTranscript: Bool
        var timestamp: Date
    }

    var fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
    }

    static func defaultFileURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WhisperM8", isDirectory: true)
            .appendingPathComponent("account-moves.jsonl")
    }

    // MARK: - Schreiben

    /// Haengt einen Batch an. Fehler werden geloggt, nie geworfen: ein
    /// fehlendes Journal darf einen bereits erfolgten Umzug nicht nachtraeglich
    /// als gescheitert erscheinen lassen — die Dateien liegen dann ja schon im
    /// Ziel. Verloren geht nur der Komfort des Zurueckrollens.
    func append(_ entries: [Entry]) {
        guard !entries.isEmpty else { return }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            var payload = Data()
            for entry in entries {
                payload.append(try encoder.encode(entry))
                payload.append(0x0A)
            }
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: payload)
            } else {
                try payload.write(to: fileURL, options: .atomic)
            }
        } catch {
            Logger.agentStore.warning(
                "account_move_journal_append_failed error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    // MARK: - Lesen

    /// Alle Eintraege in Schreibreihenfolge. Kaputte Zeilen werden
    /// uebersprungen statt die Datei unlesbar zu machen.
    func allEntries() -> [Entry] {
        guard let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n").compactMap { line in
            guard let lineData = line.data(using: .utf8) else { return nil }
            return try? decoder.decode(Entry.self, from: lineData)
        }
    }

    /// Der zuletzt geschriebene Batch — Grundlage fuer „Rueckgaengig".
    func lastBatch() -> [Entry] {
        let entries = allEntries()
        guard let lastID = entries.last?.batchID else { return [] }
        return entries.filter { $0.batchID == lastID }
    }

    /// Prozessweiter Stempel-Cache fuer `hasUndoableBatch()`, validiert ueber
    /// (mtime, size) der Journal-Datei. Grund (CPU-Befund 2026-08-23): die
    /// Abfrage haengt im `.contextMenu`-Builder und wurde damit bei jedem
    /// Body-Rebuild jedes Tabs/jeder Row ausgewertet — ohne Cache ein
    /// vollstaendiger Datei-Read + JSONL-Parse pro Render-Pass. Ein Append
    /// invalidiert automatisch (mtime/size aendern sich); explizite
    /// Invalidierung braucht es nicht.
    private static let statCacheLock = NSLock()
    private static var statCache: [String: (mtime: Date, size: Int, hasBatch: Bool)] = [:]

    /// Billige Menue-Abfrage: liegt ein zuruecknehmbarer Batch im Journal?
    /// Unveraendertes Journal kostet nur ein stat(); fehlende Datei ist ohne
    /// Read `false`.
    func hasUndoableBatch() -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let mtime = attrs[.modificationDate] as? Date,
              let size = (attrs[.size] as? NSNumber)?.intValue else {
            return false
        }

        Self.statCacheLock.lock()
        let cached = Self.statCache[fileURL.path]
        Self.statCacheLock.unlock()
        if let cached, cached.mtime == mtime, cached.size == size {
            return cached.hasBatch
        }

        let hasBatch = !lastBatch().isEmpty
        Self.statCacheLock.lock()
        Self.statCache[fileURL.path] = (mtime, size, hasBatch)
        Self.statCacheLock.unlock()
        return hasBatch
    }

    /// Dreht einen Batch um: jede Session zurueck in ihr Herkunftskonto.
    /// Reihenfolge umgekehrt, damit ein Umzug, der zwei Sessions ueber
    /// dasselbe Zwischenziel gefuehrt hat, in der Gegenrichtung dieselbe
    /// Kollisionsfreiheit hat.
    static func inverted(_ entries: [Entry]) -> [Entry] {
        entries.reversed().map { entry in
            Entry(
                batchID: entry.batchID,
                sessionID: entry.sessionID,
                sessionTitle: entry.sessionTitle,
                fromProfile: entry.toProfile,
                toProfile: entry.fromProfile,
                movedTranscript: entry.movedTranscript,
                timestamp: entry.timestamp
            )
        }
    }
}
