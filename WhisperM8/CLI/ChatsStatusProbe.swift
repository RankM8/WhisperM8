import Foundation

// MARK: - One-Shot-Runtime-Status für den CLI-Prozess

/// Warum (k)ein Transcript-basierter Status vorliegt — landet 1:1 im
/// `--json`-Output (`transcript.availability`).
enum ChatsTranscriptAvailability: String {
    case available
    case missingExternalSessionID
    case missingTranscript
    case unsupported
}

/// Ergebnis der One-Shot-Ableitung für genau eine Session.
struct ChatsRuntimeInfo: Equatable {
    /// `nil` = keine Meinung möglich → im Output `"unknown"`.
    var status: AgentSessionRuntimeStatus?
    /// `transcriptEstimate` | `supervisorJob` — `app` setzt erst der
    /// Live-Merge über den Control-Socket (Slice 2).
    var source: String
    /// Näherung des letzten Statuswechsels: Event-Timestamp, sonst mtime.
    var since: Date?
    /// Monoton wachsende Revision = Transcript-Größe in Bytes. Vergleichbar
    /// zwischen CLI-Aufrufen; Grundlage von `wait --since`.
    var revision: Int?
    var transcriptPath: String?
    var transcriptSizeBytes: Int?
    var availability: ChatsTranscriptAvailability
}

/// Leitet den Runtime-Status one-shot aus dem Transcript ab — exakt dieselben
/// puren Bausteine wie der `AgentSessionRuntimeWatcher` in der App
/// (`AgentTranscriptLocator` → stat → Tail → `AgentTranscriptParser.lastEvent`
/// → `AgentTranscriptStatusDecider.decide`), nur ohne Event-Loop.
/// Kein MainActor, kein Store, keine Singletons mit Seiteneffekten.
enum ChatsStatusProbe {
    /// 64-KB-Tail wie der Watcher — genug für das letzte semantische Event.
    static let tailReadBytes = 65_536
    /// Persistiert-beendete Sessions, deren Transcript länger ruht, melden
    /// wir als `stopped` statt des Decider-`idle` — one-shot kennen wir den
    /// Prozesszustand nicht, aber „closed + 5 min Ruhe" ist kein lebender Chat.
    static let closedQuietSeconds: TimeInterval = 5 * 60

    static func probe(entry: ChatsSessionEntry, now: Date = Date()) -> ChatsRuntimeInfo {
        let session = entry.session
        switch session.effectiveKind {
        case .terminal, .agentView:
            return ChatsRuntimeInfo(status: nil, source: "transcriptEstimate", since: nil,
                                    revision: nil, transcriptPath: nil, transcriptSizeBytes: nil,
                                    availability: .unsupported)
        case .backgroundChat:
            return probeBackground(session: session, now: now)
        case .chat, .subagentJob:
            return probeTranscript(session: session, projectPath: entry.projectPath, now: now)
        }
    }

    /// Alle Einträge parallel proben (TaskGroup) — Budget: < 2 s bei 50 Sessions.
    static func probeAll(entries: [ChatsSessionEntry], now: Date = Date()) async -> [UUID: ChatsRuntimeInfo] {
        await withTaskGroup(of: (UUID, ChatsRuntimeInfo).self) { group in
            for entry in entries {
                group.addTask { (entry.session.id, probe(entry: entry, now: now)) }
            }
            var result: [UUID: ChatsRuntimeInfo] = [:]
            for await (id, info) in group {
                result[id] = info
            }
            return result
        }
    }

    // MARK: - Pfade

    private static func probeTranscript(session: AgentChatSession, projectPath: String, now: Date) -> ChatsRuntimeInfo {
        guard let ext = session.externalSessionID, !ext.isEmpty else {
            return ChatsRuntimeInfo(status: nil, source: "transcriptEstimate", since: nil,
                                    revision: nil, transcriptPath: nil, transcriptSizeBytes: nil,
                                    availability: .missingExternalSessionID)
        }
        let cwd = AgentProjectPath.canonicalProjectPath(session.subagentCwd ?? projectPath)
        guard let url = locateFast(provider: session.provider, externalSessionID: ext, cwd: cwd) else {
            return ChatsRuntimeInfo(status: nil, source: "transcriptEstimate", since: nil,
                                    revision: nil, transcriptPath: nil, transcriptSizeBytes: nil,
                                    availability: .missingTranscript)
        }
        return derive(from: url, provider: session.provider, session: session, source: "transcriptEstimate", now: now)
    }

    private static func probeBackground(session: AgentChatSession, now: Date) -> ChatsRuntimeInfo {
        guard let shortID = session.backgroundShortID, !shortID.isEmpty else {
            return ChatsRuntimeInfo(status: nil, source: "supervisorJob", since: nil,
                                    revision: nil, transcriptPath: nil, transcriptSizeBytes: nil,
                                    availability: .missingExternalSessionID)
        }
        let stateURL = SupervisorJobReader.defaultJobsDirectory
            .appendingPathComponent(shortID)
            .appendingPathComponent("state.json")
        guard let job = SupervisorJobReader.readSingle(stateFileURL: stateURL, shortID: shortID),
              let linkScanPath = job.linkScanPath else {
            return ChatsRuntimeInfo(status: nil, source: "supervisorJob", since: nil,
                                    revision: nil, transcriptPath: nil, transcriptSizeBytes: nil,
                                    availability: .missingTranscript)
        }
        var info = derive(from: URL(fileURLWithPath: linkScanPath), provider: .claude,
                          session: session, source: "supervisorJob", now: now)
        // Supervisor-State ist für terminale Zustände autoritativ — ein
        // failed/stopped Job darf nicht als idle erscheinen, nur weil sein
        // Transcript ruht (GPT-Review).
        switch job.state {
        case "failed", "errored":
            info.status = .errored
        case "stopped", "killed":
            info.status = .stopped
        default:
            break
        }
        return info
    }

    // MARK: - Kern

    /// Internal statt private: Tests exercisen den Kern mit Temp-Transcripts,
    /// ohne die home-basierten Locator-Roots stubben zu müssen.
    static func derive(
        from url: URL,
        provider: AgentProvider,
        session: AgentChatSession,
        source: String,
        now: Date
    ) -> ChatsRuntimeInfo {
        guard let stat = fileStat(at: url) else {
            return ChatsRuntimeInfo(status: nil, source: source, since: nil,
                                    revision: nil, transcriptPath: url.path, transcriptSizeBytes: nil,
                                    availability: .missingTranscript)
        }

        // Stat-Fast-Path: Ruht die Datei länger als die working-Stall-Schwelle,
        // kann der Decider ohnehin nur idle liefern (awaitingInput kommt nie
        // aus dem Transcript-Schätzer, working nie bei stale mtime) — der
        // 64-KB-Tail-Read entfällt. Bei 1000+ indizierten Sessions ist das der
        // Unterschied zwischen ~0,5 s und mehreren Sekunden pro `list`.
        if now.timeIntervalSince(stat.mtime) > AgentTranscriptStatusDecider.workingStallSeconds {
            let isClosedQuiet = (session.status == .closed || session.status == .archived)
                && now.timeIntervalSince(stat.mtime) > closedQuietSeconds
            return ChatsRuntimeInfo(
                status: isClosedQuiet ? .stopped : .idle,
                source: source,
                since: stat.mtime,
                revision: stat.size,
                transcriptPath: url.path,
                transcriptSizeBytes: stat.size,
                availability: .available
            )
        }

        let tail = readTail(at: url, bytes: tailReadBytes) ?? ""
        let lastEvent = AgentTranscriptParser.lastEvent(in: tail, provider: provider)
        let decision = AgentTranscriptStatusDecider.decide(
            lastEvent: lastEvent,
            fileMTime: stat.mtime,
            now: now,
            priorTurnFinishedAt: session.lastTurnAt
        )

        var status = decision?.status
        // One-Shot-Korrektur: persistiert-beendete Sessions mit ruhendem
        // Transcript sind `stopped`, nicht `idle` — der Decider kennt den
        // Prozesszustand nicht, wir kennen wenigstens den Workspace-Status.
        if let derived = status, derived == .idle,
           session.status == .closed || session.status == .archived,
           now.timeIntervalSince(stat.mtime) > closedQuietSeconds {
            status = .stopped
        }

        let since: Date? = {
            switch lastEvent {
            case .userMessage(let ts), .assistantMessageOngoing(let ts),
                 .assistantMessageStopped(let ts, _), .toolResult(let ts),
                 .turnInterrupted(let ts):
                return ts ?? stat.mtime
            default:
                return stat.mtime
            }
        }()

        return ChatsRuntimeInfo(
            status: status,
            source: source,
            since: since,
            revision: stat.size,
            transcriptPath: url.path,
            transcriptSizeBytes: stat.size,
            availability: .available
        )
    }

    // MARK: - Locate-Fast-Path

    /// Claude löst über den Locator auf (wenige fileExists-Checks). Codex
    /// würde pro Session rekursiv über `~/.codex/sessions` walken — bei
    /// hunderten indizierten Sessions O(n·m). Stattdessen EIN Walk pro
    /// CLI-Prozess (lazy static = thread-safe einmalig), Fallback auf den
    /// Locator für Dateien, die nach dem Index-Bau entstanden sind.
    static func locateFast(provider: AgentProvider, externalSessionID: String, cwd: String) -> URL? {
        switch provider {
        case .claude:
            return AgentTranscriptLocator.locate(provider: .claude, externalSessionID: externalSessionID, cwd: cwd)
        case .codex:
            // Index-Treffer validieren — die Datei kann seit dem Index-Bau
            // gelöscht/rotiert sein (GPT-Review); dann Locator-Fallback.
            if let url = codexTranscriptIndex[externalSessionID.lowercased()],
               FileManager.default.fileExists(atPath: url.path) {
                return url
            }
            return AgentTranscriptLocator.locate(provider: .codex, externalSessionID: externalSessionID, cwd: cwd)
        }
    }

    /// Codex-Session-ID (36-Zeichen-Suffix des Dateistamms) → JSONL-URL.
    private static let codexTranscriptIndex: [String: URL] = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex")
            .appendingPathComponent("sessions")
        guard let enumerator = FileManager.default.enumerator(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [:] }
        var index: [String: URL] = [:]
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let stem = url.deletingPathExtension().lastPathComponent
            guard stem.count >= 36 else { continue }
            let candidate = String(stem.suffix(36)).lowercased()
            if UUID(uuidString: candidate) != nil {
                index[candidate] = url
            }
        }
        return index
    }()

    // MARK: - File-Helfer (eigene Kopien — die Watcher-Pendants sind private)

    static func fileStat(at url: URL) -> AgentTranscriptFileStat? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let mtime = attrs[.modificationDate] as? Date else {
            return nil
        }
        return AgentTranscriptFileStat(mtime: mtime, size: (attrs[.size] as? Int) ?? 0)
    }

    static func readTail(at url: URL, bytes: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        do {
            let size = try handle.seekToEnd()
            let offset = UInt64(max(0, Int64(size) - Int64(bytes)))
            try handle.seek(toOffset: offset)
            let data = handle.readData(ofLength: bytes)
            return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        } catch {
            return nil
        }
    }
}
