import Foundation
import XCTest
@testable import WhisperM8

final class ClaudeCodeProxyOrphanGuardTests: XCTestCase {
    private let started = Date(timeIntervalSince1970: 1_000_000)
    private let managed = "/Users/x/Library/Application Support/WhisperM8/bin/claude-code-proxy"

    private func listener(ppid: Int32 = 1, path: String? = nil) -> ClaudeCodeProxyOrphanGuard.ListenerProcess {
        .init(pid: 4242, parentPID: ppid, executablePath: path ?? managed, startedAt: started)
    }

    func testReplacesOrphanRunningADifferentBinary() {
        XCTAssertTrue(ClaudeCodeProxyOrphanGuard.shouldReplace(
            listener(path: "/Users/x/.local/bin/claude-code-proxy"),
            resolvedBinaryPath: managed, resolvedBinaryModifiedAt: started.addingTimeInterval(-60)
        ))
    }

    func testReplacesOrphanWhoseBinaryWasUpdatedInPlaceAfterStart() {
        XCTAssertTrue(ClaudeCodeProxyOrphanGuard.shouldReplace(
            listener(), resolvedBinaryPath: managed, resolvedBinaryModifiedAt: started.addingTimeInterval(60)
        ))
        XCTAssertFalse(ClaudeCodeProxyOrphanGuard.shouldReplace(
            listener(), resolvedBinaryPath: managed, resolvedBinaryModifiedAt: started.addingTimeInterval(-60)
        ), "Aktuelle Waise mit demselben Binary bleibt")
    }

    func testNeverTouchesUserStartedOrForeignListeners() {
        XCTAssertFalse(ClaudeCodeProxyOrphanGuard.shouldReplace(
            listener(ppid: 777, path: "/opt/homebrew/bin/claude-code-proxy"),
            resolvedBinaryPath: managed, resolvedBinaryModifiedAt: nil
        ), "Im Terminal gestartet: Elternprozess ist eine Shell")
        XCTAssertFalse(ClaudeCodeProxyOrphanGuard.shouldReplace(
            listener(path: "/usr/local/bin/some-other-server"),
            resolvedBinaryPath: managed, resolvedBinaryModifiedAt: nil
        ), "Fremdes Programm auf dem Port")
        XCTAssertFalse(ClaudeCodeProxyOrphanGuard.shouldReplace(
            listener(path: "/Users/x/.local/bin/claude-code-proxy"),
            resolvedBinaryPath: nil, resolvedBinaryModifiedAt: nil
        ), "Ohne Ersatz-Binary nichts beenden")
    }

    func testReplaceTerminatesAndWaitsUntilPortIsFree() {
        var terminated: [Int32] = []
        var probes = 0
        let replaced = ClaudeCodeProxyOrphanGuard.replaceIfOutdated(
            port: 18765,
            resolvedBinaryPath: "/nonexistent/claude-code-proxy",
            listenerResolver: { _ in self.listener(path: "/Users/x/.local/bin/claude-code-proxy") },
            terminator: { terminated.append($0) },
            isReachable: { _ in probes += 1; return probes < 3 },
            sleep: { _ in }
        )
        XCTAssertTrue(replaced)
        XCTAssertEqual(terminated, [4242])
        XCTAssertEqual(probes, 3)

        var untouched: [Int32] = []
        XCTAssertFalse(ClaudeCodeProxyOrphanGuard.replaceIfOutdated(
            port: 18765, resolvedBinaryPath: "/x/claude-code-proxy",
            listenerResolver: { _ in nil }, terminator: { untouched.append($0) },
            isReachable: { _ in false }, sleep: { _ in }
        ))
        XCTAssertTrue(untouched.isEmpty)
    }

    // MARK: - Transkriptions-Route (ChatGPT-Abo)

    private func replace(
        listener: ClaudeCodeProxyOrphanGuard.ListenerProcess,
        requireRoute: Bool,
        route: ClaudeCodeProxyTranscriptionRoute,
        probes: inout Int
    ) -> Bool {
        var count = 0
        // Binary existiert nicht → mtime nil → kein Alters-Kriterium; gleicher
        // Pfad wie die Waise → kein Binary-Wechsel. Bleibt nur die Route.
        let replaced = ClaudeCodeProxyOrphanGuard.replaceIfOutdated(
            port: 18765,
            resolvedBinaryPath: managed,
            requireTranscriptionRoute: requireRoute,
            routeProbe: { _ in count += 1; return route },
            listenerResolver: { _ in listener },
            terminator: { _ in },
            isReachable: { _ in false },
            sleep: { _ in }
        )
        probes = count
        return replaced
    }

    func testReplacesCurrentOrphanWithoutTranscriptionRoute() {
        var probes = 0
        XCTAssertTrue(replace(listener: listener(), requireRoute: true, route: .missing, probes: &probes))
        XCTAssertEqual(probes, 1)
        XCTAssertEqual(
            ClaudeCodeProxyOrphanGuard.replaceReason(
                listener(), resolvedBinaryPath: managed, resolvedBinaryModifiedAt: nil,
                lacksTranscriptionRoute: { true }
            ),
            .transcriptionRouteMissing
        )
    }

    func testKeepsOrphanWithTranscriptionRouteOrUnknownProbe() {
        var probes = 0
        XCTAssertFalse(replace(listener: listener(), requireRoute: true, route: .available, probes: &probes))
        XCTAssertFalse(replace(listener: listener(), requireRoute: true, route: .unknown, probes: &probes),
                       "Unklare Probe ersetzt nie")
    }

    func testRouteProbeIsSkippedForNonOrphans() {
        var probes = 0
        XCTAssertFalse(replace(
            listener: listener(ppid: 777), requireRoute: true, route: .missing, probes: &probes
        ))
        XCTAssertEqual(probes, 0, "Fremde/Terminal-Proxys werden nicht einmal abgefragt")
    }

    func testRouteProbeIsNeverCalledWhenNotRequired() {
        var probes = 0
        XCTAssertFalse(replace(listener: listener(), requireRoute: false, route: .missing, probes: &probes))
        XCTAssertEqual(probes, 0)
    }

    func testOutdatedBinaryKeepsItsOwnReasonWithoutProbe() {
        var probed = false
        let reason = ClaudeCodeProxyOrphanGuard.replaceReason(
            listener(path: "/Users/x/.local/bin/claude-code-proxy"),
            resolvedBinaryPath: managed, resolvedBinaryModifiedAt: nil,
            lacksTranscriptionRoute: { probed = true; return true }
        )
        XCTAssertEqual(reason, .binaryOutdated)
        XCTAssertFalse(probed)
    }

    func testListenerParsesLiveProcessTable() {
        // Kein Listener auf einem freien Port → nil statt Absturz.
        XCTAssertNil(ClaudeCodeProxyOrphanGuard.listener(port: 1))
    }
}
