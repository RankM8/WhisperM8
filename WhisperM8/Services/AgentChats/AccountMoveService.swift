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

        static func == (lhs: Outcome, rhs: Outcome) -> Bool {
            lhs.moved == rhs.moved
                && lhs.wasCancelled == rhs.wasCancelled
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
    var scanCoordinator: AgentScanCoordinator = .shared

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

        scanCoordinator.suspendScans()
        defer { scanCoordinator.resumeScans() }

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
    func undoLastBatch(
        cwdResolver: (UUID) -> String?,
        externalIDResolver: (UUID) -> String?
    ) -> Outcome {
        let batch = journal.lastBatch()
        guard !batch.isEmpty else { return Outcome() }
        let moves: [Move] = AccountMoveJournal.inverted(batch).compactMap { entry in
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
        let outcome = perform(moves, recordInJournal: false)
        if !outcome.moved.isEmpty {
            clearLastBatch(batch)
        }
        return outcome
    }

    /// Entfernt den zurueckgenommenen Batch aus dem Journal, damit
    /// „Rueckgaengig" nicht zweimal dasselbe anbietet.
    private func clearLastBatch(_ batch: [AccountMoveJournal.Entry]) {
        guard let batchID = batch.first?.batchID else { return }
        let remaining = journal.allEntries().filter { $0.batchID != batchID }
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
