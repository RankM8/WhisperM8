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
        XCTAssertFalse(shown.contains(.button(.triangle)), "Runde 3: kein Leerzeichen in einen gestoppten Chat")
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

    /// Seit 12.11.2026: In jedem lebenden Chat steht das Steuerkreuz als
    /// „Pfeiltasten“, der Stick allein bewegt. Ohne Terminal bewegt beides.
    func testArrowsInEveryLiveChat() {
        for status in [ControllerChatState.Status.idle, .working, .unknown, .awaitingInput] {
            XCTAssertTrue(labels(chat(status)).contains(.arrows), "\(status)")
            XCTAssertEqual(ControllerLegend.entries(for: chat(status)).first?.inputs, [.leftStick])
        }
        XCTAssertFalse(labels(chat(.ended)).contains(.arrows))
        XCTAssertEqual(ControllerLegend.entries(for: chat(.ended)).first?.inputs, [.leftStick, .dpad])
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

    /// Runde 3: Dreieck = Leerzeichen, R3 halten = Eingabe leeren (nicht bei
    /// Rückfragen); „nächster wartender Chat“ gibt es nicht mehr.
    func testWritingKeysInChatLegend() {
        let idle = labels(chat(.idle))
        XCTAssertTrue(idle.contains(.space))
        XCTAssertTrue(idle.contains(.clearInputHold))
        XCTAssertFalse(labels(chat(.awaitingInput) { $0.secondsSinceAwaitingBegan = 3 }).contains(.clearInputHold))
        XCTAssertFalse(labels(chat(.ended)).contains(.space))
        // Runde 4: Der nächste wartende Chat kam als L2 + Dreieck zurück, nicht als Dreieck allein.
        XCTAssertFalse(labels(chat(.idle)).contains(.nextWaiting))
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
        XCTAssertEqual(labels(.list), [.move, .open, .back, .filter, .closeHold, .newChat, .dictate])
        XCTAssertEqual(labels(.modal), [.arrows, .confirm, .back, .dictate], "Dreieck wirkt unter Dialogen nicht")
        XCTAssertEqual(ControllerLegend.entries(for: .modal).first?.inputs, [.dpad, .leftStick])
        XCTAssertEqual(ControllerLegend.entries(for: .otherWindow).first?.inputs, [.dpad])
        XCTAssertTrue(labels(.otherWindow).contains(.bringToFront))
    }

    /// Runde 4: Die Legende nennt die drei Ebenen in einem Eintrag, im Chat
    /// und im Raster; Tippen bleibt „voriger / nächster Chat“.
    func testChatLegendNamesTheLayers() {
        for context in [chat(.idle), chat(.idle) { $0.gridActive = true }, chat(.ended)] {
            let entries = ControllerLegend.entries(for: context)
            XCTAssertTrue(entries.contains(
                ControllerLegendEntry(inputs: [.button(.l1), .button(.r1), .button(.l2)], label: .layersHold)))
            XCTAssertTrue(entries.contains { $0.label == .previousNextChat })
        }
        XCTAssertFalse(labels(.list).contains(.layersHold), "in der Liste gibt es keine Ebenen")
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

    func testAllBindingsHasCoreExtraAndLayers() {
        let sections = ControllerLegend.allBindings()
        XCTAssertEqual(sections.map(\.kind), [.core, .extra, .layers])
        XCTAssertEqual(sections[0].entries.count, 9)
        XCTAssertEqual(sections[1].entries.count, 11, "Runde 4: L2 halten und L2 + R2 stehen bei den Ebenen")
        XCTAssertEqual(sections[0].entries.first { $0.inputs == [.bumpers] }?.label, .previousNextChat)
        // Alle drei Ebenen mit jeder Taste der Tabelle.
        XCTAssertEqual(sections[2].entries.map(\.label), [
            .deleteToLineStart, .newline, .continueWork, .cycleMode, .commands, .switchAccount,
            .whereToHold, .nextWaiting, .clipboardWithL2, .pickAndDictate,
        ])
        XCTAssertTrue(sections[2].entries.contains {
            $0.label == .pickAndDictate && $0.isCombination && $0.inputs == [.button(.l2), .button(.r2)]
        })
    }

    /// Touchpad als Maus: Die Belegung zeigt beim Touchpad den Zeiger; L2 +
    /// Touchpad (Verlauf) steht in beiden Fällen bei den Ebenen.
    func testTouchpadPointerBindings() {
        XCTAssertEqual(ControllerLegend.allBindings(touchpadPointer: false), ControllerLegend.allBindings())
        let sections = ControllerLegend.allBindings(touchpadPointer: true)
        XCTAssertTrue(sections[1].entries.contains(ControllerLegendEntry(inputs: [.button(.touchpad)], label: .pointer)))
        XCTAssertFalse(sections[1].entries.contains { $0.label == .clipboard })
        XCTAssertEqual(sections[2].entries.map(\.label), [
            .deleteToLineStart, .newline, .continueWork, .cycleMode, .commands, .switchAccount,
            .whereToHold, .nextWaiting, .clipboardWithL2, .pickAndDictate,
        ])
        // L2 + Touchpad wirkt im Chat, in der Liste, im Verlauf und außerhalb der App.
        let combo = sections[2].entries.first { $0.label == .clipboardWithL2 }!
        for context in [chat(.idle), .list, .clipboardPanel(ControllerClipboardState()),
                        .outsideApp(backgroundEnabled: true, wakeOnInput: true), .noWindow, .otherWindow] {
            let acts = ControllerLegend.probes(for: combo).contains {
                ControllerBindingResolver.action(for: $0, in: context) == .clipboardToggle
            }
            XCTAssertTrue(acts, "\(context)")
        }
        XCTAssertEqual(
            ControllerLegend.entries(for: .noWindow, touchpadPointer: true).last,
            ControllerLegendEntry(inputs: [.button(.l2), .button(.touchpad)], label: .clipboardWithL2, isCombination: true))
        XCTAssertEqual(ControllerLegend.entries(for: .noWindow).last?.label, .clipboard)
    }

    /// Jede Zeile der Einstellungsseite wirkt in mindestens einem Zusammenhang.
    func testAllBindingsAreBacked() {
        let contexts = representativeContexts + [chat(.idle) { $0.draftSuspected = true }, chat(.ended)]
        for section in ControllerLegend.allBindings() {
            for entry in section.entries {
                // Kombinationen mit einer Ebenen-Taste stehen für die zweite
                // Taste in dieser Ebene, und dort muss etwas passieren.
                let backed = contexts.contains { context in
                    ControllerLegend.probes(for: entry).contains { probe in
                        guard let action = ControllerBindingResolver.action(for: probe, in: context) else { return false }
                        return action != .rejected
                    }
                }
                XCTAssertTrue(backed, "\(entry.label)")
            }
        }
    }
}
