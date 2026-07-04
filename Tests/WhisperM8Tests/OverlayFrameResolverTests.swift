import AppKit
import XCTest
@testable import WhisperM8

/// Reine Geometrie der Recording-Pill: Anker→Panel-Origin (rechts verankert
/// inkl. Spiegel-Fall), Drag-Clamp auf die sichtbare Pill, Legacy-Migration.
final class OverlayFrameResolverTests: XCTestCase {
    /// Standard-Screen für alle Tests: 1600×900 ab (0, 0).
    private let visibleFrame = NSRect(x: 0, y: 0, width: 1600, height: 900)

    // MARK: - resolve: Rechts-Anker

    func testResolvePrefersTrailingAnchorWhenFullWidthFits() {
        let anchor = PillAnchor(maxX: 1200, minX: 1000, y: 100)

        let resolution = OverlayFrameResolver.resolve(anchor: anchor, visibleFrame: visibleFrame)

        XCTAssertEqual(resolution.alignment, .trailing)
        // Rechte Panel-Kante = Pill-maxX + Schattenrand.
        XCTAssertEqual(
            resolution.panelOrigin.x + OverlayFrameResolver.panelSize.width,
            1200 + OverlayFrameResolver.contentMargin
        )
        // Unterkante = Pill-Unterkante minus Schattenrand.
        XCTAssertEqual(resolution.panelOrigin.y, 100 - OverlayFrameResolver.contentMargin)
    }

    func testResolveMirrorsToLeadingNearLeftScreenEdge() {
        // Anker so weit links, dass die voll expandierte Pill (560) nicht mehr
        // nach links wachsen kann → linke Kante wird Fixpunkt.
        let anchor = PillAnchor(maxX: 300, minX: 120, y: 100)

        let resolution = OverlayFrameResolver.resolve(anchor: anchor, visibleFrame: visibleFrame)

        XCTAssertEqual(resolution.alignment, .leading)
        // Linke Panel-Kante = Pill-minX minus Schattenrand.
        XCTAssertEqual(resolution.panelOrigin.x, 120 - OverlayFrameResolver.contentMargin)
    }

    func testResolveMirrorPullsAnchorBackWhenScreenIsNarrow() {
        // Schmaler Screen + Anker links: Spiegel-Fall, aber die volle Pill
        // würde rechts überstehen — minX muss so weit zurückweichen, dass
        // sie komplett hineinpasst.
        let narrow = NSRect(x: 0, y: 0, width: 600, height: 400)
        let anchor = PillAnchor(maxX: 500, minX: 300, y: 50)

        let resolution = OverlayFrameResolver.resolve(anchor: anchor, visibleFrame: narrow)

        XCTAssertEqual(resolution.alignment, .leading)
        let pillMinX = resolution.panelOrigin.x + OverlayFrameResolver.contentMargin
        XCTAssertEqual(pillMinX, 600 - OverlayFrameResolver.maxPillWidth)
        XCTAssertGreaterThanOrEqual(pillMinX, narrow.minX)
    }

    func testResolveClampsAnchorBeyondRightScreenEdge() {
        let anchor = PillAnchor(maxX: 2400, minX: 2200, y: 100)

        let resolution = OverlayFrameResolver.resolve(anchor: anchor, visibleFrame: visibleFrame)

        XCTAssertEqual(resolution.alignment, .trailing)
        let pillMaxX = resolution.panelOrigin.x + OverlayFrameResolver.panelSize.width
            - OverlayFrameResolver.contentMargin
        XCTAssertEqual(pillMaxX, visibleFrame.maxX)
    }

    func testResolveClampsVerticallyIntoVisibleFrame() {
        let below = OverlayFrameResolver.resolve(
            anchor: PillAnchor(maxX: 1200, minX: 1000, y: -80),
            visibleFrame: visibleFrame
        )
        XCTAssertEqual(below.panelOrigin.y, visibleFrame.minY - OverlayFrameResolver.contentMargin)

        let above = OverlayFrameResolver.resolve(
            anchor: PillAnchor(maxX: 1200, minX: 1000, y: 2000),
            visibleFrame: visibleFrame
        )
        let pillMinY = above.panelOrigin.y + OverlayFrameResolver.contentMargin
        XCTAssertEqual(pillMinY, visibleFrame.maxY - OverlayFrameResolver.pillHeight)
    }

    // MARK: - Default-Anker

    func testDefaultAnchorCentersEstimatedPillWidth() {
        let anchor = OverlayFrameResolver.defaultAnchor(
            estimatedPillWidth: 200,
            visibleFrame: visibleFrame
        )

        XCTAssertEqual(anchor.maxX, visibleFrame.midX + 100)
        XCTAssertEqual(anchor.minX, visibleFrame.midX - 100)
        XCTAssertEqual(anchor.y, visibleFrame.minY + OverlayFrameResolver.defaultBottomOffset)
    }

    // MARK: - Drag-Clamp (Pill-basiert, Schattenrand darf überstehen)

    func testClampedPanelOriginKeepsVisiblePillInsideScreen() {
        let pillInPanel = NSRect(
            x: OverlayFrameResolver.panelSize.width - OverlayFrameResolver.contentMargin - 200,
            y: OverlayFrameResolver.contentMargin,
            width: 200,
            height: OverlayFrameResolver.pillHeight
        )

        // Panel so weit links, dass die Pill 50 pt über die linke Kante ragt.
        let panelOrigin = NSPoint(x: -pillInPanel.minX - 50, y: 100)
        let clamped = OverlayFrameResolver.clampedPanelOrigin(
            panelOrigin: panelOrigin,
            pillFrameInPanel: pillInPanel,
            visibleFrame: visibleFrame
        )

        XCTAssertEqual(clamped.x + pillInPanel.minX, visibleFrame.minX)
        XCTAssertEqual(clamped.y, 100)
    }

    func testClampedPanelOriginAllowsShadowMarginBeyondEdge() {
        let pillInPanel = NSRect(
            x: OverlayFrameResolver.contentMargin,
            y: OverlayFrameResolver.contentMargin,
            width: 200,
            height: OverlayFrameResolver.pillHeight
        )

        // Pill exakt an der linken Kante: Panel-Origin ist negativ
        // (Schattenrand hängt über) — und das ist erlaubt.
        let panelOrigin = NSPoint(x: -OverlayFrameResolver.contentMargin, y: 100)
        let clamped = OverlayFrameResolver.clampedPanelOrigin(
            panelOrigin: panelOrigin,
            pillFrameInPanel: pillInPanel,
            visibleFrame: visibleFrame
        )

        XCTAssertEqual(clamped, panelOrigin)
    }

    // MARK: - Anker-Roundtrip & Migration

    func testAnchorRoundTripThroughResolve() {
        let pillInPanel = NSRect(
            x: OverlayFrameResolver.panelSize.width - OverlayFrameResolver.contentMargin - 240,
            y: OverlayFrameResolver.contentMargin,
            width: 240,
            height: OverlayFrameResolver.pillHeight
        )
        let panelOrigin = NSPoint(x: 400, y: 200)

        let anchor = OverlayFrameResolver.anchor(panelOrigin: panelOrigin, pillFrameInPanel: pillInPanel)
        let resolution = OverlayFrameResolver.resolve(anchor: anchor, visibleFrame: visibleFrame)

        // Rechts verankert: dieselbe Pill-maxX ergibt denselben Panel-Origin.
        XCTAssertEqual(resolution.alignment, .trailing)
        XCTAssertEqual(resolution.panelOrigin, panelOrigin)
    }

    func testMigrateLegacyOriginMapsPanelEdgesToPillAnchor() {
        // Alte Full-Bar: 590×56 — Pill-Unterkante saß vertikal mittig im Panel.
        let anchor = OverlayFrameResolver.migrateLegacyOrigin(
            NSPoint(x: 100, y: 40),
            legacyPanelSize: NSSize(width: 590, height: 56)
        )

        XCTAssertEqual(anchor.maxX, 690)
        XCTAssertEqual(anchor.minX, 100)
        XCTAssertEqual(anchor.y, 40 + (56 - OverlayFrameResolver.pillHeight) / 2)
    }
}

/// Zustands-Mapping der Pill: Phase, Labels, Cancel-Semantik, Timer-Format.
final class OverlayPhaseTests: XCTestCase {
    func testResolvePicksExactlyOnePhase() {
        XCTAssertEqual(OverlayPhase.resolve(isTranscribing: false, isPostProcessing: false), .recording)
        XCTAssertEqual(OverlayPhase.resolve(isTranscribing: true, isPostProcessing: false), .transcribing)
        // Post-Processing gewinnt — auch falls beide Flags kurz überlappen.
        XCTAssertEqual(OverlayPhase.resolve(isTranscribing: true, isPostProcessing: true), .improving)
        XCTAssertEqual(OverlayPhase.resolve(isTranscribing: false, isPostProcessing: true), .improving)
    }

    func testStatusLabelOnlyWhereTextCarriesInformation() {
        // Recording: bewusst KEIN Dauerlabel — die Waveform ist der Status.
        XCTAssertNil(OverlayPhase.recording.statusLabel(postProcessingStatusText: nil))
        XCTAssertEqual(
            OverlayPhase.transcribing.statusLabel(postProcessingStatusText: nil),
            "Transcribing…"
        )
        // Improving zeigt den echten Codex-Status, mit Fallback.
        XCTAssertEqual(
            OverlayPhase.improving.statusLabel(postProcessingStatusText: "Formatting for Slack…"),
            "Formatting for Slack…"
        )
        XCTAssertEqual(
            OverlayPhase.improving.statusLabel(postProcessingStatusText: nil),
            "Improving…"
        )
    }

    func testBusyPhasesLockModeAndContextControls() {
        XCTAssertFalse(OverlayPhase.recording.isBusy)
        XCTAssertTrue(OverlayPhase.transcribing.isBusy)
        XCTAssertTrue(OverlayPhase.improving.isBusy)
    }

    func testCancelSemanticsStayPhaseSpecific() {
        XCTAssertEqual(OverlayPhase.recording.cancelAccessibilityLabel, "Cancel recording")
        XCTAssertEqual(OverlayPhase.transcribing.cancelAccessibilityLabel, "Cancel transcription")
        XCTAssertEqual(OverlayPhase.improving.cancelAccessibilityLabel, "Cancel Codex post-processing")
        // Der Transkriptions-Abbruch verspricht die gesicherte Aufnahme.
        XCTAssertTrue(OverlayPhase.transcribing.cancelHelp.contains("gesichert"))
        // Der Improve-Abbruch verspricht das Raw-Transkript.
        XCTAssertTrue(OverlayPhase.improving.cancelHelp.contains("Raw"))
    }

    func testClockFormatterProducesStableMonospaceFormat() {
        XCTAssertEqual(OverlayClockFormatter.format(0), "00:00")
        XCTAssertEqual(OverlayClockFormatter.format(59.9), "00:59")
        XCTAssertEqual(OverlayClockFormatter.format(60), "01:00")
        XCTAssertEqual(OverlayClockFormatter.format(3599), "59:59")
        XCTAssertEqual(OverlayClockFormatter.format(-5), "00:00")
    }
}
