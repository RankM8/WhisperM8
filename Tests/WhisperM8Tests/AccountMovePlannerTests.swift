import Foundation
import XCTest
@testable import WhisperM8

/// Slice 6: Der Planer entscheidet, was bei einem Konto-Umzug bewegt wird und
/// was nicht — mit einem Grund je uebersprungenem Chat. Genau dieser Vertrag
/// steht im Bestaetigungsdialog; ein Bulk, der still die Haelfte auslaesst,
/// waere schlimmer als gar keiner.
final class AccountMovePlannerTests: XCTestCase {
    private func candidate(
        title: String = "Chat",
        currentProfile: String? = nil,
        provider: AgentProvider = .claude,
        kind: AgentSessionKind = .chat,
        isRunning: Bool = false,
        hasTargetConflict: Bool = false
    ) -> AccountMovePlanner.Candidate {
        AccountMovePlanner.Candidate(
            sessionID: UUID(),
            title: title,
            currentProfile: currentProfile,
            provider: provider,
            kind: kind,
            isRunning: isRunning,
            hasTargetConflict: hasTargetConflict
        )
    }

    func testPlainChatIsMovable() {
        let plan = AccountMovePlanner.plan(
            candidates: [candidate(title: "Normal")],
            targetProfile: "ai3",
            targetIsLoggedIn: true
        )
        XCTAssertEqual(plan.movable.map(\.title), ["Normal"])
        XCTAssertTrue(plan.skipped.isEmpty)
    }

    func testRunningSessionIsSkippedNotStopped() {
        let plan = AccountMovePlanner.plan(
            candidates: [candidate(title: "Laeuft", isRunning: true)],
            targetProfile: "ai3",
            targetIsLoggedIn: true
        )
        XCTAssertTrue(plan.movable.isEmpty)
        XCTAssertEqual(plan.skipped.first?.reason, .running)
    }

    func testBackgroundAgentIsSkipped() {
        let plan = AccountMovePlanner.plan(
            candidates: [candidate(title: "BG", kind: .backgroundChat)],
            targetProfile: "ai3",
            targetIsLoggedIn: true
        )
        XCTAssertEqual(plan.skipped.first?.reason, .backgroundAgent)
    }

    func testTerminalAndAgentViewAreSkipped() {
        let plan = AccountMovePlanner.plan(
            candidates: [
                candidate(title: "Terminal", kind: .terminal),
                candidate(title: "AgentView", kind: .agentView),
            ],
            targetProfile: "ai3",
            targetIsLoggedIn: true
        )
        XCTAssertTrue(plan.movable.isEmpty)
        XCTAssertEqual(Set(plan.skipped.map(\.reason)), [.notAChat])
    }

    func testCodexSessionIsSkipped() {
        let plan = AccountMovePlanner.plan(
            candidates: [candidate(title: "Codex", provider: .codex)],
            targetProfile: "ai3",
            targetIsLoggedIn: true
        )
        XCTAssertEqual(plan.skipped.first?.reason, .notAChat)
    }

    func testSessionAlreadyInTargetIsSkipped() {
        let plan = AccountMovePlanner.plan(
            candidates: [candidate(title: "Schon da", currentProfile: "ai3")],
            targetProfile: "ai3",
            targetIsLoggedIn: true
        )
        XCTAssertEqual(plan.skipped.first?.reason, .alreadyInTarget)
    }

    func testMainAndNilAreTheSameAccount() {
        // Der Stempel ist `nil`, das Menue liefert "main" — beide Schreibweisen
        // muessen als dasselbe Konto gelten, sonst bietet die UI einen
        // sinnlosen Umzug an.
        let plan = AccountMovePlanner.plan(
            candidates: [candidate(title: "Main", currentProfile: nil)],
            targetProfile: "main",
            targetIsLoggedIn: true
        )
        XCTAssertNil(plan.targetProfile)
        XCTAssertEqual(plan.skipped.first?.reason, .alreadyInTarget)
    }

    func testTargetConflictIsSkipped() {
        let plan = AccountMovePlanner.plan(
            candidates: [candidate(title: "Kollision", hasTargetConflict: true)],
            targetProfile: "ai3",
            targetIsLoggedIn: true
        )
        XCTAssertEqual(plan.skipped.first?.reason, .targetConflict)
    }

    func testLoggedOutTargetBlocksEverything() {
        let plan = AccountMovePlanner.plan(
            candidates: [candidate(title: "A"), candidate(title: "B")],
            targetProfile: "ausgeloggt",
            targetIsLoggedIn: false
        )
        XCTAssertTrue(plan.movable.isEmpty)
        XCTAssertEqual(Set(plan.skipped.map(\.reason)), [.targetNotLoggedIn])
    }

    func testMixedSelectionSplitsExactly() {
        let plan = AccountMovePlanner.plan(
            candidates: [
                candidate(title: "OK 1"),
                candidate(title: "OK 2"),
                candidate(title: "Laeuft", isRunning: true),
                candidate(title: "BG", kind: .backgroundChat),
                candidate(title: "Schon da", currentProfile: "ai3"),
            ],
            targetProfile: "ai3",
            targetIsLoggedIn: true
        )
        XCTAssertEqual(plan.movable.map(\.title), ["OK 1", "OK 2"])
        XCTAssertEqual(plan.skipped.count, 3)
        let groups = plan.skippedByReason()
        XCTAssertEqual(groups.map(\.reason), [.backgroundAgent, .running, .alreadyInTarget])
    }

    func testStructuralExclusionWinsOverRunning() {
        // Ein laufender Background-Agent bleibt „Hintergrund-Agent": die
        // strukturelle Begruendung ist die stabilere, „laeuft gerade" waere
        // in fuenf Minuten hinfaellig und wuerde falsche Hoffnung machen.
        let plan = AccountMovePlanner.plan(
            candidates: [candidate(title: "BG laeuft", kind: .backgroundChat, isRunning: true)],
            targetProfile: "ai3",
            targetIsLoggedIn: true
        )
        XCTAssertEqual(plan.skipped.first?.reason, .backgroundAgent)
    }

    func testEmptySelectionYieldsEmptyPlan() {
        let plan = AccountMovePlanner.plan(candidates: [], targetProfile: "ai3", targetIsLoggedIn: true)
        XCTAssertTrue(plan.isEmpty)
        XCTAssertTrue(plan.skipped.isEmpty)
    }
}

/// Das Journal traegt die Rueckgaengig-Faehigkeit: Bulk-Umzuege sind nicht
/// atomar, Teilerfolge bleiben stehen, und das Zurueckrollen ist derselbe
/// Move mit vertauschten Argumenten.
final class AccountMoveJournalTests: XCTestCase {
    private func makeJournal() -> AccountMoveJournal {
        AccountMoveJournal(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("WhisperM8AccountMoves-\(UUID().uuidString).jsonl")
        )
    }

    private func entry(
        batchID: UUID,
        title: String,
        from: String?,
        to: String?,
        movedTranscript: Bool = true
    ) -> AccountMoveJournal.Entry {
        AccountMoveJournal.Entry(
            batchID: batchID,
            sessionID: UUID(),
            sessionTitle: title,
            fromProfile: from,
            toProfile: to,
            movedTranscript: movedTranscript,
            timestamp: Date()
        )
    }

    func testAppendAndReadRoundtrip() {
        let journal = makeJournal()
        defer { try? FileManager.default.removeItem(at: journal.fileURL) }
        let batch = UUID()
        let entries = [
            entry(batchID: batch, title: "A", from: nil, to: "ai3"),
            entry(batchID: batch, title: "B", from: "PowerUser", to: "ai3"),
        ]
        journal.append(entries)

        let read = journal.allEntries()
        XCTAssertEqual(read.map(\.sessionID), entries.map(\.sessionID))
        XCTAssertEqual(read.map(\.batchID), entries.map(\.batchID))
        XCTAssertEqual(read.map(\.sessionTitle), entries.map(\.sessionTitle))
        XCTAssertEqual(read.map(\.fromProfile), entries.map(\.fromProfile))
        XCTAssertEqual(read.map(\.toProfile), entries.map(\.toProfile))
        XCTAssertEqual(read.map(\.movedTranscript), entries.map(\.movedTranscript))
        // Zeitstempel bewusst nur sekundengenau: das Journal wird als ISO8601
        // geschrieben, damit ein Mensch es im Fehlerfall lesen kann —
        // Sub-Sekunden gehen dabei verloren und werden nirgends gebraucht.
        for (read, original) in zip(read, entries) {
            XCTAssertEqual(read.timestamp.timeIntervalSince1970,
                           original.timestamp.timeIntervalSince1970,
                           accuracy: 1.0)
        }
    }

    func testLastBatchReturnsOnlyNewestGroup() {
        let journal = makeJournal()
        defer { try? FileManager.default.removeItem(at: journal.fileURL) }
        let older = UUID(), newer = UUID()
        journal.append([entry(batchID: older, title: "alt", from: nil, to: "ai3")])
        journal.append([
            entry(batchID: newer, title: "neu 1", from: "ai3", to: "PowerUser"),
            entry(batchID: newer, title: "neu 2", from: "ai3", to: "PowerUser"),
        ])

        XCTAssertEqual(journal.lastBatch().map(\.sessionTitle), ["neu 1", "neu 2"])
    }

    func testInvertedSwapsDirectionAndOrder() {
        let batch = UUID()
        let entries = [
            entry(batchID: batch, title: "A", from: nil, to: "ai3"),
            entry(batchID: batch, title: "B", from: "PowerUser", to: "ai3"),
        ]
        let inverted = AccountMoveJournal.inverted(entries)

        XCTAssertEqual(inverted.map(\.sessionTitle), ["B", "A"])
        XCTAssertEqual(inverted.map(\.fromProfile), ["ai3", "ai3"])
        XCTAssertEqual(inverted.map(\.toProfile), ["PowerUser", nil])
    }

    func testMissingFileYieldsEmptyInsteadOfThrowing() {
        let journal = makeJournal()
        XCTAssertTrue(journal.allEntries().isEmpty)
        XCTAssertTrue(journal.lastBatch().isEmpty)
    }

    /// Die Menue-Abfrage laeuft ueber einen (mtime, size)-Stempel-Cache
    /// (CPU-Befund 2026-08-23) — sie muss den Datei-Lebenszyklus trotzdem
    /// korrekt abbilden: fehlend → false, nach Append → true (auch aus dem
    /// Cache), nach Loeschen → wieder false.
    func testHasUndoableBatchFollowsFileLifecycle() {
        let journal = makeJournal()
        defer { try? FileManager.default.removeItem(at: journal.fileURL) }

        XCTAssertFalse(journal.hasUndoableBatch())

        journal.append([entry(batchID: UUID(), title: "A", from: nil, to: "ai3")])
        XCTAssertTrue(journal.hasUndoableBatch())
        // Zweiter Aufruf bedient sich aus dem Stempel-Cache.
        XCTAssertTrue(journal.hasUndoableBatch())

        try? FileManager.default.removeItem(at: journal.fileURL)
        XCTAssertFalse(journal.hasUndoableBatch())
    }

    func testCorruptLineIsSkipped() throws {
        let journal = makeJournal()
        defer { try? FileManager.default.removeItem(at: journal.fileURL) }
        journal.append([entry(batchID: UUID(), title: "gut", from: nil, to: "ai3")])
        let handle = try FileHandle(forWritingTo: journal.fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{kaputt\n".utf8))
        try handle.close()

        XCTAssertEqual(journal.allEntries().map(\.sessionTitle), ["gut"])
    }
}

/// Die Scan-Pause ist Sicherheitsbestandteil, kein Komfort: waehrend eines
/// Umzugs liegt eine Datei kurzzeitig schon im Ziel, waehrend der
/// Session-Stempel noch auf die Quelle zeigt.
@MainActor
final class AgentScanCoordinatorSuspendTests: XCTestCase {
    func testSuspendAndResumeAreBalanced() {
        let coordinator = AgentScanCoordinator.shared
        XCTAssertFalse(coordinator.isSuspended)

        coordinator.suspendScans()
        XCTAssertTrue(coordinator.isSuspended)
        // Verschachtelte Pause (Umzug, danach dessen Rueckgaengig) darf die
        // aeussere nicht vorzeitig freigeben.
        coordinator.suspendScans()
        coordinator.resumeScans(triggerScan: false)
        XCTAssertTrue(coordinator.isSuspended, "innere Freigabe darf die aeussere Pause nicht beenden")

        coordinator.resumeScans(triggerScan: false)
        XCTAssertFalse(coordinator.isSuspended)
    }

    func testResumeWithoutSuspendIsHarmless() {
        let coordinator = AgentScanCoordinator.shared
        coordinator.resumeScans(triggerScan: false)
        XCTAssertFalse(coordinator.isSuspended)
    }
}
