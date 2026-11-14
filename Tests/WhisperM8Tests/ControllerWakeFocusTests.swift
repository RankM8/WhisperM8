import XCTest
@testable import WhisperM8

/// WM8-92: Nach dem Aufwecken aus einer anderen App hat das zuletzt aktive
/// Agent-Chats-Fenster die Tastatur, nicht ein daneben offenes
/// Einstellungsfenster (dort piepte jede Brücken-Taste).
@MainActor
final class ControllerWakeFocusTests: XCTestCase {
    private var log: [String] = []
    private var pendingWhenActive: [@MainActor () -> Void] = []
    private var pendingTimeout: [@MainActor () -> Void] = []

    private func focus(target: UUID?, makeKeySucceeds: Bool = true) -> ControllerWakeFocus {
        ControllerWakeFocus(
            targetWindowID: { target },
            makeKey: { [unowned self] id in
                log.append("makeKey \(id == target ? "target" : "other")")
                return makeKeySucceeds
            },
            openPrimary: { [unowned self] in log.append("openPrimary") },
            activate: { [unowned self] in log.append("activate") },
            whenActive: { [unowned self] block, timeout in
                log.append("whenActive")
                pendingWhenActive.append(block)
                pendingTimeout.append(timeout)
            }
        )
    }

    /// Das zuletzt aktive Fenster wird erst NACH der Aktivierung Key: macOS
    /// holt beim Aktivieren sonst sein zuletzt aktives Fenster nach vorn.
    func testKnownWindowBecomesKeyAfterActivation() {
        focus(target: UUID()).bringToFront()
        XCTAssertEqual(log, ["whenActive", "activate"], "erst warten, dann aktivieren")
        pendingWhenActive.forEach { $0() }
        XCTAssertEqual(log, ["whenActive", "activate", "makeKey target"])
        XCTAssertFalse(log.contains("openPrimary"), "kein zweites Fenster öffnen")
    }

    /// Gibt es das Fenster nicht mehr, gilt der bisherige Weg.
    func testVanishedWindowFallsBackToPrimary() {
        focus(target: UUID(), makeKeySucceeds: false).bringToFront()
        pendingWhenActive.forEach { $0() }
        XCTAssertEqual(log, ["whenActive", "activate", "makeKey target", "openPrimary"])
    }

    /// Wird die App nicht aktiv (Aktivierung verweigert), greift nach der Frist
    /// wenigstens der alte Weg.
    func testRefusedActivationFallsBackToPrimary() {
        focus(target: UUID()).bringToFront()
        pendingTimeout.forEach { $0() }
        XCTAssertEqual(log, ["whenActive", "activate", "openPrimary"])
    }

    func testWithoutKnownWindowOpensPrimaryAsBefore() {
        focus(target: nil).bringToFront()
        XCTAssertEqual(log, ["openPrimary"])
        XCTAssertTrue(pendingWhenActive.isEmpty)
    }
}
