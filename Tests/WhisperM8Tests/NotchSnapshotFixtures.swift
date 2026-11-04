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
                // Menüs links und Statussymbole rechts, beide bis dicht an die
                // Notch: so sieht man, dass die Anzeige sie nicht verdeckt.
                menuBarItems(menuBarHeight: display.isNotch ? notchHeight : 25, size: size, notch: display.isNotch)
                // Hardware-Notch als schwarze Kappe unter der Anzeige.
                if display.isNotch {
                    UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10)
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

    private static func menuBarItems(menuBarHeight: CGFloat, size: CGSize, notch: Bool) -> some View {
        let gap = notch ? notchWidth : 0
        let side = (size.width - gap) / 2
        return HStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "apple.logo")
                Text(verbatim: "Safari").fontWeight(.bold)
                Text(verbatim: "File")
                Text(verbatim: "Edit")
                Text(verbatim: "View")
                Text(verbatim: "History")
            }
            .padding(.leading, 14)
            .frame(width: side, alignment: .leading)
            Color.clear.frame(width: gap)
            HStack(spacing: 14) {
                Image(systemName: "waveform")
                Image(systemName: "bolt.horizontal.circle")
                Image(systemName: "wifi")
                Image(systemName: "battery.75percent")
                Text(verbatim: "Mi. 4. Nov. 9:41")
            }
            .padding(.leading, notch ? 8 : 0)
            .padding(.trailing, 12)
            .frame(width: side, alignment: notch ? .leading : .trailing)
        }
        .font(.system(size: 12))
        .foregroundStyle(Color.black.opacity(0.85))
        .lineLimit(1)
        .frame(width: size.width, height: menuBarHeight)
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
                     alert: NotchAlert? = nil, inputs: [NotchChatInput]? = nil, size: CGSize) -> Fixture {
            Fixture(name: name, size: size) {
                let d = display(notch: notch, expanded: expanded, alert: alert, inputs: inputs)
                return screen(d, mode: mode, size: size)
            }
        }
        // Alle vier Zähler, zweistellig: breiter als die Notch, bleibt unter der Leiste.
        let busy = (0..<12).map { input("Job \($0)", "p", .working, since: Double($0)) }
            + (0..<3).map { input("Wartet \($0)", "p", .awaitingInput, since: Double($0)) }
            + [input("Fehler", "p", .errored, since: 5), input("Fertig", "p", .idle, since: 9, turnAgo: 9)]
        let busyMode = NotchPanelMode.compact(
            chipCount: NotchStatusModel.summary(of: NotchStatusModel.rows(from: busy, now: now, showFreshDone: true)).chipCount)
        return [
            fixture("notch-ruhe", notch: true, mode: compactMode, size: size),
            fixture("notch-ruhe-voll", notch: true, mode: busyMode, inputs: busy, size: size),
            fixture("notch-braucht-dich", notch: true, mode: .alert, alert: alert, size: size),
            fixture("notch-fehler", notch: true, mode: .alert, alert: errorAlert, size: size),
            fixture("notch-aufgeklappt", notch: true, mode: expandedMode, expanded: true, size: tall),
            fixture("notch-pille-ruhe", notch: false, mode: compactMode, size: size),
            fixture("notch-pille-braucht-dich", notch: false, mode: .alert, alert: alert, size: size),
            fixture("notch-pille-aufgeklappt", notch: false, mode: expandedMode, expanded: true, size: tall),
        ]
    }
}
