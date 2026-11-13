import Darwin
import Foundation

// MARK: - Entscheidungen beim Beenden und beim Start

/// Reine Entscheidungstabellen für Paket 4. Kein I/O: Fakten kommen als
/// Eingabe, die Ausführung liegt beim Koordinator. Grundsatz: Im Zweifel gilt
/// der heutige Weg (Beenden, beim Start `--resume`), nie zwei Prozesse auf
/// einer Sitzung.
enum HandoverPlanning {}

// MARK: Beenden

/// Wodurch die App endet.
enum HandoverQuitTrigger: Equatable {
    /// `whisperm8 app handover` (`make dev`, Test-Instanz `restart --keep-chats`),
    /// Menüpunkt „Neu starten, Chats laufen weiter“, Hinweis nach Brew-Update.
    case restartRequest
    /// Cmd+Q und Menü „Beenden“: bleibt echtes Beenden (Entscheidung 3).
    case userQuit
    /// Abmelden, Neustart des Macs, SIGTERM ohne vorherige Anfrage.
    case systemQuit
}

/// Lage des Aufbewahrers dieser Instanz beim Beenden.
enum HandoverKeeperPresence: Equatable {
    case none
    /// Lebt und hält Chats, die noch niemand übernommen hat. Dann gibt die App
    /// nicht ab (eine zweite Abgabe verhindert ohnehin die Lock-Datei), sondern
    /// endet auf dem heutigen Weg; die neue App übernimmt vom alten Aufbewahrer.
    case holdingUntakenChats
    /// Antwortet nicht, Lage unklar. Lieber der heutige Weg.
    case unknown
}

struct HandoverQuitCandidate: Equatable {
    var sessionID: UUID
    /// `nil` = Art wird nie übergeben (Agents-Ansicht, Subagent-Job).
    var kind: HandoverChatKind?
    /// Prozess läuft und hat eine PID.
    var hasLiveProcess: Bool
}

enum HandoverQuitPlan: Equatable {
    enum ClassicReason: String, Equatable {
        case featureDisabled
        case notARestart
        case keeperStillHolding
        case keeperUnknown
        /// Schalter erst in diesem App-Lauf eingeschaltet: Der GPT-Router
        /// steckt noch in der App, eine Abgabe risse laufende Antworten ab.
        case routerInApp
    }

    enum Exclusion: String, Equatable {
        case kindNotHandedOver
        case notRunning
    }

    /// Heutiger Weg: Ctrl+C an die TUIs, Marker wie heute.
    case classic(ClassicReason)
    /// Neustart mit Übergabe. `handOver` darf leer sein: Dann startet kein
    /// Aufbewahrer, aber Router-Dienst und Proxys laufen weiter.
    case restart(handOver: [UUID], excluded: [UUID: Exclusion])
}

extension HandoverPlanning {
    static func quitPlan(
        featureEnabled: Bool,
        trigger: HandoverQuitTrigger,
        keeper: HandoverKeeperPresence,
        candidates: [HandoverQuitCandidate],
        routerRunsAsService: Bool = true
    ) -> HandoverQuitPlan {
        guard featureEnabled else { return .classic(.featureDisabled) }
        guard trigger == .restartRequest else { return .classic(.notARestart) }
        // Vic, Gesamt-Review Teil 2: Der Schalter wird live geprüft, der
        // Router-Modus steht aber nur einmal je Lauf fest. Wurde der Schalter
        // erst in diesem Lauf eingeschaltet, gibt es noch keinen Router-Dienst.
        guard routerRunsAsService else { return .classic(.routerInApp) }
        switch keeper {
        case .holdingUntakenChats: return .classic(.keeperStillHolding)
        case .unknown: return .classic(.keeperUnknown)
        case .none: break
        }
        var handOver: [UUID] = []
        var excluded: [UUID: HandoverQuitPlan.Exclusion] = [:]
        var seen = Set<UUID>()
        for candidate in candidates where seen.insert(candidate.sessionID).inserted {
            if candidate.kind == nil {
                excluded[candidate.sessionID] = .kindNotHandedOver
            } else if !candidate.hasLiveProcess {
                excluded[candidate.sessionID] = .notRunning
            } else {
                handOver.append(candidate.sessionID)
            }
        }
        return .restart(handOver: handOver, excluded: excluded)
    }
}

// MARK: Start

/// Was die neue App mit einem lebenden Aufbewahrer tut.
enum HandoverLaunchPlan: Equatable {
    /// Kein Zustand „übergeben“ im Marker: heutiger Start.
    case nothing
    /// Übernehmen mit dem Geheimnis aus dem Schlüsselbund.
    case take(secret: String)
    /// Aufbewahrer lebt, Übernahme nicht möglich (unverträglich), Geheimnis
    /// vorhanden: `RELEASE`, er beendet geordnet; danach `--resume`.
    case release(secret: String)
    /// Ohne Geheimnis oder bei fremdem Lauf: SIGTERM an die PID aus `STATUS`
    /// (geordnetes Ende über seinen Signal-Handler); danach `--resume`.
    case terminateKeeper(pid: Int32)
    /// Kein Aufbewahrer erreichbar: je Chat prüfen, ob der Prozess lebt.
    case keeperGone
}

/// Was die neue App über den Aufbewahrer weiß, bevor sie entscheidet.
struct HandoverKeeperObservation: Equatable {
    var runID: String
    var pid: Int32
    /// Spricht er ein Protokoll, das dieser Build versteht?
    var compatible: Bool
}

extension HandoverPlanning {
    static func launchPlan(
        markerHandover: AgentCrashRecoveryMarker.HandedOver?,
        keeper: HandoverKeeperObservation?,
        secret: HandoverSecretLookup
    ) -> HandoverLaunchPlan {
        guard let markerHandover else {
            // Kein „übergeben“ im Marker, aber ein Aufbewahrer lebt: Er stammt
            // aus einem Lauf, den diese App nicht kennt (Marker verloren). Ohne
            // Geheimnis kann sie nicht übernehmen; damit niemand die Chats
            // doppelt startet, beendet sie ihn geordnet.
            if let keeper { return .terminateKeeper(pid: keeper.pid) }
            return .nothing
        }
        guard let keeper else { return .keeperGone }
        guard keeper.runID == markerHandover.runID, case .found(let value) = secret else {
            return .terminateKeeper(pid: keeper.pid)
        }
        return keeper.compatible ? .take(secret: value) : .release(secret: value)
    }
}

/// Ausgang der Übernahme je Chat.
enum HandoverTakeOutcome: Equatable {
    /// Leitung gehört der App (`take` kam mit OK zurück).
    case adopted
    /// Prozess endete in der Lücke; Bild und Exit-Status sind da.
    case endedInGap(exitStatus: Int32?)
    /// Nicht übernommen (Aufbewahrer weg, unverträglich, `take` gescheitert).
    case notTaken
}

enum HandoverChatAction: Equatable {
    /// Controller mit der übernommenen Leitung bauen.
    case adopt
    /// „Beendet“ zeigen, mit dem letzten Bild; kein automatischer Neustart.
    case showEnded
    /// Prozess ist tot: wie nach einem Absturz per `--resume` fortsetzen.
    case resume
    /// Prozess lebt noch ohne App: erst geordnet beenden, nach seinem Ende
    /// fortsetzen. Nie starten, solange er lebt.
    case terminateThenResume
    /// Prozess lebt, die Art lässt sich nicht fortsetzen (Terminal-Tab):
    /// geordnet beenden, nichts neu starten.
    case terminate
    /// Tot und nicht fortsetzbar: nichts tun.
    case none
}

extension HandoverPlanning {
    /// - Parameters:
    ///   - processAlive: Lebt unter der PID aus dem Marker noch derselbe
    ///     Prozess (Startzeit passt)? Siehe `isSameProcess`.
    ///   - resumable: Lässt sich die Sitzung per `--resume` fortsetzen?
    static func chatAction(
        outcome: HandoverTakeOutcome,
        processAlive: Bool,
        resumable: Bool
    ) -> HandoverChatAction {
        switch outcome {
        case .adopted: return .adopt
        case .endedInGap: return .showEnded
        case .notTaken:
            if processAlive { return resumable ? .terminateThenResume : .terminate }
            return resumable ? .resume : .none
        }
    }

    /// Lebt unter `pid` noch der Prozess mit dieser Startzeit? Ohne bekannte
    /// Startzeit zählt nur, ob die PID lebt — dann lieber „lebt“ annehmen und
    /// beenden, als einen zweiten Prozess auf dieselbe Sitzung zu starten.
    static func isSameProcess(
        pid: Int32,
        expectedStartTime: Double?,
        isAlive: (Int32) -> Bool = { HandoverPlanning.isRunningProcess($0) },
        startTime: (Int32) -> Date? = { ProcessStartTime.of(pid: $0) }
    ) -> Bool {
        guard pid > 1, isAlive(pid) else { return false }
        guard let expectedStartTime else { return true }
        guard let current = startTime(pid) else { return true }
        return abs(current.timeIntervalSince1970 - expectedStartTime) < 0.001
    }

    /// Wie `isSameProcess`, aber ohne Zweifel zugunsten des Prozesses: Die
    /// erwartete und die aktuelle Startzeit müssen bekannt sein und passen.
    /// Für SIGKILL, wo ein Irrtum einen fremden Prozess träfe.
    static func isCertainlySameProcess(
        pid: Int32,
        expectedStartTime: Double?,
        isAlive: (Int32) -> Bool = { HandoverPlanning.isRunningProcess($0) },
        startTime: (Int32) -> Date? = { ProcessStartTime.of(pid: $0) }
    ) -> Bool {
        guard pid > 1, isAlive(pid), let expectedStartTime, let current = startTime(pid) else { return false }
        return abs(current.timeIntervalSince1970 - expectedStartTime) < 0.001
    }

    /// Lebt der Prozess? Ein Zombie (beendet, noch nicht abgeholt) zählt als
    /// beendet: Er schreibt nichts mehr in seine Sitzung.
    static func isRunningProcess(_ pid: Int32) -> Bool {
        guard pid > 0, kill(pid, 0) == 0 || errno == EPERM else { return false }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return true }
        return info.kp_proc.p_stat != SZOMB
    }

    /// Sitzungsarten, die `--resume` kennen (wie die Absturz-Wiederaufnahme).
    static func isResumable(_ kind: AgentSessionKind) -> Bool {
        switch kind {
        case .chat, .backgroundChat: return true
        case .agentView, .terminal, .subagentJob: return false
        }
    }
}

// MARK: - Bericht der Übernahme

/// Ergebnis der letzten Übernahme, für `whisperm8 app handover-status
/// --wait-take` (Dauerlauf, Test-Instanz `restart --keep-chats`). Ohne Tokens
/// und ohne Inhalte; liegt im Ordner des Aufbewahrers.
struct HandoverTakeReport: Codable, Equatable {
    var runID: String
    var finishedAt: Double
    /// In der App übernommen.
    var adopted: [String]
    /// In der Lücke beendet, „beendet“ angezeigt.
    var endedInGap: [String]
    /// Nicht übernommen, fortgesetzt oder beendet (Rückfall).
    var fallback: [String]

    var isComplete: Bool { fallback.isEmpty }

    static func fileURL(paths: HandoverPaths) -> URL {
        paths.directory.appendingPathComponent("last-take.json")
    }

    static func read(paths: HandoverPaths) -> HandoverTakeReport? {
        // Nur eine eigene, normale Datei (kein Symlink).
        var st = stat()
        let url = fileURL(paths: paths)
        guard lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == getuid(),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(HandoverTakeReport.self, from: data)
    }

    /// Schreibt in den geprüften Ordner des Aufbewahrers (kein Symlink, eigener
    /// Besitzer, 0700 — derselbe Weg wie beim Aufbewahrer), die Datei exklusiv
    /// mit 0600 und danach per Umbenennen eingetauscht. `false`, wenn der
    /// Ordner die Prüfung nicht besteht; dann wird nichts geschrieben.
    @discardableResult
    func write(paths: HandoverPaths) -> Bool {
        try? FileManager.default.createDirectory(at: paths.directory.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        guard AgentControlServer.prepareOwnedDirectory(at: paths.directory),
              let data = try? JSONEncoder().encode(self) else { return false }
        let temp = paths.directory.appendingPathComponent(".last-take-\(UUID().uuidString).tmp")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return false }
        let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        close(fd)
        guard written == data.count, rename(temp.path, Self.fileURL(paths: paths).path) == 0 else {
            unlink(temp.path)
            return false
        }
        return true
    }
}

// MARK: - Rückfall: höchstens ein Chat je Sitzung

extension AgentCollectiveStartPlanner {
    /// Wie `plan(_:sessions:)` für den Rückfall der Übernahme. Zusätzlich
    /// führt ein Chat, der schon läuft (übernommen) oder in diesem Start schon
    /// vorgemerkt ist, seine Sitzung weiter: Ein vorgemerkter Chat mit derselben
    /// Sitzung startet dann nicht, egal welcher nach der Regel gewönne. Für
    /// Codex ist das der einzige Schutz; es gibt weder Registry-Sperre noch
    /// Reservierung (Vic, 13.11.2026).
    static func plan(
        _ ids: [UUID],
        sessions: [AgentChatSession],
        alreadyStarted: Set<UUID>,
        evidence: (AgentChatSession) -> AgentSessionOwnershipEvidence = { _ in .noEvidence }
    ) -> Plan {
        let byID = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func key(_ id: UUID) -> String? {
            guard let session = byID[id],
                  let external = session.externalSessionID?.lowercased(), !external.isEmpty else { return nil }
            return "\(session.provider.rawValue):\(external)"
        }
        var holder: [String: UUID] = [:]
        for id in alreadyStarted.sorted(by: { $0.uuidString < $1.uuidString }) {
            if let key = key(id), holder[key] == nil { holder[key] = id }
        }
        var held = Plan(start: [], skipped: [])
        var open: [UUID] = []
        for id in ids {
            if alreadyStarted.contains(id) {
                held.skipped.append(id)
            } else if let key = key(id), let owner = holder[key] {
                held.skipped.append(id)
                held.keeperOf[id] = owner
            } else {
                open.append(id)
            }
        }
        let rest = plan(open, sessions: sessions, evidence: evidence)
        let skipped = Set(held.skipped + rest.skipped)
        return Plan(start: rest.start,
                    skipped: ids.filter { skipped.contains($0) },
                    keeperOf: held.keeperOf.merging(rest.keeperOf) { first, _ in first })
    }
}
