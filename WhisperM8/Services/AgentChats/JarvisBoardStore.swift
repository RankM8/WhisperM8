import Foundation

// MARK: - Jarvis-Board (wm8.board/1)

/// Ampel eines Board-Eintrags. Die Reihenfolge der Fälle ist NICHT die
/// Sortierung — die steht in `sortRank`.
enum JarvisBoardLight: String, Codable, CaseIterable, Equatable {
    case needsYou
    case running
    case done
    case parked

    /// Was den User braucht zuerst, Fertiges (zu prüfen) vor Laufendem,
    /// Geparktes zuletzt.
    var sortRank: Int {
        switch self {
        case .needsYou: return 0
        case .done: return 1
        case .running: return 2
        case .parked: return 3
        }
    }

    static var allowedList: String { allCases.map(\.rawValue).joined(separator: "|") }
}

/// Ein betreuter Chat auf dem Board einer Jarvis-Session.
struct JarvisBoardEntry: Codable, Equatable {
    var sessionID: UUID
    var light: JarvisBoardLight
    /// Eine Zeile: was der Chat tut.
    var mission: String
    /// Was er von wem braucht.
    var needs: String
    /// Nächster Schritt.
    var next: String
    var updatedAt: Date

    init(sessionID: UUID, light: JarvisBoardLight, mission: String = "", needs: String = "",
         next: String = "", updatedAt: Date) {
        self.sessionID = sessionID
        self.light = light
        self.mission = mission
        self.needs = needs
        self.next = next
        self.updatedAt = updatedAt
    }

    /// Tolerant gegenüber fehlenden Textfeldern und unbekannten Ampelwerten
    /// einer späteren Version — sonst machte ein einziger fremder Wert die
    /// ganze Datei unlesbar und der nächste Schreibvorgang verwürfe sie.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try container.decode(UUID.self, forKey: .sessionID)
        let rawLight = try container.decodeIfPresent(String.self, forKey: .light) ?? ""
        light = JarvisBoardLight(rawValue: rawLight) ?? .running
        mission = try container.decodeIfPresent(String.self, forKey: .mission) ?? ""
        needs = try container.decodeIfPresent(String.self, forKey: .needs) ?? ""
        next = try container.decodeIfPresent(String.self, forKey: .next) ?? ""
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
    }
}

/// Ein Board je Jarvis-Session (`owner` = deren WhisperM8-Session-ID).
struct JarvisBoard: Codable, Equatable {
    var owner: UUID
    var isActive: Bool
    var updatedAt: Date
    var entries: [JarvisBoardEntry]

    /// Einträge in Anzeige-Reihenfolge: Ampel-Rang, innerhalb ältestes
    /// `updatedAt` zuerst (was am längsten liegt, steht oben).
    var sortedEntries: [JarvisBoardEntry] {
        JarvisBoardLogic.sorted(entries)
    }
}

/// Inhalt von `jarvis-board.json`.
struct JarvisBoardFile: Codable, Equatable {
    static let currentSchema = "wm8.board/1"

    var schema: String = JarvisBoardFile.currentSchema
    var boards: [JarvisBoard] = []

    func board(owner: UUID) -> JarvisBoard? {
        boards.first { $0.owner == owner }
    }

    /// Alle Owner, auf deren Board dieser Chat steht.
    func owners(containing sessionID: UUID) -> [UUID] {
        boards.filter { board in board.entries.contains { $0.sessionID == sessionID } }.map(\.owner)
    }
}

// MARK: - Pure Mutationslogik

/// Teil-Änderung eines Eintrags: `nil` = Feld bleibt, wie es ist.
struct JarvisBoardPatch: Equatable {
    var light: JarvisBoardLight?
    var mission: String?
    var needs: String?
    var next: String?
}

enum JarvisBoardOp: String, Equatable {
    case set, remove, clear, activate, deactivate
}

/// Ergebnis einer Mutation. `changed == false` heißt: Der Bestand war schon
/// so — kein Schreiben, kein Journal-Ereignis (der Aktivierungs-Hook ruft
/// `activate` bei jedem Skill-Aufruf, das darf das Journal nicht fluten).
struct JarvisBoardChange: Equatable {
    var op: JarvisBoardOp
    var owner: UUID
    var changed: Bool
    var sessionID: UUID?
    /// Ampel nach `set` bzw. die zuletzt gültige Ampel vor `remove`.
    var light: JarvisBoardLight?
    var entry: JarvisBoardEntry?
    var removedCount = 0
    /// Board-Zustand nach der Mutation (`nil`, wenn es keines gibt).
    var board: JarvisBoard?
}

enum JarvisBoardLogic {
    static func sorted(_ entries: [JarvisBoardEntry]) -> [JarvisBoardEntry] {
        entries.sorted { lhs, rhs in
            if lhs.light.sortRank != rhs.light.sortRank { return lhs.light.sortRank < rhs.light.sortRank }
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt < rhs.updatedAt }
            return lhs.sessionID.uuidString < rhs.sessionID.uuidString
        }
    }

    /// Legt den Eintrag an oder ändert ihn. Nicht angegebene Felder bleiben;
    /// ein neuer Eintrag ohne Ampel startet als `running`. Fehlt das Board,
    /// entsteht es aktiv — wer einträgt, will es auch sehen.
    static func set(_ file: inout JarvisBoardFile, owner: UUID, sessionID: UUID,
                    patch: JarvisBoardPatch, now: Date) -> JarvisBoardChange {
        let patch = sanitized(patch)
        var boardIndex = file.boards.firstIndex { $0.owner == owner }
        if boardIndex == nil {
            file.boards.append(JarvisBoard(owner: owner, isActive: true, updatedAt: now, entries: []))
            boardIndex = file.boards.count - 1
        }
        let index = boardIndex!
        var board = file.boards[index]

        let existingIndex = board.entries.firstIndex { $0.sessionID == sessionID }
        let before = existingIndex.map { board.entries[$0] }
        var entry = before ?? JarvisBoardEntry(sessionID: sessionID, light: .running, updatedAt: now)
        if let light = patch.light { entry.light = light }
        if let mission = patch.mission { entry.mission = mission }
        if let needs = patch.needs { entry.needs = needs }
        if let next = patch.next { entry.next = next }

        let entryChanged = before.map { !sameContent($0, entry) } ?? true
        guard entryChanged else {
            return JarvisBoardChange(op: .set, owner: owner, changed: false, sessionID: sessionID,
                                     light: entry.light, entry: entry, board: board)
        }
        entry.updatedAt = now
        if let existingIndex {
            board.entries[existingIndex] = entry
        } else {
            board.entries.append(entry)
        }
        board.updatedAt = now
        file.boards[index] = board
        return JarvisBoardChange(op: .set, owner: owner, changed: true, sessionID: sessionID,
                                 light: entry.light, entry: entry, board: board)
    }

    static func remove(_ file: inout JarvisBoardFile, owner: UUID, sessionID: UUID, now: Date) -> JarvisBoardChange {
        guard let index = file.boards.firstIndex(where: { $0.owner == owner }),
              let entryIndex = file.boards[index].entries.firstIndex(where: { $0.sessionID == sessionID }) else {
            return JarvisBoardChange(op: .remove, owner: owner, changed: false, sessionID: sessionID,
                                     board: file.board(owner: owner))
        }
        let removed = file.boards[index].entries.remove(at: entryIndex)
        file.boards[index].updatedAt = now
        return JarvisBoardChange(op: .remove, owner: owner, changed: true, sessionID: sessionID,
                                 light: removed.light, entry: removed, removedCount: 1,
                                 board: file.boards[index])
    }

    static func clear(_ file: inout JarvisBoardFile, owner: UUID, now: Date) -> JarvisBoardChange {
        guard let index = file.boards.firstIndex(where: { $0.owner == owner }),
              !file.boards[index].entries.isEmpty else {
            return JarvisBoardChange(op: .clear, owner: owner, changed: false, board: file.board(owner: owner))
        }
        let count = file.boards[index].entries.count
        file.boards[index].entries.removeAll()
        file.boards[index].updatedAt = now
        return JarvisBoardChange(op: .clear, owner: owner, changed: true, removedCount: count,
                                 board: file.boards[index])
    }

    /// `activate` legt ein fehlendes Board an; `deactivate` auf ein fehlendes
    /// Board ist ein No-op (es gibt nichts auszuschalten).
    static func setActive(_ file: inout JarvisBoardFile, owner: UUID, active: Bool, now: Date) -> JarvisBoardChange {
        let op: JarvisBoardOp = active ? .activate : .deactivate
        guard let index = file.boards.firstIndex(where: { $0.owner == owner }) else {
            guard active else { return JarvisBoardChange(op: op, owner: owner, changed: false) }
            let board = JarvisBoard(owner: owner, isActive: true, updatedAt: now, entries: [])
            file.boards.append(board)
            return JarvisBoardChange(op: op, owner: owner, changed: true, board: board)
        }
        guard file.boards[index].isActive != active else {
            return JarvisBoardChange(op: op, owner: owner, changed: false, board: file.boards[index])
        }
        file.boards[index].isActive = active
        file.boards[index].updatedAt = now
        return JarvisBoardChange(op: op, owner: owner, changed: true, board: file.boards[index])
    }

    static func sanitized(_ patch: JarvisBoardPatch) -> JarvisBoardPatch {
        JarvisBoardPatch(light: patch.light,
                         mission: patch.mission.map(JarvisBoardText.sanitize),
                         needs: patch.needs.map(JarvisBoardText.sanitize),
                         next: patch.next.map(JarvisBoardText.sanitize))
    }

    private static func sameContent(_ lhs: JarvisBoardEntry, _ rhs: JarvisBoardEntry) -> Bool {
        lhs.light == rhs.light && lhs.mission == rhs.mission && lhs.needs == rhs.needs && lhs.next == rhs.next
    }
}

/// Textfelder sind einzeilig und kurz — sie landen in einer Zeile des Bands.
enum JarvisBoardText {
    static let maxLength = 160

    static func sanitize(_ raw: String) -> String {
        let oneLine = raw.replacingOccurrences(
            of: "[\\r\\n\\x{2028}\\x{2029}]+", with: " ", options: .regularExpression)
        let trimmed = oneLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxLength else { return trimmed }
        return String(trimmed.prefix(maxLength - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

// MARK: - Kill-Switch

/// `defaults write com.whisperm8.app jarvisBoardEnabled -bool NO`: Handeln
/// antwortet mit klarer Fehlermeldung, Lesen liefert ein leeres Board.
///
/// Gelesen über `CFPreferencesCopyAppValue` mit fester Domain statt
/// `UserDefaults.standard`: Die CLI läuft als Symlink auf das App-Binary, ihre
/// Standard-Domain ist nicht verlässlich die der App.
enum JarvisBoardSettings {
    static let defaultsKey = PreferenceKeys.jarvisBoardEnabled
    static let appDomain = "com.whisperm8.app"

    static func isEnabled(read: (String) -> Any? = Self.readAppPreference) -> Bool {
        (read(defaultsKey) as? Bool) ?? true
    }

    static func readAppPreference(_ key: String) -> Any? {
        CFPreferencesCopyAppValue(key as CFString, appDomain as CFString)
    }

    static let disabledMessage =
        "Jarvis-Board ist abgeschaltet (defaults write com.whisperm8.app jarvisBoardEnabled -bool YES schaltet es ein)."
}

// MARK: - Ablage

/// Einzige Schreibstelle ist die App (wie beim Workspace); die CLI liest nur
/// über `load(fileURL:)`. Jede echte Änderung erzeugt ein Journal-Ereignis —
/// `chats since`/`watch` liefern es mit, die Mod braucht keinen zweiten Kanal.
final class JarvisBoardStore: @unchecked Sendable {
    static let shared = JarvisBoardStore()

    enum StoreError: LocalizedError {
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .writeFailed(let message): return "jarvis-board.json nicht schreibbar: \(message)"
            }
        }
    }

    let fileURL: URL
    private let journal: ChatsStatusJournal
    private let lock = NSLock()

    init(fileURL: URL? = nil, journal: ChatsStatusJournal = .shared) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        self.journal = journal
    }

    /// Hängt an keinem Claude-Profil — überlebt damit einen Kontowechsel.
    static func defaultFileURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WhisperM8", isDirectory: true)
            .appendingPathComponent("jarvis-board.json")
    }

    /// Reine Disk-Funktion ohne Schreib-Nebenwirkung. Fehlt die Datei oder
    /// ist sie unlesbar, gibt es schlicht kein Board.
    static func load(fileURL: URL? = nil) -> JarvisBoardFile {
        let url = fileURL ?? defaultFileURL()
        guard let data = try? Data(contentsOf: url),
              let file = try? decoder.decode(JarvisBoardFile.self, from: data) else {
            return JarvisBoardFile()
        }
        return file
    }

    /// Führt eine Mutation unter dem Store-Lock aus, schreibt atomar und
    /// protokolliert das Ereignis. Unveränderter Bestand → weder Schreiben
    /// noch Ereignis.
    func mutate(now: Date = Date(),
                _ body: (inout JarvisBoardFile, Date) -> JarvisBoardChange) throws -> JarvisBoardChange {
        lock.lock()
        defer { lock.unlock() }
        var file = loadForWriting()
        let change = body(&file, now)
        guard change.changed else { return change }
        try write(file)
        journal.appendBoard(op: change.op.rawValue, owner: change.owner, sessionID: change.sessionID,
                            light: change.light?.rawValue, at: now)
        return change
    }

    /// Wie `load`, aber eine unlesbare Datei wird beiseitegelegt statt still
    /// überschrieben — so bleibt sie für eine Nachanalyse erhalten.
    private func loadForWriting() -> JarvisBoardFile {
        guard let data = try? Data(contentsOf: fileURL) else { return JarvisBoardFile() }
        if let file = try? Self.decoder.decode(JarvisBoardFile.self, from: data) { return file }
        let quarantine = fileURL.appendingPathExtension("corrupt")
        try? FileManager.default.removeItem(at: quarantine)
        try? FileManager.default.moveItem(at: fileURL, to: quarantine)
        Logger.info("[JarvisBoard] unlesbare Datei nach \(quarantine.lastPathComponent) verschoben")
        return JarvisBoardFile()
    }

    private func write(_ file: JarvisBoardFile) throws {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try Self.encoder.encode(file)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw StoreError.writeFailed(error.localizedDescription)
        }
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
