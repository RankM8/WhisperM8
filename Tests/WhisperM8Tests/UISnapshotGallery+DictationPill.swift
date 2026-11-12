import SwiftUI
import XCTest
@testable import WhisperM8

/// Snapshot-Fixtures der Diktat-Pille in allen Zuständen (Mini und Voll),
/// als Vergleichsgrundlage für die vereinte Pille: Die Diktat-Zustände müssen
/// davor und danach gleich aussehen. Animierte Zustände (verbindet,
/// transkribiert, verbessert) hängen an der Uhrzeit und unterscheiden sich
/// zwischen zwei Läufen im Kern.
extension UISnapshotGallery {
    @MainActor
    static func dictationPillController(
        style: OverlayStyle = .mini,
        configure: (OverlayController) -> Void = { _ in }
    ) -> OverlayController {
        let controller = OverlayController()
        controller.overlayStyle = style
        controller.selectedOutputMode = OutputMode.builtInModes.first { $0.id == OutputMode.defaultMode().id }
            ?? OutputMode.defaultMode()
        controller.outputModes = OutputMode.builtInModes
        configure(controller)
        return controller
    }

    /// Kontext wie im Entwurf: Chat, markierter Text und zwei Bildschirmfotos.
    static var dictationPillDemoContext: TranscriptContextBundle {
        let shot = URL(fileURLWithPath: "/tmp/whisperm8-snapshot-gibt-es-nicht.png")
        return TranscriptContextBundle(
            selectedText: SelectedContext(text: "Markierter Text", sourceAppName: "Notes", sourceBundleIdentifier: nil),
            agentChat: AgentChatContextRef(
                sessionID: UUID(), provider: .claude, projectName: "whisperm8", projectPath: "/tmp/whisperm8",
                title: "Pille vereint", externalSessionID: nil),
            screenshots: [
                ContextAttachment(kind: .screenshot, fileURL: shot),
                ContextAttachment(kind: .screenshot, fileURL: shot),
            ],
            createdAt: Date(timeIntervalSince1970: 1_800_000_000))
    }

    @MainActor
    static func dictationPillFixtures() -> [Fixture] {
        let mini = CGSize(width: 360, height: 80)
        let wide = CGSize(width: 620, height: 80)

        func pill(_ name: String, size: CGSize, style: OverlayStyle = .mini,
                  storage: [String: Any] = [:], configure: @escaping (OverlayController) -> Void) -> Fixture {
            Fixture(name: "diktatpille-\(name)", size: size, storage: storage) {
                let controller = dictationPillController(style: style, configure: configure)
                return AnyView(RecordingPillView(controller: controller).padding(20))
            }
        }

        return [
            pill("mini-verbindet", size: mini) { $0.isConnecting = true },
            pill("mini-aufnahme-stille", size: mini) { $0.levelModel.level = 0 },
            pill("mini-aufnahme-pegel", size: mini) { $0.levelModel.level = 0.45 },
            pill("mini-aufnahme-laut", size: mini) { $0.levelModel.level = 0.98 },
            pill("mini-transkribiert", size: mini) { $0.isTranscribing = true },
            pill("mini-verbessert", size: mini) { $0.isPostProcessing = true },
            pill("mini-kontext", size: wide) {
                $0.levelModel.level = 0.45
                $0.contextBundle = dictationPillDemoContext
            },
            pill("mini-ohne-modus", size: mini) { $0.showModePickerInMiniOverlay = false },
            pill("mini-ohne-haken", size: mini) { $0.showConfirmButton = false },
            pill("mini-hover", size: wide) {
                $0.levelModel.level = 0.45
                $0.isHoverExpanded = true
            },
            pill("mini-controller", size: wide) {
                $0.levelModel.level = 0.45
                $0.controllerTargetLabel = "Jarvis: Supervisor"
            },
            pill("mini-clip", size: wide) {
                $0.levelModel.level = 0.45
                $0.isScreenClipRecording = true
            },
            pill("voll-aufnahme", size: wide, style: .full) { $0.levelModel.level = 0.45 },
            pill("voll-transkribiert", size: wide, style: .full) { $0.isTranscribing = true },
            pill("voll-kontext", size: wide, style: .full) {
                $0.levelModel.level = 0.45
                $0.contextBundle = dictationPillDemoContext
            },
            pill("schnellaktion-arbeitet", size: mini) {
                $0.isPostProcessing = true
                $0.quickActionLabel = String(localized: "Correcting…")
            },
            pill("schnellaktion-hinweis", size: mini) {
                $0.quickActionLabel = String(localized: "Select text first")
                $0.isQuickActionHint = true
            },
        ]
    }
}
