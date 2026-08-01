import Foundation
import XCTest
@testable import WhisperM8

/// Der Watchdog ist die Antwort auf einen konkreten Vorfall (01.08.2026): Die
/// App stand endlos, und der Stall-Monitor schwieg — weil er selbst auf dem
/// blockierten Thread lief und eine Blockade erst NACH ihrem Ende melden kann.
/// Diese Tests halten fest, dass laufende Blockaden gemeldet werden und das
/// Log dabei nicht überläuft.
final class StallWatchdogTests: XCTestCase {

    // MARK: - Melde-Entscheidung (rein)

    func testUnterhalbDerSchwelleWirdNichtGemeldet() {
        XCTAssertFalse(StallWatchdog.shouldReport(elapsed: 0.4, lastReported: nil))
        XCTAssertFalse(StallWatchdog.shouldReport(elapsed: 0.99, lastReported: nil))
    }

    func testErsteMeldungAbDerSchwelle() {
        XCTAssertTrue(StallWatchdog.shouldReport(elapsed: 1.0, lastReported: nil))
        XCTAssertTrue(StallWatchdog.shouldReport(elapsed: 3.2, lastReported: nil))
    }

    /// Ohne Staffelung würde eine endlose Blockade das Log viermal pro
    /// Sekunde vollschreiben.
    func testNachEinerMeldungErstWiederBeiVerdopplung() {
        XCTAssertFalse(StallWatchdog.shouldReport(elapsed: 1.5, lastReported: 1.0))
        XCTAssertFalse(StallWatchdog.shouldReport(elapsed: 1.9, lastReported: 1.0))
        XCTAssertTrue(StallWatchdog.shouldReport(elapsed: 2.0, lastReported: 1.0))
        XCTAssertTrue(StallWatchdog.shouldReport(elapsed: 8.0, lastReported: 4.0))
    }

    /// Zwei Minuten Stillstand dürfen nur eine Handvoll Zeilen erzeugen.
    func testEndloseBlockadeErzeugtNurWenigeMeldungen() {
        var lastReported: TimeInterval?
        var meldungen = 0
        var elapsed: TimeInterval = 0
        while elapsed < 120 {
            elapsed += 0.25
            if StallWatchdog.shouldReport(elapsed: elapsed, lastReported: lastReported) {
                lastReported = elapsed
                meldungen += 1
            }
        }
        XCTAssertGreaterThan(meldungen, 4, "eine laufende Blockade MUSS mehrfach sichtbar sein")
        XCTAssertLessThan(meldungen, 12, "aber sie darf das Log nicht fluten — war: \(meldungen)")
    }

    // MARK: - Verhalten mit gesteuerter Uhr

    func testLaufendeBlockadeWirdWaehrendSieLaeuftGemeldet() {
        let watchdog = StallWatchdog()
        var clock: TimeInterval = 100
        watchdog.now = { clock }
        var gemeldet: [TimeInterval] = []
        watchdog.onBlock = { gemeldet.append($0) }

        watchdog.beat()          // Main Thread lebt
        clock += 0.5
        watchdog.check()
        XCTAssertTrue(gemeldet.isEmpty, "halbe Sekunde ist kein Stillstand")

        // Ab hier schlägt kein Herz mehr — die App steht.
        clock += 0.6             // 1,1 s ohne Herzschlag
        watchdog.check()
        XCTAssertEqual(gemeldet.count, 1)
        XCTAssertEqual(gemeldet.first ?? 0, 1.1, accuracy: 0.001)

        clock += 0.5             // 1,6 s — noch keine Verdopplung
        watchdog.check()
        XCTAssertEqual(gemeldet.count, 1)

        clock += 0.7             // 2,3 s — über der Verdopplung
        watchdog.check()
        XCTAssertEqual(gemeldet.count, 2)
    }

    func testHerzschlagSetztDieStaffelungZurueck() {
        let watchdog = StallWatchdog()
        var clock: TimeInterval = 500
        watchdog.now = { clock }
        var gemeldet: [TimeInterval] = []
        watchdog.onBlock = { gemeldet.append($0) }

        watchdog.beat()
        clock += 2.0
        watchdog.check()
        XCTAssertEqual(gemeldet.count, 1)

        // App reagiert wieder …
        watchdog.beat()
        clock += 0.5
        watchdog.check()
        XCTAssertEqual(gemeldet.count, 1, "kurz nach dem Herzschlag ist nichts zu melden")

        // … und blockiert erneut: die neue Blockade meldet wieder ab 1 s,
        // nicht erst ab der doppelten Dauer der vorherigen.
        clock += 0.6
        watchdog.check()
        XCTAssertEqual(gemeldet.count, 2)
        XCTAssertEqual(gemeldet.last ?? 0, 1.1, accuracy: 0.001)
    }
}
