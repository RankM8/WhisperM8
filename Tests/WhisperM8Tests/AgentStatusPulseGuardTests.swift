import XCTest
@testable import WhisperM8

/// LR-AU-002: Dauer-Pulse (`repeatForever`) halten die Layout-Schleife des
/// ganzen Fensters am Laufen. Im Ruhig-Modus (Default) darf es sie nicht geben —
/// sie existieren nur noch hinter dem A/B-Schalter `agentStatusPulseEnabled`.
final class AgentStatusPulseGuardTests: XCTestCase {
    private func source(_ relativePath: String) throws -> [String] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("WhisperM8/Views/\(relativePath)"), encoding: .utf8)
        return text.components(separatedBy: "\n")
    }

    func testPulseSwitchDefaultsToOff() throws {
        let suite = "whisperm8-pulse-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = AppPreferences(defaults: defaults)
        XCTAssertFalse(prefs.isAgentStatusPulseEnabled)
        defaults.set(true, forKey: "agentStatusPulseEnabled")
        XCTAssertTrue(prefs.isAgentStatusPulseEnabled)
    }

    /// Kachelkopf, Chat-Kopf, Tab-Leiste und Grid haben keinen eigenen Dauer-Puls.
    func testNoRepeatForeverInHeaderTabAndGridViews() throws {
        for file in ["AgentChatChromeViews.swift", "AgentChatsView+Grid.swift", "AgentChatsView.swift", "AgentChatsSidebarViews.swift"] {
            let lines = try source(file)
            XCTAssertFalse(lines.contains { $0.contains("repeatForever") }, "\(file) enthält repeatForever")
        }
    }

    /// Die verbliebenen Dauer-Animationen hängen an `continuous` bzw. dem Schalter.
    func testRemainingRepeatForeverIsGatedBySwitch() throws {
        for file in ["AgentStatusIndicator.swift", "Transcript/TimelinePulsingDot.swift"] {
            let lines = try source(file)
            for (index, line) in lines.enumerated() where line.contains("repeatForever") {
                let context = lines[max(0, index - 8)...index].joined(separator: "\n")
                XCTAssertTrue(
                    context.contains("continuous"),
                    "\(file):\(index + 1) repeatForever ohne Schalter-Gate"
                )
            }
        }
    }

    /// Das 30-fps-Lauflicht des Subagent-Chips läuft nur mit Schalter.
    func testSubagentRoadTimelineViewIsGated() throws {
        let lines = try source("AgentChatsSidebarViews.swift")
        let index = try XCTUnwrap(lines.firstIndex { $0.contains("TimelineView(.animation") })
        let context = lines[max(0, index - 6)...index].joined(separator: "\n")
        XCTAssertTrue(context.contains("AgentStatusPulse.continuousEnabled"))
    }
}

/// Sanfter Puls über Core Animation (19.10.2026): bewegt sich, ohne SwiftUI pro
/// Frame neu auszuwerten — gedrosselt, pausiert verdeckt, respektiert
/// „Bewegung reduzieren“.
@MainActor
final class SoftPulseRingTests: XCTestCase {
    func testSoftPulseIsDefaultOnWithKillSwitch() throws {
        let suite = "whisperm8-softpulse-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = AppPreferences(defaults: defaults)
        XCTAssertTrue(prefs.isAgentStatusSoftPulseEnabled)
        defaults.set(false, forKey: "agentStatusSoftPulseEnabled")
        XCTAssertFalse(prefs.isAgentStatusSoftPulseEnabled)
    }

    func testAnimationIsThrottledAndRepeatsInRenderServer() {
        let style = SoftPulseRingView.Style(color: .systemGreen, maxScale: 2.7, duration: 2.7, filled: true, startOpacity: 0.45)
        let animation = SoftPulseRingView.makeAnimation(style)
        XCTAssertEqual(animation.repeatCount, .infinity)
        XCTAssertLessThanOrEqual(animation.preferredFrameRateRange.maximum, 15)
        XCTAssertEqual(animation.duration, 2.7)
    }

    func testPausesWhenHiddenOrReduceMotion() {
        XCTAssertTrue(SoftPulseRingView.shouldAnimate(windowVisible: true, reduceMotion: false))
        XCTAssertFalse(SoftPulseRingView.shouldAnimate(windowVisible: false, reduceMotion: false))
        XCTAssertFalse(SoftPulseRingView.shouldAnimate(windowVisible: true, reduceMotion: true))
    }
}
