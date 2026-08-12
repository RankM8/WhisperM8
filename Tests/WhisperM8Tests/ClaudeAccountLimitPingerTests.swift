import Foundation
import XCTest
@testable import WhisperM8

/// CLI-Ping zur Token-Erneuerung (`ClaudeAccountLimitPinger`): Argv/Env des
/// Claude-Aufrufs, Outcome-Klassifikation (inkl. der real beobachteten
/// CLI-Fehlermeldung bei totem Login), Skips (busy/cooldown) und das
/// Aufräumen der Ping-Artefakte aus dem Profil.
final class ClaudeAccountLimitPingerTests: XCTestCase {
    /// ProcessRunner-Spy: zeichnet den Aufruf auf und liefert ein
    /// vorgegebenes Ergebnis (oder wirft).
    private final class RunnerSpy: ProcessRunner, @unchecked Sendable {
        struct Call {
            var executable: String
            var arguments: [String]
            var workingDirectory: String
            var environmentOverrides: [String: String]
        }

        var calls: [Call] = []
        var result: ProcessRunResult = ProcessRunResult(exitCode: 0, stdout: "ok", stderr: "")
        var error: Error?

        func run(
            executable: String,
            arguments: [String],
            workingDirectory: String,
            environmentOverrides: [String: String],
            timeout: TimeInterval
        ) async throws -> ProcessRunResult {
            calls.append(Call(
                executable: executable,
                arguments: arguments,
                workingDirectory: workingDirectory,
                environmentOverrides: environmentOverrides
            ))
            if let error { throw error }
            return result
        }
    }

    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("limit-pinger-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    private func makePinger(
        runner: RunnerSpy,
        busy: Set<String> = [],
        throttle: ClaudeTokenRefreshThrottle = ClaudeTokenRefreshThrottle()
    ) -> (pinger: ClaudeAccountLimitPinger, throttle: ClaudeTokenRefreshThrottle) {
        var profiles = ClaudeAccountProfiles()
        profiles.homeDirectory = tempRoot
        var pinger = ClaudeAccountLimitPinger(profiles: profiles)
        pinger.commandResolver = { _ in "/fake/bin/claude" }
        pinger.processRunner = runner
        pinger.throttle = throttle
        pinger.busyProfileNames = { busy }
        pinger.workDirectory = tempRoot.appendingPathComponent(
            ClaudeAccountLimitPinger.workDirectoryName, isDirectory: true
        )
        return (pinger, throttle)
    }

    /// Ping-Artefakte ins Profil legen (encodiertes projects/-Verzeichnis mit
    /// Session-JSONL + memory/ — exakt was die CLI beim Test-Ping anlegte).
    private func seedPingArtifacts(configDir: URL) throws -> URL {
        let encoded = configDir
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(
                "-tmp-fake-\(ClaudeAccountLimitPinger.workDirectoryName)", isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: encoded.appendingPathComponent("memory", isDirectory: true),
            withIntermediateDirectories: true
        )
        try "{}".write(
            to: encoded.appendingPathComponent("\(UUID().uuidString.lowercased()).jsonl"),
            atomically: true,
            encoding: .utf8
        )
        return encoded
    }

    func testSuccessfulPingRunsClaudeUnderProfileAndCleansUp() async throws {
        let runner = RunnerSpy()
        let (pinger, throttle) = makePinger(runner: runner)
        let configDir = pinger.profiles.configDir(forProfile: "acc")
        let encoded = try seedPingArtifacts(configDir: configDir)

        let outcome = await pinger.ping(profileNamed: "acc")

        XCTAssertEqual(outcome, .refreshed)
        let call = try XCTUnwrap(runner.calls.first)
        XCTAssertEqual(runner.calls.count, 1)
        XCTAssertEqual(call.executable, "/fake/bin/claude")
        XCTAssertEqual(call.environmentOverrides["CLAUDE_CONFIG_DIR"], configDir.path)
        XCTAssertEqual(call.workingDirectory, pinger.workDirectory.path)
        XCTAssertEqual(call.arguments.first, "-p")
        XCTAssertTrue(call.arguments.contains("--model"), "billigstes Modell, nie das Default-Modell des Profils")
        XCTAssertTrue(call.arguments.contains("--session-id"))
        // Artefakte weg (zweite Verteidigungslinie neben dem Indexer-Skip).
        XCTAssertFalse(FileManager.default.fileExists(atPath: encoded.path))
        // Erfolgs-Cooldown ohne Problem-Auskunft.
        let entry = try XCTUnwrap(throttle.blockedEntry(forProfile: "acc", now: Date()))
        XCTAssertNil(entry.problem)
    }

    func testDeadLoginOutputIsClassifiedAsLoginRequired() async throws {
        let runner = RunnerSpy()
        // Real beobachtete Meldung (2026-08-09, Profil ohne Keychain-Token).
        runner.result = ProcessRunResult(
            exitCode: 1,
            stdout: "",
            stderr: "Failed to authenticate: OAuth session expired and could not be refreshed"
        )
        let (pinger, throttle) = makePinger(runner: runner)

        let outcome = await pinger.ping(profileNamed: "acc")

        XCTAssertEqual(outcome, .loginRequired)
        // Passive Fetches zeigen waehrend des Cooldowns den praezisen Grund.
        let entry = try XCTUnwrap(throttle.blockedEntry(forProfile: "acc", now: Date()))
        XCTAssertEqual(entry.problem, .loginExpired)
    }

    func testGenericFailureEntersCooldownWithoutLoginClaim() async throws {
        let runner = RunnerSpy()
        runner.result = ProcessRunResult(exitCode: 1, stdout: "", stderr: "model overloaded")
        let (pinger, throttle) = makePinger(runner: runner)

        let outcome = await pinger.ping(profileNamed: "acc")

        guard case .failed = outcome else {
            return XCTFail("erwartet .failed, war \(outcome)")
        }
        let entry = try XCTUnwrap(throttle.blockedEntry(forProfile: "acc", now: Date()))
        XCTAssertNil(entry.problem, "ein Wackler darf nie als „Login tot“ ausgewiesen werden")
    }

    func testBusyProfileIsSkippedWithoutProcessRun() async {
        let runner = RunnerSpy()
        let (pinger, _) = makePinger(runner: runner, busy: ["acc"])

        let outcome = await pinger.ping(profileNamed: "acc")

        XCTAssertEqual(outcome, .skippedBusy)
        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testCooldownSkipsWithoutProcessRun() async {
        let runner = RunnerSpy()
        let throttle = ClaudeTokenRefreshThrottle()
        let until = Date().addingTimeInterval(300)
        throttle.record(profile: "acc", nextAllowedAt: until, problem: nil)
        let (pinger, _) = makePinger(runner: runner, throttle: throttle)

        let outcome = await pinger.ping(profileNamed: "acc")

        XCTAssertEqual(outcome, .skippedCooldown(until: until))
        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testMissingClaudeIsReported() async {
        let runner = RunnerSpy()
        var (pinger, _) = makePinger(runner: runner)
        pinger.commandResolver = { _ in nil }

        let outcome = await pinger.ping(profileNamed: "acc")

        XCTAssertEqual(outcome, .claudeMissing)
        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testPingProjectsDirectoryDetection() {
        XCTAssertTrue(ClaudeAccountLimitPinger.isPingProjectsDirectory(
            "-Users-x-Library-Application Support-WhisperM8-whisperm8-limit-ping"
        ))
        XCTAssertTrue(ClaudeAccountLimitPinger.isPingProjectsDirectory("-tmp-whisperm8-limit-ping"))
        XCTAssertFalse(ClaudeAccountLimitPinger.isPingProjectsDirectory("-Users-x-repos-whisperm8"))
        XCTAssertFalse(ClaudeAccountLimitPinger.isPingProjectsDirectory("-Users-x-limit-ping-notes"))
    }
}

/// Gemeinsamer manueller Update-Ablauf (Accounts-Tab + Popover).
final class ClaudeUsageUpdateFlowTests: XCTestCase {
    func testOnlyExpiredProfilesArePingedAndSummaryReportsRenewal() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-flow-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Zwei Profile: "fresh" mit gueltigem Token, "stale" abgelaufen.
        var profiles = ClaudeAccountProfiles()
        profiles.homeDirectory = tmp
        profiles.securityRunner = { args in
            guard args.first == "find-generic-password" else { return (0, "") }
            let service = args[args.firstIndex(of: "-s").map { $0 + 1 } ?? 0]
            // main = "fresh" (Service ohne Suffix), Profil-Service = "stale".
            if service == "Claude Code-credentials" {
                return (0, #"{"claudeAiOauth":{"accessToken":"ok","expiresAt":4000000000000}}"#)
            }
            return (0, #"{"claudeAiOauth":{"accessToken":"old","expiresAt":1000}}"#)
        }

        var fetcher = ClaudeAccountUsageFetcher(profiles: profiles)
        fetcher.temporaryDirectory = tmp.path
        fetcher.busyProfileNames = { [] }
        fetcher.refreshThrottle = ClaudeTokenRefreshThrottle()
        fetcher.httpResponse = { request in
            let token = (request.value(forHTTPHeaderField: "Authorization") ?? "")
                .replacingOccurrences(of: "Bearer ", with: "")
            guard token == "ok" else { return (Data("{}".utf8), 401) }
            return (Data(#"{"five_hour": {"utilization": 5.0}}"#.utf8), 200)
        }

        let runner = PingRunnerSpy()
        var pinger = ClaudeAccountLimitPinger(profiles: profiles)
        pinger.commandResolver = { _ in "/fake/bin/claude" }
        pinger.processRunner = runner
        pinger.throttle = ClaudeTokenRefreshThrottle()
        pinger.busyProfileNames = { [] }
        pinger.workDirectory = tmp.appendingPathComponent("ping", isDirectory: true)

        var updates: [String] = []
        let summary = await ClaudeUsageUpdateFlow.run(
            profileNames: ["main", "stale"],
            fetcher: fetcher,
            pinger: pinger
        ) { name, _ in
            updates.append(name)
        }

        XCTAssertEqual(summary.renewed, ["stale"], "nur das abgelaufene Profil wird gepingt")
        XCTAssertEqual(runner.launchCount, 1)
        // Beide Profile in Phase 1 gemeldet, das gepingte in Phase 2 erneut.
        XCTAssertEqual(updates.filter { $0 == "stale" }.count, 2)
        XCTAssertEqual(updates.filter { $0 == "main" }.count, 1)
    }
}

/// Minimaler Runner fuer den Flow-Test (eigener Typ, da der Spy oben
/// `private` im Pinger-Testfall lebt).
private final class PingRunnerSpy: ProcessRunner, @unchecked Sendable {
    var launchCount = 0

    func run(
        executable: String,
        arguments: [String],
        workingDirectory: String,
        environmentOverrides: [String: String],
        timeout: TimeInterval
    ) async throws -> ProcessRunResult {
        launchCount += 1
        return ProcessRunResult(exitCode: 0, stdout: "ok", stderr: "")
    }
}
