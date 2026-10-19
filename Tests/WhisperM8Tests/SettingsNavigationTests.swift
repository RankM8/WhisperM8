import XCTest
@testable import WhisperM8

/// LR-ONB-012: Einstellungen nach Launch-Klassen (Kern / Erweitert / Labs).
final class SettingsNavigationTests: XCTestCase {
    private func pages(_ groups: [SettingsPageGroup]) -> [SettingsPage] {
        groups.flatMap(\.pages)
    }

    func testDictationRawMainListHasNoAgentPages() {
        let visible = pages(SettingsNavigation.pageGroups(for: .dictationRaw, revealAgentPages: false))
        for page in SettingsNavigation.agentPages {
            XCTAssertFalse(visible.contains(page), "\(page) darf im Diktat-Profil nicht in der Hauptliste stehen")
        }
        XCTAssertTrue(visible.contains(.recording))
        XCTAssertTrue(visible.contains(.transcription))
        XCTAssertTrue(visible.contains(.general))
    }

    func testEveryPageReachableInEveryProfileWhenRevealed() {
        for profile in AppUsageProfile.allCases {
            let visible = Set(pages(SettingsNavigation.pageGroups(for: profile, revealAgentPages: true)))
            XCTAssertEqual(visible, Set(SettingsPage.allCases), "\(profile): Seiten gehen verloren")
        }
    }

    func testNoPageAppearsTwice() {
        for profile in AppUsageProfile.allCases {
            for reveal in [false, true] {
                let list = pages(SettingsNavigation.pageGroups(for: profile, revealAgentPages: reveal))
                XCTAssertEqual(list.count, Set(list).count)
            }
        }
    }

    func testGroupsAreOrderedCoreThenAdvancedThenLabs() {
        for profile in AppUsageProfile.allCases {
            let classes = SettingsNavigation.pageGroups(for: profile, revealAgentPages: true).map(\.launchClass)
            XCTAssertEqual(classes, classes.sorted(), "\(profile): Kern vor Erweitert vor Labs")
            XCTAssertEqual(classes.first, .core)
        }
    }

    func testGPTBackendOnlyLivesInLabsGroup() {
        for profile in AppUsageProfile.allCases {
            for reveal in [false, true] {
                for group in SettingsNavigation.pageGroups(for: profile, revealAgentPages: reveal)
                where group.pages.contains(.gptBackend) {
                    XCTAssertEqual(group.launchClass, .labs)
                }
            }
        }
        XCTAssertEqual(SettingsNavigation.launchClass(of: .gptBackend), .labs)
        XCTAssertEqual(SettingsNavigation.launchClass(of: .voiceGate), .labs)
        XCTAssertEqual(SettingsNavigation.launchClass(of: .jarvis), .labs)
    }

    func testLabsGroupIsClearlyLabelled() {
        let groups = SettingsNavigation.pageGroups(for: .full, revealAgentPages: false)
        XCTAssertEqual(groups.last?.launchClass, .labs)
        XCTAssertEqual(groups.last?.title, "Labs")
        XCTAssertTrue(groups.contains { $0.launchClass == .advanced && $0.title == "Advanced" })
    }

    func testFullProfileShowsAllPagesInMainList() {
        let visible = pages(SettingsNavigation.pageGroups(for: .full, revealAgentPages: false))
        XCTAssertEqual(Set(visible), Set(SettingsPage.allCases))
    }

    func testHiddenPageBecomesVisibleWhenSelected() {
        // Deep-Link auf eine ausgeblendete Seite (z. B. Route gpt-backend) klappt die Liste auf.
        XCTAssertTrue(SettingsNavigation.requiresReveal(.gptBackend, profile: .dictationRaw))
        XCTAssertFalse(SettingsNavigation.requiresReveal(.gptBackend, profile: .full))
        XCTAssertFalse(SettingsNavigation.requiresReveal(.recording, profile: .dictationRaw))
    }

    func testOldVoiceAgentRouteStillResolves() {
        XCTAssertEqual(SettingsRouteTarget.resolve(routeID: "voiceAgent")?.page, .voiceGate)
    }

    // MARK: - ChatGPT-Abo als Anbieter

    func testChatGPTHiddenWithoutBackendAndWithoutSelection() {
        let options = TranscriptionProvider.settingsOptions(killSwitchEnabled: true, backendEnabled: false, stored: .groq)
        XCTAssertFalse(options.contains(.chatgpt))
    }

    func testChatGPTOfferedWithBackend() {
        let options = TranscriptionProvider.settingsOptions(killSwitchEnabled: true, backendEnabled: true, stored: .groq)
        XCTAssertEqual(options, [.groq, .openai, .chatgpt])
    }

    func testStoredChatGPTSelectionIsNeverLost() {
        let options = TranscriptionProvider.settingsOptions(killSwitchEnabled: true, backendEnabled: false, stored: .chatgpt)
        XCTAssertTrue(options.contains(.chatgpt))
    }

    func testKillSwitchOffHidesChatGPTEverywhere() {
        for stored in TranscriptionProvider.allCases {
            let options = TranscriptionProvider.settingsOptions(killSwitchEnabled: false, backendEnabled: true, stored: stored)
            XCTAssertFalse(options.contains(.chatgpt))
        }
    }
}
