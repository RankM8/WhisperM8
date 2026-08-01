import XCTest
@testable import WhisperM8

/// Sichert das zweistufige Messgeruest ab (Paket A4).
///
/// Der Kern der Absicherung ist nicht „misst es richtig", sondern **„kostet es
/// nichts, wenn es aus ist"**. Ein Messgeruest, das die App verlangsamt, misst
/// sich am Ende selbst.
final class PerformanceInstrumentationTests: XCTestCase {
    private var savedGate: Bool!

    override func setUp() {
        super.setUp()
        savedGate = PerfDetailGate.isEnabled
    }

    override func tearDown() {
        PerfDetailGate.isEnabled = savedGate
        super.tearDown()
    }

    // MARK: - Stufen-Gate

    /// Stufe-1-Messpunkte laufen immer — auch bei abgeschalteter Detail-Stufe.
    /// Sie sind der Grund, warum im Alltag ueberhaupt Budget-Warnungen
    /// auftauchen, ohne dass jemand etwas einschalten muss.
    func testAlwaysTierMeasuresEvenWhenDetailDisabled() {
        PerfDetailGate.isEnabled = false
        var violations: [(String, TimeInterval)] = []
        var clock = Date(timeIntervalSince1970: 0)

        var budget = PerformanceBudget(name: "test.always", budget: 0.010, signposter: PerfSignposts.store)
        budget.tier = .always
        budget.now = { clock }
        budget.onViolation = { violations.append(($0, $1)) }

        XCTAssertTrue(budget.isActive)
        let token = budget.begin()
        clock = clock.addingTimeInterval(0.050)
        budget.end(token)

        XCTAssertEqual(violations.count, 1)
        XCTAssertEqual(violations.first?.1 ?? 0, 0.050, accuracy: 0.0001)
    }

    /// Detail-Messpunkte schweigen komplett, wenn die Stufe aus ist — kein
    /// Signpost, keine Zeitmessung, keine Budget-Bewertung.
    func testDetailTierIsSilentWhenDisabled() {
        PerfDetailGate.isEnabled = false
        var violations: [(String, TimeInterval)] = []
        var clock = Date(timeIntervalSince1970: 0)

        var budget = PerformanceBudget(name: "test.detail", budget: 0.010, signposter: PerfSignposts.store)
        budget.tier = .detail
        budget.now = { clock }
        budget.onViolation = { violations.append(($0, $1)) }

        XCTAssertFalse(budget.isActive)
        let token = budget.begin()
        clock = clock.addingTimeInterval(5.0)   // weit ueber Budget
        budget.end(token)

        XCTAssertTrue(violations.isEmpty, "Ein abgeschalteter Detail-Messpunkt darf nichts melden")
    }

    /// Dieselbe Messung meldet, sobald die Detail-Stufe an ist.
    func testDetailTierMeasuresWhenEnabled() {
        PerfDetailGate.isEnabled = true
        var violations: [(String, TimeInterval)] = []
        var clock = Date(timeIntervalSince1970: 0)

        var budget = PerformanceBudget(name: "test.detail", budget: 0.010, signposter: PerfSignposts.store)
        budget.tier = .detail
        budget.now = { clock }
        budget.onViolation = { violations.append(($0, $1)) }

        XCTAssertTrue(budget.isActive)
        let token = budget.begin()
        clock = clock.addingTimeInterval(0.020)
        budget.end(token)

        XCTAssertEqual(violations.count, 1)
    }

    /// Bestehende Messpunkte duerfen sich durch die neue Stufe nicht aendern:
    /// ohne explizites `tier` gilt `.always`.
    func testDefaultTierIsAlways() {
        PerfDetailGate.isEnabled = false
        let budget = PerformanceBudget(name: "test.default", budget: 0.010, signposter: PerfSignposts.store)
        XCTAssertEqual(budget.tier, .always)
        XCTAssertTrue(budget.isActive)
    }

    /// `end` bleibt idempotent, auch beim inaktiven Token — sonst waere das
    /// dokumentierte Safety-`defer` an den Aufrufstellen ein Fehler.
    func testEndIsIdempotentForInactiveToken() {
        PerfDetailGate.isEnabled = false
        var violations = 0
        var budget = PerformanceBudget(name: "test.detail", budget: 0.001, signposter: PerfSignposts.store)
        budget.tier = .detail
        budget.onViolation = { _, _ in violations += 1 }

        let token = budget.begin()
        budget.end(token)
        budget.end(token)
        budget.cancel(token)
        XCTAssertEqual(violations, 0)
    }

    /// Ein abgebrochener Stufe-1-Messpunkt wird NICHT gegen sein Budget
    /// bewertet — sonst erzeugte jede verworfene Messung Fehlalarme.
    func testCancelSkipsBudgetEvaluation() {
        PerfDetailGate.isEnabled = false
        var violations = 0
        var clock = Date(timeIntervalSince1970: 0)
        var budget = PerformanceBudget(name: "test.always", budget: 0.001, signposter: PerfSignposts.store)
        budget.now = { clock }
        budget.onViolation = { _, _ in violations += 1 }

        let token = budget.begin()
        clock = clock.addingTimeInterval(5.0)
        budget.cancel(token)
        XCTAssertEqual(violations, 0)
    }

    /// Das inaktive Token ist EIN geteiltes Objekt (spart Allokationen in
    /// dichten Pfaden). Deshalb darf es nie beschrieben werden — sonst gaelte
    /// es nach dem ersten `end` global als beendet, und ein spaeter
    /// eingeschalteter Messpunkt bekaeme ein „verbrauchtes" Token.
    func testInactiveTokenIsSharedAndNeverConsumed() {
        PerfDetailGate.isEnabled = false
        var budget = PerformanceBudget(name: "test.detail", budget: 0.001, signposter: PerfSignposts.store)
        budget.tier = .detail

        let first = budget.begin()
        budget.end(first)          // wuerde `ended` setzen, wenn die Reihenfolge kippt
        budget.cancel(first)

        let second = budget.begin()
        XCTAssertTrue(first === second, "Inaktive Tokens sollen dasselbe Objekt sein")

        // Der entscheidende Punkt: nach beliebig vielen end/cancel muss ein
        // frisch aktivierter Messpunkt weiterhin sauber messen koennen.
        PerfDetailGate.isEnabled = true
        var violations = 0
        var clock = Date(timeIntervalSince1970: 0)
        var active = PerformanceBudget(name: "test.detail", budget: 0.001, signposter: PerfSignposts.store)
        active.tier = .detail
        active.now = { clock }
        active.onViolation = { _, _ in violations += 1 }

        let token = active.begin()
        clock = clock.addingTimeInterval(0.5)
        active.end(token)
        XCTAssertEqual(violations, 1, "Nach Aktivierung muss wieder regulaer gemessen werden")
    }

    // MARK: - Zaehler

    /// Zaehlen bei abgeschalteter Detail-Stufe darf nicht abstuerzen und
    /// nichts tun — es steht in den heissesten Pfaden der App.
    func testCountersAreNoOpWhenDetailDisabled() {
        PerfDetailGate.isEnabled = false
        PerformanceCounters.shared.count(.terminalFeedChunk, bytes: 4096)
        PerformanceCounters.shared.reportPending(bytes: 99_999)
        // Kein beobachtbarer Effekt — der Test sichert, dass der Pfad
        // erreichbar und absturzfrei bleibt.
    }

    /// Aus vielen Threads gleichzeitig zaehlen darf nicht zu Datenschaeden
    /// fuehren; `dataReceived` laeuft zwar auf dem Main Thread, andere
    /// Zaehlstellen aber nicht zwingend.
    func testCountersSurviveConcurrentUse() {
        PerfDetailGate.isEnabled = true
        let done = expectation(description: "concurrent counting")
        done.expectedFulfillmentCount = 8
        for _ in 0..<8 {
            DispatchQueue.global().async {
                for _ in 0..<500 {
                    PerformanceCounters.shared.count(.terminalFeedChunk, bytes: 16)
                    PerformanceCounters.shared.reportPending(bytes: 32)
                }
                done.fulfill()
            }
        }
        wait(for: [done], timeout: 10)
    }

    // MARK: - Stillstands-Waechter

    /// Ein regulaerer Tick im Soll-Abstand ist kein Stillstand.
    @MainActor
    func testStallMonitorIgnoresOnTimeTicks() {
        let monitor = MainThreadStallMonitor.shared
        // Singleton: den Stand aus einem vorherigen Test verwerfen, sonst
        // waere der erste Tick hier schon eine Messung gegen dessen Uhr.
        monitor.stop()
        var clock = Date(timeIntervalSince1970: 1000)
        var stalls: [TimeInterval] = []
        monitor.now = { clock }
        monitor.onStall = { stalls.append($0) }
        defer { monitor.now = Date.init; monitor.onStall = nil }

        monitor.tick()                                  // setzt den Startpunkt
        clock = clock.addingTimeInterval(0.1)           // exakt im Soll
        monitor.tick()
        clock = clock.addingTimeInterval(0.13)          // 30 ms Verzug, unter Schwelle
        monitor.tick()

        XCTAssertTrue(stalls.isEmpty)
    }

    /// Bleibt der Tick aus, ist die Verspaetung die Blockadedauer — das ist
    /// die Zahl, die „die App stand still" beziffert.
    @MainActor
    func testStallMonitorReportsDelayAsStallDuration() {
        let monitor = MainThreadStallMonitor.shared
        // Singleton: den Stand aus einem vorherigen Test verwerfen, sonst
        // waere der erste Tick hier schon eine Messung gegen dessen Uhr.
        monitor.stop()
        var clock = Date(timeIntervalSince1970: 2000)
        var stalls: [TimeInterval] = []
        monitor.now = { clock }
        monitor.onStall = { stalls.append($0) }
        defer { monitor.now = Date.init; monitor.onStall = nil }

        monitor.tick()
        clock = clock.addingTimeInterval(0.85)          // Soll 0,1 → 0,75 s Blockade
        monitor.tick()

        XCTAssertEqual(stalls.count, 1)
        XCTAssertEqual(stalls.first ?? 0, 0.75, accuracy: 0.0001)
    }

    /// Ein langer Stillstand wird ebenfalls gemeldet (im Betrieb sofort und
    /// als Fehler, damit er im Log neben seinem Verursacher steht).
    @MainActor
    func testStallMonitorReportsFreeze() {
        let monitor = MainThreadStallMonitor.shared
        // Singleton: den Stand aus einem vorherigen Test verwerfen, sonst
        // waere der erste Tick hier schon eine Messung gegen dessen Uhr.
        monitor.stop()
        var clock = Date(timeIntervalSince1970: 3000)
        var stalls: [TimeInterval] = []
        monitor.now = { clock }
        monitor.onStall = { stalls.append($0) }
        defer { monitor.now = Date.init; monitor.onStall = nil }

        monitor.tick()
        clock = clock.addingTimeInterval(2.6)           // 2,5 s eingefroren
        monitor.tick()

        XCTAssertEqual(stalls.count, 1)
        XCTAssertEqual(stalls.first ?? 0, 2.5, accuracy: 0.0001)
    }
}
