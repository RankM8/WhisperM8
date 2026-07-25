import SwiftUI
import XCTest
@testable import WhisperM8

/// Rendert die PRODUKTIVEN Tab-Views (`ChatTabButton` samt Silhouette und
/// Gruppen-Kontur) headless und prüft sie pixelweise. Zwei Aussagen sind so
/// offline belegbar, die sonst nur ein Screenshot der laufenden App zeigt:
///
/// 1. Der aktive Tab geht ohne Farbwechsel in den Chat-Header über.
/// 2. Die Gruppen-Kontur läuft als EIN Zug um den Tab — unterhalb der
///    Fußabzweigung bleibt kein Sporn stehen.
///
/// Bewusst der echte View statt einer nachgebauten Geometrie: nur so schlägt
/// der Test auch bei einer Regression in den Modifiern an.
@MainActor
final class ChromeTabSeamTests: XCTestCase {
    private let tabWidth: CGFloat = 150
    private let barHeight: CGFloat = 34
    private let headerHeight: CGFloat = 22
    private let leadingPad: CGFloat = 12
    private let scale: CGFloat = 3
    /// Kräftiges Magenta — kommt in keiner Theme-Fläche vor, ist im Bild
    /// also eindeutig der Gruppen-Kontur zuzuordnen.
    private let groupColor = Color(red: 1, green: 0, blue: 1)

    private func makeSession() -> AgentChatSession {
        AgentChatSession(
            id: UUID(),
            provider: .claude,
            projectID: UUID(),
            title: "Chat",
            lastActivityAt: Date(timeIntervalSince1970: 1_000),
            createdManually: true
        )
    }

    private func makeProject(id: UUID) -> AgentProject {
        AgentProject(
            id: id,
            name: "Repo",
            path: "/tmp/repo",
            color: "#4b76d1",
            lastBranch: nil,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0),
            createdManually: true
        )
    }

    /// Aktiver Tab in einer Gruppe, unten bündig in der Leiste, darunter der
    /// Chat-Header — dieselbe Schichtung wie in `projectChatStrip`.
    private func probe(isMultiSelected: Bool = false, groupColor: Color?) -> some View {
        let session = makeSession()
        let width = tabWidth + leadingPad * 2
        return VStack(spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                Color.clear.frame(width: width, height: barHeight)
                ChatTabButton(
                    session: session,
                    project: makeProject(id: session.projectID),
                    isSelected: true,
                    isMultiSelected: isMultiSelected,
                    statusStore: AgentSessionRuntimeStatusStore(),
                    groupColor: groupColor,
                    onSelect: {},
                    onClose: {}
                )
                .frame(width: tabWidth)
                .padding(.leading, leadingPad)
            }
            .background(AgentTheme.tabBar)

            Rectangle()
                .fill(AgentTheme.header)
                .frame(width: width, height: headerHeight)
        }
        .frame(width: width, height: barHeight + headerHeight)
    }

    private func render(_ view: some View) throws -> NSBitmapImageRep {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        let image = try XCTUnwrap(renderer.nsImage, "ImageRenderer lieferte kein Bild")
        return try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
    }

    private func isGroupColor(_ color: NSColor) -> Bool {
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return false }
        return rgb.redComponent > 0.6 && rgb.blueComponent > 0.6 && rgb.greenComponent < 0.4
    }

    // MARK: - Naht

    func testActiveTabMergesIntoHeaderWithoutSeam() throws {
        let bitmap = try render(probe(groupColor: nil))
        let x = Int((leadingPad + tabWidth / 2) * scale)
        // Von der Tab-Mitte bis kurz vor den unteren Bildrand.
        let start = Int((barHeight - 8) * scale)
        let end = bitmap.pixelsHigh - 3

        let reference = try XCTUnwrap(bitmap.colorAt(x: x, y: start))
        for y in start...end {
            let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y))
            let delta = max(
                abs(color.redComponent - reference.redComponent),
                max(abs(color.greenComponent - reference.greenComponent),
                    abs(color.blueComponent - reference.blueComponent))
            )
            XCTAssertLessThan(delta, 0.02, "Farbwechsel bei y=\(y): Naht Tab→Header unterbrochen")
        }
    }

    // MARK: - Gruppen-Kontur

    /// Die Kontur muss an der Tab-Seite OBERHALB der Fußabzweigung liegen …
    func testGroupContourRunsAlongTabSide() throws {
        let bitmap = try render(probe(groupColor: groupColor))
        let x = Int(leadingPad * scale)
        let y = Int((barHeight - 16) * scale)

        let column = (max(0, x - 2)...min(bitmap.pixelsWide - 1, x + 2)).contains { probeX in
            (max(0, y - 2)...min(bitmap.pixelsHigh - 1, y + 2)).contains { probeY in
                bitmap.colorAt(x: probeX, y: probeY).map(isGroupColor) ?? false
            }
        }
        XCTAssertTrue(column, "Gruppen-Kontur fehlt an der Tab-Seite")
    }

    /// … und muss im unteren Drittel der Fußzone bereits deutlich nach außen
    /// abgebogen sein. Eine Kontur, die dort noch an der Tab-Kante steht, ist
    /// der Sporn einer separat gezeichneten Seitenlinie.
    ///
    /// Messband bewusst erst ab `Abzweigung + 5pt`: direkt unter der
    /// Abzweigung streift der Bogen die Kante noch legitim.
    func testGroupContourHasNoSpurBelowFootJunction() throws {
        let bitmap = try render(probe(groupColor: groupColor))
        let foot = ChromeTabMetrics.footSize
        let start = Int((barHeight - foot + 5) * scale)
        let end = Int((barHeight - 1) * scale)
        // Tab-Kante plus die 2pt, auf denen eine geradlinige Seitenkontur
        // (mit oder ohne 1pt-Inset) läge.
        let columns = Int(leadingPad * scale)...Int((leadingPad + 2) * scale)

        for y in start...end {
            for x in columns {
                let hit = bitmap.colorAt(x: x, y: y).map(isGroupColor) ?? false
                XCTAssertFalse(hit, "Sporn: Kontur steht bei (\(x),\(y)) noch an der Tab-Kante")
            }
        }
    }

    // MARK: - Mehrfach-Auswahl

    /// Der Auswahl-Ring darf den aktiven Tab unten nicht schließen — sonst
    /// zerschneidet er die nahtlose Fläche zum Header.
    func testMultiSelectDoesNotCloseActiveTabBottom() throws {
        let bitmap = try render(probe(isMultiSelected: true, groupColor: nil))
        let x = Int((leadingPad + tabWidth / 2) * scale)
        let start = Int((barHeight - 6) * scale)
        let end = bitmap.pixelsHigh - 3

        let reference = try XCTUnwrap(bitmap.colorAt(x: x, y: start))
        for y in start...end {
            let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y))
            let delta = max(
                abs(color.redComponent - reference.redComponent),
                max(abs(color.greenComponent - reference.greenComponent),
                    abs(color.blueComponent - reference.blueComponent))
            )
            XCTAssertLessThan(delta, 0.03, "Auswahl-Ring schneidet bei y=\(y) die Naht")
        }
    }

    // MARK: - Gegenproben

    /// Ohne sichtbaren Unterschied zwischen Leiste und Header wäre der
    /// Nahttest wertlos — hier explizit für BEIDE Erscheinungsbilder.
    func testTabBarIsDistinguishableFromHeaderInBothAppearances() throws {
        for appearance in [NSAppearance(named: .aqua)!, NSAppearance(named: .darkAqua)!] {
            var barColor = NSColor.clear
            var headerColor = NSColor.clear
            appearance.performAsCurrentDrawingAppearance {
                barColor = NSColor(AgentTheme.tabBar).usingColorSpace(.deviceRGB) ?? .clear
                headerColor = NSColor(AgentTheme.header).usingColorSpace(.deviceRGB) ?? .clear
            }
            let delta = abs(barColor.brightnessComponent - headerColor.brightnessComponent)
            XCTAssertGreaterThan(
                delta, 0.01,
                "Leiste und Header sind in \(appearance.name.rawValue) nicht unterscheidbar"
            )
        }
    }

    /// Der Chip-Text muss auf JEDER Standard-Gruppenfarbe lesbar sein
    /// (WCAG AA für Fließtext, 4.5:1).
    func testChipTextMeetsContrastOnAllPresetColors() throws {
        for hex in AgentChatColorName.map.keys {
            let text = NSColor(chipTextColor(forHex: hex)).usingColorSpace(.deviceRGB)
            let background = NSColor(Color(hex: hex)).usingColorSpace(.deviceRGB)
            let textLuminance = try relativeLuminance(XCTUnwrap(text))
            let backgroundLuminance = try relativeLuminance(XCTUnwrap(background))
            let lighter = max(textLuminance, backgroundLuminance)
            let darker = min(textLuminance, backgroundLuminance)
            let ratio = (lighter + 0.05) / (darker + 0.05)
            XCTAssertGreaterThanOrEqual(
                ratio, 4.5,
                "Chip-Text auf \(hex) (\(AgentChatColorName.label(for: hex))) hat nur \(String(format: "%.2f", ratio)):1"
            )
        }
    }

    private func relativeLuminance(_ color: NSColor) -> Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.redComponent)
            + 0.7152 * linear(color.greenComponent)
            + 0.0722 * linear(color.blueComponent)
    }
}
