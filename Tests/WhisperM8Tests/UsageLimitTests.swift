import Foundation
import XCTest
@testable import WhisperM8

/// WM8-69 (Chat am Nutzungslimit) und WM8-70 (chats send: vormerken, Start
/// bestätigen). Die Limit-Zeilen sind im Aufbau echten Verläufen vom
/// 13./14.11.2026 nachgebaut (Inhalte gekürzt).
final class UsageLimitTests: XCTestCase {
    private let resets = Date(timeIntervalSince1970: 1_794_626_400)

    private let fiveHourLine = #"{"type":"assistant","timestamp":"2026-11-14T01:20:14.751Z","isApiErrorMessage":true,"error":"rate_limit","apiError":"usage_limit_reached","apiErrorStatus":429,"quotaLimits":{"status":"rejected","resetsAt":1794626400,"rateLimitType":"five_hour"},"message":{"model":"<synthetic>","role":"assistant","stop_reason":"stop_sequence","content":[{"type":"text","text":"You've hit your 5-hour limit · resets 4:20am (Europe/Zurich)"}]}}"#
    private let creditsLine = #"{"type":"assistant","timestamp":"2026-11-10T10:00:00.000Z","isApiErrorMessage":true,"error":"rate_limit","apiError":"model_requires_usage_credits","quotaLimits":null,"apiErrorParams":{"rate_limit_info":{"status":"rejected","resetsAt":1794434400,"rateLimitType":"seven_day_overage_included"}},"message":{"model":"<synthetic>","stop_reason":"stop_sequence","content":[{"type":"text","text":"You've reached your Fable limit."}]}}"#
    private let serverErrorLine = #"{"type":"assistant","isApiErrorMessage":true,"error":"server_error","message":{"model":"<synthetic>","stop_reason":"stop_sequence","content":[{"type":"text","text":"API Error: 503"}]}}"#
    private let loginLine = #"{"type":"assistant","isApiErrorMessage":true,"error":"authentication_failed","message":{"model":"<synthetic>","stop_reason":"stop_sequence","content":[{"type":"text","text":"Login expired"}]}}"#
    private let systemAfter = #"{"type":"system","subtype":"informational","content":"Usage limit reached · continuing automatically at 4:20am"}"#
    private let userLine = #"{"type":"user","timestamp":"2026-11-14T03:30:00.000Z","message":{"content":"weiter"}}"#

    // MARK: - Erkennung im Verlauf

    func testFiveHourLimitLineIsRecognizedWithItsReset() {
        guard case .usageLimit(_, let resetsAt, let kind) = AgentTranscriptParser.parseLine(fiveHourLine, provider: .claude) else {
            return XCTFail("Limit-Zeile nicht erkannt")
        }
        XCTAssertEqual(resetsAt, resets)
        XCTAssertEqual(kind, "five_hour")
    }

    func testCreditsLimitTakesTheResetFromApiErrorParams() {
        guard case .usageLimit(_, let resetsAt, let kind) = AgentTranscriptParser.parseLine(creditsLine, provider: .claude) else {
            return XCTFail("Guthaben-Limit nicht erkannt")
        }
        XCTAssertEqual(resetsAt, Date(timeIntervalSince1970: 1_794_434_400))
        XCTAssertEqual(kind, "model_requires_usage_credits", "Guthaben-Limit bleibt als solches erkennbar")
    }

    func testServerAndLoginErrorsAreNoLimit() {
        for line in [serverErrorLine, loginLine] {
            guard case .assistantMessageStopped = AgentTranscriptParser.parseLine(line, provider: .claude) else {
                return XCTFail("kein Limit erwartet: \(line.prefix(60))")
            }
        }
    }

    func testLimitStaysTheLastEventPastSystemLinesAndEndsWithANewTurn() {
        let tail = [fiveHourLine, systemAfter].joined(separator: "\n")
        XCTAssertNotNil(AgentUsageLimit(event: AgentTranscriptParser.lastEvent(in: tail, provider: .claude)))
        let later = [fiveHourLine, systemAfter, userLine].joined(separator: "\n")
        XCTAssertNil(AgentUsageLimit(event: AgentTranscriptParser.lastEvent(in: later, provider: .claude)))
    }

    func testLimitIsIdleWithoutAFinishedTurn() {
        let decision = AgentTranscriptStatusDecider.decide(
            lastEvent: .usageLimit(timestamp: nil, resetsAt: resets, kind: "five_hour"),
            fileMTime: Date(), now: Date(), priorTurnFinishedAt: nil)
        XCTAssertEqual(decision?.status, .idle)
        XCTAssertEqual(decision?.turnFinished, false, "keine Fertig-Meldung am Limit")
    }

    func testActiveUntilTheReset() {
        let limit = AgentUsageLimit(resetsAt: resets, kind: "five_hour", since: nil)
        XCTAssertTrue(limit.isActive(at: resets.addingTimeInterval(-1)))
        XCTAssertFalse(limit.isActive(at: resets))
        XCTAssertTrue(AgentUsageLimit(resetsAt: nil, kind: "x", since: nil).isActive(at: .distantFuture))
    }

    // MARK: - Weitermachen zum Ende (Belege 11.–14.11.2026)

    private let armed = #"{"type":"system","subtype":"informational","content":"Usage limit reached · continuing automatically at 4:20am · esc to cancel"}"#
    private let cancelled = #"{"type":"system","subtype":"informational","content":"Automatic continue cancelled · /rate-limit-options to re-arm"}"#

    func testAutoContinueIsReadFromTheSystemLinesAfterTheLimit() {
        XCTAssertEqual(AgentUsageLimit.autoContinueState(inTail: [fiveHourLine, armed].joined(separator: "\n")), true)
        XCTAssertEqual(AgentUsageLimit.autoContinueState(inTail: [fiveHourLine, armed, cancelled].joined(separator: "\n")), false,
                       "eine neue Nachricht bricht das Weitermachen ab")
        XCTAssertNil(AgentUsageLimit.autoContinueState(inTail: fiveHourLine))
        // Eine ältere Aussage vor der letzten Limit-Zeile zählt nicht.
        XCTAssertNil(AgentUsageLimit.autoContinueState(inTail: [armed, fiveHourLine].joined(separator: "\n")))
    }

    func testAgainLineArmsAutoContinueAgain() {
        let again = #"{"type":"system","subtype":"informational","content":"Usage limit reached again · continuing automatically at 4:20am"}"#
        XCTAssertEqual(AgentUsageLimit.autoContinueState(inTail: [fiveHourLine, armed, cancelled, fiveHourLine, again].joined(separator: "\n")), true)
    }

    func testOnlyAnAnswerEndsTheLimitNotAUserLine() {
        let cached = AgentUsageLimit(resetsAt: resets, kind: "five_hour", since: nil)
        XCTAssertEqual(AgentUsageLimit.after(event: .userMessage(timestamp: nil), tail: "", cached: cached), cached,
                       "Teammate-Nachricht oder Task-Meldung beendet das Limit nicht")
        XCTAssertEqual(AgentUsageLimit.after(event: .toolResult(timestamp: nil), tail: "", cached: cached), cached)
        XCTAssertNil(AgentUsageLimit.after(event: .assistantMessageOngoing(timestamp: nil), tail: "", cached: cached))
        XCTAssertNil(AgentUsageLimit.after(event: .turnInterrupted(timestamp: nil), tail: "", cached: cached))
        XCTAssertEqual(AgentUsageLimit.after(event: nil, tail: "", cached: cached), cached)
    }

    func testAccountWideLimitBlocksARestingChatOfTheSameAccount() {
        // Vorfall 14.11.2026 (Dex): Der Chat ruhte, als sein Konto ans Limit
        // kam, und hatte keine eigene Limit-Zeile.
        let now = resets.addingTimeInterval(-60)
        var limited = AgentChatSession(provider: .claude, projectID: UUID(), title: "a")
        limited.claudeProfileName = "RankM8"
        limited.usageLimit = AgentUsageLimit(resetsAt: resets, kind: "five_hour", since: nil, account: "RankM8")
        var resting = AgentChatSession(provider: .claude, projectID: UUID(), title: "b")
        resting.claudeProfileName = "RankM8"
        var other = AgentChatSession(provider: .claude, projectID: UUID(), title: "c")
        other.claudeProfileName = "PowerUser2"
        let all = [limited, resting, other]
        XCTAssertEqual(resting.blockingUsageLimit(in: all, now: now)?.kind, "five_hour")
        XCTAssertNil(other.blockingUsageLimit(in: all, now: now), "anderes Konto")
        XCTAssertNil(resting.blockingUsageLimit(in: all, now: resets.addingTimeInterval(1)), "abgelaufen")
        XCTAssertNil(resting.usageLimitWarning(in: all, now: now))
    }

    func testCreditsLimitOfAnotherChatOnlyWarns() {
        let now = resets.addingTimeInterval(-60)
        var limited = AgentChatSession(provider: .claude, projectID: UUID(), title: "a")
        limited.usageLimit = AgentUsageLimit(resetsAt: resets, kind: "model_requires_usage_credits", since: nil,
                                             account: "main")
        let resting = AgentChatSession(provider: .claude, projectID: UUID(), title: "b")
        XCTAssertNil(resting.blockingUsageLimit(in: [limited, resting], now: now),
                     "Guthaben gilt nur für ein Modell: nicht sperren")
        XCTAssertNotNil(resting.usageLimitWarning(in: [limited, resting], now: now))
        XCTAssertFalse(limited.usageLimit!.blocksAccount)
        // Der Chat mit dem Guthaben-Limit selbst bleibt gesperrt.
        XCTAssertNotNil(limited.blockingUsageLimit(in: [limited, resting], now: now))
    }

    func testOnlyKnownAccountWideKindsWithAnEndBlockOtherChats() {
        // Vic: Ohne Ende hinge die Sperre an einem Verlauf, der vielleicht nie
        // weitergeht; eine unbekannte Art sperrt nicht das ganze Konto.
        let now = resets.addingTimeInterval(-60)
        func sibling(_ limit: AgentUsageLimit) -> (AgentChatSession, [AgentChatSession]) {
            var limited = AgentChatSession(provider: .claude, projectID: UUID(), title: "a")
            limited.usageLimit = limit
            let resting = AgentChatSession(provider: .claude, projectID: UUID(), title: "b")
            return (resting, [limited, resting])
        }
        for kind in ["five_hour", "seven_day"] {
            let (resting, all) = sibling(AgentUsageLimit(resetsAt: resets, kind: kind, since: nil, account: "main"))
            XCTAssertNotNil(resting.blockingUsageLimit(in: all, now: now), kind)
        }
        let noEnd = sibling(AgentUsageLimit(resetsAt: nil, kind: "five_hour", since: nil, account: "main"))
        XCTAssertNil(noEnd.0.blockingUsageLimit(in: noEnd.1, now: now), "ohne Ende keine kontoweite Sperre")
        XCTAssertNotNil(noEnd.0.usageLimitWarning(in: noEnd.1, now: now), "aber eine Warnung")
        let unknown = sibling(AgentUsageLimit(resetsAt: resets, kind: "seven_day_opus", since: nil, account: "main"))
        XCTAssertNil(unknown.0.blockingUsageLimit(in: unknown.1, now: now), "unbekannte Art sperrt nicht")
        XCTAssertTrue(ChatsSendReadinessGuard.creditsWarning(unknown.1[0].usageLimit!).contains("seven_day_opus"))
    }

    func testOnlyRealSlashCommandsPassTheLimit() {
        for command in ["/login", "/model opus", "/rate-limit-options", "  /usage-credits", "/mcp:list"] {
            XCTAssertTrue(AgentUsageLimit.isSlashCommand(command), command)
        }
        for text in ["/Users/demo/datei.txt ansehen", "/", "/ alles", "/2fa", "bitte /login", "//kommentar"] {
            XCTAssertFalse(AgentUsageLimit.isSlashCommand(text), text)
        }
    }

    func testLimitBelongsToItsAccount() {
        var session = AgentChatSession(provider: .claude, projectID: UUID(), title: "t")
        session.claudeProfileName = "PowerUser2"
        session.usageLimit = AgentUsageLimit(resetsAt: resets, kind: "five_hour", since: nil, account: "PowerUser2")
        let now = resets.addingTimeInterval(-60)
        XCTAssertNotNil(session.activeUsageLimit(at: now))
        session.claudeProfileName = nil // nach move-account ins Hauptkonto
        XCTAssertNil(session.activeUsageLimit(at: now), "nach dem Kontowechsel sperrt das alte Limit nicht")
        session.usageLimit?.account = nil
        XCTAssertNotNil(session.activeUsageLimit(at: now), "ohne Stempel gilt es weiter")
        XCTAssertNil(session.activeUsageLimit(at: resets.addingTimeInterval(1)))
    }

    func testOwnCaseOrgMonthlySpendLimitIsAFiveHourLimit() {
        // Eigener Verlauf 14.11.2026 02:39: „org's monthly spend limit“, gesperrt
        // ist der Mehrverbrauch, das Ende nennt das 5-Stunden-Limit.
        let own = #"{"type":"assistant","timestamp":"2026-11-14T02:39:40.000Z","isApiErrorMessage":true,"error":"rate_limit","apiError":"usage_limit_reached","quotaLimits":{"status":"rejected","resetsAt":1794637200,"rateLimitType":"five_hour","overageDisabledReason":"org_level_disabled_until"},"message":{"model":"<synthetic>","stop_reason":"stop_sequence","content":[{"type":"text","text":"You've hit your org's monthly spend limit · your 5-hour limit resets 7:20am (Europe/Zurich)"}]}}"#
        let limit = AgentUsageLimit(event: AgentTranscriptParser.lastEvent(in: [own, cancelled].joined(separator: "\n"), provider: .claude),
                                    tail: [own, cancelled].joined(separator: "\n"))
        XCTAssertEqual(limit?.kind, "five_hour")
        XCTAssertEqual(limit?.resetsAt, Date(timeIntervalSince1970: 1_794_637_200))
        XCTAssertEqual(limit?.autoContinues, false)
    }

    func testTextsSayWhenClaudeContinuesOnItsOwn() {
        let now = resets.addingTimeInterval(-600)
        var limit = AgentUsageLimit(resetsAt: resets, kind: "five_hour", since: nil, autoContinues: true)
        XCTAssertTrue(ChatsSendReadinessGuard.usageLimitMessage(limit, now: now)?.contains("von selbst weiter") == true)
        var session = AgentChatSession(provider: .claude, projectID: UUID(), title: "t")
        session.usageLimit = limit
        XCTAssertTrue(ChatsOutput.statusText(.idle, session: session, now: now).hasSuffix(", dann weiter"))
        XCTAssertTrue(ChatsOutput.usageLimitLine(limit, now: now).contains("läuft dann von selbst weiter"))
        limit.autoContinues = false
        XCTAssertFalse(ChatsSendReadinessGuard.usageLimitMessage(limit, now: now)?.contains("von selbst weiter") == true)
    }

    // MARK: - Watcher und Store

    func testWatcherCarriesTheLimitAndClearsItWithAnAnswer() {
        let url = URL(fileURLWithPath: "/tmp/wm8-69.jsonl")
        var entry = WatchedSession(id: UUID(), provider: .claude, cwd: "/a", externalSessionID: "x",
                                   transcriptURL: url, lastTurnFinishedAt: nil)
        func poll(_ tail: String, size: Int) -> AgentSessionRuntimePollSnapshot {
            AgentSessionRuntimeWatcher.pollSnapshot(
                for: entry, now: Date(), statProvider: { _ in AgentTranscriptFileStat(mtime: Date(), size: size) },
                tailProvider: { _, _ in tail }, urlResolver: { _ in url })
        }
        let limited = poll([fiveHourLine, systemAfter].joined(separator: "\n"), size: 10)
        XCTAssertEqual(limited.usageLimit?.resetsAt, resets)
        entry.lastStat = limited.stat
        entry.cachedLastEvent = limited.lastEvent
        entry.cachedUsageLimit = limited.usageLimit
        // Stat-first: unveränderte Datei behält das Limit.
        let cached = AgentSessionRuntimeWatcher.pollSnapshot(
            for: entry, now: Date(), statProvider: { _ in limited.stat }, tailProvider: { _, _ in nil },
            urlResolver: { _ in url })
        XCTAssertEqual(cached.usageLimit, limited.usageLimit)
        // Eine User-Zeile beendet das Limit nicht (Claude antwortet sofort mit
        // der nächsten Limit-Zeile), erst eine echte Antwort.
        XCTAssertEqual(poll([fiveHourLine, userLine].joined(separator: "\n"), size: 20).usageLimit, limited.usageLimit)
        let answer = #"{"type":"assistant","timestamp":"2026-11-14T03:31:00.000Z","message":{"stop_reason":"end_turn","content":[{"type":"text","text":"weiter"}]}}"#
        XCTAssertNil(poll([fiveHourLine, userLine, answer].joined(separator: "\n"), size: 30).usageLimit)
    }

    func testStoreKeepsActivityTimeAndDecodingIsLenient() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wm8-69-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = AgentSessionStore(fileURL: dir.appendingPathComponent("ws.json"),
                                      uiStateFileURL: dir.appendingPathComponent("ui.json"))
        let created = try store.createSession(provider: .claude, projectPath: dir.path, title: "t",
                                              model: "m", reasoningEffort: "medium")
        let before = try XCTUnwrap(store.loadWorkspace().sessions.first { $0.id == created.id })
        let limit = AgentUsageLimit(resetsAt: resets, kind: "five_hour", since: nil)
        try store.setUsageLimit(limit, for: created.id)
        let after = try XCTUnwrap(store.loadWorkspace().sessions.first { $0.id == created.id })
        XCTAssertEqual(after.usageLimit, limit)
        XCTAssertEqual(after.lastActivityAt, before.lastActivityAt)
        try store.setUsageLimit(nil, for: created.id)
        XCTAssertNil(try XCTUnwrap(store.loadWorkspace().sessions.first { $0.id == created.id }).usageLimit)

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(after)) as? [String: Any])
        object["usageLimit"] = ["kind": 5]
        XCTAssertNil(try JSONDecoder().decode(AgentChatSession.self, from: JSONSerialization.data(withJSONObject: object)).usageLimit)
    }

    // MARK: - Senden und Warteschlange (c)

    func testSendIsRefusedWhileTheLimitIsActive() {
        let now = resets.addingTimeInterval(-600)
        let limit = AgentUsageLimit(resetsAt: resets, kind: "five_hour", since: nil)
        let message = ChatsSendReadinessGuard.usageLimitMessage(limit, now: now)
        XCTAssertNotNil(message)
        XCTAssertTrue(message?.contains("chats enqueue") == true)
        XCTAssertNil(ChatsSendReadinessGuard.usageLimitMessage(limit, now: resets.addingTimeInterval(1)))
        XCTAssertNil(ChatsSendReadinessGuard.usageLimitMessage(nil, now: now))
    }

    func testLiveEntryNamesTheLimit() {
        var session = AgentChatSession(provider: .claude, projectID: UUID(), title: "t")
        session.usageLimit = AgentUsageLimit(resetsAt: resets, kind: "five_hour", since: nil)
        let entry = ChatsSendReadinessGuard.liveEntry(session: session, isRunning: true, runtime: .idle,
                                                      now: resets.addingTimeInterval(-60))
        XCTAssertEqual(entry["usageLimit"] as? String, "five_hour")
        XCTAssertEqual((entry["usageLimitResetsAt"] as? String).flatMap(ChatsOutput.parseISO), resets)
        let after = ChatsSendReadinessGuard.liveEntry(session: session, isRunning: true, runtime: .idle,
                                                      now: resets.addingTimeInterval(60))
        XCTAssertNil(after["usageLimit"])
    }

    func testLiveEntryCarriesStartAndPID() {
        // Neustart-Vorhaben: `runtime.pid` und „Terminal-Tab läuft (PID …)“
        // hängen an diesen Feldern; die PID nur, solange der Prozess läuft.
        let session = AgentChatSession(provider: .claude, projectID: UUID(), title: "t")
        let running = ChatsSendReadinessGuard.liveEntry(session: session, isRunning: true, runtime: .idle,
                                                        hasStarted: true, pid: 4711)
        XCTAssertEqual(running["hasStarted"] as? Bool, true)
        XCTAssertEqual(running["pid"] as? Int, 4711)
        let ended = ChatsSendReadinessGuard.liveEntry(session: session, isRunning: false, runtime: nil,
                                                      hasStarted: true, pid: nil)
        XCTAssertEqual(ended["hasStarted"] as? Bool, true)
        XCTAssertTrue(ended["pid"] is NSNull)
    }

    // MARK: - chats send --wait-started (WM8-70)

    func testStartDecider() {
        let now = Date()
        let deadline = now.addingTimeInterval(10)
        func step(_ status: AgentSessionRuntimeStatus?, limit: Date? = nil, at time: Date = now) -> ChatsSendStartDecider.Step {
            ChatsSendStartDecider.evaluate(status: status, limitUntil: limit, now: time, deadline: deadline, waitedSeconds: 3)
        }
        XCTAssertEqual(step(.working), .started)
        XCTAssertEqual(step(.idle, limit: now.addingTimeInterval(60)), .stop(.usageLimit(until: now.addingTimeInterval(60))))
        XCTAssertEqual(step(.idle), .keepWaiting)
        XCTAssertEqual(step(.awaitingInput), .keepWaiting, "die Nachricht kann die Rückfrage beantworten")
        XCTAssertEqual(step(.awaitingInput, at: deadline), .stop(.awaitingInput))
        XCTAssertEqual(step(.idle, at: deadline), .stop(.timeout(seconds: 3, status: "idle")))
        XCTAssertEqual(step(.stopped), .stop(.stopped))
        XCTAssertEqual(step(.errored), .stop(.errored))
        // Ein abgelaufenes Limit hält nicht auf.
        XCTAssertEqual(step(.working, limit: now.addingTimeInterval(-1)), .started)
        // Limit ohne bekanntes Ende (Review M4).
        XCTAssertEqual(ChatsSendStartDecider.evaluate(status: .idle, limitUntil: nil, now: now, deadline: deadline,
                                                      waitedSeconds: 1, limited: true), .stop(.usageLimit(until: nil)))
    }

    func testWaiterCatchesALimitThatFollowsAShortWorkingPhase() {
        let id = UUID()
        var answers: [ChatsLiveStatus] = [
            ChatsLiveStatus(runtimeStatus: .working, isAttachedPTY: true, canSend: true, canInterrupt: true),
            ChatsLiveStatus(runtimeStatus: .working, isAttachedPTY: true, canSend: true, canInterrupt: true),
            ChatsLiveStatus(runtimeStatus: .idle, isAttachedPTY: true, canSend: true, canInterrupt: false,
                            usageLimitUntil: nil, usageLimited: true),
        ]
        var clock = Date()
        let outcome = ChatsSendStartWaiter.wait(
            targetID: id, seconds: 20,
            fetch: {
                let next = answers.count > 1 ? answers.removeFirst() : answers[0]
                return ChatsLiveSnapshot(entries: [id: next], omittedAreDetached: true)
            },
            sleep: { clock = clock.addingTimeInterval($0) }, now: { clock })
        XCTAssertEqual(outcome, .notStarted(.usageLimit(until: nil)))
    }

    func testWaiterPollsTheAppUntilTheChatWorks() {
        let id = UUID()
        var statuses: [AgentSessionRuntimeStatus] = [.idle, .idle, .working]
        var clock = Date()
        let outcome = ChatsSendStartWaiter.wait(
            targetID: id, seconds: 20,
            fetch: {
                let status = statuses.isEmpty ? .working : statuses.removeFirst()
                return ChatsLiveSnapshot(entries: [id: ChatsLiveStatus(runtimeStatus: status, isAttachedPTY: true,
                                                                       canSend: true, canInterrupt: false)],
                                         omittedAreDetached: true)
            },
            sleep: { clock = clock.addingTimeInterval($0) },
            now: { clock })
        guard case .started(let waited) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(waited, 1, accuracy: 0.01)
        XCTAssertEqual(ChatsSendStartWaiter.wait(targetID: id, seconds: 5, fetch: { nil }, sleep: { _ in }),
                       .notStarted(.appUnreachable))
    }

    func testWaiterReportsTheLimitFromTheApp() {
        let id = UUID()
        let until = Date().addingTimeInterval(3600)
        let outcome = ChatsSendStartWaiter.wait(
            targetID: id, seconds: 20,
            fetch: {
                ChatsLiveSnapshot(entries: [id: ChatsLiveStatus(runtimeStatus: .idle, isAttachedPTY: true, canSend: true,
                                                                canInterrupt: false, usageLimitUntil: until)],
                                  omittedAreDetached: true)
            },
            sleep: { _ in })
        XCTAssertEqual(outcome, .notStarted(.usageLimit(until: until)))
        XCTAssertEqual(outcome.exitCode, ChatsCLIExit.conflict)
        XCTAssertTrue(outcome.line(title: "Dex", characters: 10).hasPrefix("✗ nicht angekommen: Dex — Konto am Nutzungslimit bis"))
    }

    func testApprovalOutcomesFollowTheWM875Rules() {
        // Zurückgehaltenes Enter: nie „gestartet“, nie vormerken, Exit 4.
        let withheld = ChatsSendOutcome.notStarted(.enterWithheld)
        XCTAssertEqual(withheld.exitCode, ChatsCLIExit.conflict)
        XCTAssertEqual(withheld.reasonCode, "enterWithheld")
        XCTAssertTrue(withheld.line(title: "Fin", characters: 3).contains("Nicht neu senden und nicht vormerken"))
        let pending = ChatsSendOutcome.notStarted(.approvalPending)
        XCTAssertEqual(pending.exitCode, ChatsCLIExit.conflict)
        XCTAssertTrue(pending.line(title: "Fin", characters: 3).contains("send bestätigt keine Freigaben"))
    }

    func testOutcomeTextsAndExitCodes() {
        XCTAssertEqual(ChatsSendOutcome.started(waited: 2).line(title: "Fin", characters: 5), "✓ gestartet: Fin arbeitet (nach 2 s)")
        XCTAssertEqual(ChatsSendOutcome.queued(position: 2, status: "working").line(title: "Fin", characters: 5),
                       "✓ vorgemerkt als Nr. 2 bei Fin (Chat ist working; Zustellung beim nächsten Turn-Ende)")
        XCTAssertEqual(ChatsSendOutcome.queued(position: 1, status: "working").exitCode, ChatsCLIExit.ok)
        XCTAssertEqual(ChatsSendOutcome.notStarted(.timeout(seconds: 20, status: "idle")).exitCode, ChatsCLIExit.timeout)
        XCTAssertEqual(ChatsSendOutcome.notStarted(.awaitingInput).reasonCode, "awaitingInput")
        XCTAssertEqual(ChatsSendOutcome.started(waited: 1).keyword, "started")
    }

    // MARK: - CLI-Anzeige (a) und chats new (d)

    func testCLIShowsTheLimitAsOwnState() {
        let now = resets.addingTimeInterval(-600)
        var session = AgentChatSession(provider: .claude, projectID: UUID(), title: "t")
        XCTAssertEqual(ChatsOutput.statusText(.idle, session: session, now: now), "idle")
        session.usageLimit = AgentUsageLimit(resetsAt: resets, kind: "five_hour", since: nil)
        XCTAssertTrue(ChatsOutput.statusText(.idle, session: session, now: now).hasPrefix("limit bis "))
        XCTAssertEqual(ChatsOutput.statusText(.idle, session: session, now: resets.addingTimeInterval(1)), "idle")
        XCTAssertTrue(ChatsOutput.usageLimitLine(session.usageLimit!, now: now).hasPrefix("Konto am 5-Stunden-Limit bis "))
        XCTAssertEqual(ChatsOutput.usageLimitJSON(session.usageLimit!)["kind"] as? String, "five_hour")
    }

    func testBoardPutsALimitedChatUnderNeedsYou() {
        var session = AgentChatSession(provider: .claude, projectID: UUID(), title: "t")
        session.usageLimit = AgentUsageLimit(resetsAt: Date().addingTimeInterval(3600), kind: "five_hour", since: nil)
        let entry = ChatsSessionEntry(session: session, projectName: "p", projectPath: "/p")
        let runtime = ChatsRuntimeInfo(status: .idle, source: "app", since: nil, revision: nil,
                                       transcriptPath: nil, transcriptSizeBytes: nil, availability: .available)
        let board = AttentionModelBuilder.build(items: [(entry, runtime)])
        XCTAssertEqual(board.items.first?.category, .needsYou)
    }

    func testNewChatWarnsWhenTheAccountIsAtItsLimit() {
        var limited = AgentChatSession(provider: .claude, projectID: UUID(), title: "a")
        limited.claudeProfileName = "RankM8"
        limited.usageLimit = AgentUsageLimit(resetsAt: Date().addingTimeInterval(3600), kind: "five_hour", since: nil)
        var other = AgentChatSession(provider: .claude, projectID: UUID(), title: "b")
        other.claudeProfileName = "PowerUser2"
        XCTAssertNotNil(ChatsAccountUsageLimit.active(account: "RankM8", sessions: [limited, other]))
        XCTAssertNil(ChatsAccountUsageLimit.active(account: "PowerUser2", sessions: [limited, other]))
        XCTAssertNil(ChatsAccountUsageLimit.active(account: "main", sessions: [limited, other]))
    }
}
