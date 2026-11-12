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
        candidates: [HandoverQuitCandidate]
    ) -> HandoverQuitPlan {
        guard featureEnabled else { return .classic(.featureDisabled) }
        guard trigger == .restartRequest else { return .classic(.notARestart) }
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
        isAlive: (Int32) -> Bool = { kill($0, 0) == 0 || errno == EPERM },
        startTime: (Int32) -> Date? = { ProcessStartTime.of(pid: $0) }
    ) -> Bool {
        guard pid > 1, isAlive(pid) else { return false }
        guard let expectedStartTime else { return true }
        guard let current = startTime(pid) else { return true }
        return abs(current.timeIntervalSince1970 - expectedStartTime) < 0.001
    }

    /// Sitzungsarten, die `--resume` kennen (wie die Absturz-Wiederaufnahme).
    static func isResumable(_ kind: AgentSessionKind) -> Bool {
        switch kind {
        case .chat, .backgroundChat: return true
        case .agentView, .terminal, .subagentJob: return false
        }
    }
}
