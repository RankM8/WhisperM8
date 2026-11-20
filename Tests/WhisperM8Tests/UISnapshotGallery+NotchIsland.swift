import AppKit
import SwiftUI
import XCTest
@testable import WhisperM8

/// Snapshot-Fixtures der Anzeige an einer Kamera-Insel (Dynamic Island):
/// kompakt, minimal, „braucht dich“ und Liste als große Form, Diktat samt
/// Übergang und aufgeklappter großer Form, Controller-Insel; auch neben
/// Apples eigener Insel mit Mikrofon-Hinweis oder Musik.
/// Die Attrappe hat die am 18.11.2026 gemessenen Maße (Menüleiste 45 pt,
/// Sicherheitsrand 40 pt, Aussparung 59 pt) und zeichnet die Kamera-Kapsel
/// zuletzt, über allem: So legt macOS die echte Insel über jedes Fenster.
extension UISnapshotGallery {
    private static let islandNow = Date(timeIntervalSince1970: 1_800_000_000)
    private static let islandCutout = CGSize(width: 59, height: 32)
    private static let islandMenuBar: CGFloat = 45
    private static let islandSafeTop: CGFloat = 40

    static func islandScreen(_ size: CGSize) -> NotchScreenInfo {
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
    static func islandOccupancy(
        _ size: CGSize, crowded: Bool = false, tight: Bool = false, microphone: Bool = false, statusGap: CGFloat? = nil,
        music: Bool = false
    ) -> NotchMenuBarOccupancy {
        let height = max(600, size.height)
        let bar = { (minX: CGFloat, maxX: CGFloat) in
            CGRect(x: minX, y: height - islandMenuBar, width: maxX - minX, height: islandMenuBar)
        }
        var occupancy = NotchMenuBarOccupancy(
            frames: [
                bar(10, crowded ? size.width / 2 - 36 : 255),
                bar(tight ? size.width / 2 + islandCutout.width / 2 + (statusGap ?? 40) : size.width - 150, size.width - 10),
            ],
            systemIsland: microphone ? (size.width / 2 - 55.75)...(size.width / 2 + 55.75) : nil,
            systemIslandInsets: microphone ? 8...40 : nil)
        if music {
            // Gemessen mit Musik: 143 × 34 pt, 66 pt links und 77 pt rechts
            // der Kamera-Mitte, 6 pt unter der Kante.
            occupancy.systemIsland = (size.width / 2 - 66)...(size.width / 2 + 77)
            occupancy.systemIslandInsets = 6...40
        }
        return occupancy
    }

    /// Schreibtisch mit Menüleiste; die Kamera-Kapsel liegt über dem Inhalt.
    struct IslandDesk<Content: View>: View {
        @Environment(\.colorScheme) private var scheme
        let size: CGSize
        /// Menüs reichen bis an die Kamera.
        var crowded = false
        /// Ein Statussymbol steht schon dicht rechts der Kamera.
        var tight = false
        /// Abstand dieses Statussymbols zur Kamera.
        var statusGap: CGFloat = 40
        /// Apples Insel mit Mikrofon-Hinweis: breiter, oranger Punkt rechts.
        var microphone = false
        /// Apples Insel zeigt Musik: 143 × 34 pt, Titelbild links, Pegel rechts.
        var music = false
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
                if music {
                    Capsule()
                        .fill(Color.black)
                        .frame(width: 143, height: 34)
                        .overlay { Circle().fill(Color(white: 0.16)).frame(width: 7, height: 7).offset(x: -5.5) }
                        .overlay {
                            HStack {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(LinearGradient(colors: [.teal, .indigo], startPoint: .top, endPoint: .bottom))
                                    .frame(width: 22, height: 14)
                                Spacer()
                                HStack(spacing: 2) {
                                    ForEach(Array([6, 11, 15, 9, 13, 7].enumerated()), id: \.offset) { _, height in
                                        Capsule().fill(Color.white.opacity(0.55)).frame(width: 2, height: CGFloat(height))
                                    }
                                }
                            }
                            .padding(.horizontal, 14)
                        }
                        .position(x: size.width / 2 + 5.5, y: 6 + 17)
                } else {
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
    /// rechnet, in der Stufe, die zur Belegung der Menüleiste passt. Hinweis
    /// und Liste als große Form im Fenster mit Rand, wie der Controller sie
    /// zeigt. `progress`: Standbild der Bewegung (0 = die Kapsel, aus der
    /// die Form wächst, 1 = offen).
    private static func islandStatus(
        _ name: String, size: CGSize, inputs: [NotchChatInput], expanded: Bool = false, alert: NotchAlert? = nil,
        crowded: Bool = false, tight: Bool = false, microphone: Bool = false, music: Bool = false,
        progress: CGFloat = 1, selectFirst: Bool = false
    ) -> Fixture {
        Fixture(name: "kamera-insel-\(name)", size: size) {
            let screen = islandScreen(size)
            let rows = NotchStatusModel.rows(from: inputs, now: islandNow, showFreshDone: true)
            let summary = NotchStatusModel.summary(of: rows)
            let sections = expanded ? NotchStatusModel.sections(of: rows) : []
            let occupancy = islandOccupancy(size, crowded: crowded, tight: tight, microphone: microphone, music: music)
            let signal = NotchIslandSignal(summary: summary)
            let stage = NotchIslandGeometry.presentation(signal: signal, screen: screen, occupancy: occupancy)
            let band = NotchIslandGeometry.band(
                screen: screen, occupancy: occupancy, presentation: stage, digits: signal?.digits ?? 1)
            var frame = NotchGeometry.panelFrame(screen: screen, mode: .compact(chipCount: summary.chipCount), islandBand: band)
            var display = NotchDisplay(
                style: NotchStatusController.displayStyle(screen: screen, islandBand: band),
                summary: summary, alert: alert, isExpanded: expanded, sections: sections,
                selectedRowID: selectFirst ? sections.first?.rows.first?.id : nil,
                cameraOffset: screen.notchCenterX - frame.midX)
            if expanded || alert != nil {
                let kind: NotchIslandLargeKind = expanded
                    ? .list(rowCount: sections.reduce(0) { $0 + $1.rows.count }, sectionCount: sections.count) : .alert
                let form = NotchIslandLargeGeometry.form(screen: screen, kind: kind, occupancy: occupancy)
                let seed = NotchIslandLargeGeometry.outline(
                    of: NotchIslandLargeGeometry.seedFrame(
                        screen: screen, band: band, presentation: stage, occupancy: occupancy),
                    screen: screen)
                let open = NotchIslandLargeGeometry.openOutline(form)
                display.cameraOffset = 0
                display.islandLarge = progress >= 1
                    ? .open(form) : .closed(form, outline: seed.interpolated(to: open, progress: progress))
                // Wie der Controller: die Art des Wartens, sonst das Projekt.
                display.alertDetail = alert.flatMap { alert in
                    NotchStatusController.alertDetail(kind: alert.kind, input: inputs.first { $0.title == alert.title })
                }
                frame = NotchIslandLargeGeometry.canvas(form.frame, margin: NotchIslandLargeGeometry.overshootMargin)
            }
            return AnyView(IslandDesk(size: size, crowded: crowded, tight: tight, microphone: microphone, music: music) {
                NotchStatusView(display: display)
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: screen.frame.maxY - frame.maxY)
            })
        }
    }

    /// Diktat im Fenster der vereinten Pille an der Insel: kompakt in der
    /// Menüleiste, wo die Belegung Platz lässt (`measured: false`: ohne
    /// Messung), sonst die Ausweichform unter der Menüleiste.
    @MainActor
    private static func islandDictation(
        _ name: String, size: CGSize, rest: UnifiedPillRestLook? = nil, midway: Bool = false, microphone: Bool = false,
        crowded: Bool = false, tight: Bool = false, statusGap: CGFloat? = nil, measured: Bool = true,
        configure: @escaping (OverlayController) -> Void = { _ in }
    ) -> Fixture {
        Fixture(name: "kamera-insel-\(name)", size: size) {
            let screen = islandScreen(size)
            let occupancy = islandOccupancy(size, crowded: crowded, tight: tight, microphone: microphone, statusGap: statusGap)
            let band = NotchIslandGeometry.band(screen: screen, occupancy: occupancy)
            let controller = morphController(notch: .island(band), rest: rest)
            configure(controller)
            if let label = controller.quickActionLabel {
                controller.islandCapsule = NotchIslandGeometry.quickActionCapsule(
                    screen: screen, occupancy: measured ? occupancy : nil,
                    contentWidth: OverlayController.quickActionCapsuleWidth(label: label, isHint: controller.isQuickActionHint),
                    maxExtent: size.width / 2 - 24)
            } else {
                controller.islandCapsule = NotchIslandGeometry.dictationCapsule(
                    screen: screen, occupancy: measured ? occupancy : nil, hasBadge: controller.statusBadge != nil)
            }
            controller.islandDictationForm = NotchIslandLargeGeometry.form(
                screen: screen, kind: controller.controllerTargetLabel == nil ? .dictation : .dictationWithTarget,
                occupancy: measured ? occupancy : nil,
                reserve: NotchIslandGeometry.dictationReserve(screen: screen, occupancy: measured ? occupancy : nil))
            // Das Fenster des Diktats beginnt auf Höhe der großen Form.
            return AnyView(IslandDesk(size: size, crowded: crowded, tight: tight, microphone: microphone) {
                RecordingOverlayView(controller: controller)
                    .environment(\.colorScheme, .dark)
                    .padding(.top, NotchIslandLargeGeometry.topInset(screen))
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
        // Diktat: breiter, damit links der Insel Platz wie am echten Bildschirm ist.
        let wide = CGSize(width: 960, height: 130)
        let tall = CGSize(width: 720, height: 540)
        // Aufgeklapptes Diktat: Platz für die große Form.
        let wideOpen = CGSize(width: 960, height: 230)
        let alert = NotchAlert(sessionID: UUID(), title: "Release-Notizen prüfen", kind: .awaitingInput)
        let errorAlert = NotchAlert(sessionID: UUID(), title: "Landing Page Texte", kind: .errored, extraCount: 1)
        let working = [islandInput("Clipboard Verlauf", .working, since: 480),
                       islandInput("Landing Page Texte", .working, since: 70)]
        let busy = (0..<12).map { islandInput("Job \($0)", .working, since: Double($0)) }
            + (0..<3).map { islandInput("Wartet \($0)", .awaitingInput, since: Double($0)) }
            + [islandInput("Fehler", .errored, since: 5), islandInput("Fertig", .idle, since: 9, turnAgo: 9)]

        let restSummary = NotchSummary(working: 2, waiting: 1)
        let wideRest = UnifiedPillRestLook.island(
            summary: restSummary,
            band: NotchIslandGeometry.band(
                screen: islandScreen(wide), occupancy: islandOccupancy(wide), presentation: .compact(.leading)))
        let manyWorking = (0..<12).map { islandInput("Job \($0)", .working, since: Double($0)) }
        let done = [islandInput("Tab-Switcher Review", .idle, since: 60, turnAgo: 60)]

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
            // Expandiert: Hinweis (kurz, von selbst) und Liste (Klick) als
            // EINE große Form um die Kamera. Zeigt Apples Insel etwas
            // (Musik), steht es oben in der Mitte der Form.
            islandStatus("braucht-dich", size: strip, inputs: islandDemoInputs, alert: alert),
            islandStatus("braucht-dich-musik", size: strip, inputs: islandDemoInputs, alert: alert, music: true),
            islandStatus("fehler", size: strip, inputs: islandDemoInputs + [islandInput("Landing Page Texte", .errored, since: 20)],
                         alert: errorAlert),
            islandStatus("liste", size: tall, inputs: islandDemoInputs, expanded: true),
            islandStatus("liste-musik", size: tall, inputs: islandDemoInputs, expanded: true, music: true),
            islandStatus("liste-rechts", size: tall, inputs: islandDemoInputs, expanded: true, crowded: true),
            islandStatus("liste-auswahl", size: tall, inputs: islandDemoInputs, expanded: true, selectFirst: true),
            islandStatus("liste-lang", size: CGSize(width: 720, height: 600), inputs: busy, expanded: true),
            islandStatus("liste-leer", size: CGSize(width: 720, height: 180), inputs: [], expanded: true),
            // Nur ein Zähler: Die andere Seite der Kopfzeile bleibt leer.
            islandStatus("braucht-dich-allein", size: strip, inputs: [islandInput("Release-Notizen prüfen", .awaitingInput, since: 40)],
                         alert: alert),
            // Bewegung in drei Standbildern: die Kapsel, halb offen, offen.
            islandStatus("bewegung-1-kapsel", size: tall, inputs: islandDemoInputs, expanded: true, progress: 0),
            islandStatus("bewegung-2-halb", size: tall, inputs: islandDemoInputs, expanded: true, progress: 0.5),
            islandStatus("bewegung-3-offen", size: tall, inputs: islandDemoInputs, expanded: true, progress: 1),
            // Diktat kompakt: eigene Kapsel links neben der Insel, Wellenform und Zeit.
            islandDictation("diktat", size: wide) { $0.levelModel.level = 0.45 },
            islandDictation("diktat-raute", size: wide) {
                $0.levelModel.level = 0.45
                $0.statusBadge = DictationStatusBadge(waiting: 1, errored: 0)
            },
            // Mit Mikrofon zeigt Apples Insel ihren Punkt; die Kapsel steht daneben.
            islandDictation("diktat-mikrofon", size: wide, microphone: true) { $0.levelModel.level = 0.45 },
            islandDictation("diktat-transkribiert", size: wide) { $0.isTranscribing = true },
            islandDictation("diktat-nachbearbeitung", size: wide) { $0.isPostProcessing = true },
            // Menüs reichen heran: rechts der Insel. Für die Zeit reicht es
            // nirgends: nur die Wellenform. Ohne Messung: die schmalste Form.
            islandDictation("diktat-rechts", size: wide, crowded: true) { $0.levelModel.level = 0.45 },
            islandDictation("diktat-minimal", size: wide, crowded: true, tight: true, statusGap: 120) { $0.levelModel.level = 0.45 },
            islandDictation("diktat-ohne-messung", size: wide, measured: false) { $0.levelModel.level = 0.45 },
            // Klick auf die Kapsel: Sie wächst zur großen Form mit allen Knöpfen.
            islandDictation("diktat-aufgeklappt", size: wideOpen, microphone: true) {
                $0.levelModel.level = 0.45
                $0.statusBadge = DictationStatusBadge(waiting: 1, errored: 0)
                $0.isIslandExpanded = true
            },
            islandDictation("diktat-aufgeklappt-laut", size: wideOpen, microphone: true) {
                $0.levelModel.level = 0.95
                $0.isIslandExpanded = true
            },
            islandDictation("diktat-aufgeklappt-transkribiert", size: wideOpen, microphone: true) {
                $0.isTranscribing = true
                $0.isIslandExpanded = true
            },
            islandDictation("diktat-aufgeklappt-clip", size: wideOpen, microphone: true) {
                $0.levelModel.level = 0.3
                $0.isScreenClipRecording = true
                $0.isIslandExpanded = true
            },
            // Nirgends Platz: trotzdem die schmalste Kapsel neben der Insel,
            // nie die Form unter der Menüleiste.
            islandDictation("diktat-ohne-platz", size: wide, microphone: true, crowded: true, tight: true) {
                $0.levelModel.level = 0.45
                $0.statusBadge = DictationStatusBadge(waiting: 1, errored: 0)
            },
            // Schnellaktion: Kapsel mit Zeichen und Beschriftung neben der
            // Insel (läuft kurz, will nichts: kompakt nach Apples Muster).
            islandDictation("schnellaktion", size: wide) {
                $0.isPostProcessing = true
                $0.quickActionLabel = "Correcting…"
            },
            islandDictation("schnellaktion-hinweis", size: wide) {
                $0.quickActionLabel = "Select text first"
                $0.isQuickActionHint = true
            },
            islandDictation("schnellaktion-rechts", size: wide, crowded: true) {
                $0.isPostProcessing = true
                $0.quickActionLabel = "Correcting…"
            },
            // Langer Hinweis: Die Kapsel wird so breit wie nötig (höchstens wie das Fenster).
            islandDictation("schnellaktion-lang", size: CGSize(width: 1100, height: 130)) {
                $0.quickActionLabel = "Not writable here. The result is on the clipboard."
                $0.isQuickActionHint = true
            },
            islandDictation("schnellaktion-ohne-messung", size: wide, measured: false) {
                $0.isPostProcessing = true
                $0.quickActionLabel = "Correcting…"
            },
            // Aufnahme per Controller: die große Form steht von selbst offen,
            // Ziel-Chat und Modus sind ohne Klick zu sehen.
            islandDictation("diktat-controller", size: CGSize(width: 960, height: 260), microphone: true) {
                $0.levelModel.level = 0.45
                $0.controllerTargetLabel = "Chat A"
            },
            // Übergang: Ruhebild (Kapsel mit Zeichen und Zahl), Mitte, und aus
            // der leeren Insel, wenn an ihr nichts los ist.
            islandDictation("uebergang-ruhe", size: wide, rest: wideRest),
            islandDictation("uebergang-mitte", size: wide, rest: wideRest, midway: true),
            islandDictation("uebergang-leer", size: wide, rest: .notchBand),
        ]
    }
}
