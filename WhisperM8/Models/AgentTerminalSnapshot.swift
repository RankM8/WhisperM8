import Foundation

/// Persistierter Terminal-Zustand einer Agent-Session. Anzeige-Layer, nicht
/// Wahrheit fuer Resume — die echte Identitaet sitzt weiterhin in
/// `AgentChatSession.externalSessionID`. Snapshot wird vom
/// `AgentTerminalSnapshotStore` atomisch geschrieben.
struct AgentTerminalSnapshot: Codable, Equatable {
    /// Lokale WhisperM8-Tab-Identitaet — derselbe Wert wie
    /// `AgentChatSession.id`. Snapshot wird pro lokalem Tab gehalten, nicht
    /// pro externer Session, weil dieselbe externe Session nach `/resume`
    /// in einem anderen Tab landen kann.
    var localSessionID: UUID
    var provider: AgentProvider
    /// Zum Zeitpunkt der Erfassung bekannte externe Conversation-ID. Wird
    /// nur fuer Logging/Debug benoetigt — beim Restore wird die aktuelle
    /// `externalSessionID` aus dem Store verwendet.
    var externalSessionID: String?
    /// Project-CWD zum Zeitpunkt des Snapshots. Falls der User das Projekt
    /// inzwischen verschoben hat, hilft das beim Forensik-Logging.
    var cwd: String
    var capturedAt: Date
    var terminalColumns: Int?
    var terminalRows: Int?
    /// `true` wenn der Subprocess beim letzten Snapshot noch lief — danach
    /// ist das Snapshot ein definitiver Final-State (Force Quit oder Exit).
    var processWasRunning: Bool
    var exitCode: Int32?
    /// Visible-Slice (~ letzte 2000 Zeichen) fuer den schnellen Render in der
    /// Snapshot-Ansicht. Plain Text, keine ANSI-Codes.
    var visibleText: String
    /// Erweiterter Scrollback (~ 64 KiB) fuer Recovery-Detailview.
    var scrollbackText: String
    /// Optionaler Pfad zu einem ANSI-Replay-Tail fuer spaetere
    /// pixel-genaue Rekonstruktion. Phase 7+, initial `nil`.
    var ansiReplayDataPath: String?

    /// Maximalwerte fuer die Text-Slots. Wenn Capture mehr liefert, kuerzen
    /// wir am Anfang (aelteste Zeilen verlieren).
    enum Limits {
        static let visibleTextBytes = 8 * 1024
        static let scrollbackTextBytes = 64 * 1024
    }

    /// Schneidet die uebergebenen Strings auf die `Limits` zu. Wir kuerzen
    /// am Anfang, damit die juengsten Ausgaben erhalten bleiben.
    static func clamp(visible: String, scrollback: String) -> (visible: String, scrollback: String) {
        return (
            visible: clampedFromEnd(visible, maxBytes: Limits.visibleTextBytes),
            scrollback: clampedFromEnd(scrollback, maxBytes: Limits.scrollbackTextBytes)
        )
    }

    /// Schneidet `text` so, dass das UTF-8-Bytecount-Limit `maxBytes` nicht
    /// ueberschritten wird. Wir tasten uns vom Ende zurueck und schneiden an
    /// einer UTF-8-Codepoint-Grenze, damit kein halber Multibyte-Char
    /// uebrigbleibt.
    static func clampedFromEnd(_ text: String, maxBytes: Int) -> String {
        let bytes = text.utf8
        if bytes.count <= maxBytes { return text }

        // Suche das aelteste Byte das wir noch nehmen wuerden.
        // Wir wollen die letzten `maxBytes` Bytes — also Offset = count - maxBytes.
        // Dann tasten wir uns nach vorn, bis wir auf den Anfang einer
        // UTF-8-Sequence treffen (Byte beginnt nicht mit 10xxxxxx).
        var startOffset = bytes.count - maxBytes
        let bytesArray = Array(bytes)
        while startOffset < bytesArray.count {
            let byte = bytesArray[startOffset]
            // UTF-8 continuation byte? -> nach vorn.
            if (byte & 0b1100_0000) == 0b1000_0000 {
                startOffset += 1
            } else {
                break
            }
        }
        let slice = Array(bytesArray[startOffset...])
        return String(decoding: slice, as: UTF8.self)
    }
}

/// Persistenz-Layer fuer `AgentTerminalSnapshot`. Pro lokaler Session eine
/// JSON-Datei in `~/Library/Application Support/WhisperM8/agent-terminal-snapshots/`.
/// Schreiben ist atomisch via `Data.write(options: .atomic)`. Robust gegen
/// Korruption: kaputtes JSON wird gestillt geloescht und der Aufrufer bekommt
/// `nil`, damit die App nicht crashed.
struct AgentTerminalSnapshotStore {
    /// Wurzelverzeichnis fuer alle Snapshot-Dateien.
    var directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory()
    }

    static func defaultDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WhisperM8", isDirectory: true)
            .appendingPathComponent("agent-terminal-snapshots", isDirectory: true)
    }

    func fileURL(for localSessionID: UUID) -> URL {
        directory.appendingPathComponent("\(localSessionID.uuidString).json", isDirectory: false)
    }

    /// Schreibt das Snapshot atomisch. Existierendes Snapshot fuer dieselbe
    /// `localSessionID` wird ueberschrieben.
    @discardableResult
    func save(_ snapshot: AgentTerminalSnapshot) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(snapshot)
            try data.write(to: fileURL(for: snapshot.localSessionID), options: .atomic)
            Logger.terminalSnapshot.debug("snapshot_saved localID=\(snapshot.localSessionID.uuidString, privacy: .public) size=\(data.count) provider=\(snapshot.provider.rawValue, privacy: .public)")
            return true
        } catch {
            Logger.terminalSnapshot.warning("snapshot_save_failed localID=\(snapshot.localSessionID.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Liefert das Snapshot, oder `nil` wenn keins existiert oder das File
    /// korrupt ist. Korrupte Files werden zur naechsten Schreib-Operation
    /// einfach ueberschrieben — wir haben keinen Grund, kaputten Read-State
    /// als „echte Quelle" zu behandeln.
    func load(localSessionID: UUID) -> AgentTerminalSnapshot? {
        let url = fileURL(for: localSessionID)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let snapshot = try decoder.decode(AgentTerminalSnapshot.self, from: data)
            Logger.terminalSnapshot.debug("snapshot_loaded localID=\(localSessionID.uuidString, privacy: .public)")
            return snapshot
        } catch {
            Logger.terminalSnapshot.warning("snapshot_corrupted localID=\(localSessionID.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Loescht das Snapshot fuer eine lokale Session. Idempotent — fehlende
    /// Dateien sind kein Fehler.
    @discardableResult
    func delete(localSessionID: UUID) -> Bool {
        let url = fileURL(for: localSessionID)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return false
        }
        do {
            try FileManager.default.removeItem(at: url)
            Logger.terminalSnapshot.debug("snapshot_deleted localID=\(localSessionID.uuidString, privacy: .public)")
            return true
        } catch {
            Logger.terminalSnapshot.warning("snapshot_delete_failed localID=\(localSessionID.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Loescht alle Snapshots, deren `localSessionID` nicht im uebergebenen
    /// Set vorkommt. Wird vom Cleanup-Job (Phase 7) genutzt — entfernt
    /// Snapshots fuer Sessions, die der User aus dem Workspace geloescht hat.
    @discardableResult
    func pruneOrphans(keeping liveLocalIDs: Set<UUID>) -> Int {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return 0
        }
        var removed = 0
        for url in urls where url.pathExtension == "json" {
            let stem = url.deletingPathExtension().lastPathComponent
            guard let uuid = UUID(uuidString: stem) else { continue }
            if liveLocalIDs.contains(uuid) { continue }
            if (try? FileManager.default.removeItem(at: url)) != nil {
                removed += 1
            }
        }
        if removed > 0 {
            Logger.terminalSnapshot.info("snapshot_pruned removed=\(removed)")
        }
        return removed
    }
}
