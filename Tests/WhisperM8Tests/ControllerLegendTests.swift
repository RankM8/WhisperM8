import Foundation
import XCTest
@testable import WhisperM8

/// Legende gegen die Belegung: Was die Legende zeigt, wirkt auch.
final class ControllerLegendTests: XCTestCase {
    private func chat(
        _ status: ControllerChatState.Status, _ configure: (inout ControllerChatState) -> Void = { _ in }
    ) -> ControllerContext {
        var state = ControllerChatState(status: status, profile: .claude)
        configure(&state)
        return .chat(state)
    }

    private var representativeContexts: [ControllerContext] {
        ControllerBindingMatrixTests.expectations.map(\.context)
    }

    private func labels(_ context: ControllerContext) -> [ControllerLegendLabel] {
        ControllerLegend.entries(for: context).map(\.label)
    }

    private func inputs(_ context: ControllerContext) -> Set<ControllerLegendInput> {
        Set(ControllerLegend.entries(for: context).flatMap(\.inputs))
    }

    func testEveryShownEntryHasAnEffect() {
        for context in representativeContexts {
            for entry in ControllerLegend.entries(for: context) {
                let acts = entry.inputs
                    .flatMap(ControllerLegend.gestures(for:))
                    .contains { ControllerBindingResolver.action(for: $0, in: context) != nil }
                XCTAssertTrue(acts, "\(context): \(entry.label) ohne Wirkung")
            }
        }
    }

    /// Runde 2: Viereck ist die Rücktaste, in jedem lebenden Zustand.
    func testSquareIsBackspaceWhileChatLives() {
        for status in [ControllerChatState.Status.idle, .working, .awaitingInput, .unknown] {
            XCTAssertTrue(labels(chat(status)).contains(.backspace), "\(status)")
        }
        XCTAssertFalse(inputs(chat(.ended)).contains(.button(.square)))
    }

    /// Runde 2: Bei gestopptem Chat zeigt Kreuz „Start“.
    func testEndedChatShowsStartButNoTerminalKeys() {
        let shown = inputs(chat(.ended) { $0.draftSuspected = true })
        for input in [ControllerLegendInput.button(.circle), .button(.square)] {
            XCTAssertFalse(shown.contains(input), "\(input)")
        }
        XCTAssertFalse(labels(chat(.ended)).contains(.arrows), "Steuerkreuz bewegt nur noch")
        XCTAssertTrue(labels(chat(.ended)).contains(.start))
        XCTAssertTrue(labels(chat(.working) { $0.hasTerminal = false }).contains(.start))
        XCTAssertFalse(labels(chat(.idle)).contains(.start))
        XCTAssertTrue(shown.contains(.leftStick))
        XCTAssertTrue(shown.contains(.rightStick))
        XCTAssertTrue(shown.contains(.button(.triangle)))
    }

    func testCrossLabelFollowsChatState() {
        XCTAssertTrue(labels(chat(.idle)).contains(.send))
        let asking = labels(chat(.awaitingInput) { $0.secondsSinceAwaitingBegan = 3 })
        XCTAssertTrue(asking.contains(.confirm))
        XCTAssertTrue(asking.contains(.reject))
        XCTAssertFalse(asking.contains(.send))
        // In der Sperrzeit nach einer neuen Rückfrage fehlt Kreuz.
        XCTAssertFalse(inputs(chat(.awaitingInput) { $0.secondsSinceAwaitingBegan = 0.1 }).contains(.button(.cross)))
    }

    func testCircleLabelFollowsChatState() {
        XCTAssertTrue(labels(chat(.idle)).contains(.back))
        XCTAssertFalse(labels(chat(.idle)).contains(.interruptHold))
        XCTAssertTrue(labels(chat(.working)).contains(.interruptHold))
        XCTAssertFalse(labels(chat(.working)).contains(.back))
    }

    /// Review-Befund 1: „Pfeiltasten“ nur bei einer Rückfrage; sonst steht
    /// das Steuerkreuz beim Bewegen neben dem Stick.
    func testArrowsOnlyWhileAgentAsks() {
        for status in [ControllerChatState.Status.idle, .working, .unknown] {
            XCTAssertFalse(labels(chat(status)).contains(.arrows), "\(status)")
            XCTAssertEqual(ControllerLegend.entries(for: chat(status)).first?.inputs, [.leftStick, .dpad])
        }
        let asking = chat(.awaitingInput) { $0.secondsSinceAwaitingBegan = 3 }
        XCTAssertTrue(labels(asking).contains(.arrows))
        XCTAssertEqual(ControllerLegend.entries(for: asking).first?.inputs, [.leftStick])
    }

    /// Runde 3: Der linke Stick steht in der Einzelansicht und im Raster als
    /// „Bewegen“ in der Legende, solange ein Diktat läuft aber nicht.
    func testLeftStickShownInChatButNotWhileDictating() {
        XCTAssertTrue(inputs(chat(.idle)).contains(.leftStick))
        XCTAssertTrue(inputs(chat(.idle) { $0.gridActive = true }).contains(.leftStick))
        for phase in ControllerRecordingPhase.allCases {
            XCTAssertFalse(inputs(.recording(phase: phase, targetIsChat: true)).contains(.leftStick), "\(phase)")
        }
        XCTAssertFalse(inputs(.quickAction).contains(.leftStick))
    }

    func testRecordingLegend() {
        XCTAssertEqual(labels(.recording(phase: .recording, targetIsChat: true)),
                       [.stopDictation, .stopAndSend, .discard, .outputMode, .scroll])
        XCTAssertEqual(labels(.recording(phase: .recording, targetIsChat: false)),
                       [.stopDictation, .discard, .outputMode, .scroll])
        XCTAssertEqual(labels(.recording(phase: .transcribing, targetIsChat: true)), [.cancel, .scroll])
    }

    func testPausedAndOutsideApp() {
        XCTAssertEqual(ControllerLegend.entries(for: .paused),
                       [ControllerLegendEntry(inputs: [.bumpers], label: .resume)])
        XCTAssertEqual(ControllerLegend.entries(for: .outsideApp(backgroundEnabled: false)), [])
        XCTAssertEqual(labels(.outsideApp(backgroundEnabled: true)), [.dictate, .bringToFront, .clipboard])
    }

    func testListAndModal() {
        XCTAssertEqual(labels(.list), [.move, .open, .back, .filter, .closeHold, .newChat, .nextWaiting, .dictate])
        XCTAssertEqual(labels(.modal), [.arrows, .confirm, .back, .dictate], "Dreieck wirkt unter Dialogen nicht")
        XCTAssertEqual(ControllerLegend.entries(for: .modal).first?.inputs, [.dpad, .leftStick])
        XCTAssertEqual(ControllerLegend.entries(for: .otherWindow).first?.inputs, [.dpad])
        XCTAssertTrue(labels(.otherWindow).contains(.nextWaiting))
    }

    /// Runde 3: Im Raster zeigt die Legende L2 als Workspace-Auswahl, in der
    /// Einzelansicht nicht.
    func testGridLegendShowsWorkspaceHold() {
        XCTAssertTrue(labels(chat(.idle) { $0.gridActive = true }).contains(.switchWorkspaceHold))
        XCTAssertFalse(labels(chat(.idle)).contains(.switchWorkspaceHold))
        XCTAssertEqual(labels(.workspacePicker), [.move, .select, .switchOnRelease, .cancel])
    }

    func testChatPickerShowsCrossSwitch() {
        XCTAssertEqual(labels(.chatPicker), [.move, .select, .switchOnRelease, .pickAndDictate, .cancel])
    }

    /// Runde 2: Die Fußzeile des Verlaufs kommt aus dieser Tabelle. „Geht
    /// nicht“ (Korrigieren ohne Text, Bild groß ohne Bild) zeigt sie nicht.
    func testClipboardEntriesFollowState() {
        XCTAssertEqual(labels(.clipboardPanel(ControllerClipboardState())),
                       [.move, .paste, .deleteHold, .clipboardFilter, .menu, .close])
        XCTAssertEqual(labels(.clipboardPanel(ControllerClipboardState(canCorrect: true, selectedIsImage: true))),
                       [.move, .paste, .correctAndPaste, .deleteHold, .clipboardFilter, .zoomImage, .menu, .close])
        XCTAssertEqual(labels(.clipboardPanel(ControllerClipboardState(isZoomed: true, selectedIsImage: true))),
                       [.move, .paste, .deleteHold, .zoomImage, .menu, .back])
        XCTAssertEqual(labels(.clipboardPanel(ControllerClipboardState(isConfirmingClear: true))), [.clearHistory, .cancel])
        XCTAssertEqual(labels(.clipboardPanel(ControllerClipboardState(menuOpen: true))), [.move, .select, .close])
    }

    func testMenuLegend() {
        XCTAssertEqual(labels(.menu(dialogOpen: false)), [.move, .select, .back, .close])
    }

    /// Runde 2: R3 erscheint nur bei gestopptem Chat.
    func testR3OnlyForStoppedChat() {
        XCTAssertTrue(labels(chat(.ended)).contains(.startChat))
        XCTAssertFalse(labels(chat(.idle)).contains(.startChat))
        XCTAssertFalse(labels(.list).contains(.startChat))
    }

    func testAllBindingsHasCoreAndExtra() {
        let sections = ControllerLegend.allBindings()
        XCTAssertEqual(sections.map(\.kind), [.core, .extra])
        XCTAssertEqual(sections[0].entries.count, 9)
        XCTAssertEqual(sections[1].entries.count, 12, "Runde 3: L2 halten im Raster = Workspace-Auswahl")
        XCTAssertEqual(sections[0].entries.first { $0.inputs == [.bumpers] }?.label, .previousNextChat)
        XCTAssertTrue(sections[1].entries.contains {
            $0.label == .pickAndDictate && $0.isCombination && $0.inputs == [.button(.l2), .button(.r2)]
        })
    }

    /// Jede Zeile der Einstellungsseite wirkt in mindestens einem Zusammenhang.
    func testAllBindingsAreBacked() {
        let contexts = representativeContexts + [.chatPicker, chat(.idle) { $0.draftSuspected = true }, chat(.ended)]
        for section in ControllerLegend.allBindings() {
            for entry in section.entries {
                let backed = contexts.contains { context in
                    entry.inputs.flatMap(ControllerLegend.gestures(for:))
                        .contains { ControllerBindingResolver.action(for: $0, in: context) != nil }
                }
                XCTAssertTrue(backed, "\(entry.label)")
            }
        }
    }
}
