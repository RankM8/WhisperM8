import SwiftUI
@testable import WhisperM8

/// Fußzeile der Sidebar in der Mindestbreite und breit. Die Knöpfe rechts sind
/// statisch gezeichnet (gleiche Maße): der echte Wach-Knopf startet beim
/// Erscheinen den Controller samt `sudo -n -l`.
extension UISnapshotGallery {
    /// Die festen Knöpfe der Fußzeile in ihren echten Maßen — schlimmster Fall
    /// mit Update-Hinweis.
    @MainActor
    @ViewBuilder
    static func sidebarFooterTrailingPlaceholders() -> some View {
        ForEach(["arrow.down.circle.fill", "archivebox", "powerplug", "bell"], id: \.self) { symbol in
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(symbol == "arrow.down.circle.fill" ? AgentTheme.accent : AgentTheme.textSecondary)
                .frame(width: 28, height: 28)
        }
        HStack(spacing: 0) {
            ProviderIcon(provider: .claude, size: 13, tint: AgentTheme.textSecondary)
                .frame(width: 26, height: 28)
            ProviderIcon(provider: .codex, size: 13, tint: AgentTheme.textSecondary)
                .frame(width: 26, height: 28)
        }
    }

    @MainActor
    static func sidebarFooterFixtures() -> [Fixture] {
        func footer(_ name: String, width: CGFloat) -> Fixture {
            Fixture(name: name, size: CGSize(width: width + 60, height: 90)) {
                // Rechts 60 pt Content-Fläche: ragte die Fußzeile über die
                // Spalte hinaus, wäre es hier zu sehen.
                AnyView(HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        SidebarFooterBar(onOpenSettings: {}) {
                            sidebarFooterTrailingPlaceholders()
                        }
                    }
                    .background(AppTheme.sidebar)
                    .frame(width: width, alignment: .leading)
                    .clipped()
                    Color.clear.frame(width: 60)
                })
            }
        }
        return [
            footer("sidebar-fusszeile-mindestbreite", width: SidebarWidthResolver.minWidth),
            footer("sidebar-fusszeile-breit", width: 360),
        ]
    }
}
