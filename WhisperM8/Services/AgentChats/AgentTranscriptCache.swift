import Foundation

/// Geteilter Transcript-Cache (Plan F12, Blaupause ff489fdb): Workspace-
/// Wechsel mounten bis zu 9 Offline-Panes gleichzeitig — ohne Cache liefe
/// je Mount ein eigener 512-KiB-Tail-Read + Parse. Der Cache teilt
/// Ergebnisse UND laufende Reads (mehrere Mounts derselben Session warten
/// auf denselben Task) und begrenzt die Lese-Parallelität global auf 2,
/// damit 9 Parses nicht CPU und SSD gleichzeitig fluten.
///
/// Frische: der Eintrag trägt Datei-Identität (Größe + mtime); ein Lookup
/// stattet die Datei (1 syscall) und lädt bei Abweichung neu. Ein größeres
/// Lesefenster (`loadEarlierHistory`) ist ein eigener Key und ersetzt den
/// kleineren Eintrag nicht unkontrolliert.
actor AgentTranscriptCache {
    static let shared = AgentTranscriptCache()

    struct Key: Hashable {
        let provider: AgentProvider
        let externalSessionID: String
        let cwd: String
        let tailBytes: Int
    }

    private struct Entry {
        let transcript: AgentChatTranscript?
        let fileSize: UInt64
        let fileModified: Date
        var lastAccess: ContinuousClock.Instant
    }

    /// Obergrenze der gehaltenen Einträge (LRU) — 24 ≈ zwei volle
    /// 9er-Workspaces plus Wechselreserve.
    private let maxEntries: Int
    /// Max. gleichzeitige Datei-Reads (CPU/SSD-Schutz).
    private let maxConcurrentReads: Int

    private var entries: [Key: Entry] = [:]
    private var inFlight: [Key: (generation: Int, task: Task<AgentChatTranscript?, Never>)] = [:]
    private var activeReads = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let clock = ContinuousClock()
    /// Invalidierungs-Generation: `invalidate`/`removeAll` erhöhen sie — ein
    /// Read, der VOR der Invalidierung startete, darf sein Ergebnis danach
    /// nicht mehr in den Cache zurückschreiben (Review-Finding).
    private var generation = 0

    init(maxEntries: Int = 24, maxConcurrentReads: Int = 2) {
        self.maxEntries = maxEntries
        self.maxConcurrentReads = maxConcurrentReads
    }

    /// Transcript für die Session — Cache-Hit sofort, Miss lädt (geteilt
    /// mit parallelen Anfragen desselben Keys, global gedrosselt).
    func transcript(for key: Key) async -> AgentChatTranscript? {
        let identity = Self.fileIdentity(for: key)

        if var entry = entries[key],
           let identity,
           entry.fileSize == identity.size,
           entry.fileModified == identity.modified {
            entry.lastAccess = clock.now
            entries[key] = entry
            PerfSignposts.grid.emitEvent("grid.transcript.cacheHit")
            return entry.transcript
        }
        PerfSignposts.grid.emitEvent("grid.transcript.cacheMiss")

        // Laufende Reads nur teilen, wenn sie aus der AKTUELLEN Generation
        // stammen — nach einer Invalidierung darf ein neuer Lookup nicht das
        // Ergebnis eines vor der Invalidierung gestarteten Reads erhalten
        // (Re-Verifikations-Finding); der alte Task läuft aus, cached aber
        // nichts mehr.
        if let running = inFlight[key], running.generation == generation {
            return await running.task.value
        }

        let startGeneration = generation
        let task = Task<AgentChatTranscript?, Never> { [weak self] in
            await self?.performRead(key: key, identity: identity)
        }
        inFlight[key] = (startGeneration, task)
        let result = await task.value
        if inFlight[key]?.generation == startGeneration {
            inFlight[key] = nil
        }
        return result
    }

    /// Externe Invalidierung (FSEvent/Statuswechsel) — der nächste Lookup
    /// lädt frisch; laufende Reads schreiben ihr Ergebnis nicht mehr zurück.
    func invalidate(externalSessionID: String) {
        entries = entries.filter { $0.key.externalSessionID != externalSessionID }
        generation += 1
    }

    func removeAll() {
        entries = [:]
        generation += 1
    }

    // MARK: - Intern

    private func performRead(
        key: Key,
        identity: (size: UInt64, modified: Date)?
    ) async -> AgentChatTranscript? {
        let startedGeneration = generation
        await acquireReadSlot()
        defer { releaseReadSlot() }

        let transcript = await Task.detached(priority: .utility) {
            Self.read(key: key)
        }.value

        // Nur cachen, wenn zwischenzeitlich keine Invalidierung lief —
        // sonst würde ein alter Read den frisch geleerten Eintrag
        // wiederbeleben. (Ändert sich die Datei WÄHREND des Reads, heilt
        // der nächste Lookup über den Identitäts-Vergleich.)
        if let identity, startedGeneration == generation {
            entries[key] = Entry(
                transcript: transcript,
                fileSize: identity.size,
                fileModified: identity.modified,
                lastAccess: clock.now
            )
            evictIfNeeded()
        }
        return transcript
    }

    /// Bekannte Grenze (bewusst): Waiter sind nicht cancellation-fähig —
    /// die Aufrufer sind fire-and-forget-Loads der Detail-Views, die nie
    /// cancelled werden; ein abgebrochener Task würde lediglich einen
    /// Slot-Handoff verzögern, nicht leaken (der Read läuft aus und gibt
    /// den Slot regulär weiter).
    private func acquireReadSlot() async {
        if activeReads < maxConcurrentReads {
            activeReads += 1
            return
        }
        // Der Slot wird beim Handoff ÜBERTRAGEN (releaseReadSlot
        // dekrementiert dann nicht) — ein resumter Waiter darf nicht
        // erneut inkrementieren, sonst könnte ein Dritter, der zwischen
        // Resume und Fortsetzung synchron eintritt, das Limit überschreiten
        // (Actor-Reentrancy; Review-Finding).
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func releaseReadSlot() {
        if !waiters.isEmpty {
            // Slot direkt an den nächsten Waiter übergeben — `activeReads`
            // bleibt konstant, kein Fenster für Überbelegung.
            waiters.removeFirst().resume()
        } else {
            activeReads -= 1
        }
    }

    private func evictIfNeeded() {
        guard entries.count > maxEntries else { return }
        let sorted = entries.sorted { $0.value.lastAccess < $1.value.lastAccess }
        for (key, _) in sorted.prefix(entries.count - maxEntries) {
            entries.removeValue(forKey: key)
        }
    }

    private static func transcriptURL(for key: Key) -> URL? {
        switch key.provider {
        case .claude:
            return ClaudeTranscriptReader.transcriptURL(forCwd: key.cwd, sessionID: key.externalSessionID)
        case .codex:
            return CodexTranscriptReader.transcriptURL(forSessionID: key.externalSessionID)
        }
    }

    private static func fileIdentity(for key: Key) -> (size: UInt64, modified: Date)? {
        guard let url = transcriptURL(for: key),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? UInt64,
              let modified = attributes[.modificationDate] as? Date else { return nil }
        return (size, modified)
    }

    private static func read(key: Key) -> AgentChatTranscript? {
        switch key.provider {
        case .claude:
            return ClaudeTranscriptReader.readTail(
                cwd: key.cwd, sessionID: key.externalSessionID, tailBytes: key.tailBytes
            )
        case .codex:
            return CodexTranscriptReader.readTail(
                sessionID: key.externalSessionID, tailBytes: key.tailBytes
            )
        }
    }
}
