import Foundation

/// Persistierter Terminal-Stand einer beendeten Session (Stufe 1: Plaintext
/// ohne Farben, docs/plans — Beratung 2026-07-16). Der Snapshot zeigt das
/// Terminal, wie es beim Prozessende stand — inklusive CLI-Exit-Hinweis wie
/// `Resume this session with: claude --resume <id>` — ohne dass für die
/// reine Anzeige das provider-spezifische JSONL-Transcript geladen werden
/// muss.
struct TerminalSnapshot: Equatable {
    let capturedAt: Date
    let text: String
}

/// Sidecar-Ablage der Terminal-Snapshots: eine Datei pro Session unter
/// `~/Library/Application Support/WhisperM8/TerminalSnapshots/<uuid>`.
/// Bewusst KEIN Feld im Workspace-Store — die Existenz-Prüfung ist ein
/// einzelner stat()-Syscall, und Store-Mutationen dürfen ohnehin kein I/O
/// ausführen. Dateiformat: erste Zeile JSON-Header (Version, capturedAt),
/// danach das UTF-8-Plaintext-Payload — unbekannte Header-Versionen werden
/// ignoriert (Fallback auf die Transcript-Ansicht), damit spätere Formate
/// (Stufe 2: ANSI mit Farben) abwärtskompatibel einführbar sind.
final class TerminalSnapshotStore {
    static let shared = TerminalSnapshotStore()

    /// Header-Version dieses Formats (1 = Plaintext).
    static let currentVersion = 1
    /// Maximal persistierte Scrollback-Zeilen (Deckel für Dateigröße UND
    /// Render-Kosten der Anzeige).
    static let maxLines = 2000

    private struct Header: Codable {
        let version: Int
        let capturedAt: Date
    }

    private let directory: URL
    private let fileManager = FileManager.default

    init(directory: URL? = nil) {
        self.directory = directory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("WhisperM8", isDirectory: true)
                .appendingPathComponent("TerminalSnapshots", isDirectory: true)
    }

    // MARK: - Pure Helfer (unit-getestet)

    /// Bereitet Roh-Buffer-Text fürs Persistieren auf: trailing Leerzeilen
    /// (der ungefüllte Rest des Terminal-Buffers) fallen weg, danach wird
    /// auf die letzten `maxLines` Zeilen gedeckelt — der jüngste Stand
    /// (Exit-/Resume-Hinweis) steht am Ende und bleibt immer erhalten.
    static func prepared(_ rawText: String, maxLines: Int = TerminalSnapshotStore.maxLines) -> String {
        var lines = rawText.components(separatedBy: "\n")
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - I/O

    func fileURL(sessionID: UUID) -> URL {
        directory.appendingPathComponent(sessionID.uuidString, isDirectory: false)
            .appendingPathExtension("terminal-snapshot")
    }

    /// Existenz-Check — 1 stat(), keine Reads. Für die Anzeige-Weiche.
    func hasSnapshot(sessionID: UUID) -> Bool {
        fileManager.fileExists(atPath: fileURL(sessionID: sessionID).path)
    }

    /// Persistiert einen Snapshot atomar. Leere Inhalte werden verworfen
    /// (ein leerer Buffer ist kein sinnvoller Terminal-Stand).
    func save(sessionID: UUID, text rawText: String, capturedAt: Date = Date()) {
        let text = Self.prepared(rawText)
        guard !text.isEmpty else { return }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let header = Header(version: Self.currentVersion, capturedAt: capturedAt)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            var data = try encoder.encode(header)
            data.append(0x0A)
            data.append(Data(text.utf8))
            try data.write(to: fileURL(sessionID: sessionID), options: .atomic)
        } catch {
            Logger.debug("[TerminalSnapshot] Speichern fehlgeschlagen: \(error.localizedDescription)")
        }
    }

    /// Lädt einen Snapshot; `nil` bei fehlender Datei, kaputtem Header oder
    /// unbekannter (neuerer) Version — Aufrufer fällt auf die Transcript-
    /// Ansicht zurück.
    func load(sessionID: UUID) -> TerminalSnapshot? {
        guard let data = try? Data(contentsOf: fileURL(sessionID: sessionID)),
              let newlineIndex = data.firstIndex(of: 0x0A) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let header = try? decoder.decode(Header.self, from: data.prefix(upTo: newlineIndex)),
              header.version == Self.currentVersion,
              let text = String(data: data.suffix(from: data.index(after: newlineIndex)), encoding: .utf8),
              !text.isEmpty else { return nil }
        return TerminalSnapshot(capturedAt: header.capturedAt, text: text)
    }

    /// Entfernt den Snapshot einer Session (Session-Löschung). Idempotent.
    func delete(sessionID: UUID) {
        try? fileManager.removeItem(at: fileURL(sessionID: sessionID))
    }

    /// Entfernt die Snapshots mehrerer Sessions (Projekt-Löschung).
    func delete(sessionIDs: [UUID]) {
        for id in sessionIDs {
            delete(sessionID: id)
        }
    }
}
