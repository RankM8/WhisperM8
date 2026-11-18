import AppKit
import SwiftUI
import XCTest
@testable import WhisperM8

/// Snapshot-Fixtures der Anzeige an einer Kamera-Insel (Dynamic Island):
/// kompakt, minimal, „braucht dich“, Liste, Diktat samt Übergang und
/// Controller-Insel, auch neben Apples eigener Insel mit Mikrofon-Hinweis.
/// Die Attrappe hat die am 18.11.2026 gemessenen Maße (Menüleiste 45 pt,
/// Sicherheitsrand 40 pt, Aussparung 59 pt) und zeichnet die Kamera-Kapsel
/// zuletzt, über allem: So legt macOS die echte Insel über jedes Fenster.
extension UISnapshotGallery {
    private static let islandNow = Date(timeIntervalSince1970: 1_800_000_000)
    private static let islandCutout = CGSize(width: 59, height: 32)
    private static let islandMenuBar: CGFloat = 45
    private static let islandSafeTop: CGFloat = 40

    private static func islandScreen(_ size: CGSize) -> NotchScreenInfo {
        let height = max(600, size.height)
        let side = (size.width - islandCutout.width) / 2
        return NotchScreenInfo(
            displayID: 1, frame: CGRect(x: 0, y: 0, width: size.width, height: height),
            visibleFrame: CGRect(x: 0, y: 0, width: size.width, height: height - islandMenuBar),
            safeAreaTop: islandSafeTop, auxiliaryLeftWidth: side, auxiliaryRightWidth: side, isBuiltIn: true)
    }

    private static func islandInput(
        _ title: String, _ status: AgentSessionRuntimeStatus, since: TimeInterval, turnAgo: TimeInterval? = nil,
        line: AgentSessionActivity? = nil
    ) -> NotchChatInput {
        NotchChatInput(
            id: UUID(), title: title, project: "whisperm8", status: status,
            statusSince: islandNow.addingTimeInterval(-since),
            lastTurnAt: turnAgo.map { islandNow.addingTimeInterval(-$0) },
            lastActivityAt: islandNow.addingTimeInterval(-since), activity: line)
    }

    private static var islandDemoInputs: [NotchChatInput] {
        [
            islandInput("Release-Notizen prüfen", .awaitingInput, since: 130,
                        line: AgentSessionActivity(awaitingKind: .permission, awaitingToolName: "Bash")),
            islandInput("Tab-Switcher Review", .idle, since: 360, turnAgo: 360,
                        line: AgentSessionActivity(detail: .reply("Alle Befunde eingearbeitet."))),
            islandInput("Clipboard Verlauf", .working, since: 480,
                        line: AgentSessionActivity(detail: .tool(name: "Edit", argument: "ClipboardStore.swift"))),
            islandInput("Landing Page Texte", .working, since: 70,
                        line: AgentSessionActivity(detail: .reply("Ich schreibe die Antwort."))),
            islandInput("Skripte aufräumen", .idle, since: 7_200),
        ]
    }

    /// Belegung der Attrappe: Menüs links bis 255 pt (`crowded`: bis kurz vor
    /// die Kamera), Statussymbole rechts ab 150 pt vor dem Rand (`tight`:
    /// eines schon 40 pt neben der Kamera). `microphone`: Apples Insel zeigt
    /// den Mikrofon-Hinweis (gemessen 111,5 pt breit).
    private static func islandOccupancy(
        _ size: CGSize, crowded: Bool = false, tight: Bool = false, microphone: Bool = false
    ) -> NotchMenuBarOccupancy {
        let height = max(600, size.height)
        let bar = { (minX: CGFloat, maxX: CGFloat) in
            CGRect(x: minX, y: height - islandMenuBar, width: maxX - minX, height: islandMenuBar)
        }
        return NotchMenuBarOccupancy(
            frames: [
                bar(10, crowded ? size.width / 2 - 36 : 255),
                bar(tight ? size.width / 2 + islandCutout.width / 2 + 40 : size.width - 150, size.width - 10),
            ],
            systemIsland: microphone ? (size.width / 2 - 55.75)...(size.width / 2 + 55.75) : nil,
            systemIslandInsets: microphone ? 8...40 : nil)
    }

    /// Schreibtisch mit Menüleiste; die Kamera-Kapsel liegt über dem Inhalt.
    private struct IslandDesk<Content: View>: View {
        @Environment(\.colorScheme) private var scheme
        let size: CGSize
        /// Menüs reichen bis an die Kamera.
        var crowded = false
        /// Ein Statussymbol steht schon dicht rechts der Kamera.
        var tight = false
        /// Apples Insel mit Mikrofon-Hinweis: breiter, oranger Punkt rechts.
        var microphone = false
        @ViewBuilder let content: Content

        var body: some View {
            ZStack(alignment: .topLeading) {
                LinearGradient(
                    colors: scheme == .dark
                        ? [Color(red: 0.13, green: 0.15, blue: 0.20), Color(red: 0.22, green: 0.18, blue: 0.20)]
                        : [Color(red: 0.80, green: 0.84, blue: 0.93), Color(red: 0.93, green: 0.86, blue: 0.82)],
                    startPoint: .topLeading, endPoint: .bottomTrailing)
                Rectangle()
                    .fill(scheme == .dark ? Color.black.opacity(0.35) : Color.white.opacity(0.55))
                    .frame(height: UISnapshotGallery.islandMenuBar)
                menuBarItems
                // Eigener Rahmen wie das Fenster.
                GeometryReader { _ in content }
                // Die Hardware samt System-Insel: immer zuoberst.
                Capsule()
                    .fill(Color.black)
                    .frame(
                        width: microphone ? 111.5 : UISnapshotGallery.islandCutout.width + 6,
                        height: UISnapshotGallery.islandCutout.height)
                    .overlay { Circle().fill(Color(white: 0.16)).frame(width: 7, height: 7) }
                    .overlay {
                        if microphone {
                            Circle().fill(Color.orange).frame(width: 5, height: 5).offset(x: 38)
                        }
                    }
                    .position(x: size.width / 2, y: 8 + UISnapshotGallery.islandCutout.height / 2)
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .clipped()
        }

        private var menuBarItems: some View {
            HStack(spacing: 0) {
                HStack(spacing: 14) {
                    Image(systemName: "apple.logo")
                    Text(verbatim: "Safari").fontWeight(.bold)
                    Text(verbatim: "File")
                    Text(verbatim: "Edit")
                    Text(verbatim: "View")
                    Text(verbatim: "History")
                    if crowded {
                        Text(verbatim: "Window")
                    }
                }
                .padding(.leading, 16)
                Spacer(minLength: 0)
                HStack(spacing: 14) {
                    if tight {
                        Image(systemName: "headphones")
                        Image(systemName: "bell")
                        Image(systemName: "magnifyingglass")
                        Spacer().frame(width: 2)
                    }
                    Image(systemName: "wifi")
                    Image(systemName: "battery.75percent")
                    Text(verbatim: "Mi. 18. Nov. 9:41")
                }
                .padding(.trailing, 14)
            }
            .font(.system(size: 13))
            .foregroundStyle(scheme == .dark ? Color.white.opacity(0.85) : Color.black.opacity(0.85))
            .lineLimit(1)
            .frame(width: size.width, height: UISnapshotGallery.islandMenuBar)
        }
    }

    /// Status-Anzeige an der Stelle, die `NotchGeometry` auf dem Bildschirm
    /// rechnet, in der Stufe, die zur Belegung der Menüleiste passt.
    private static func islandStatus(
        _ name: String, size: CGSize, inputs: [NotchChatInput], expanded: Bool = false, alert: NotchAlert? = nil,
        crowded: Bool = false, tight: Bool = false, microphone: Bool = false
    ) -> Fixture {
        Fixture(name: "kamera-insel-\(name)", size: size) {
            let screen = islandScreen(size)
            let rows = NotchStatusModel.rows(from: inputs, now: islandNow, showFreshDone: true)
            let summary = NotchStatusModel.summary(of: rows)
            let sections = expanded ? NotchStatusModel.sections(of: rows) : []
            let mode = NotchStatusModel.panelMode(isExpanded: expanded, alert: alert, rows: rows, sections: sections)
            let occupancy = islandOccupancy(size, crowded: crowded, tight: tight, microphone: microphone)
            let signal = NotchIslandSignal(summary: summary)
            let stage = NotchIslandGeometry.presentation(signal: signal, screen: screen, occupancy: occupancy)
            let band = NotchIslandGeometry.band(
                screen: screen, occupancy: occupancy, presentation: stage, digits: signal?.digits ?? 1)
            let frame = NotchGeometry.panelFrame(screen: screen, mode: mode, islandBand: band)
            let display = NotchDisplay(
                style: NotchStatusController.displayStyle(screen: screen, islandBand: band),
                summary: summary, alert: alert, isExpanded: expanded, sections: sections,
                cameraOffset: screen.notchCenterX - frame.midX)
            return AnyView(IslandDesk(size: size, crowded: crowded, tight: tight, microphone: microphone) {
                NotchStatusView(display: display)
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: screen.frame.maxY - frame.maxY)
            })
        }
    }

    /// Diktat-Pille im Fenster der vereinten Pille an der Insel.
    @MainActor
    private static func islandDictation(
        _ name: String, size: CGSize, rest: UnifiedPillRestLook? = nil, midway: Bool = false, microphone: Bool = false,
        configure: @escaping (OverlayController) -> Void = { _ in }
    ) -> Fixture {
        Fixture(name: "kamera-insel-\(name)", size: size) {
            let screen = islandScreen(size)
            let band = NotchIslandGeometry.band(
                screen: screen, occupancy: islandOccupancy(size, microphone: microphone))
            let controller = morphController(notch: .island(band), rest: rest)
            configure(controller)
            return AnyView(IslandDesk(size: size, microphone: microphone) {
                RecordingOverlayView(controller: controller)
                    .environment(\.colorScheme, .dark)
                    .padding(.top, NotchIslandGeometry.topInset(screen))
                    .onAppear {
                        guard midway else { return }
                        DispatchQueue.main.asyncAfter(deadline: .now() + morphMidwayDelay) {
                            controller.showsRestLook = false
                        }
                    }
            })
        }
    }

    @MainActor
    static func notchIslandFixtures() -> [Fixture] {
        let strip = CGSize(width: 720, height: 130)
        let tall = CGSize(width: 720, height: 470)
        let alert = NotchAlert(sessionID: UUID(), title: "Release-Notizen prüfen", kind: .awaitingInput)
        let errorAlert = NotchAlert(sessionID: UUID(), title: "Landing Page Texte", kind: .errored, extraCount: 1)
        let working = [islandInput("Clipboard Verlauf", .working, since: 480),
                       islandInput("Landing Page Texte", .working, since: 70)]
        let busy = (0..<12).map { islandInput("Job \($0)", .working, since: Double($0)) }
            + (0..<3).map { islandInput("Wartet \($0)", .awaitingInput, since: Double($0)) }
            + [islandInput("Fehler", .errored, since: 5), islandInput("Fertig", .idle, since: 9, turnAgo: 9)]

        let screen = islandScreen(strip)
        let restSummary = NotchSummary(working: 2, waiting: 1)
        let rest = UnifiedPillRestLook.island(
            summary: restSummary, alert: nil,
            band: NotchIslandGeometry.band(screen: screen, occupancy: islandOccupancy(strip), presentation: .compact(.leading)),
            bodyWidth: nil)
        let manyWorking = (0..<12).map { islandInput("Job \($0)", .working, since: Double($0)) }
        let done = [islandInput("Tab-Switcher Review", .idle, since: 60, turnAgo: 60)]

        let controllerSize = CGSize(width: 720, height: 300)
        let controllerIsland = Fixture(name: "kamera-insel-controller", size: controllerSize) {
            let screen = islandScreen(controllerSize)
            let model = ControllerIslandModel(
                target: ControllerIslandTarget(title: "Controller Insel", status: .idle),
                content: .writing(ControllerWritingSlots(state: ControllerChatState(status: .idle, profile: .claude))))
            let display = ControllerIslandDisplay(
                style: ControllerIslandGeometry.style(for: screen), model: model,
                counts: ControllerIslandCounts(working: 2, waiting: 1))
            return AnyView(IslandDesk(size: controllerSize) {
                ControllerIslandView(display: display)
                    .frame(maxWidth: .infinity, alignment: .top)
                    .padding(.top, NotchIslandGeometry.topInset(screen))
            })
        }

        return [
            // Kompakt: Zeichen und Zahl zusammen links der Kamera.
            islandStatus("kompakt-arbeitet", size: strip, inputs: working),
            islandStatus("kompakt-wartet", size: strip, inputs: islandDemoInputs),
            islandStatus("kompakt-fehler", size: strip, inputs: [islandInput("Landing Page Texte", .errored, since: 20)] + working),
            islandStatus("kompakt-fertig", size: strip, inputs: done),
            islandStatus("kompakt-zweistellig", size: strip, inputs: manyWorking),
            islandStatus("kompakt-voll", size: strip, inputs: busy),
            // Menüs reichen an die Kamera: beides rechts von ihr.
            islandStatus("kompakt-rechts", size: strip, inputs: islandDemoInputs, crowded: true),
            // Minimal: Für die Zahl ist nirgends Platz bzw. Apples Insel zeigt
            // selbst etwas; nur das Zeichen.
            islandStatus("minimal-eng", size: strip, inputs: islandDemoInputs, crowded: true, tight: true),
            islandStatus("minimal-mikrofon", size: strip, inputs: islandDemoInputs, microphone: true),
            // Expandiert: Hinweis (kurz) und Liste (Klick) unter der Menüleiste.
            islandStatus("braucht-dich", size: strip, inputs: islandDemoInputs, alert: alert),
            islandStatus("fehler", size: strip, inputs: islandDemoInputs + [islandInput("Landing Page Texte", .errored, since: 20)],
                         alert: errorAlert),
            islandStatus("liste", size: tall, inputs: islandDemoInputs, expanded: true),
            islandStatus("liste-rechts", size: tall, inputs: islandDemoInputs, expanded: true, crowded: true),
            islandDictation("diktat", size: strip) {
                $0.levelModel.level = 0.45
                $0.statusBadge = DictationStatusBadge(waiting: 1, errored: 0)
            },
            // Mit Mikrofon ist Apples Insel breiter: der Hals ist so breit wie sie.
            islandDictation("diktat-mikrofon", size: strip, microphone: true) {
                $0.levelModel.level = 0.45
                $0.statusBadge = DictationStatusBadge(waiting: 1, errored: 0)
            },
            islandDictation("diktat-transkribiert", size: strip, microphone: true) { $0.isTranscribing = true },
            // Übergang: Ruhebild (Kapsel mit Zeichen und Zahl), Mitte, und aus
            // der leeren Insel, wenn an ihr nichts los ist.
            islandDictation("uebergang-ruhe", size: strip, rest: rest),
            islandDictation("uebergang-mitte", size: strip, rest: rest, midway: true),
            islandDictation("uebergang-leer", size: strip, rest: .notchBand),
            controllerIsland,
        ]
    }
}
