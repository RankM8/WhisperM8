import Foundation

/// Fuehrt einen geplanten Konto-Umzug aus: Transcript bewegen, Session
/// umstempeln, Journal schreiben. Haelt den Indexer-Scan waehrenddessen an.
///
/// Bewusst getrennt von der View: die Reihenfolge (erst Datei, dann Stempel)
/// und die Fehlerbehandlung pro Session sind Fachlogik, kein UI-Detail.
@MainActor
struct AccountMoveService {
    struct Outcome: Equatable {
        var moved: [AccountMoveJournal.Entry] = []
        /// Session-Titel + Fehlertext, fuer den Abschlussbericht.
        var failed: [(title: String, message: String)] = []
        var wasCancelled = false
        /// Nur beim Zuruecknehmen: Titel der Chats, die gerade laufen und
        /// deshalb NICHT zurueckbewegt wurden. Sie bleiben im Journal.
        var skippedRunning: [String] = []

        static func == (lhs: Outcome, rhs: Outcome) -> Bool {
            lhs.moved == rhs.moved
                && lhs.wasCancelled == rhs.wasCancelled
                && lhs.skippedRunning == rhs.skippedRunning
                && lhs.failed.map(\.title) == rhs.failed.map(\.title)
                && lhs.failed.map(\.message) == rhs.failed.map(\.message)
        }
    }

    /// Eine ausfuehrungsfertige Bewegung: alles aufgeloest, nichts mehr zu
    /// suchen. `cwd` ist der Pfad, unter dem Claude das Transcript ablegt.
    struct Move: Equatable {
        var sessionID: UUID
        var title: String
        var externalSessionID: String?
        var cwd: String
        var fromProfile: String?
        var toProfile: String?
    }

    var store: AgentSessionStore = AgentSessionStore()
    var profiles: ClaudeAccountProfiles = ClaudeAccountProfiles()
    var journal: AccountMoveJournal = AccountMoveJournal()
    /// Scan-Steuerung als Closures statt als Coordinator-Referenz: der
    /// Coordinator ist ein Singleton, das beim Fortsetzen einen ECHTEN Scan
    /// gegen die Produktions-Workspace-Datei startet — in Tests waere das ein
    /// Seiteneffekt auf die Daten des Nutzers.
    var suspendScans: () -> Void = { AgentScanCoordinator.shared.suspendScans() }
    var resumeScans: () -> Void = { AgentScanCoordinator.shared.resumeScans() }

    /// - Parameters:
    ///   - progress: nach jeder Session (erledigt, gesamt).
    ///   - shouldCancel: wird VOR jeder Session gefragt. Ein Abbruch beendet
    ///     nach der zuletzt vollstaendig bewegten Session — nie mitten im
    ///     zweistufigen Move (JSONL + Subagent-Ordner).
    ///   - recordInJournal: `false` beim Zuruecknehmen, sonst wuerde der
    ///     Rueckweg selbst wieder als neuester Batch gelten und „Rueckgaengig"
    ///     liefe im Kreis.
    func perform(
        _ moves: [Move],
        batchID: UUID = UUID(),
        recordInJournal: Bool = true,
        progress: ((Int, Int) -> Void)? = nil,
        shouldCancel: (() -> Bool)? = nil
    ) -> Outcome {
        guard !moves.isEmpty else { return Outcome() }

        suspendScans()
        defer { resumeScans() }

        var outcome = Outcome()
        for (index, move) in moves.enumerated() {
            if shouldCancel?() == true {
                outcome.wasCancelled = true
                break
            }
            do {
                // Reihenfolge ist wesentlich: erst die Datei, dann der
                // Stempel. Andersherum zeigte der Stempel auf einen Root ohne
                // Transcript, und ein Resume in genau diesem Fenster liefe ins
                // Leere („No conversation found").
                var movedTranscript = false
                if let externalID = move.externalSessionID, !externalID.isEmpty {
                    movedTranscript = try profiles.moveTranscript(
                        externalSessionID: externalID,
                        cwd: move.cwd,
                        toProfile: move.toProfile
                    )
                }
                try store.setClaudeSessionProfile(id: move.sessionID, profileName: move.toProfile)
                outcome.moved.append(AccountMoveJournal.Entry(
                    batchID: batchID,
                    sessionID: move.sessionID,
                    sessionTitle: move.title,
                    fromProfile: move.fromProfile,
                    toProfile: move.toProfile,
                    movedTranscript: movedTranscript,
                    timestamp: Date()
                ))
            } catch {
                // Teilerfolge bleiben stehen (siehe AccountMoveJournal): ein
                // Auto-Rollback koennte selbst scheitern.
                Logger.agentStore.warning(
                    "account_move_failed session=\(move.sessionID.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                )
                outcome.failed.append((title: move.title, message: error.localizedDescription))
            }
            progress?(index + 1, moves.count)
        }

        if recordInJournal {
            journal.append(outcome.moved)
        }
        Logger.agentStore.notice(
            "account_move_batch moved=\(outcome.moved.count) failed=\(outcome.failed.count) cancelled=\(outcome.wasCancelled)"
        )
        return outcome
    }

    /// Nimmt den zuletzt protokollierten Batch zurueck.
    ///
    /// - Parameter isRunning: Laufende Chats werden uebersprungen und in
    ///   `Outcome.skippedRunning` gemeldet. Ihr Prozess haelt die Registry im
    ///   jetzigen Config-Dir und schreibt weiter in die jetzige Datei — ein
    ///   Rueckzug unter ihm teilte den Verlauf auf zwei Dateien auf (dieselbe
    ///   Regel wie `AccountMovePlanner.SkipReason.running` beim Hinweg). Ihre
    ///   Journal-Eintraege bleiben stehen: nach dem Anhalten nimmt ein
    ///   erneutes „Rueckgaengig" genau sie zurueck.
    func undoLastBatch(
        isRunning: (UUID) -> Bool = { _ in false },
        cwdResolver: (UUID) -> String?,
        externalIDResolver: (UUID) -> String?
    ) -> Outcome {
        let batch = journal.lastBatch()
        guard !batch.isEmpty else { return Outcome() }
        let inverted = AccountMoveJournal.inverted(batch)
        let running = inverted.filter { isRunning($0.sessionID) }
        let runningIDs = Set(running.map(\.sessionID))
        let moves: [Move] = inverted.filter { !runningIDs.contains($0.sessionID) }.compactMap { entry in
            guard let cwd = cwdResolver(entry.sessionID) else { return nil }
            return Move(
                sessionID: entry.sessionID,
                title: entry.sessionTitle,
                externalSessionID: externalIDResolver(entry.sessionID),
                cwd: cwd,
                fromProfile: entry.fromProfile,
                toProfile: entry.toProfile
            )
        }
        // Der Rueckweg wird bewusst NICHT journalisiert — sonst waere er der
        // neueste Batch und ein zweites „Rueckgaengig" pendelte zurueck.
        var outcome = perform(moves, recordInJournal: false)
        outcome.skippedRunning = running.map(\.sessionTitle)
        if !running.isEmpty {
            Logger.agentStore.notice("account_move_undo_skipped_running count=\(running.count)")
        }
        if !outcome.moved.isEmpty {
            clearLastBatch(batch, keeping: runningIDs)
        }
        return outcome
    }

    /// Entfernt den zurueckgenommenen Batch aus dem Journal, damit
    /// „Rueckgaengig" nicht zweimal dasselbe anbietet. Eintraege der
    /// uebersprungenen, laufenden Chats (`keeping`) bleiben — mit derselben
    /// Batch-ID, also weiterhin der zuletzt zuruecknehmbare Batch.
    private func clearLastBatch(_ batch: [AccountMoveJournal.Entry], keeping keptSessionIDs: Set<UUID>) {
        guard let batchID = batch.first?.batchID else { return }
        let remaining = journal.allEntries().filter {
            $0.batchID != batchID || keptSessionIDs.contains($0.sessionID)
        }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            var payload = Data()
            for entry in remaining {
                payload.append(try encoder.encode(entry))
                payload.append(0x0A)
            }
            try payload.write(to: journal.fileURL, options: .atomic)
        } catch {
            Logger.agentStore.warning(
                "account_move_journal_rewrite_failed error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
