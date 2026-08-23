import Foundation

/// Planung eines Konto-Umzugs (ein Chat oder eine Auswahl) — pur und ohne
/// I/O, damit der Vertrag „was wird bewegt, was nicht und warum" testbar ist.
/// Der Aufrufer sammelt die Fakten (laeuft die Session? liegt im Ziel schon
/// eine Datei?) und bekommt hier die Entscheidung.
///
/// Hintergrund: ein Umzug bewegt das Transcript zwischen den `projects/`-Roots
/// zweier Config-Dirs. Nur dort sucht `claude --resume` — der Ablageort
/// entscheidet also, unter welchem Konto ein Chat weiterlaeuft.
/// Siehe docs/plans/claude-account-routing.md, Slice 6.
enum AccountMovePlanner {
    /// Ein Umzugskandidat, angereichert um alles, was die Entscheidung
    /// braucht. `currentProfile`/`targetProfile`: `nil` = Haupt-Account.
    struct Candidate: Equatable, Identifiable {
        var sessionID: UUID
        var title: String
        var currentProfile: String?
        var provider: AgentProvider
        var kind: AgentSessionKind
        var isRunning: Bool
        /// Im Ziel-Root liegt bereits eine Datei mit dieser Session-ID (oder
        /// ein gleichnamiger Subagent-Ordner). Der Umzug wuerde abbrechen.
        var hasTargetConflict: Bool

        var id: UUID { sessionID }
    }

    enum SkipReason: String, Equatable {
        /// Laeuft gerade: der Prozess haelt seine Registry im alten Config-Dir
        /// und schreibt weiter in die alte JSONL.
        case running
        /// Background-Agent: Supervisor, `~/.claude/jobs/` und die
        /// Lifecycle-Aufrufe sind fest auf den Haupt-Account verdrahtet.
        case backgroundAgent
        /// Terminal / Agent View — kein Claude-Transcript, nichts zu bewegen.
        case notAChat
        case alreadyInTarget
        case targetConflict
        case targetNotLoggedIn

        var label: String {
            switch self {
            case .running: return "läuft gerade"
            case .backgroundAgent: return "Hintergrund-Agent"
            case .notAChat: return "kein Claude-Chat"
            case .alreadyInTarget: return "schon in diesem Konto"
            case .targetConflict: return "Ziel hat bereits ein Transcript mit dieser ID"
            case .targetNotLoggedIn: return "Zielkonto ist nicht eingeloggt"
            }
        }
    }

    struct Skip: Equatable {
        var candidate: Candidate
        var reason: SkipReason
    }

    struct Plan: Equatable {
        var targetProfile: String?
        var movable: [Candidate]
        var skipped: [Skip]

        var isEmpty: Bool { movable.isEmpty }
        var targetLabel: String { targetProfile ?? ClaudeAccountProfiles.mainProfileName }

        /// Uebersprungene, nach Grund gruppiert — Reihenfolge stabil fuer die
        /// Anzeige im Bestaetigungsdialog.
        func skippedByReason() -> [(reason: SkipReason, candidates: [Candidate])] {
            let order: [SkipReason] = [
                .targetNotLoggedIn, .notAChat, .backgroundAgent,
                .running, .alreadyInTarget, .targetConflict,
            ]
            return order.compactMap { reason in
                let matches = skipped.filter { $0.reason == reason }.map(\.candidate)
                return matches.isEmpty ? nil : (reason, matches)
            }
        }
    }

    /// - Parameter targetIsLoggedIn: `main` gilt immer als eingeloggt; fuer
    ///   Zusatzprofile prueft der Aufrufer `ClaudeAccountProfile.isLoggedIn`.
    ///   Ein Umzug in ein ausgeloggtes Konto ist technisch erfolgreich und
    ///   praktisch eine Sackgasse — deshalb hier eine harte Sperre.
    static func plan(
        candidates: [Candidate],
        targetProfile: String?,
        targetIsLoggedIn: Bool
    ) -> Plan {
        let normalizedTarget = normalize(targetProfile)
        guard targetIsLoggedIn else {
            return Plan(
                targetProfile: normalizedTarget,
                movable: [],
                skipped: candidates.map { Skip(candidate: $0, reason: .targetNotLoggedIn) }
            )
        }

        var movable: [Candidate] = []
        var skipped: [Skip] = []
        for candidate in candidates {
            if let reason = skipReason(for: candidate, target: normalizedTarget) {
                skipped.append(Skip(candidate: candidate, reason: reason))
            } else {
                movable.append(candidate)
            }
        }
        return Plan(targetProfile: normalizedTarget, movable: movable, skipped: skipped)
    }

    /// Reihenfolge der Pruefungen ist bewusst: der strukturelle Ausschluss
    /// (falscher Provider/Art) kommt vor dem zeitlichen (laeuft gerade), damit
    /// die Begruendung im Dialog die stabilere ist.
    private static func skipReason(for candidate: Candidate, target: String?) -> SkipReason? {
        guard candidate.provider == .claude else { return .notAChat }
        switch candidate.kind {
        case .backgroundChat:
            return .backgroundAgent
        case .terminal, .agentView, .subagentJob:
            return .notAChat
        case .chat:
            break
        }
        if normalize(candidate.currentProfile) == target { return .alreadyInTarget }
        if candidate.isRunning { return .running }
        if candidate.hasTargetConflict { return .targetConflict }
        return nil
    }

    /// „main" und `nil` sind derselbe Account — beide Schreibweisen kommen im
    /// Bestand vor (Menue liefert den Namen, der Stempel `nil`).
    static func normalize(_ profile: String?) -> String? {
        guard let profile, !profile.isEmpty, profile != ClaudeAccountProfiles.mainProfileName else {
            return nil
        }
        return profile
    }
}
