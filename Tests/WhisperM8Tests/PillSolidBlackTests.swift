import AppKit
import Combine
import SwiftUI
import XCTest
@testable import WhisperM8

/// Einstellung „Tiefschwarzer Hintergrund“ der vereinten Pille: Standard aus,
/// eine reine Entscheidungsstelle (`PillSurface`), ein Live-Wert, der sofort
/// umschaltet (`PillAppearance`), und im Bild wirklich deckendes Schwarz nur
/// dort, wo die vereinte Pille zeichnet.
@MainActor
final class PillSolidBlackTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "PillSolidBlackTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    // MARK: Entscheidung

    func testSurfaceIsBlackOnlyForTheUnifiedPillWithTheSettingOn() {
        XCTAssertEqual(PillSurface.resolve(unified: true, solidBlack: true), .solidBlack)
        XCTAssertEqual(PillSurface.resolve(unified: true, solidBlack: false), .glass)
        XCTAssertEqual(PillSurface.resolve(unified: false, solidBlack: true), .glass)
        XCTAssertEqual(PillSurface.resolve(unified: false, solidBlack: false), .glass)
    }

    func testSettingIsOffByDefault() {
        let prefs = AppPreferences(defaults: defaults)
        XCTAssertFalse(prefs.isPillSolidBlackEnabled)
        XCTAssertFalse(PillAppearance.isSolidBlack(prefs))
    }

    func testSolidBlackNeedsTheUnifiedPill() {
        let prefs = AppPreferences(defaults: defaults)
        prefs.isPillSolidBlackEnabled = true
        XCTAssertTrue(PillAppearance.isSolidBlack(prefs))
        prefs.isUnifiedPillEnabled = false
        XCTAssertFalse(PillAppearance.isSolidBlack(prefs), "Kill-Switch aus: getrennte Pillen bleiben Glas")
    }

    // MARK: Live-Wert

    func testAppearanceSwitchesOnPreferenceChangeAndOnlyReportsRealChanges() {
        let center = NotificationCenter()
        let prefs = AppPreferences(defaults: defaults)
        let appearance = PillAppearance(read: { PillAppearance.isSolidBlack(prefs) }, center: center)
        XCTAssertFalse(appearance.isSolidBlack)

        var changes = 0
        let subscription = appearance.objectWillChange.sink { changes += 1 }
        defer { subscription.cancel() }

        prefs.isPillSolidBlackEnabled = true
        center.post(name: UserDefaults.didChangeNotification, object: defaults)
        XCTAssertTrue(appearance.isSolidBlack)
        XCTAssertEqual(changes, 1)

        // Andere Preference geändert: kein neues Zeichnen der Pillen.
        center.post(name: UserDefaults.didChangeNotification, object: defaults)
        XCTAssertEqual(changes, 1)

        prefs.isPillSolidBlackEnabled = false
        center.post(name: UserDefaults.didChangeNotification, object: defaults)
        XCTAssertFalse(appearance.isSolidBlack)
        XCTAssertEqual(changes, 2)
    }

    // MARK: Bild

    private static let desk = Color(red: 0.5, green: 0.6, blue: 0.7)

    /// Anzahl Pixel in reinem Schwarz (#000, deckend).
    private func blackPixels(_ view: some View, size: CGSize, solidBlack: Bool) throws -> Int {
        let png = try ViewSnapshotRenderer.pngData(
            view.environment(\.pillSolidBlackOverride, solidBlack),
            size: size, appearance: .dark, background: Self.desk, scale: 2, settle: 0)
        let image = try XCTUnwrap(NSBitmapImageRep(data: png))
        let data = try XCTUnwrap(image.bitmapData)
        let bytesPerPixel = image.bitsPerPixel / 8
        var count = 0
        for y in 0..<image.pixelsHigh {
            for x in 0..<image.pixelsWide {
                let offset = y * image.bytesPerRow + x * bytesPerPixel
                if data[offset] == 0, data[offset + 1] == 0, data[offset + 2] == 0 { count += 1 }
            }
        }
        return count
    }

    private func assertBlackOnlyWhenOn(_ view: some View, size: CGSize, _ what: String) throws {
        let on = try blackPixels(view, size: size, solidBlack: true)
        let off = try blackPixels(view, size: size, solidBlack: false)
        XCTAssertGreaterThan(on, 3000, "\(what): an, aber keine schwarze Fläche")
        XCTAssertLessThan(off, on / 10, "\(what): aus, aber trotzdem schwarz")
    }

    private func statusDisplay(expanded: Bool) -> NotchDisplay {
        NotchDisplay(
            style: .pill, summary: NotchSummary(working: 2, waiting: 1), alert: nil, isExpanded: expanded,
            sections: [])
    }

    func testStatusPillAtRestTurnsBlack() throws {
        try assertBlackOnlyWhenOn(
            UnifiedStatusPillView(display: statusDisplay(expanded: false)),
            size: CGSize(width: UnifiedPillGeometry.statusPanelWidth, height: 88), "Status-Pille in Ruhe")
    }

    func testStatusListTurnsBlack() throws {
        try assertBlackOnlyWhenOn(
            UnifiedStatusPillView(display: statusDisplay(expanded: true)),
            size: CGSize(width: UnifiedPillGeometry.statusPanelWidth, height: 200), "Status-Liste")
    }

    func testDictationPillTurnsBlack() throws {
        let controller = OverlayController(presentsWindow: false)
        controller.presentation = .pill
        try assertBlackOnlyWhenOn(
            RecordingOverlayView(controller: controller).environment(\.colorScheme, .dark),
            size: OverlayFrameResolver.panelSize, "Diktat-Pille")
    }

    func testClassicDictationPillStaysGlass() throws {
        let controller = OverlayController(presentsWindow: false)
        controller.presentation = .classic
        let view = RecordingOverlayView(controller: controller).environment(\.colorScheme, .dark)
        let on = try blackPixels(view, size: OverlayFrameResolver.panelSize, solidBlack: true)
        let off = try blackPixels(view, size: OverlayFrameResolver.panelSize, solidBlack: false)
        XCTAssertEqual(on, off, "getrennte Diktat-Pille darf sich nicht ändern")
    }

    func testControllerIslandWithoutNotchTurnsBlack() throws {
        let model = ControllerIslandModel(
            target: ControllerIslandTarget(title: "Controller Insel", status: .idle),
            content: .writing(ControllerWritingSlots(state: ControllerChatState(status: .idle, profile: .claude))))
        try assertBlackOnlyWhenOn(
            ControllerIslandView(display: ControllerIslandDisplay(style: .pill, model: model))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top),
            size: CGSize(width: 520, height: 230), "Controller-Insel")
    }
}
