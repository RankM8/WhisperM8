import SwiftUI
import XCTest
@testable import WhisperM8

/// Snapshot-Fixtures der Notch-Anzeige: Ruhe, „braucht dich", aufgeklappt,
/// jeweils an der Notch und als Pille. Rein darstellend: die Ansicht bekommt
/// einen fertigen `NotchDisplay`, nichts Echtes wird gelesen.
extension UISnapshotGallery {
    private static let notchWidth: CGFloat = 185
    private static let notchHeight: CGFloat = 38
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private static func input(
        _ title: String, _ project: String, _ status: AgentSessionRuntimeStatus,
        since: TimeInterval, turnAgo: TimeInterval? = nil, line: AgentSessionActivity? = nil
    ) -> NotchChatInput {
        NotchChatInput(
            id: UUID(), title: title, project: project, status: status,
            statusSince: now.addingTimeInterval(-since),
            lastTurnAt: turnAgo.map { now.addingTimeInterval(-$0) },
            lastActivityAt: now.addingTimeInterval(-since),
            activity: line)
    }

    private static var demoInputs: [NotchChatInput] {
        [
            input("Release-Notizen prüfen", "whisperm8", .awaitingInput, since: 130,
                  line: AgentSessionActivity(awaitingKind: .permission, awaitingToolName: "Bash")),
            input("Tab-Switcher Review", "whisperm8", .idle, since: 360, turnAgo: 360,
                  line: AgentSessionActivity(detail: .reply("Alle Befunde eingearbeitet."))),
            input("Clipboard Verlauf", "whisperm8", .working, since: 480,
                  line: AgentSessionActivity(detail: .tool(name: "Edit", argument: "ClipboardStore.swift"))),
            input("Landing Page Texte", "rankm8-web", .working, since: 70,
                  line: AgentSessionActivity(detail: .reply("Ich schreibe die Antwort."))),
            input("Skripte aufräumen", "scripts", .idle, since: 7_200),
        ]
    }

    private static func display(
        notch: Bool, expanded: Bool = false, alert: NotchAlert? = nil, inputs: [NotchChatInput]? = nil
    ) -> NotchDisplay {
        let rows = NotchStatusModel.rows(from: inputs ?? demoInputs, now: now, showFreshDone: true)
        return NotchDisplay(
            style: notch ? .notch(width: notchWidth, height: notchHeight) : .pill,
            summary: NotchStatusModel.summary(of: rows),
            alert: alert,
            isExpanded: expanded,
            sections: expanded ? NotchStatusModel.sections(of: rows) : [])
    }

    /// Bildschirm-Attrappe mit Menüleiste, damit man die Lage zur Notch sieht.
    private static func screen(_ display: NotchDisplay, mode: NotchPanelMode, size: CGSize) -> AnyView {
        let info = display.isNotch
            ? NotchScreenInfo(
                displayID: 1, frame: CGRect(x: 0, y: 0, width: size.width, height: 600),
                visibleFrame: CGRect(x: 0, y: 0, width: size.width, height: 562),
                safeAreaTop: notchHeight,
                auxiliaryLeftWidth: (size.width - notchWidth) / 2, auxiliaryRightWidth: (size.width - notchWidth) / 2,
                isBuiltIn: true)
            : NotchScreenInfo(
                displayID: 2, frame: CGRect(x: 0, y: 0, width: size.width, height: 600),
                visibleFrame: CGRect(x: 0, y: 0, width: size.width, height: 575),
                safeAreaTop: 0, auxiliaryLeftWidth: nil, auxiliaryRightWidth: nil, isBuiltIn: false)
        let frame = NotchGeometry.panelFrame(screen: info, mode: mode)
        // Cocoa (unten links) → SwiftUI (oben links).
        let top = info.frame.maxY - frame.maxY
        return AnyView(
            ZStack(alignment: .topLeading) {
                LinearGradient(colors: [Color(red: 0.80, green: 0.84, blue: 0.93), Color(red: 0.93, green: 0.86, blue: 0.82)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Rectangle()
                    .fill(Color.white.opacity(0.55))
                    .frame(height: display.isNotch ? notchHeight : 25)
                // Hardware-Notch als schwarze Kappe unter der Anzeige.
                if display.isNotch {
                    UnevenRoundedRectangle(bottomLeadingRadius: 12, bottomTrailingRadius: 12)
                        .fill(Color.black)
                        .frame(width: notchWidth, height: notchHeight)
                        .position(x: size.width / 2, y: notchHeight / 2)
                }
                NotchStatusView(display: display)
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: top)
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .clipped())
    }

    static var notchFixtures: [Fixture] {
        let size = CGSize(width: 640, height: 150)
        let tall = CGSize(width: 640, height: 480)
        let alert = NotchAlert(sessionID: UUID(), title: "Release-Notizen prüfen", kind: .awaitingInput)
        let errorAlert = NotchAlert(sessionID: UUID(), title: "Landing Page Texte", kind: .errored, extraCount: 1)
        let rows = NotchStatusModel.rows(from: demoInputs, now: now, showFreshDone: true)
        let sections = NotchStatusModel.sections(of: rows)
        let expandedMode = NotchPanelMode.expanded(rowCount: rows.count, sectionCount: sections.count)
        let compactMode = NotchPanelMode.compact(chipCount: NotchStatusModel.summary(of: rows).chipCount)

        func fixture(_ name: String, notch: Bool, mode: NotchPanelMode, expanded: Bool = false,
                     alert: NotchAlert? = nil, size: CGSize) -> Fixture {
            Fixture(name: name, size: size) {
                let d = display(notch: notch, expanded: expanded, alert: alert)
                return screen(d, mode: mode, size: size)
            }
        }
        return [
            fixture("notch-ruhe", notch: true, mode: compactMode, size: size),
            fixture("notch-braucht-dich", notch: true, mode: .alert, alert: alert, size: size),
            fixture("notch-fehler", notch: true, mode: .alert, alert: errorAlert, size: size),
            fixture("notch-aufgeklappt", notch: true, mode: expandedMode, expanded: true, size: tall),
            fixture("notch-pille-ruhe", notch: false, mode: compactMode, size: size),
            fixture("notch-pille-braucht-dich", notch: false, mode: .alert, alert: alert, size: size),
            fixture("notch-pille-aufgeklappt", notch: false, mode: expandedMode, expanded: true, size: tall),
        ]
    }
}
