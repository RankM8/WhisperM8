import Foundation

struct AgentWorkspaceRepository {
    private let fileURL: URL

    /// Anzahl rotierender Last-known-good-Generationen (`.bak.1` = neueste).
    static let generationBackupCount = 3
    /// Drosselung der Rotation — der 0,5-s-Debounce darf nicht pro Save drei
    /// Datei-Operationen erzeugen. Im Test auf 0 setzbar.
    var generationBackupMinInterval: TimeInterval = 5 * 60

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
    }

    func load(migrate: (AgentWorkspace) -> AgentWorkspace) -> AgentWorkspace {
        PerfBudgets.storeLoad.withInterval { loadBody(migrate: migrate) }
    }

    /// Eigentlicher Load — vom Signpost-Wrapper getrennt, damit die
    /// bestehende durationMs-Logzeile (log-stream-Schnittstelle laut
    /// CLAUDE.md) unverändert erhalten bleibt.
    private func loadBody(migrate: (AgentWorkspace) -> AgentWorkspace) -> AgentWorkspace {
        let startedAt = Date()
        defer {
            Logger.agentPerformance.debug("agent_store_load durationMs=\(Int(Date().timeIntervalSince(startedAt) * 1000))")
        }

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .empty
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let workspace = try decoder.decode(AgentWorkspace.self, from: data)
            let migrated = migrate(workspace)
            if migrated != workspace {
                do {
                    try backup(reason: "pre-migration")
                    try save(migrated)
                } catch {
                    Logger.debug("Failed to migrate agent sessions: \(error.localizedDescription)")
                }
            }
            return migrated
        } catch {
            Logger.debug("Failed to load agent sessions: \(error.localizedDescription)")
            do {
                try backup(reason: "decode-failed")
            } catch {
                Logger.debug("Failed to back up unreadable agent sessions: \(error.localizedDescription)")
            }
            // RECOVERY (Review-Befund 2026-07-13): Ein Decode-Fehler der
            // Hauptdatei bedeutete vorher Totalverlust ALLER Session-Metadaten
            // (leerer Workspace, naechster Save ueberschreibt die Hauptdatei).
            // Jetzt: neuestes dekodierbares Generation-Backup laden — die
            // korrupte Datei ist oben bereits als .decode-failed quarantaenisiert.
            if let recovered = loadNewestDecodableGenerationBackup() {
                Logger.agentStore.notice("agent_store_recovered_from_backup sessions=\(recovered.sessions.count) projects=\(recovered.projects.count)")
                return migrate(recovered)
            }
            return .empty
        }
    }

    private func loadNewestDecodableGenerationBackup() -> AgentWorkspace? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for generation in 1...Self.generationBackupCount {
            let url = generationBackupURL(generation)
            guard let data = try? Data(contentsOf: url),
                  let workspace = try? decoder.decode(AgentWorkspace.self, from: data) else {
                continue
            }
            return workspace
        }
        return nil
    }

    func save(_ workspace: AgentWorkspace) throws {
        try PerfBudgets.storeSave.withInterval {
            let startedAt = Date()
            defer {
                Logger.agentPerformance.debug("agent_store_save durationMs=\(Int(Date().timeIntervalSince(startedAt) * 1000)) projects=\(workspace.projects.count) sessions=\(workspace.sessions.count)")
            }

            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(workspace)
            try data.write(to: fileURL, options: .atomic)
            // NACH dem erfolgreichen Write rotieren und die soeben encodierten
            // (garantiert dekodierbaren) Bytes als Generation sichern — so
            // landet nie eine korrupte Datei in den Backups.
            rotateGenerationBackupsIfDue(with: data)
        }
    }

    /// Rotierende Last-known-good-Generationen: `.bak.2`→`.bak.3`,
    /// `.bak.1`→`.bak.2`, frische Daten → `.bak.1`. Gedrosselt ueber
    /// `generationBackupMinInterval` (mtime von `.bak.1`). Best-effort —
    /// ein Backup-Fehler darf den eigentlichen Save nie scheitern lassen.
    private func rotateGenerationBackupsIfDue(with data: Data) {
        let fm = FileManager.default
        let newest = generationBackupURL(1)
        if let mtime = (try? fm.attributesOfItem(atPath: newest.path))?[.modificationDate] as? Date,
           Date().timeIntervalSince(mtime) < generationBackupMinInterval {
            return
        }
        for generation in stride(from: Self.generationBackupCount - 1, through: 1, by: -1) {
            let source = generationBackupURL(generation)
            guard fm.fileExists(atPath: source.path) else { continue }
            let target = generationBackupURL(generation + 1)
            try? fm.removeItem(at: target)
            try? fm.moveItem(at: source, to: target)
        }
        try? data.write(to: newest, options: .atomic)
    }

    func generationBackupURL(_ generation: Int) -> URL {
        fileURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(fileURL.lastPathComponent).bak.\(generation)")
    }

    func backup(reason: String) throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let backupURL = fileURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(fileURL.lastPathComponent).\(reason).\(timestamp).bak")
        try FileManager.default.copyItem(at: fileURL, to: backupURL)
    }

    /// Produktions-Pfad der Workspace-JSON. Internal, weil die
    /// `AgentWorkspaceStoreRegistry` damit die Default-Instanz auflöst.
    static func defaultFileURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WhisperM8", isDirectory: true)
            .appendingPathComponent("AgentSessions.json")
    }
}
