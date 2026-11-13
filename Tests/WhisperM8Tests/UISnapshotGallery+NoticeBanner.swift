import SwiftUI
@testable import WhisperM8

/// Meldungsbanner der Chat-Ansicht in einer schmalen Grid-Pane (320 pt, etwa
/// eine Spalte im 3×3-Grid), mit den langen deutschen Texten: nur Fehler,
/// Fehler mit „Prozess beenden“, Fehler plus Hinweis des Rückfalls, nur Hinweis.
extension UISnapshotGallery {
    static let noticeBannerPaneWidth: CGFloat = 320

    static let noticeBannerCodexError = "soak codex lässt sich nicht fortsetzen: Ein Codex-Prozess außerhalb von WhisperM8 (PID 48211), vermutlich in einem Terminalfenster, wurde mit diesem Gespräch gestartet und läuft noch. Schließe ihn dort oder nutze „Prozess beenden“. Ein zweiter Codex-Prozess auf demselben Gespräch würde es doppelt führen."
    static let noticeBannerFallback = "Nach dem Neustart nicht fortgesetzt: Dieser Chat hat noch keine gebundene Sitzungs-ID, obwohl er schon Turns hatte. Sein Verlauf bleibt erhalten; starte ihn wieder, sobald die Sitzung gebunden ist, oder beginne einen neuen Chat."

    static let noticeBannerStates: [(name: String, error: String?, notice: String?, phase: AgentSessionNoticeBanner.CodexEndPhase?)] = [
        ("nur-fehler", noticeBannerCodexError, nil, nil),
        ("fehler-prozess-beenden", noticeBannerCodexError, nil, .ready),
        ("fehler-und-hinweis", noticeBannerCodexError, noticeBannerFallback, .ready),
        ("nur-hinweis", nil, noticeBannerFallback, nil),
    ]

    @MainActor
    static func noticeBanner(error: String?, notice: String?, phase: AgentSessionNoticeBanner.CodexEndPhase?) -> some View {
        AgentSessionNoticeBanner(errorMessage: error, fallbackNotice: notice, codexEndPhase: phase, onClose: {})
            .environment(\.locale, Locale(identifier: "de"))
            .frame(width: noticeBannerPaneWidth)
            .fixedSize(horizontal: false, vertical: true)
    }

    @MainActor
    static func noticeBannerFixtures() -> [Fixture] {
        noticeBannerStates.map { state in
            Fixture(name: "meldungsbanner-\(state.name)", size: CGSize(width: noticeBannerPaneWidth, height: 360)) {
                AnyView(
                    VStack(spacing: 0) {
                        noticeBanner(error: state.error, notice: state.notice, phase: state.phase)
                        Spacer(minLength: 0)
                    }
                    .frame(width: noticeBannerPaneWidth, height: 360)
                    .background(AgentTheme.background)
                )
            }
        }
    }
}
