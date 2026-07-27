import Foundation

// MARK: - `chats snapshot` — agentenorientiertes Lagebild

/// Der Befehl für Agenten: ein kompakter, versionierter Snapshot über ALLE
/// Sessions statt einer Volliste.
///
/// Bewusst ein eigener Befehl statt einer Option an `overview`: `overview` und
/// `list` haben einen etablierten Vertrag, auf den Skripte und der Skill
/// bauen. Ein neuer Name erlaubt das saubere Schema `wm8.overview/1`, ohne
/// bestehende Aufrufer zu brechen — Kompatibilitätsregel „Breaking ist
/// versioniert" (§7).
enum ChatsSnapshotCommand {
    struct Options: Equatable {
        var includeIdle = false
        var limit = 0          // 0 = Budget entscheidet
        var json = true        // Text ist hier nur Diagnose
    }

    static func parse(_ arguments: [String]) throws -> Options {
        var options = Options()
        var index = 0
        while index < arguments.count {
            let arg = arguments[index]
            switch arg {
            case "--json":
                options.json = true
            case "--text":
                options.json = false
            case "--include":
                index += 1
                guard index < arguments.count else {
                    throw AgentCLIParser.ParseError.missingValue("--include")
                }
                guard arguments[index] == "idle" else {
                    throw AgentCLIParser.ParseError.invalidValue(
                        flag: "--include", value: arguments[index], allowed: "idle")
                }
                options.includeIdle = true
            case "--limit":
                index += 1
                guard index < arguments.count, let value = Int(arguments[index]), value >= 0 else {
                    throw AgentCLIParser.ParseError.invalidValue(
                        flag: "--limit", value: index < arguments.count ? arguments[index] : "",
                        allowed: "Ganzzahl >= 0 (0 = Budget entscheidet)")
                }
                options.limit = value
            default:
                throw AgentCLIParser.ParseError.unknownFlag(arg)
            }
            index += 1
        }
        return options
    }

    static func run(_ arguments: [String]) async -> Int32 {
        let options: Options
        do {
            options = try parse(arguments)
        } catch {
            CLIIO.err(error.localizedDescription)
            CLIIO.err("Usage: whisperm8 chats snapshot [--include idle] [--limit N] [--json|--text]")
            return ChatsCLIExit.usage
        }

        let context = ChatsCommandContext.load()
        let live = ChatsLiveMerge.fetch()
        let liveRunningIDs = Set((live ?? [:]).filter { $0.value.isAttachedPTY }.map(\.key))

        // Kandidatenmenge: alles Nicht-Archivierte. Der Snapshot rechnet über
        // den vollen Bestand und liefert nur das Handlungsrelevante aus.
        let all = context.view.entries.filter { $0.session.status != .archived }
        let scoped = context.scopedEntries(
            scope: "all", liveRunningIDs: liveRunningIDs, liveAvailable: live != nil)
            .filter { $0.session.status != .archived }

        // Nur Sessions proben, die überhaupt einen Bucket ≠ idle erreichen
        // können: laufend, offener Tab, gepinnt oder kürzlich aktiv. Ein
        // Vollscan über 900 Sessions wäre genau der Fehler, den dieser Befehl
        // behebt.
        let cutoff = context.now.addingTimeInterval(-ChatsAgentSnapshotBuilder.recentlyDoneWindow)
        let candidates = scoped.filter { entry in
            liveRunningIDs.contains(entry.session.id)
                || context.isOpen(entry.session.id)
                || context.isPinned(entry.session.id)
                || entry.session.lastActivityAt > cutoff
                || (entry.session.lastTurnAt.map { $0 > cutoff } ?? false)
        }

        let runtimeByID = await ChatsStatusProbe.probeAll(entries: candidates, now: context.now)
        let queueCounts = AgentPromptQueueLogic.openCounts(
            in: AgentPromptQueueStore.read(from: AgentPromptQueueStore.defaultFileURL()))

        var sessions: [ChatsSnapshotSession] = []
        var counts: [ChatsSnapshotBucket: Int] = [:]

        for entry in candidates {
            let estimate = runtimeByID[entry.session.id] ?? ChatsRuntimeInfo(
                status: nil, source: "transcriptEstimate", since: nil, revision: nil,
                transcriptPath: nil, transcriptSizeBytes: nil, availability: .unsupported)
            let runtime = ChatsLiveMerge.merge(estimate: estimate, live: live?[entry.session.id])
            let liveStatus = live?[entry.session.id]

            let axes = ChatsSessionAxesBuilder.build(
                status: entry.session.status,
                kind: entry.session.effectiveKind,
                lifecycle: nil,   // Lifecycle liefert erst der Live-Merge (P2)
                runtimeStatus: runtime.status,
                awaitingReason: nil,
                isAttachedPTY: liveStatus?.isAttachedPTY,
                source: runtime.source,
                statusSince: runtime.since,
                observedAt: context.now,
                now: context.now)

            let bucket = ChatsAgentSnapshotBuilder.bucket(
                axes: axes, lastTurnAt: entry.session.lastTurnAt, now: context.now)
            counts[bucket, default: 0] += 1
            guard bucket != .idle || options.includeIdle else { continue }

            let wantsExcerpt = bucket == .needsYou || bucket == .recentlyDone
            sessions.append(ChatsSnapshotSession(
                ref: ChatsOutput.shortID(entry.session.id),
                name: "\(entry.projectName)/\(entry.session.title)",
                bucket: bucket,
                axes: axes,
                queued: queueCounts[entry.session.id] ?? 0,
                actions: ChatsAgentSnapshotBuilder.actions(for: axes),
                excerpt: wantsExcerpt
                    ? ChatsAgentSnapshotBuilder.excerpt(
                        ChatsOutput.tierOneLine(entry: entry, runtime: runtime))
                    : nil,
                doneSec: bucket == .recentlyDone
                    ? entry.session.lastTurnAt.map { Int(context.now.timeIntervalSince($0)) }
                    : nil))
        }

        // Nicht geprobte Sessions sind per Definition idle (ausserhalb des
        // Fensters, kein Tab, kein Prozess) — sie zählen mit, ohne Kosten.
        counts[.idle, default: 0] += max(0, all.count - candidates.count)

        var ordered = ChatsAgentSnapshotBuilder.sorted(sessions)
        if options.limit > 0, ordered.count > options.limit {
            ordered = Array(ordered.prefix(options.limit))
        }
        let (fitted, omitted) = ChatsAgentSnapshotBuilder.fitToBudget(ordered)
        let totalOmitted = omitted + max(0, sessions.count - ordered.count)

        let truth = ChatsEvidenceAxis(
            quality: live != nil ? .observed : .inferred,
            source: live != nil ? "app" : "transcript",
            ageMs: 0)

        let payload = ChatsAgentSnapshotBuilder.json(
            sessions: fitted,
            counts: counts,
            queuedTotal: queueCounts.values.reduce(0, +),
            anomalies: ChatsAnomalyDetector.detect(
                sessions: fitted, appReachable: live != nil).map(\.json),
            totalInScope: all.count,
            omitted: totalOmitted,
            truth: truth,
            generatedAt: context.now,
            cursor: ChatsStatusJournal.currentCursor())

        if options.json {
            CLIIO.out(ChatsOutput.encodeJSON(payload))
        } else {
            printDiagnostic(fitted, counts: counts, totalInScope: all.count, omitted: totalOmitted)
        }
        return ChatsCLIExit.ok
    }

    /// Diagnosehilfe für Menschen — ausdrücklich ohne Stabilitätszusage.
    private static func printDiagnostic(
        _ sessions: [ChatsSnapshotSession],
        counts: [ChatsSnapshotBucket: Int],
        totalInScope: Int,
        omitted: Int
    ) {
        let summary = ChatsSnapshotBucket.allCases
            .map { "\($0.rawValue)=\(counts[$0] ?? 0)" }
            .joined(separator: " ")
        CLIIO.out("\(summary)  (von \(totalInScope)\(omitted > 0 ? ", \(omitted) ausgelassen" : ""))")
        for session in sessions {
            var line = "\(session.ref) \(session.name) — \(session.axes.conversation.state.rawValue)"
            if let reason = session.axes.conversation.reason { line += "(\(reason.rawValue))" }
            if session.queued > 0 { line += " ⏳\(session.queued)" }
            CLIIO.out(line)
            if let excerpt = session.excerpt { CLIIO.out("   „\(excerpt)\"") }
        }
    }
}
