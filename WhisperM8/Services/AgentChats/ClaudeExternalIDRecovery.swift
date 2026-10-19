import Darwin
import Foundation

/// Selbstheilung für Claude-Chats, deren `externalSessionID` auf eine Session
/// ohne Transcript zeigt (Vorfall 2026-09-30, Chat 06760440: nach dem
/// Umwandeln in einen Background-Agent war die leere Vordergrund-Session der
/// TUI gebunden, der echte Verlauf lag unverändert unter der alten ID).
///
/// Quelle ist das Hook-Event-File des Chats (`claude-session-events/<localID>.jsonl`):
/// Es hält jede Session-ID fest, die je in diesem Chat einen Turn hatte, samt
/// `transcript_path`. Gewählt wird die ID mit dem JÜNGSTEN Turn-Beleg, deren
/// Datei noch existiert — also genau der Verlauf, an dem der User zuletzt
/// gearbeitet hat.
///
/// Kostenregel (LR-AK-039): Event-Files können hunderte MB groß sein. Jede
/// Datei wird je Aufruf höchstens einmal byteweise indiziert, Dateien ohne
/// Rückfall-ID landen in einem persistenten Negativ-Cache (Pfad + Größe +
/// mtime), und pro Aufruf werden nur begrenzt viele neue Chats geprüft.
enum ClaudeExternalIDRecovery {
    /// Turn-Events, die belegen, dass eine Session wirklich gearbeitet hat
    /// (und damit ein Transcript schreibt). Bewusst ohne SessionStart/-End.
    private static let turnEventMarkers = [
        "\"hook_event_name\":\"UserPromptSubmit\"",
        "\"hook_event_name\":\"Stop\"",
    ]
    private static let sessionStartMarker = "\"hook_event_name\":\"SessionStart\""
    private static let forkSourceMarker = "\"source\":\"fork\""

    /// Rückfall-Kandidat: Session-ID + wo ihr Transcript HEUTE liegt.
    struct Candidate: Equatable {
        let sessionID: String
        let transcriptURL: URL
    }

    /// Aus dem Event-File gewonnene Turn-Belege — unabhängig von der kaputten
    /// ID, damit eine Datei nur EINMAL zerlegt werden muss.
    struct EventIndex: Equatable {
        /// Reihenfolge des letzten Turn-Belegs je ID.
        var lastTurnIndex: [String: Int] = [:]
        /// Jüngster protokollierter Transcript-Pfad je ID.
        var pathByID: [String: String] = [:]
        /// Background-Forks (`SessionStart` mit `source: fork`) schreiben ihre
        /// Turns ins selbe Event-File und sind jünger als das Original — ohne
        /// Ausschluss fiele der Chat auf den bg-Agent zurück (Review 2026-10-02).
        var forkIDs = Set<String>()

        /// Gibt es überhaupt eine fremde ID mit Turn (≠ `brokenID`, kein Fork)?
        func hasTurnCandidate(besides brokenID: String) -> Bool {
            lastTurnIndex.keys.contains { $0 != brokenID && !forkIDs.contains($0) }
        }
    }

    /// Wertet eine bereits als relevant erkannte, geparste Zeile aus.
    private static func absorb(object: [String: Any], isForkStart: Bool, index: Int, into result: inout EventIndex) {
        guard let sessionID = object["session_id"] as? String else { return }
        if isForkStart {
            result.forkIDs.insert(sessionID)
            return
        }
        guard !sessionID.isEmpty,
              let path = object["transcript_path"] as? String, !path.isEmpty else { return }
        result.lastTurnIndex[sessionID] = index
        result.pathByID[sessionID] = path
    }

    static func buildIndex(eventLines: some Sequence<Substring>) -> EventIndex {
        var result = EventIndex()
        var index = 0
        for line in eventLines {
            index += 1
            let isForkStart = line.contains(sessionStartMarker) && line.contains(forkSourceMarker)
            // Billiger Vorfilter: Tool-Events tragen teils MB-große Payloads
            // (Base64-Screenshots) — nur Turn-/Fork-Zeilen werden geparst.
            guard isForkStart || turnEventMarkers.contains(where: { line.contains($0) }),
                  let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            absorb(object: object, isForkStart: isForkStart, index: index, into: &result)
        }
        return result
    }

    /// Byte-genauer Scan ohne String-Kopie der ganzen Datei: der alte Weg
    /// (`String(decoding:)` + `split`) belegte beim Start bis zu 2 GB und einen
    /// Kern. Hier wird die gemappte Datei zeilenweise per `memchr`/`memmem`
    /// durchsucht, geparst werden nur Treffer-Zeilen.
    static func buildIndex(data: Data) -> EventIndex {
        var result = EventIndex()
        let turnMarkers = turnEventMarkers.map { Array($0.utf8) }
        let startMarker = Array(sessionStartMarker.utf8)
        let forkMarker = Array(forkSourceMarker.utf8)

        func contains(_ marker: [UInt8], in line: UnsafeRawPointer, length: Int) -> Bool {
            marker.withUnsafeBytes { memmem(line, length, $0.baseAddress!, marker.count) != nil }
        }

        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            let count = raw.count
            var offset = 0
            var index = 0
            while offset < count {
                let lineStart = base + offset
                let remaining = count - offset
                let length: Int
                if let newline = memchr(lineStart, 0x0A, remaining) {
                    length = UnsafeRawPointer(newline) - lineStart
                } else {
                    length = remaining
                }
                offset += length + 1
                if length == 0 { continue }
                index += 1
                let isForkStart = contains(startMarker, in: lineStart, length: length)
                    && contains(forkMarker, in: lineStart, length: length)
                guard isForkStart || turnMarkers.contains(where: { contains($0, in: lineStart, length: length) }),
                      let object = try? JSONSerialization.jsonObject(
                        with: Data(bytes: lineStart, count: length)) as? [String: Any]
                else { continue }
                absorb(object: object, isForkStart: isForkStart, index: index, into: &result)
            }
        }
        return result
    }

    /// Wählt aus dem Index den Kandidaten mit dem jüngsten Turn, dessen Datei existiert.
    static func candidate(
        from index: EventIndex,
        brokenID: String,
        locateTranscript: (String, String) -> URL?
    ) -> Candidate? {
        let ids = index.lastTurnIndex
            .filter { $0.key != brokenID && !index.forkIDs.contains($0.key) }
            .sorted { $0.value > $1.value }
            .map(\.key)
        for id in ids {
            if let url = locateTranscript(id, index.pathByID[id] ?? "") {
                return Candidate(sessionID: id, transcriptURL: url)
            }
        }
        return nil
    }

    /// - Parameter locateTranscript: (Session-ID, im Hook protokollierter
    ///   Pfad) → heutiger Ort der Datei oder `nil`. Der protokollierte Pfad
    ///   allein reicht nicht: ein Kontowechsel (`move-account`, Kontextmenü)
    ///   verschiebt das Transcript in ein anderes Profil (Vorfall 2026-10-01:
    ///   ac020fd4 lag danach unter PowerUser2 statt RankM8).
    /// - Returns: Kandidat mit dem jüngsten Turn, dessen Datei existiert.
    static func recoverableCandidate(
        eventLines: some Sequence<Substring>,
        brokenID: String,
        locateTranscript: (String, String) -> URL?
    ) -> Candidate? {
        candidate(from: buildIndex(eventLines: eventLines), brokenID: brokenID, locateTranscript: locateTranscript)
    }

    /// Standardsuche: protokollierter Pfad, sonst der Locator über ALLE
    /// Profil-Roots (inkl. cwd-verifiziertem Glob).
    static func defaultLocator(projectPath: String) -> (String, String) -> URL? {
        { id, loggedPath in
            if !loggedPath.isEmpty, FileManager.default.fileExists(atPath: loggedPath) {
                return URL(fileURLWithPath: loggedPath)
            }
            return AgentTranscriptLocator.locate(
                provider: .claude, externalSessionID: id, cwd: projectPath)
        }
    }

    /// Liest das Event-File und liefert den Rückfall-Kandidaten (oder `nil`).
    static func recoverableCandidate(
        eventFileURL: URL,
        brokenID: String,
        projectPath: String,
        locateTranscript: ((String, String) -> URL?)? = nil
    ) -> Candidate? {
        guard let data = try? Data(contentsOf: eventFileURL, options: .mappedIfSafe) else { return nil }
        return candidate(
            from: buildIndex(data: data),
            brokenID: brokenID,
            locateTranscript: locateTranscript ?? defaultLocator(projectPath: projectPath))
    }

    /// Größe des Dateiendes, das der Start-Pfad (Main-Thread) höchstens liest.
    static let unboundResumeTailBytes = 2 * 1024 * 1024

    /// Letzte `maxBytes` des Event-Files (mapped, ohne die ganze Datei zu laden).
    /// Die erste, angeschnittene Zeile scheitert beim Parsen und wird übersprungen.
    static func tailData(of url: URL, maxBytes: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil else { return nil }
        return try? handle.readToEnd()
    }

    /// Resume-Kandidat für einen gestarteten Chat OHNE gebundene ID (Start-Pfad,
    /// Main-Thread): liest nur das Dateiende und übernimmt keine ID, die schon an
    /// einen anderen Chat gebunden ist (LR-AK-021, wie in `recoveries`).
    static func unboundResumeCandidate(
        eventFileURL: URL,
        projectPath: String,
        boundExternalIDs: Set<String>,
        maxTailBytes: Int = ClaudeExternalIDRecovery.unboundResumeTailBytes,
        locateTranscript: ((String, String) -> URL?)? = nil
    ) -> Candidate? {
        guard let data = tailData(of: eventFileURL, maxBytes: maxTailBytes) else { return nil }
        guard let candidate = candidate(
            from: buildIndex(data: data),
            brokenID: "",
            locateTranscript: locateTranscript ?? defaultLocator(projectPath: projectPath))
        else { return nil }
        guard !boundExternalIDs.contains(candidate.sessionID) else {
            Logger.claudeBinding.notice("resume_unbound_skipped_bound_elsewhere candidate=\(candidate.sessionID, privacy: .public)")
            return nil
        }
        return candidate
    }

    struct Recovery: Equatable {
        let localID: UUID
        let brokenID: String
        let recoveredID: String
        /// Profil des Chats beim Scan — angewendet wird nur, wenn es noch
        /// gilt (ein Kontowechsel dazwischen gewinnt).
        var expectedProfileName: String? = nil
        /// Profil, unter dem das Transcript heute liegt (`nil` = main).
        /// `--resume` findet die Session nur unter diesem Config-Dir — liegt
        /// die Datei nach einem Kontowechsel woanders, zieht das Profil des
        /// Chats mit.
        let recoveredProfileName: String?
    }

    /// Je (localID, kaputte ID) nur EIN Versuch pro App-Lauf — die Sidebar
    /// berechnet „tote Zeiger" bei jedem Workspace-Reload neu, und nach
    /// Claudes 30-Tage-Cleanup gibt es viele echte Tote ohne Rückfall-ID.
    private static let attemptedLock = NSLock()
    nonisolated(unsafe) private static var attempted: Set<String> = []

    /// Obergrenze NEUER Versuche pro Aufruf: Nach einem Cleanup gibt es
    /// hunderte tote Zeiger; sie in einem Rutsch zu prüfen belegte nach jedem
    /// Start minutenlang einen Kern. Der Rest folgt beim nächsten
    /// Workspace-Reload (die Sidebar ruft das ohnehin laufend auf).
    static let maxNewAttemptsPerCall = 40

    /// Prüft die Claude-Sessions unter `candidates` (tote Zeiger) auf eine
    /// Rückfall-ID. Off-main gedacht (liest Event-Files).
    ///
    /// - Parameter boundExternalIDs: externe IDs ALLER Sessions im Workspace.
    ///   Ist die Rückfall-ID schon an einen anderen Chat gebunden (z. B. den
    ///   Ersatz-Chat, in dem der User weitergearbeitet hat), wird NICHT
    ///   geheilt — zwei Chats auf derselben Claude-Session schreiben beim
    ///   gleichzeitigen Resume in dasselbe Transcript.
    /// - Parameter eventFileURL: Event-File je Chat (Test-Seam; Default über `hookPaths`).
    /// - Parameter negativeCache: merkt Event-Files ohne Rückfall-ID über
    ///   App-Starts hinweg (Pfad + Größe + mtime).
    /// - Parameter onIndexBuilt: Test-Seam, feuert bei jedem Zerlegen einer Datei.
    static func recoveries(
        candidates: [AgentChatSession],
        projectPathByID: [UUID: String],
        boundExternalIDs: Set<String>,
        hookPaths: ClaudeHookPaths = ClaudeHookPaths(),
        locateTranscript: ((String, String) -> URL?)? = nil,
        eventFileURL: ((AgentChatSession) -> URL)? = nil,
        negativeCache: RecoveryNegativeCache? = nil,
        maxNewAttempts: Int = ClaudeExternalIDRecovery.maxNewAttemptsPerCall,
        onIndexBuilt: ((URL) -> Void)? = nil
    ) -> [Recovery] {
        let token = PerfBudgets.externalIDRecovery.begin()
        defer { PerfBudgets.externalIDRecovery.end(token) }
        let cache = negativeCache ?? RecoveryNegativeCache(
            fileURL: hookPaths.rootDirectory.appendingPathComponent("recovery-negative-cache.json"))
        var result: [Recovery] = []
        // Je Event-File einmal zerlegen, auch bei vielen Kandidaten.
        var indexByFile: [String: EventIndex?] = [:]
        var newAttempts = 0
        var cacheChanged = false
        // Jüngste Chats zuerst: dort lohnt die Heilung am meisten.
        let ordered = candidates.filter { $0.provider == .claude }
            .sorted { $0.lastActivityAt > $1.lastActivityAt }
        for session in ordered {
            guard let broken = session.externalSessionID, !broken.isEmpty,
                  let projectPath = projectPathByID[session.projectID] else { continue }
            let key = "\(session.id.uuidString)|\(broken)"
            attemptedLock.lock()
            let alreadyTried = attempted.contains(key)
            attemptedLock.unlock()
            if alreadyTried { continue }

            let fileURL = eventFileURL?(session) ?? hookPaths.eventFileURL(localSessionID: session.id)
            let signature = RecoveryNegativeCache.signature(of: fileURL)
            // Negativ-Cache VOR dem Budget: ein Treffer kostet nur ein stat() und
            // darf die 40 echten Prüfungen pro Aufruf nicht aufzehren (LR-AK-039).
            if let signature, cache.isKnownNegative(path: fileURL.path, brokenID: broken, signature: signature) {
                attemptedLock.lock()
                attempted.insert(key)
                attemptedLock.unlock()
                continue
            }
            if newAttempts >= maxNewAttempts { break }
            newAttempts += 1
            attemptedLock.lock()
            attempted.insert(key)
            attemptedLock.unlock()

            let index: EventIndex?
            if let known = indexByFile[fileURL.path] {
                index = known
            } else {
                onIndexBuilt?(fileURL)
                index = (try? Data(contentsOf: fileURL, options: .mappedIfSafe)).map(buildIndex(data:))
                indexByFile[fileURL.path] = index
            }
            guard let index else { continue }
            guard index.hasTurnCandidate(besides: broken) else {
                // Rein vom Event-File bestimmt → sicher cachebar.
                if let signature {
                    cache.recordNegative(path: fileURL.path, brokenID: broken, signature: signature)
                    cacheChanged = true
                }
                continue
            }
            guard let candidate = candidate(
                from: index, brokenID: broken,
                locateTranscript: locateTranscript ?? defaultLocator(projectPath: projectPath))
            else { continue }
            guard !boundExternalIDs.contains(candidate.sessionID) else {
                Logger.claudeBinding.notice("binding_recovery_skipped_bound_elsewhere localID=\(session.id.uuidString, privacy: .public) candidate=\(candidate.sessionID, privacy: .public)")
                continue
            }
            result.append(Recovery(
                localID: session.id,
                brokenID: broken,
                recoveredID: candidate.sessionID,
                expectedProfileName: session.claudeProfileName,
                recoveredProfileName: ClaudeAccountProfiles.profileName(
                    forTranscriptPath: candidate.transcriptURL.path)))
        }
        if cacheChanged { cache.save() }
        return result
    }

    /// Nur für Tests: den „einmal pro Lauf"-Merker zurücksetzen.
    static func resetAttemptedForTesting() {
        attemptedLock.lock()
        attempted.removeAll()
        attemptedLock.unlock()
    }
}

/// Persistenter Negativ-Cache der Selbstheilung: „dieses Event-File (Größe +
/// mtime) enthält keine fremde ID mit Turn". Ändert sich die Datei, gilt der
/// Eintrag nicht mehr. Fehler beim Lesen/Schreiben sind folgenlos (dann wird
/// einfach neu geprüft).
final class RecoveryNegativeCache: @unchecked Sendable {
    struct Signature: Codable, Equatable {
        var size: Int64
        var mtime: Double
    }

    private let fileURL: URL?
    private let lock = NSLock()
    private var entries: [String: Signature]
    private let maxEntries = 5000

    init(fileURL: URL?) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: Signature].self, from: data) {
            entries = decoded
        } else {
            entries = [:]
        }
    }

    static func signature(of url: URL) -> Signature? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.int64Value,
              let mtime = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 else { return nil }
        return Signature(size: size, mtime: mtime)
    }

    private func key(_ path: String, _ brokenID: String) -> String { "\(path)|\(brokenID)" }

    func isKnownNegative(path: String, brokenID: String, signature: Signature) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return entries[key(path, brokenID)] == signature
    }

    func recordNegative(path: String, brokenID: String, signature: Signature) {
        lock.lock(); defer { lock.unlock() }
        if entries.count >= maxEntries { entries.removeAll() }
        entries[key(path, brokenID)] = signature
    }

    func save() {
        guard let fileURL else { return }
        lock.lock()
        let snapshot = entries
        lock.unlock()
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
