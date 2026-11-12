import SwiftUI
import XCTest
@testable import WhisperM8

/// Snapshot-Fixtures der vereinten Pille: Ruhe, Hinweis, Liste (ohne Notch),
/// Diktat mit Raute, Diktat an der Notch und ein Vergleich Seite an Seite mit
/// der Diktat-Pille (gleiche Höhe, gleiches Glas, gleicher Rand). Rein
/// darstellend, nichts Echtes wird gelesen.
extension UISnapshotGallery {
    private static let unifiedNow = Date(timeIntervalSince1970: 1_800_000_000)

    private static func unifiedInput(
        _ title: String, _ project: String, _ status: AgentSessionRuntimeStatus,
        since: TimeInterval, turnAgo: TimeInterval? = nil
    ) -> NotchChatInput {
        NotchChatInput(
            id: UUID(), title: title, project: project, status: status,
            statusSince: unifiedNow.addingTimeInterval(-since),
            lastTurnAt: turnAgo.map { unifiedNow.addingTimeInterval(-$0) },
            lastActivityAt: unifiedNow.addingTimeInterval(-since), activity: nil)
    }

    private static var unifiedDemoInputs: [NotchChatInput] {
        [
            unifiedInput("Jarvis: Supervisor", "whisperm8", .awaitingInput, since: 120),
            unifiedInput("Pille vereint", "whisperm8", .working, since: 240),
            unifiedInput("Kampagnen Import", "listm8", .working, since: 660),
            unifiedInput("Release Notizen", "whisperm8", .idle, since: 300, turnAgo: 300),
        ]
    }

    private static func unifiedDisplay(
        inputs: [NotchChatInput], expanded: Bool = false, alert: NotchAlert? = nil, upward: Bool = false
    ) -> NotchDisplay {
        let rows = NotchStatusModel.rows(from: inputs, now: unifiedNow, showFreshDone: true)
        return NotchDisplay(
            style: .pill, summary: NotchStatusModel.summary(of: rows), alert: alert, isExpanded: expanded,
            sections: expanded ? NotchStatusModel.sections(of: rows) : [], opensUpward: upward)
    }

    /// Schreibtisch hinter der Pille: hell im hellen, dunkel im dunklen Bild
    /// (die Pille selbst ist immer schwarz).
    private struct UnifiedDesk<Content: View>: View {
        @Environment(\.colorScheme) private var scheme
        @ViewBuilder let content: Content

        var body: some View {
            ZStack {
                LinearGradient(
                    colors: scheme == .dark
                        ? [Color(red: 0.13, green: 0.15, blue: 0.20), Color(red: 0.22, green: 0.18, blue: 0.20)]
                        : [Color(red: 0.80, green: 0.86, blue: 0.95), Color(red: 0.96, green: 0.89, blue: 0.80)],
                    startPoint: .topLeading, endPoint: .bottomTrailing)
                content
            }
        }
    }

    @MainActor
    static func unifiedPillFixtures() -> [Fixture] {
        let compact = CGSize(width: UnifiedPillGeometry.statusPanelWidth, height: 88)
        let alert = NotchAlert(sessionID: UUID(), title: "Jarvis: Supervisor", kind: .awaitingInput)
        let error = NotchAlert(sessionID: UUID(), title: "Lead Varianten", kind: .errored, extraCount: 1)
        let rows = NotchStatusModel.rows(from: unifiedDemoInputs, now: unifiedNow, showFreshDone: true)
        let listHeight = 88 + NotchGeometry.listHeight(
            rowCount: rows.count, sectionCount: NotchStatusModel.sections(of: rows).count)
        let tall = CGSize(width: UnifiedPillGeometry.statusPanelWidth, height: listHeight)

        func status(_ name: String, size: CGSize, _ display: @escaping () -> NotchDisplay) -> Fixture {
            Fixture(name: "vereint-\(name)", size: size) {
                AnyView(UnifiedDesk { UnifiedStatusPillView(display: display()) })
            }
        }

        func dictation(_ name: String, size: CGSize, configure: @escaping (OverlayController) -> Void) -> Fixture {
            Fixture(name: "vereint-\(name)", size: size) {
                let controller = dictationPillController(configure: configure)
                // In der App ist die Pill immer dunkel (darkAqua am Fenster).
                return AnyView(UnifiedDesk {
                    RecordingPillView(controller: controller).padding(20).environment(\.colorScheme, .dark)
                })
            }
        }

        let notch = OverlayPresentation.notch(width: 185, height: 32)

        return [
            status("ruhe-leer", size: compact) { unifiedDisplay(inputs: []) },
            status("ruhe-zaehler", size: compact) { unifiedDisplay(inputs: unifiedDemoInputs) },
            status("hinweis", size: compact) { unifiedDisplay(inputs: unifiedDemoInputs, alert: alert) },
            status("fehler", size: compact) {
                unifiedDisplay(inputs: unifiedDemoInputs + [unifiedInput("Lead Varianten", "listm8", .errored, since: 20)],
                               alert: error)
            },
            status("liste", size: tall) { unifiedDisplay(inputs: unifiedDemoInputs, expanded: true) },
            status("liste-nach-oben", size: tall) {
                unifiedDisplay(inputs: unifiedDemoInputs, expanded: true, upward: true)
            },
            dictation("diktat-raute", size: CGSize(width: 420, height: 80)) {
                $0.presentation = .pill
                $0.levelModel.level = 0.45
                $0.statusBadge = DictationStatusBadge(waiting: 1, errored: 0)
            },
            dictation("diktat-raute-fehler", size: CGSize(width: 420, height: 80)) {
                $0.presentation = .pill
                $0.isTranscribing = true
                $0.statusBadge = DictationStatusBadge(waiting: 2, errored: 1)
            },
            dictation("notch-diktat", size: CGSize(width: 420, height: 112)) {
                $0.presentation = notch
                $0.levelModel.level = 0.45
                $0.statusBadge = DictationStatusBadge(waiting: 1, errored: 0)
            },
            dictation("notch-diktat-transkribiert", size: CGSize(width: 420, height: 112)) {
                $0.presentation = notch
                $0.isTranscribing = true
            },
            dictation("notch-diktat-schmal", size: CGSize(width: 420, height: 112)) {
                $0.presentation = notch
                $0.quickActionLabel = String(localized: "Select text first")
                $0.isQuickActionHint = true
            },
            // Seite an Seite: oben die Diktat-Pille (Aufnahme, still), darunter
            // die ruhende Pille — gleiche Höhe, gleiches Glas, gleicher Rand.
            Fixture(name: "vereint-vergleich", size: CGSize(width: 428, height: 200)) {
                let controller = dictationPillController { $0.presentation = .pill }
                return AnyView(UnifiedDesk {
                    VStack(spacing: 0) {
                        RecordingPillView(controller: controller).padding(24)
                            .environment(\.colorScheme, .dark)
                        UnifiedStatusPillView(display: unifiedDisplay(inputs: unifiedDemoInputs))
                            .frame(height: 88)
                    }
                })
            },
        ]
    }
}
