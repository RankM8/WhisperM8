import XCTest
@testable import WhisperM8

// MARK: - Snapshot-Vertrag (wm8.overview/1)

final class ChatsAgentSnapshotTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func axes(
        catalog: ChatsCatalogState = .active,
        state: ChatsConversationAxis.State = .ready,
        reason: AwaitingInputKind? = nil,
        worker: ChatsExecutionAxis.Worker = .alive,
        quality: ChatsEvidenceAxis.Quality = .observed,
        sinceSec: Int? = nil
    ) -> ChatsSessionAxes {
        ChatsSessionAxes(
            catalog: catalog,
            execution: ChatsExecutionAxis(mode: .foreground, worker: worker, attachment: .attached),
            conversation: ChatsConversationAxis(state: state, reason: reason, sinceSec: sinceSec),
            evidence: ChatsEvidenceAxis(quality: quality, source: "app", ageMs: 0))
    }

    private func session(
        _ ref: String, bucket: ChatsSnapshotBucket, axes: ChatsSessionAxes,
        queued: Int = 0, excerpt: String? = nil, name: String = "projekt/titel"
    ) -> ChatsSnapshotSession {
        ChatsSnapshotSession(ref: ref, name: name, bucket: bucket, axes: axes,
                             queued: queued, actions: ChatsAgentSnapshotBuilder.actions(for: axes),
                             excerpt: excerpt, doneSec: nil)
    }

    // MARK: Buckets

    func testBucketsFollowConversationState() {
        XCTAssertEqual(ChatsAgentSnapshotBuilder.bucket(
            axes: axes(state: .needsInput), lastTurnAt: nil, now: now), .needsYou)
        XCTAssertEqual(ChatsAgentSnapshotBuilder.bucket(
            axes: axes(state: .errored), lastTurnAt: nil, now: now), .needsYou)
        XCTAssertEqual(ChatsAgentSnapshotBuilder.bucket(
            axes: axes(state: .working), lastTurnAt: nil, now: now), .working)
    }

    func testLaunchingCountsAsWorkingNotIdle() {
        // Ein startender Chat ist beschäftigt — er darf nicht als frei
        // erscheinen, sonst sendet ein Agent hinein (Start-Race).
        XCTAssertEqual(ChatsAgentSnapshotBuilder.bucket(
            axes: axes(state: .launching), lastTurnAt: nil, now: now), .working)
    }

    func testRecentlyDoneUsesLastTurnWindow() {
        let fresh = now.addingTimeInterval(-300)
        XCTAssertEqual(ChatsAgentSnapshotBuilder.bucket(
            axes: axes(state: .turnDone), lastTurnAt: fresh, now: now), .recentlyDone)

        let old = now.addingTimeInterval(-ChatsAgentSnapshotBuilder.recentlyDoneWindow - 60)
        XCTAssertEqual(ChatsAgentSnapshotBuilder.bucket(
            axes: axes(state: .turnDone), lastTurnAt: old, now: now), .idle,
            "nach dem Fenster fällt es aus recentlyDone heraus")
    }

    func testSessionWithoutTurnIsIdle() {
        XCTAssertEqual(ChatsAgentSnapshotBuilder.bucket(
            axes: axes(state: .ready), lastTurnAt: nil, now: now), .idle)
    }

    // MARK: Aktionen

    func testLaunchingNeverOffersSend() {
        // Kern der Race-Prävention im Vertrag: `send` darf hier nicht als
        // mögliche Aktion erscheinen.
        let actions = ChatsAgentSnapshotBuilder.actions(for: axes(state: .launching))
        XCTAssertFalse(actions.contains("send"))
        XCTAssertTrue(actions.contains("enqueue"), "der sichere Weg muss angeboten werden")
    }

    func testWorkingOffersEnqueueNotSend() {
        let actions = ChatsAgentSnapshotBuilder.actions(for: axes(state: .working))
        XCTAssertFalse(actions.contains("send"))
        XCTAssertTrue(actions.contains("enqueue"))
        XCTAssertTrue(actions.contains("interrupt"))
    }

    func testNeedsInputOffersSend() {
        XCTAssertTrue(ChatsAgentSnapshotBuilder.actions(for: axes(state: .needsInput)).contains("send"))
    }

    func testStoppedOffersResume() {
        XCTAssertEqual(ChatsAgentSnapshotBuilder.actions(for: axes(state: .stopped)), ["resume", "enqueue"])
    }

    func testArchivedOnlyOffersUnarchive() {
        XCTAssertEqual(
            ChatsAgentSnapshotBuilder.actions(for: axes(catalog: .archived, state: .ready)),
            ["unarchive"])
    }

    // MARK: Auszüge und Budget

    func testExcerptIsFlattenedAndCapped() {
        let long = "Zeile eins\nZeile zwei " + String(repeating: "x", count: 300)
        let excerpt = try? XCTUnwrap(ChatsAgentSnapshotBuilder.excerpt(long))
        XCTAssertFalse(excerpt?.contains("\n") ?? true)
        XCTAssertEqual(excerpt?.count, ChatsAgentSnapshotBuilder.excerptLimit)
    }

    func testEmptyExcerptBecomesNil() {
        XCTAssertNil(ChatsAgentSnapshotBuilder.excerpt("   \n "))
        XCTAssertNil(ChatsAgentSnapshotBuilder.excerpt(nil))
    }

    func testBudgetDropsExcerptsBeforeSessions() {
        let many = (0..<12).map {
            session("r\($0)", bucket: .working, axes: axes(state: .working),
                    excerpt: String(repeating: "x", count: 110))
        }
        let (fitted, omitted) = ChatsAgentSnapshotBuilder.fitToBudget(many, budget: 2_500)
        XCTAssertEqual(omitted, 0, "erst Auszüge streichen, keine Session verlieren")
        XCTAssertTrue(fitted.allSatisfy { $0.excerpt == nil })
    }

    func testNeedsYouKeepsItsExcerptLongest() {
        var list = [session("a", bucket: .needsYou, axes: axes(state: .needsInput),
                            excerpt: String(repeating: "n", count: 110))]
        list += (0..<10).map {
            session("w\($0)", bucket: .working, axes: axes(state: .working),
                    excerpt: String(repeating: "x", count: 110))
        }
        let (fitted, _) = ChatsAgentSnapshotBuilder.fitToBudget(list, budget: 2_500)
        XCTAssertNotNil(fitted.first { $0.ref == "a" }?.excerpt,
                        "der handlungsbedürftige Auszug überlebt am längsten")
    }

    func testOverflowIsReportedNotSilentlyDropped() {
        let many = (0..<80).map {
            session("r\($0)", bucket: .working, axes: axes(state: .working))
        }
        let (fitted, omitted) = ChatsAgentSnapshotBuilder.fitToBudget(many, budget: 800)
        XCTAssertGreaterThan(omitted, 0)
        XCTAssertEqual(fitted.count + omitted, many.count, "nichts verschwindet unbemerkt")
    }

    // MARK: Sortierung

    func testPriorityOrderIsNeedsYouThenWorkingThenDone() {
        let list = [
            session("c", bucket: .idle, axes: axes()),
            session("b", bucket: .working, axes: axes(state: .working)),
            session("a", bucket: .needsYou, axes: axes(state: .needsInput)),
            session("d", bucket: .recentlyDone, axes: axes(state: .turnDone)),
        ]
        XCTAssertEqual(ChatsAgentSnapshotBuilder.sorted(list).map(\.ref), ["a", "b", "d", "c"])
    }

    func testOldestWaitFirstWithinABucket() {
        let list = [
            session("neu", bucket: .needsYou, axes: axes(state: .needsInput, sinceSec: 10)),
            session("alt", bucket: .needsYou, axes: axes(state: .needsInput, sinceSec: 900)),
        ]
        XCTAssertEqual(ChatsAgentSnapshotBuilder.sorted(list).map(\.ref), ["alt", "neu"],
                       "wer am längsten wartet, steht oben")
    }

    // MARK: JSON-Vertrag

    func testCountsCoverFullScopeEvenWhenListIsTruncated() {
        let payload = ChatsAgentSnapshotBuilder.json(
            sessions: [session("a", bucket: .working, axes: axes(state: .working))],
            counts: [.working: 4, .idle: 900],
            queuedTotal: 2, anomalies: [], totalInScope: 904, omitted: 3,
            truth: ChatsEvidenceAxis(quality: .observed, source: "app", ageMs: 0),
            generatedAt: now, cursor: "j1:42")

        XCTAssertEqual(payload["schema"] as? String, "wm8.overview/1")
        let counts = payload["counts"] as? [String: Any]
        XCTAssertEqual(counts?["working"] as? Int, 4, "Zähler über den vollen Bestand")
        XCTAssertEqual(counts?["idle"] as? Int, 900)
        XCTAssertEqual(counts?["queuedTotal"] as? Int, 2)

        let coverage = payload["coverage"] as? [String: Any]
        XCTAssertEqual(coverage?["totalInScope"] as? Int, 904)
        XCTAssertEqual(coverage?["returned"] as? Int, 1)
        XCTAssertEqual(coverage?["omitted"] as? Int, 3)
        XCTAssertEqual(coverage?["truncated"] as? Bool, true)
        XCTAssertEqual(coverage?["countsComplete"] as? Bool, true)
        XCTAssertEqual(payload["cursor"] as? String, "j1:42")
    }

    func testAnomaliesOmittedWhenEmpty() {
        let payload = ChatsAgentSnapshotBuilder.json(
            sessions: [], counts: [:], queuedTotal: 0, anomalies: [], totalInScope: 0, omitted: 0,
            truth: ChatsEvidenceAxis(quality: .observed, source: "app", ageMs: 0),
            generatedAt: now, cursor: nil)
        XCTAssertNil(payload["anomalies"], "leere Felder blähen die Ausgabe nur auf")
        XCTAssertNil(payload["cursor"])
    }

    func testSessionJSONOmitsZeroQueue() {
        let plain = session("a", bucket: .working, axes: axes(state: .working)).json
        XCTAssertNil(plain["queued"])
        let queued = session("b", bucket: .working, axes: axes(state: .working), queued: 3).json
        XCTAssertEqual(queued["queued"] as? Int, 3)
    }
}

// MARK: - Anomalien

final class ChatsAnomalyDetectorTests: XCTestCase {
    private func session(
        state: ChatsConversationAxis.State,
        worker: ChatsExecutionAxis.Worker,
        catalog: ChatsCatalogState = .active,
        quality: ChatsEvidenceAxis.Quality = .observed,
        queued: Int = 0
    ) -> ChatsSnapshotSession {
        let axes = ChatsSessionAxes(
            catalog: catalog,
            execution: ChatsExecutionAxis(mode: .foreground, worker: worker, attachment: .detached),
            conversation: ChatsConversationAxis(state: state, reason: nil, sinceSec: nil),
            evidence: ChatsEvidenceAxis(quality: quality, source: "app", ageMs: 0))
        return ChatsSnapshotSession(ref: "r1", name: "p/t", bucket: .working, axes: axes,
                                    queued: queued, actions: [], excerpt: nil, doneSec: nil)
    }

    func testWorkingWithoutWorkerIsCriticalWhenObserved() {
        let found = ChatsAnomalyDetector.detect(
            sessions: [session(state: .working, worker: .missing)], appReachable: true)
        let anomaly = found.first { $0.code == "workingWithoutWorker" }
        XCTAssertEqual(anomaly?.severity, .critical)
        XCTAssertEqual(anomaly?.recommendedAction, "resume")
        XCTAssertTrue(anomaly?.evidence.contains("worker=missing") ?? false)
    }

    func testWorkingWithoutWorkerIsOnlyAWarningWhenInferred() {
        // Reine Schätzung auf einer geschlossenen Session ist ein
        // Anzeigefehler, kein Notfall — sonst wäre der kritische Kanal voll
        // mit Rauschen.
        let found = ChatsAnomalyDetector.detect(
            sessions: [session(state: .working, worker: .missing, catalog: .inactive, quality: .inferred)],
            appReachable: true)
        XCTAssertEqual(found.first { $0.code == "workingWithoutWorker" }?.severity, .warning)
    }

    func testQueuedWithoutWorkerIsFlagged() {
        let found = ChatsAnomalyDetector.detect(
            sessions: [session(state: .ready, worker: .exited, queued: 2)], appReachable: true)
        let anomaly = found.first { $0.code == "queuedWithoutWorker" }
        XCTAssertEqual(anomaly?.severity, .warning)
        XCTAssertEqual(anomaly?.recommendedAction, "resume")
    }

    func testHealthySessionProducesNoAnomaly() {
        XCTAssertTrue(ChatsAnomalyDetector.detect(
            sessions: [session(state: .working, worker: .alive)], appReachable: true).isEmpty)
    }

    func testUnreachableAppIsItsOwnAnomaly() {
        let found = ChatsAnomalyDetector.detect(sessions: [], appReachable: false)
        XCTAssertEqual(found.map(\.code), ["appUnreachable"])
        XCTAssertEqual(found.first?.severity, .warning)
    }

    func testAnomalyJSONCarriesEvidence() {
        let json = ChatsAnomaly(code: "x", severity: .critical, ref: "r1",
                                evidence: ["a=1"], recommendedAction: "resume").json
        XCTAssertEqual(json["code"] as? String, "x")
        XCTAssertEqual(json["severity"] as? String, "critical")
        XCTAssertEqual(json["evidence"] as? [String], ["a=1"])
        XCTAssertEqual(json["recommendedAction"] as? String, "resume")
    }
}
