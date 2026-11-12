import Foundation
import XCTest
@testable import WhisperM8

/// Vorrang der Zusammenhänge (Plan 3.1).
final class ControllerContextResolverTests: XCTestCase {
    private let chat = ControllerChatState(status: .idle, profile: .claude)

    private func context(_ configure: (inout ControllerAppSnapshot) -> Void) -> ControllerContext {
        var snapshot = ControllerAppSnapshot(chat: chat)
        configure(&snapshot)
        return ControllerContextResolver.context(for: snapshot)
    }

    func testDefaultIsChat() {
        XCTAssertEqual(context { _ in }, .chat(chat))
    }

    func testPausedBeatsEverything() {
        XCTAssertEqual(context {
            $0.isPaused = true
            $0.recordingPhase = .recording
            $0.quickActionRunning = true
            $0.clipboardPanelOpen = true
            $0.appIsActive = false
        }, .paused)
    }

    func testRecordingBeatsQuickActionClipboardAndOutsideApp() {
        XCTAssertEqual(context {
            $0.recordingPhase = .transcribing
            $0.recordingTargetIsChat = true
            $0.quickActionRunning = true
            $0.clipboardPanelOpen = true
            $0.appIsActive = false
        }, .recording(phase: .transcribing, targetIsChat: true))
    }

    func testQuickActionBeatsClipboard() {
        XCTAssertEqual(context {
            $0.quickActionRunning = true
            $0.clipboardPanelOpen = true
        }, .quickAction)
    }

    func testClipboardPanelBeatsOutsideApp() {
        XCTAssertEqual(context {
            $0.clipboardPanelOpen = true
            $0.appIsActive = false
        }, .clipboardPanel(ControllerClipboardState()))
    }

    func testOutsideAppCarriesBackgroundFlag() {
        XCTAssertEqual(context {
            $0.appIsActive = false
            $0.backgroundEnabled = true
            $0.window = .none
        }, .outsideApp(backgroundEnabled: true))
        XCTAssertEqual(context { $0.appIsActive = false }, .outsideApp(backgroundEnabled: false))
    }

    func testWindowKindsBeatMenuModalAndList() {
        XCTAssertEqual(context {
            $0.window = .none
            $0.controllerMenuOpen = true
            $0.modalOpen = true
        }, .noWindow)
        XCTAssertEqual(context {
            $0.window = .other
            $0.controllerMenuOpen = true
            $0.area = .list
        }, .otherWindow)
    }

    func testMenuBeatsModalAndCarriesDialogState() {
        XCTAssertEqual(context {
            $0.controllerMenuOpen = true
            $0.modalOpen = true
        }, .menu(dialogOpen: false))
        var asking = chat
        asking.status = .awaitingInput
        XCTAssertEqual(context {
            $0.controllerMenuOpen = true
            $0.chat = asking
        }, .menu(dialogOpen: true))
    }

    func testModalBeatsList() {
        XCTAssertEqual(context {
            $0.modalOpen = true
            $0.area = .list
        }, .modal)
        XCTAssertEqual(context { $0.area = .list }, .list)
    }

    func testContentWithoutChatFallsBackToList() {
        XCTAssertEqual(context { $0.chat = nil }, .list)
    }
}
