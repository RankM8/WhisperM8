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

    func testSquareOnlyWithDraft() {
        XCTAssertTrue(labels(chat(.idle) { $0.draftSuspected = true }).contains(.clearInput))
        XCTAssertFalse(labels(chat(.idle)).contains(.clearInput))
        XCTAssertFalse(inputs(chat(.idle)).contains(.button(.square)))
        XCTAssertFalse(inputs(chat(.working) { $0.draftSuspected = true }).contains(.button(.square)))
    }

    func testEndedChatShowsNoTerminalKeys() {
        let shown = inputs(chat(.ended) { $0.draftSuspected = true })
        for input in [ControllerLegendInput.button(.cross), .button(.circle), .button(.square), .dpad] {
            XCTAssertFalse(shown.contains(input), "\(input)")
        }
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

    func testRecordingLegend() {
        XCTAssertEqual(labels(.recording(phase: .recording, targetIsChat: true)),
                       [.stopDictation, .stopAndSend, .discard, .outputMode])
        XCTAssertEqual(labels(.recording(phase: .recording, targetIsChat: false)),
                       [.stopDictation, .discard, .outputMode])
        XCTAssertEqual(labels(.recording(phase: .transcribing, targetIsChat: true)), [.cancel])
    }

    func testPausedAndOutsideApp() {
        XCTAssertEqual(ControllerLegend.entries(for: .paused),
                       [ControllerLegendEntry(inputs: [.bumpers], label: .resume)])
        XCTAssertEqual(ControllerLegend.entries(for: .outsideApp(backgroundEnabled: false)), [])
        XCTAssertEqual(labels(.outsideApp(backgroundEnabled: true)), [.dictate, .bringToFront, .clipboard])
    }

    func testListAndModal() {
        XCTAssertEqual(labels(.list), [.move, .open, .back, .filter, .newChat, .nextWaiting, .dictate])
        XCTAssertEqual(labels(.modal), [.arrows, .confirm, .back, .dictate], "Dreieck wirkt unter Dialogen nicht")
        XCTAssertTrue(labels(.otherWindow).contains(.nextWaiting))
    }

    func testClipboardShowsDeleteHold() {
        XCTAssertEqual(labels(.clipboardPanel), [.move, .paste, .pin, .deleteHold, .close])
    }

    func testAllBindingsHasCoreAndExtra() {
        let sections = ControllerLegend.allBindings()
        XCTAssertEqual(sections.map(\.kind), [.core, .extra])
        XCTAssertEqual(sections[0].entries.count, 9)
        XCTAssertEqual(sections[1].entries.count, 9)
        XCTAssertTrue(sections[1].entries.contains {
            $0.label == .pickAndDictate && $0.isCombination && $0.inputs == [.button(.l2), .button(.r2)]
        })
    }

    /// Jede Zeile der Einstellungsseite wirkt in mindestens einem Zusammenhang.
    func testAllBindingsAreBacked() {
        let contexts = representativeContexts + [.chatPicker, chat(.idle) { $0.draftSuspected = true }]
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
