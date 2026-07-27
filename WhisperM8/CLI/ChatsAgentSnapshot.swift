import Foundation

// MARK: - Agentenorientierter Overview-Snapshot (wm8.overview/1)

/// Kategorie einer Session im Lagebild. Die Reihenfolge ist die Priorität, in
/// der ein Agent handeln soll.
enum ChatsSnapshotBucket: String, CaseIterable, Equatable {
    case needsYou
    case working
    case recentlyDone
    case idle
}

/// Eine Session im Snapshot — nur Felder, die eine Handlungsentscheidung
/// verändern. Alles Weitere holt der Agent gezielt über `show`.
struct ChatsSnapshotSession: Equatable {
    var ref: String
    var name: String
    var bucket: ChatsSnapshotBucket
    var axes: ChatsSessionAxes
    var queued: Int
    var actions: [String]
    /// Nur bei `needsYou`/`recentlyDone`, hart begrenzt.
    var excerpt: String?
    /// Sekunden seit dem letzten abgeschlossenen Turn (nur `recentlyDone`).
    var doneSec: Int?

    var json: [String: Any] {
        var dict: [String: Any] = [
            "ref": ref,
            "name": name,
            "catalog": axes.catalog.rawValue,
            "execution": axes.execution.json,
            "conversation": axes.conversation.json,
            "evidence": axes.evidence.json,
            "actions": actions,
        ]
        if queued > 0 { dict["queued"] = queued }
        if let excerpt { dict["excerpt"] = excerpt }
        if let doneSec { dict["doneSec"] = doneSec }
        return dict
    }
}

/// Reine Aufbaulogik des Snapshots: Einordnen, Priorisieren, Kürzen.
///
/// Der Grund für diesen Typ: `overview --json` lieferte zuletzt 868.379
/// Zeichen für 920 Sessions, von denen fünf relevant waren. Für einen
/// Token-begrenzten Konsumenten ist das unbrauchbar. Der Snapshot kehrt das
/// um — Zähler über den vollen Bestand, Liste nur über das Handlungsrelevante.
enum ChatsAgentSnapshotBuilder {
    /// Schema-Kennung. Additive Felder ändern sie nicht; Entfernen oder
    /// Umdeuten eines Feldes erzwingt `/2`.
    static let schema = "wm8.overview/1"

    /// Fenster für „kürzlich abgeschlossen".
    static let recentlyDoneWindow: TimeInterval = 30 * 60

    /// Zeichenbudget der Sessionliste. Wird es überschritten, fallen zuerst
    /// Auszüge weg — niemals ganze Sessions ohne Vermerk.
    static let sessionBudgetChars = 2_500

    /// Maximale Länge eines Auszugs.
    static let excerptLimit = 120

    static func bucket(
        axes: ChatsSessionAxes,
        lastTurnAt: Date?,
        now: Date
    ) -> ChatsSnapshotBucket {
        switch axes.conversation.state {
        case .needsInput, .errored:
            return .needsYou
        case .working, .launching:
            return .working
        case .ready, .turnDone, .stopped, .unknown:
            if let lastTurnAt, now.timeIntervalSince(lastTurnAt) <= recentlyDoneWindow {
                return .recentlyDone
            }
            return .idle
        }
    }

    /// Welche Aktionen jetzt sinnvoll sind — ersetzt Provider-, Kind- und
    /// PTY-Details durch die tatsächlich möglichen nächsten Schritte.
    static func actions(for axes: ChatsSessionAxes) -> [String] {
        guard axes.catalog != .archived else { return ["unarchive"] }
        switch axes.conversation.state {
        case .launching:
            // Bewusst KEIN `send`: der Start-Race würde still zuschlagen.
            return ["enqueue", "open"]
        case .working:
            return ["enqueue", "interrupt", "open"]
        case .needsInput:
            return ["send", "interrupt", "open"]
        case .stopped:
            return ["resume", "enqueue"]
        case .ready, .turnDone, .errored, .unknown:
            return ["send", "enqueue", "open"]
        }
    }

    static func excerpt(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let flat = raw.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !flat.isEmpty else { return nil }
        return flat.count <= excerptLimit ? flat : String(flat.prefix(excerptLimit - 1)) + "…"
    }

    /// Sortiert nach Handlungspriorität, dann nach Dringlichkeit (älteste
    /// Rückfrage zuerst — sie wartet am längsten).
    static func sorted(_ sessions: [ChatsSnapshotSession]) -> [ChatsSnapshotSession] {
        sessions.sorted { lhs, rhs in
            let lhsRank = ChatsSnapshotBucket.allCases.firstIndex(of: lhs.bucket) ?? 99
            let rhsRank = ChatsSnapshotBucket.allCases.firstIndex(of: rhs.bucket) ?? 99
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            let lhsAge = lhs.axes.conversation.sinceSec ?? 0
            let rhsAge = rhs.axes.conversation.sinceSec ?? 0
            if lhsAge != rhsAge { return lhsAge > rhsAge }
            return lhs.ref < rhs.ref
        }
    }

    /// Kürzt auf das Budget. Erst fallen Auszüge weg, dann Sessions vom Ende —
    /// und das Weglassen wird im Ergebnis vermerkt, nie verschwiegen.
    static func fitToBudget(
        _ sessions: [ChatsSnapshotSession],
        budget: Int = sessionBudgetChars
    ) -> (sessions: [ChatsSnapshotSession], omitted: Int) {
        func size(_ list: [ChatsSnapshotSession]) -> Int {
            list.reduce(0) { $0 + approximateSize($1) }
        }
        var working = sessions
        guard size(working) > budget else { return (working, 0) }

        // Stufe 1: Auszüge bei allem streichen, was nicht handlungsbedürftig ist.
        for index in working.indices where working[index].bucket != .needsYou {
            working[index].excerpt = nil
        }
        guard size(working) > budget else { return (working, 0) }

        // Stufe 2: von hinten kürzen (niedrigste Priorität zuerst).
        var omitted = 0
        while size(working) > budget, working.count > 1 {
            working.removeLast()
            omitted += 1
        }
        return (working, omitted)
    }

    /// Grobe Größenabschätzung einer Session im JSON — reicht fürs Budget und
    /// vermeidet ein Probe-Serialisieren pro Kürzungsschritt.
    static func approximateSize(_ session: ChatsSnapshotSession) -> Int {
        var size = 150 // Feldnamen, Achsen, Klammern
        size += session.ref.count + session.name.count
        size += session.actions.reduce(0) { $0 + $1.count + 4 }
        size += session.excerpt?.count ?? 0
        return size
    }

    /// Baut das vollständige JSON-Dokument.
    static func json(
        sessions: [ChatsSnapshotSession],
        counts: [ChatsSnapshotBucket: Int],
        queuedTotal: Int,
        anomalies: [[String: Any]],
        totalInScope: Int,
        omitted: Int,
        truth: ChatsEvidenceAxis,
        generatedAt: Date,
        cursor: String?
    ) -> [String: Any] {
        var countsDict: [String: Any] = [:]
        for bucket in ChatsSnapshotBucket.allCases {
            countsDict[bucket.rawValue] = counts[bucket] ?? 0
        }
        countsDict["queuedTotal"] = queuedTotal

        var dict: [String: Any] = [
            "schema": schema,
            "asOf": ChatsOutput.iso(generatedAt),
            "truth": truth.json,
            // `counts` deckt IMMER den vollen Scope ab, auch wenn die Liste
            // gekürzt ist — sonst läse ein Agent aus einer gekürzten Ansicht
            // ein falsches Lagebild.
            "counts": countsDict,
            "coverage": [
                "totalInScope": totalInScope,
                "returned": sessions.count,
                "omitted": omitted,
                "truncated": omitted > 0,
                "countsComplete": true,
            ],
            "sessions": sessions.map(\.json),
        ]
        if let cursor { dict["cursor"] = cursor }
        if !anomalies.isEmpty { dict["anomalies"] = anomalies }
        return dict
    }
}
