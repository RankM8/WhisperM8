import XCTest
@testable import WhisperM8

/// Familie des Controllers und was die Anzeige daraus macht (Plan
/// `controller-xbox-paddles.md`, Schritt 2).
final class ControllerFamilyTests: XCTestCase {
    func testClassifiesByCategoryText() {
        XCTAssertEqual(ControllerFamily.classify(productCategory: "Xbox One"), .xbox)
        XCTAssertEqual(ControllerFamily.classify(productCategory: "Xbox Series X"), .xbox)
        XCTAssertEqual(ControllerFamily.classify(productCategory: "DualSense"), .playStation)
        XCTAssertEqual(ControllerFamily.classify(productCategory: "DualShock 4"), .playStation)
        XCTAssertEqual(ControllerFamily.classify(productCategory: "Switch Pro Controller"), .generic)
    }

    func testOnlyXboxLacksTheTouchpad() {
        XCTAssertTrue(ControllerFamily.playStation.hasTouchpad)
        XCTAssertTrue(ControllerFamily.generic.hasTouchpad)
        XCTAssertFalse(ControllerFamily.xbox.hasTouchpad)
        XCTAssertFalse(ControllerInputTraits(family: .xbox).hasTouchpad)
        XCTAssertTrue(ControllerInputTraits(family: .xbox, hasTouchpad: true).hasTouchpad)
    }

    func testDeviceInfoDefaultsToPlayStation() {
        let info = ControllerDeviceInfo(name: "Pad", category: "DualSense", batteryLevel: nil, hasLight: true, hasHaptics: true)
        XCTAssertEqual(info.traits, .standard)
    }

    func testXboxNamesFollowThePosition() {
        XCTAssertEqual(ControllerButton.cross.glyph(.xbox), "A")
        XCTAssertEqual(ControllerButton.circle.glyph(.xbox), "B")
        XCTAssertEqual(ControllerButton.square.glyph(.xbox), "X")
        XCTAssertEqual(ControllerButton.triangle.glyph(.xbox), "Y")
        XCTAssertEqual(ControllerButton.l1.glyph(.xbox), "LB")
        XCTAssertEqual(ControllerButton.r2.glyph(.xbox), "RT")
        XCTAssertEqual(ControllerButton.l3.glyph(.xbox), "LS")
        XCTAssertEqual(ControllerButton.create.glyph(.xbox), "View")
        XCTAssertEqual(ControllerButton.options.glyph(.xbox), "Menu")
        XCTAssertEqual(ControllerButton.dpadUp.glyph(.xbox), "▲")
        // Allgemeine Gamepads behalten die PlayStation-Zeichen.
        XCTAssertEqual(ControllerButton.cross.glyph(.generic), "✕")
        XCTAssertEqual(ControllerButton.l1.glyph(.playStation), "L1")
    }

    func testExplanationsUseTheGlyphsOfTheFamily() {
        let xbox = ControllerLegendLabel.deleteToLineStart.explanation(.xbox)
        XCTAssertTrue(xbox.contains("LB"), xbox)
        XCTAssertTrue(xbox.contains("X"), xbox)
        XCTAssertFalse(xbox.contains("□"), xbox)
        XCTAssertTrue(ControllerLegendLabel.deleteToLineStart.explanation(.playStation).contains("□"))
    }

    // MARK: - Legende ohne Touchpad

    func testXboxLegendDropsTouchpadEntries() {
        let xbox = ControllerInputTraits(family: .xbox)
        let outside = ControllerContext.outsideApp(backgroundEnabled: true)
        XCTAssertTrue(ControllerLegend.entries(for: outside).contains { $0.inputs.contains(.button(.touchpad)) })
        XCTAssertFalse(ControllerLegend.entries(for: outside, traits: xbox).contains { $0.inputs.contains(.button(.touchpad)) })
        for section in ControllerLegend.allBindings(traits: xbox) {
            XCTAssertFalse(section.entries.contains { $0.inputs.contains(.button(.touchpad)) }, "\(section.kind)")
        }
        // Mit lesbarem Xbox-Knopf steht der Verlauf wieder da.
        let withButton = ControllerInputTraits(family: .xbox, hasTouchpad: true)
        XCTAssertEqual(ControllerLegend.allBindings(traits: withButton), ControllerLegend.allBindings())
    }

    func testOtherEntriesStayTheSameForXbox() {
        let chat = ControllerContext.chat(ControllerChatState(status: .idle, profile: .claude))
        XCTAssertEqual(ControllerLegend.entries(for: chat, traits: ControllerInputTraits(family: .xbox)),
                       ControllerLegend.entries(for: chat))
    }
}
