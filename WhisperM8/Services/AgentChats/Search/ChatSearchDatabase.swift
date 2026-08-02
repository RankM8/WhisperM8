import Foundation
import SQLite3

/// SQLite-Handle des Suchindex — dünner Wrapper um die C-API, kein ORM.
///
/// Der Index ist eine REIN ABGELEITETE Kopie: er darf jederzeit gelöscht und
/// neu aufgebaut werden. Deshalb ist er bewusst NICHT Teil des Workspaces und
/// bricht auch nicht dessen Single-Writer-Regel — die gilt für
/// `AgentSessions.json`, dessen einziger Schreiber die App bleibt.
///
/// Nebenläufigkeit: App und CLI dürfen beide schreiben.
/// - **Korrektheit** garantiert SQLite selbst: WAL (Leser blockieren Schreiber
///   nie) + `busy_timeout` + implizite Transaktionsserialisierung.
/// - **Doppelarbeit** verhindert `ChatSearchWriterLock`: ein nicht-blockierender
///   `flock` sorgt dafür, dass immer nur EIN Prozess einen Indexlauf fährt.
///   Wer den Lock nicht bekommt, liest einfach den vorhandenen Stand.
final class ChatSearchDatabase {
    enum DatabaseError: Error, Equatable {
        case open(String)
        case exec(String)
        case prepare(String)
        case step(String)
    }

    /// Schemaversion. Erhöhen erzwingt einen Neuaufbau (der Index ist
    /// abgeleitet — Migrationen wären teurer als ein Rebuild).
    static let schemaVersion = 1

    private let handle: OpaquePointer
    let fileURL: URL

    /// Standardort: eigener Ordner neben dem Workspace, damit ein Rebuild
    /// (Ordner löschen) nie versehentlich echte Daten trifft.
    static func defaultFileURL() -> URL {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/WhisperM8/SearchIndex", isDirectory: true)
        return base.appendingPathComponent("index.sqlite", isDirectory: false)
    }

    init(fileURL: URL) throws {
        self.fileURL = fileURL
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var pointer: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(fileURL.path, &pointer, flags, nil) == SQLITE_OK, let pointer else {
            let message = pointer.map { String(cString: sqlite3_errmsg($0)) } ?? "unbekannt"
            if let pointer { sqlite3_close_v2(pointer) }
            throw DatabaseError.open(message)
        }
        self.handle = pointer

        // 5 s Wartezeit statt sofortigem SQLITE_BUSY: App-Indexlauf und
        // CLI-Query überschneiden sich im Alltag ständig.
        sqlite3_busy_timeout(handle, 5_000)
        try execute("PRAGMA journal_mode=WAL;")
        try execute("PRAGMA synchronous=NORMAL;")
        try execute("PRAGMA foreign_keys=ON;")
        // Nur der Eigentümer darf lesen — Transcript-Inhalte sind privat.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    // MARK: - Ausführung

    func execute(_ sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &errorPointer) == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? "unbekannt"
            sqlite3_free(errorPointer)
            throw DatabaseError.exec(message)
        }
    }

    /// Bereitet ein Statement vor und gibt es an `body`. Das Statement wird
    /// immer finalisiert — auch wenn `body` wirft.
    func prepare<T>(_ sql: String, _ body: (ChatSearchStatement) throws -> T) throws -> T {
        var pointer: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &pointer, nil) == SQLITE_OK, let pointer else {
            throw DatabaseError.prepare(String(cString: sqlite3_errmsg(handle)))
        }
        let statement = ChatSearchStatement(pointer: pointer, databaseHandle: handle)
        defer { sqlite3_finalize(pointer) }
        return try body(statement)
    }

    /// `BEGIN IMMEDIATE` — reserviert den Schreibplatz sofort, statt erst beim
    /// ersten Write in einen Upgrade-Deadlock zu laufen.
    func writeTransaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE;")
        do {
            let result = try body()
            try execute("COMMIT;")
            return result
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }

    // MARK: - Schema

    /// Legt das Schema an bzw. verwirft einen Index, dessen Schema- oder
    /// Normalisierungsversion nicht mehr passt. Rückgabe: `true`, wenn der
    /// Inhalt verworfen wurde und neu aufgebaut werden muss.
    @discardableResult
    func migrate() throws -> Bool {
        try execute(Self.metaSchema)
        let storedSchema = try metaInt(for: "schemaVersion")
        let storedNormalizer = try metaInt(for: "normalizerVersion")

        let mismatched = (storedSchema != nil && storedSchema != Self.schemaVersion)
            || (storedNormalizer != nil && storedNormalizer != ChatSearchNormalizer.version)
        if mismatched {
            try execute(Self.dropSchema)
        }
        try execute(Self.contentSchema)
        if storedSchema == nil || mismatched {
            try setMeta("schemaVersion", String(Self.schemaVersion))
            try setMeta("normalizerVersion", String(ChatSearchNormalizer.version))
        }
        return mismatched
    }

    func setMeta(_ key: String, _ value: String) throws {
        try prepare("INSERT INTO index_meta(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value") {
            try $0.bind(text: key, at: 1)
            try $0.bind(text: value, at: 2)
            try $0.run()
        }
    }

    func meta(for key: String) throws -> String? {
        try prepare("SELECT value FROM index_meta WHERE key = ?") { statement in
            try statement.bind(text: key, at: 1)
            guard try statement.next() else { return nil }
            return statement.text(at: 0)
        }
    }

    private func metaInt(for key: String) throws -> Int? {
        try meta(for: key).flatMap(Int.init)
    }

    private static let metaSchema = """
        CREATE TABLE IF NOT EXISTS index_meta (
            key   TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        """

    private static let dropSchema = """
        DROP TABLE IF EXISTS messages_fts;
        DROP TABLE IF EXISTS messages;
        DROP TABLE IF EXISTS transcripts;
        """

    /// `messages.text` hält den ORIGINALTEXT (Grundlage der Snippets),
    /// `messages_fts` indexiert die normalisierte Fassung contentless — so
    /// liegt der Text genau einmal auf der Platte statt dreifach.
    /// `contentless_delete=1` (SQLite ≥ 3.43) macht Reindex per DELETE möglich.
    private static let contentSchema = """
        CREATE TABLE IF NOT EXISTS transcripts (
            id                  INTEGER PRIMARY KEY,
            provider            TEXT    NOT NULL,
            path                TEXT    NOT NULL UNIQUE,
            external_session_id TEXT,
            size_bytes          INTEGER NOT NULL DEFAULT 0,
            mtime               REAL    NOT NULL DEFAULT 0,
            inode               INTEGER NOT NULL DEFAULT 0,
            prefix_hash         TEXT,
            indexed_bytes       INTEGER NOT NULL DEFAULT 0,
            message_count       INTEGER NOT NULL DEFAULT 0,
            state               TEXT    NOT NULL DEFAULT 'pending',
            last_error          TEXT,
            updated_at          REAL    NOT NULL DEFAULT 0
        );

        CREATE TABLE IF NOT EXISTS messages (
            id            INTEGER PRIMARY KEY,
            transcript_id INTEGER NOT NULL REFERENCES transcripts(id) ON DELETE CASCADE,
            byte_offset   INTEGER NOT NULL,
            line_number   INTEGER NOT NULL,
            block_index   INTEGER NOT NULL,
            timestamp     REAL,
            role          TEXT    NOT NULL,
            kind          TEXT    NOT NULL,
            text          TEXT    NOT NULL
        );

        CREATE INDEX IF NOT EXISTS idx_messages_transcript
            ON messages(transcript_id, byte_offset);
        CREATE INDEX IF NOT EXISTS idx_messages_kind_time
            ON messages(kind, timestamp);

        CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(
            norm,
            content='',
            contentless_delete=1,
            tokenize='unicode61 remove_diacritics 2'
        );
        """
}

/// Ein vorbereitetes Statement. Lebensdauer wird von `prepare` verwaltet.
struct ChatSearchStatement {
    private let pointer: OpaquePointer
    private let databaseHandle: OpaquePointer

    init(pointer: OpaquePointer, databaseHandle: OpaquePointer) {
        self.pointer = pointer
        self.databaseHandle = databaseHandle
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    func bind(text: String, at index: Int32) throws {
        guard sqlite3_bind_text(pointer, index, text, -1, Self.transient) == SQLITE_OK else {
            throw ChatSearchDatabase.DatabaseError.step(String(cString: sqlite3_errmsg(databaseHandle)))
        }
    }

    func bind(int: Int64, at index: Int32) throws {
        guard sqlite3_bind_int64(pointer, index, int) == SQLITE_OK else {
            throw ChatSearchDatabase.DatabaseError.step(String(cString: sqlite3_errmsg(databaseHandle)))
        }
    }

    func bind(double: Double, at index: Int32) throws {
        guard sqlite3_bind_double(pointer, index, double) == SQLITE_OK else {
            throw ChatSearchDatabase.DatabaseError.step(String(cString: sqlite3_errmsg(databaseHandle)))
        }
    }

    func bindNull(at index: Int32) throws {
        guard sqlite3_bind_null(pointer, index) == SQLITE_OK else {
            throw ChatSearchDatabase.DatabaseError.step(String(cString: sqlite3_errmsg(databaseHandle)))
        }
    }

    /// Führt ein Statement ohne Ergebniszeilen aus.
    func run() throws {
        let code = sqlite3_step(pointer)
        guard code == SQLITE_DONE || code == SQLITE_ROW else {
            throw ChatSearchDatabase.DatabaseError.step(String(cString: sqlite3_errmsg(databaseHandle)))
        }
    }

    /// - Returns: `true`, solange eine weitere Zeile vorliegt.
    func next() throws -> Bool {
        let code = sqlite3_step(pointer)
        if code == SQLITE_ROW { return true }
        guard code == SQLITE_DONE else {
            throw ChatSearchDatabase.DatabaseError.step(String(cString: sqlite3_errmsg(databaseHandle)))
        }
        return false
    }

    func reset() {
        sqlite3_reset(pointer)
        sqlite3_clear_bindings(pointer)
    }

    func text(at column: Int32) -> String? {
        guard let raw = sqlite3_column_text(pointer, column) else { return nil }
        return String(cString: raw)
    }

    func int(at column: Int32) -> Int64 { sqlite3_column_int64(pointer, column) }

    func double(at column: Int32) -> Double? {
        sqlite3_column_type(pointer, column) == SQLITE_NULL ? nil : sqlite3_column_double(pointer, column)
    }
}

/// Nicht-blockierender Advisory-Lock für Indexläufe.
///
/// Zweck ist NICHT Datenintegrität (das macht SQLite) sondern Verschwendung:
/// ohne ihn würden App und CLI nach einem FSEvent parallel dieselben Dateien
/// parsen. Wer den Lock nicht bekommt, arbeitet mit dem vorhandenen Stand
/// weiter — Suchen blockiert nie auf einem laufenden Indexlauf.
final class ChatSearchWriterLock {
    private let descriptor: Int32

    /// - Returns: `nil`, wenn bereits ein anderer Prozess indexiert.
    init?(fileURL: URL) {
        let path = fileURL.deletingLastPathComponent().appendingPathComponent("index.lock").path
        descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return nil }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return nil
        }
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}
