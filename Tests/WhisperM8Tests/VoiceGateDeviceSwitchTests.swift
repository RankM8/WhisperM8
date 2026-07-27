import Foundation
import XCTest
@testable import WhisperM8

// ==============================================================================
// Regressionstests zum Gerätewechsel-Fehler vom 27.07.2026:
// AirPods raus und wieder rein machten den Listener stumm — ohne Fehler, ohne
// Log, das Gate meldete weiter „scharf". Ursache war ein Konfigurations-
// Beobachter, der an der verworfenen Engine haengenblieb; niemand bemerkte den
// Ausfall, weil es kein Lebenszeichen gab.
//
// Die Engine-Seite selbst (AVAudioEngine, Tap, NotificationCenter) bleibt
// manuelle QA. Getestet wird hier das Sicherheitsnetz: Erkennt das System
// ueberhaupt, dass kein Audio mehr kommt — und reagiert es maassvoll?
// ==============================================================================

final class VoiceGateListenerHealthTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testStartingUntilFirstBufferWithinGrace() {
        var health = VoiceGateListenerHealth(deafThreshold: 5, startupGrace: 3)
        health.markStarted(at: t0)

        XCTAssertEqual(health.verdict(now: t0.addingTimeInterval(1)), .starting)
    }

    /// Der Kernfall: gestartet, aber es kommt nie ein Puffer — genau das
    /// passierte nach dem Rebind auf ein totes Geraet.
    func testDeafWhenNoBufferArrivesAfterGrace() {
        var health = VoiceGateListenerHealth(deafThreshold: 5, startupGrace: 3)
        health.markStarted(at: t0)

        guard case .deaf(let gap) = health.verdict(now: t0.addingTimeInterval(4)) else {
            return XCTFail("nach der Schonfrist ohne Puffer muss es taub sein")
        }
        XCTAssertEqual(gap, 4, accuracy: 0.001)
    }

    func testHealthyWhileBuffersKeepArriving() {
        var health = VoiceGateListenerHealth(deafThreshold: 5, startupGrace: 3)
        health.markStarted(at: t0)
        health.recordBuffer(at: t0.addingTimeInterval(0.1))

        XCTAssertEqual(health.verdict(now: t0.addingTimeInterval(2)), .healthy)
    }

    /// Stille im Raum darf NICHT als taub gelten — der Tap feuert unabhaengig
    /// davon, ob jemand spricht. Deshalb ist der Puffer das Signal, nicht die
    /// Erkennung.
    func testSilenceWithFlowingBuffersStaysHealthy() {
        var health = VoiceGateListenerHealth(deafThreshold: 5, startupGrace: 3)
        health.markStarted(at: t0)

        // 60 s Stille, aber der Tap liefert weiter alle 100 ms.
        var now = t0
        for _ in 0..<600 {
            now = now.addingTimeInterval(0.1)
            health.recordBuffer(at: now)
        }
        XCTAssertEqual(health.verdict(now: now.addingTimeInterval(1)), .healthy)
    }

    /// Puffer versiegen mitten im Betrieb — der Gerätewechsel-Fall.
    func testDeafAfterBuffersStop() {
        var health = VoiceGateListenerHealth(deafThreshold: 5, startupGrace: 3)
        health.markStarted(at: t0)
        health.recordBuffer(at: t0.addingTimeInterval(1))

        XCTAssertEqual(health.verdict(now: t0.addingTimeInterval(4)), .healthy)
        guard case .deaf = health.verdict(now: t0.addingTimeInterval(7)) else {
            return XCTFail("nach 6 s ohne Puffer muss es taub sein")
        }
    }

    /// Nach einem Rebind laeuft die Schonfrist neu — sonst wuerde der Wachhund
    /// sofort wieder zuschlagen.
    func testRebindResetsTheClock() {
        var health = VoiceGateListenerHealth(deafThreshold: 5, startupGrace: 3)
        health.markStarted(at: t0)
        XCTAssertNotEqual(health.verdict(now: t0.addingTimeInterval(10)), .starting)

        health.markStarted(at: t0.addingTimeInterval(10))
        XCTAssertEqual(health.verdict(now: t0.addingTimeInterval(11)), .starting)
    }

    func testStoppedListenerIsNotJudged() {
        var health = VoiceGateListenerHealth()
        health.markStarted(at: t0)
        health.markStopped()

        XCTAssertEqual(health.verdict(now: t0.addingTimeInterval(600)), .starting)
    }
}

final class VoiceGateWatchdogPolicyTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testRestartsWhenArmedAndDeaf() {
        var policy = VoiceGateWatchdogPolicy()
        XCTAssertEqual(policy.decide(armed: true, verdict: .deaf(gap: 9), now: t0), .restart)
    }

    func testDoesNotRestartWhenHealthy() {
        var policy = VoiceGateWatchdogPolicy()
        XCTAssertEqual(policy.decide(armed: true, verdict: .healthy, now: t0), .none)
    }

    func testDoesNotRestartWhileStarting() {
        var policy = VoiceGateWatchdogPolicy()
        XCTAssertEqual(policy.decide(armed: true, verdict: .starting, now: t0), .none)
    }

    /// Nicht scharf heisst: der Listener soll gar nicht laufen — dann ist
    /// „kein Audio" der Normalzustand und kein Grund fuer einen Neustart.
    func testDoesNotRestartWhenNotArmed() {
        var policy = VoiceGateWatchdogPolicy()
        XCTAssertEqual(policy.decide(armed: false, verdict: .deaf(gap: 60), now: t0), .none)
    }

    /// Ohne Mindestabstand wuerde der 10-s-Takt eine Neustart-Schleife bauen.
    func testHonoursMinimumIntervalBetweenRestarts() {
        var policy = VoiceGateWatchdogPolicy(minRestartInterval: 30)
        XCTAssertEqual(policy.decide(armed: true, verdict: .deaf(gap: 9), now: t0), .restart)
        XCTAssertEqual(policy.decide(armed: true, verdict: .deaf(gap: 19), now: t0.addingTimeInterval(10)), .none)
        XCTAssertEqual(policy.decide(armed: true, verdict: .deaf(gap: 40), now: t0.addingTimeInterval(31)), .restart)
    }

    /// Irgendwann ist Aufgeben ehrlicher als weiter zu probieren — und die
    /// Oberflaeche soll aufhoeren, „scharf" zu behaupten.
    func testGivesUpAfterConsecutiveFailedRestarts() {
        var policy = VoiceGateWatchdogPolicy(minRestartInterval: 30, maxConsecutiveRestarts: 3)
        var now = t0
        for _ in 0..<3 {
            XCTAssertEqual(policy.decide(armed: true, verdict: .deaf(gap: 9), now: now), .restart)
            now = now.addingTimeInterval(31)
        }
        XCTAssertEqual(policy.decide(armed: true, verdict: .deaf(gap: 9), now: now), .giveUp)
        // Danach still — kein Dauerfeuer aus giveUp.
        XCTAssertEqual(
            policy.decide(armed: true, verdict: .deaf(gap: 9), now: now.addingTimeInterval(120)),
            .none
        )
    }

    /// Ein gesunder Durchlauf loescht die Historie — sonst legt ein einzelner
    /// Ausrutscher den Wachhund fuer den Rest der Sitzung lahm.
    func testHealthyRunResetsFailureCounter() {
        var policy = VoiceGateWatchdogPolicy(minRestartInterval: 0, maxConsecutiveRestarts: 2)
        _ = policy.decide(armed: true, verdict: .deaf(gap: 9), now: t0)
        _ = policy.decide(armed: true, verdict: .deaf(gap: 9), now: t0.addingTimeInterval(1))

        XCTAssertEqual(policy.decide(armed: true, verdict: .healthy, now: t0.addingTimeInterval(2)), .none)
        XCTAssertEqual(policy.decide(armed: true, verdict: .deaf(gap: 9), now: t0.addingTimeInterval(3)), .restart)
    }

    /// Manuelles Aus/An ist die Geste „probier es nochmal".
    func testResetAllowsRetryingAfterGivingUp() {
        var policy = VoiceGateWatchdogPolicy(minRestartInterval: 0, maxConsecutiveRestarts: 1)
        _ = policy.decide(armed: true, verdict: .deaf(gap: 9), now: t0)
        XCTAssertEqual(policy.decide(armed: true, verdict: .deaf(gap: 9), now: t0.addingTimeInterval(1)), .giveUp)

        policy.reset()
        XCTAssertEqual(policy.decide(armed: true, verdict: .deaf(gap: 9), now: t0.addingTimeInterval(2)), .restart)
    }
}
