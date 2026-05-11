import Foundation

/// Eine zusammenhaengende Sequenz von Zeichen mit identischen Attributen
/// (foreground, background, bold, italic). Vom Capturer aus aufeinander-
/// folgenden Buffer-Cells gruppiert, damit das Snapshot kompakt bleibt.
struct AgentTerminalRun: Codable, Equatable {
    var text: String
    var fg: AgentTerminalCellColor
    var bg: AgentTerminalCellColor
    var bold: Bool
    var italic: Bool
    var underline: Bool
    var inverse: Bool
    var dim: Bool

    /// Default-Attribute (kein Color-Override, keine Style-Flags). Wird vom
    /// Decoder als Fallback und beim Whitespace-Padding verwendet.
    static var plain: AgentTerminalRun {
        AgentTerminalRun(
            text: "",
            fg: .defaultFg,
            bg: .defaultBg,
            bold: false,
            italic: false,
            underline: false,
            inverse: false,
            dim: false
        )
    }
}

/// Eine Zeile aus dem Terminal-Buffer als Sequenz von attributed runs.
struct AgentTerminalLine: Codable, Equatable {
    var runs: [AgentTerminalRun]
}

/// Codable-Repraesentation einer SwiftTerm-Cell-Farbe. Wir behalten das
/// Original-Format bei: bei `ansi`/`rgb` resolven wir erst beim Render mit
/// der aktuellen App-Palette → Light/Dark wird beim erneuten Oeffnen korrekt
/// dargestellt.
enum AgentTerminalCellColor: Codable, Equatable {
    case defaultFg
    case defaultBg
    case ansi(UInt8)
    case rgb(r: UInt8, g: UInt8, b: UInt8)

    enum Kind: String, Codable {
        case defaultFg
        case defaultBg
        case ansi
        case rgb
    }

    enum CodingKeys: String, CodingKey {
        case kind, code, r, g, b
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        switch kind {
        case .defaultFg: self = .defaultFg
        case .defaultBg: self = .defaultBg
        case .ansi:
            self = .ansi(try c.decode(UInt8.self, forKey: .code))
        case .rgb:
            self = .rgb(
                r: try c.decode(UInt8.self, forKey: .r),
                g: try c.decode(UInt8.self, forKey: .g),
                b: try c.decode(UInt8.self, forKey: .b)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .defaultFg:
            try c.encode(Kind.defaultFg, forKey: .kind)
        case .defaultBg:
            try c.encode(Kind.defaultBg, forKey: .kind)
        case .ansi(let code):
            try c.encode(Kind.ansi, forKey: .kind)
            try c.encode(code, forKey: .code)
        case .rgb(let r, let g, let b):
            try c.encode(Kind.rgb, forKey: .kind)
            try c.encode(r, forKey: .r)
            try c.encode(g, forKey: .g)
            try c.encode(b, forKey: .b)
        }
    }
}

/// Persistierter Terminal-Zustand. Speichert den Buffer als Sequenz von
/// attributed lines (statt Plain-Text) — beim Restore wird damit der exakte
/// optische Zustand inkl. Farben rekonstruiert.
struct AgentTerminalSnapshot: Codable, Equatable {
    var localSessionID: UUID
    var provider: AgentProvider
    var externalSessionID: String?
    var cwd: String
    var capturedAt: Date
    var terminalColumns: Int?
    var terminalRows: Int?
    var processWasRunning: Bool
    var exitCode: Int32?
    /// Zeilen aus dem aktiven SwiftTerm-Buffer (inkl. Scrollback). Frische
    /// Snapshot-Files schreiben hier rein; Legacy-Snapshots ohne dieses
    /// Feld werden weiterhin geladen (siehe init(from:)).
    var lines: [AgentTerminalLine]

    enum CodingKeys: String, CodingKey {
        case localSessionID
        case provider
        case externalSessionID
        case cwd
        case capturedAt
        case terminalColumns
        case terminalRows
        case processWasRunning
        case exitCode
        case lines
    }

    init(
        localSessionID: UUID,
        provider: AgentProvider,
        externalSessionID: String?,
        cwd: String,
        capturedAt: Date,
        terminalColumns: Int?,
        terminalRows: Int?,
        processWasRunning: Bool,
        exitCode: Int32?,
        lines: [AgentTerminalLine]
    ) {
        self.localSessionID = localSessionID
        self.provider = provider
        self.externalSessionID = externalSessionID
        self.cwd = cwd
        self.capturedAt = capturedAt
        self.terminalColumns = terminalColumns
        self.terminalRows = terminalRows
        self.processWasRunning = processWasRunning
        self.exitCode = exitCode
        self.lines = lines
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        localSessionID = try c.decode(UUID.self, forKey: .localSessionID)
        provider = try c.decode(AgentProvider.self, forKey: .provider)
        externalSessionID = try c.decodeIfPresent(String.self, forKey: .externalSessionID)
        cwd = try c.decode(String.self, forKey: .cwd)
        capturedAt = try c.decode(Date.self, forKey: .capturedAt)
        terminalColumns = try c.decodeIfPresent(Int.self, forKey: .terminalColumns)
        terminalRows = try c.decodeIfPresent(Int.self, forKey: .terminalRows)
        processWasRunning = try c.decode(Bool.self, forKey: .processWasRunning)
        exitCode = try c.decodeIfPresent(Int32.self, forKey: .exitCode)
        lines = try c.decodeIfPresent([AgentTerminalLine].self, forKey: .lines) ?? []
    }
}

/// Persistenz-Layer fuer `AgentTerminalSnapshot`. Atomisches Save/Load,
/// Korruption-resilient, plus Orphan-Pruning.
struct AgentTerminalSnapshotStore {
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

    @discardableResult
    func save(_ snapshot: AgentTerminalSnapshot) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            // Snapshots koennen MB-gross werden bei langem Scrollback — keine
            // pretty-print, das spart Disk + JSON-Parse-Zeit.
            let data = try encoder.encode(snapshot)
            try data.write(to: fileURL(for: snapshot.localSessionID), options: .atomic)
            Logger.terminalSnapshot.debug("snapshot_saved localID=\(snapshot.localSessionID.uuidString, privacy: .public) bytes=\(data.count) lines=\(snapshot.lines.count)")
            return true
        } catch {
            Logger.terminalSnapshot.warning("snapshot_save_failed localID=\(snapshot.localSessionID.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            return false
        }
    }

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
            Logger.terminalSnapshot.debug("snapshot_loaded localID=\(localSessionID.uuidString, privacy: .public) lines=\(snapshot.lines.count)")
            return snapshot
        } catch {
            Logger.terminalSnapshot.warning("snapshot_corrupted localID=\(localSessionID.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

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
