import XCTest
@testable import WhisperM8

final class AgentAlertLevelTests: XCTestCase {
    private let settings = AgentStatusPreferences(
        hooksEnabled: true,
        stopNotificationEnabled: true,
        awaitingNotificationEnabled: true,
        stopSoundEnabled: true,
        stopSoundName: "Glass"
    )

    func testCyclesThroughAllThreeLevels() {
        XCTAssertEqual(AgentAlertLevel.all.next(soundStageHasEffect: true), .soundOff)
        XCTAssertEqual(AgentAlertLevel.soundOff.next(soundStageHasEffect: true), .off)
        XCTAssertEqual(AgentAlertLevel.off.next(soundStageHasEffect: true), .all)
    }

    func testSkipsSoundOffWhenNothingWouldBeMuted() {
        XCTAssertEqual(AgentAlertLevel.all.next(soundStageHasEffect: false), .off)
        XCTAssertEqual(AgentAlertLevel.soundOff.next(soundStageHasEffect: false), .off)
        XCTAssertEqual(AgentAlertLevel.off.next(soundStageHasEffect: false), .all)
    }

    func testAllKeepsSettingsUntouched() {
        var custom = settings
        custom.awaitingNotificationEnabled = false
        custom.stopSoundName = "Ping"
        let applied = AgentAlertLevel.all.applied(to: custom)
        XCTAssertFalse(applied.awaitingNotificationEnabled)
        XCTAssertTrue(applied.stopNotificationEnabled)
        XCTAssertTrue(applied.stopSoundEnabled)
        XCTAssertEqual(applied.stopSoundName, "Ping")
    }

    func testSoundOffMutesSoundButKeepsNotifications() {
        let applied = AgentAlertLevel.soundOff.applied(to: settings)
        XCTAssertFalse(applied.stopSoundEnabled)
        XCTAssertTrue(applied.stopNotificationEnabled)
        XCTAssertTrue(applied.awaitingNotificationEnabled)
        XCTAssertTrue(applied.hooksEnabled)
    }

    func testOffMutesSoundAndNotificationsButNeverHooks() {
        let applied = AgentAlertLevel.off.applied(to: settings)
        XCTAssertFalse(applied.stopSoundEnabled)
        XCTAssertFalse(applied.stopNotificationEnabled)
        XCTAssertFalse(applied.awaitingNotificationEnabled)
        XCTAssertTrue(applied.hooksEnabled)
    }

    func testStoredLevelDefaultsToAllAndSurvivesUnknownValues() throws {
        let suite = "agent-alert-level-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = AppPreferences(defaults: defaults)

        XCTAssertEqual(prefs.agentAlertLevel, .all)
        prefs.agentAlertLevel = .off
        XCTAssertEqual(prefs.agentAlertLevel, .off)
        defaults.set("kaputt", forKey: PreferenceKeys.agentAlertLevel)
        XCTAssertEqual(prefs.agentAlertLevel, .all)
    }
}
