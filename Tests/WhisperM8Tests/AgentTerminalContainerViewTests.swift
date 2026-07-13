import AppKit
import XCTest
@testable import WhisperM8

/// Regressionstests für die fenster-gebundene Terminal-Adoption
/// (Grid-Maximize-Bug 2026-07-13: sichtbarer, aber leerer Container, weil
/// ein verworfener SwiftUI-Zwischen-Host das geteilte Terminal-NSView
/// ersatzlos aus der Hierarchie geworfen hat).
@MainActor
final class AgentTerminalContainerViewTests: XCTestCase {
    private var window: NSWindow!

    override func setUp() {
        super.setUp()
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
    }

    override func tearDown() {
        window = nil
        super.tearDown()
    }

    private func makeTerminal() -> QuietableTerminalView {
        QuietableTerminalView(frame: .zero)
    }

    func testDoesNotAdoptWhileDetachedFromWindow() {
        let container = AgentTerminalContainerView(frame: .zero)
        let terminal = makeTerminal()

        container.configure(terminal: terminal, sessionID: UUID())

        // Ohne Fenster keine Adoption — genau das verhindert, dass ein
        // verworfener Zwischen-Host das Terminal an sich zieht.
        XCTAssertNil(terminal.superview)
    }

    func testAdoptsTerminalOnWindowInsertion() {
        let container = AgentTerminalContainerView(frame: .zero)
        let terminal = makeTerminal()
        container.configure(terminal: terminal, sessionID: UUID())

        window.contentView?.addSubview(container)

        XCTAssertTrue(terminal.superview === container)
    }

    func testLayoutHealsAfterTerminalWasDropped() {
        let container = AgentTerminalContainerView(frame: .zero)
        let terminal = makeTerminal()
        container.configure(terminal: terminal, sessionID: UUID())
        window.contentView?.addSubview(container)
        XCTAssertTrue(terminal.superview === container)

        // Bug-Simulation: dismantleNSView eines fremden Hosts hat das
        // Terminal ersatzlos entfernt.
        terminal.removeFromSuperview()
        XCTAssertNil(terminal.superview)

        container.layout()

        XCTAssertTrue(terminal.superview === container)
    }

    func testLayoutReclaimsTerminalFromDetachedForeignContainer() {
        let container = AgentTerminalContainerView(frame: .zero)
        let terminal = makeTerminal()
        container.configure(terminal: terminal, sessionID: UUID())
        window.contentView?.addSubview(container)

        // Bug-Simulation: ein fensterloser Zwischen-Host hat das Terminal
        // gestohlen (frühere attach-Semantik in makeNSView).
        let foreign = AgentTerminalContainerView(frame: .zero)
        foreign.addSubview(terminal)
        XCTAssertTrue(terminal.superview === foreign)

        container.layout()

        XCTAssertTrue(terminal.superview === container)
    }

    func testDetachedContainerDoesNotStealFromVisibleHost() {
        let visible = AgentTerminalContainerView(frame: .zero)
        let terminal = makeTerminal()
        visible.configure(terminal: terminal, sessionID: UUID())
        window.contentView?.addSubview(visible)
        XCTAssertTrue(terminal.superview === visible)

        // Zwischen-Host außerhalb des Fensters: configure + layout dürfen
        // NICHT adoptieren.
        let transient = AgentTerminalContainerView(frame: .zero)
        transient.configure(terminal: terminal, sessionID: UUID())
        transient.layout()

        XCTAssertTrue(terminal.superview === visible)
    }

    func testConfigureReplacesForeignTerminalResidue() {
        let container = AgentTerminalContainerView(frame: .zero)
        let oldTerminal = makeTerminal()
        container.configure(terminal: oldTerminal, sessionID: UUID())
        window.contentView?.addSubview(container)
        XCTAssertTrue(oldTerminal.superview === container)

        // Controller-Wechsel (z. B. Restart): neues Terminal ersetzt das alte.
        let newTerminal = makeTerminal()
        container.configure(terminal: newTerminal, sessionID: UUID())

        XCTAssertTrue(newTerminal.superview === container)
        XCTAssertNil(oldTerminal.superview)
    }
}
