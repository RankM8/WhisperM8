import SwiftUI

/// Fußzeile der Agent-Chats-Sidebar: links „Einstellungen", rechts die festen
/// Symbol-Knöpfe (Update, Archiv, Wach-Knopf, Glocke, Konten).
///
/// Die Zeile darf der Sidebar nie eine Mindestbreite aufzwingen. Bis
/// 10.11.2026 stand die Beschriftung mit `.fixedSize()` neben den festen
/// Knöpfen. Auf Deutsch brauchte das rund 306 pt, mit Update-Hinweis 338 pt —
/// mehr als die Sidebar hat (ab 276 pt). Der `VStack` der Sidebar wurde so
/// breit wie die Fußzeile und ragte zentriert über seinen Platz hinaus: links
/// aus dem Fenster (Zahnrad abgeschnitten), rechts über Tab-Leiste und
/// Terminal, wo er Klicks schluckte.
///
/// Jetzt weicht die Beschriftung: reicht der Platz nicht, bleibt das Zahnrad.
/// Die Knöpfe rechts sind fest und brauchen zusammen deutlich weniger als die
/// Mindestbreite (`SidebarFooterLayoutTests`).
struct SidebarFooterBar<Trailing: View>: View {
    var onOpenSettings: () -> Void
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 4) {
            // Beide Varianten füllen den Restplatz und schieben die Knöpfe nach
            // rechts; `ViewThatFits` nimmt die erste, deren Wunschbreite passt.
            ViewThatFits(in: .horizontal) {
                labeledSettingsButton
                compactSettingsButton
            }

            trailing()
        }
        .padding(.trailing, 8)
        .padding(.vertical, 7)
    }

    private var labeledSettingsButton: some View {
        // Kein eigenes Padding links: `SidebarRowButtonStyle` bringt die 8 pt
        // Außenkante mit, das Zahnrad fluchtet so mit den Rows darüber.
        Button(action: onOpenSettings) {
            HStack(spacing: 9) {
                Image(systemName: "gearshape")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 16)
                Text("Settings")
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .fixedSize()
                Spacer(minLength: 0)
            }
            .foregroundStyle(AgentTheme.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarRowButtonStyle())
        .help("Open settings")
    }

    private var compactSettingsButton: some View {
        HStack(spacing: 0) {
            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AgentTheme.textSecondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open settings")
            .accessibilityLabel(Text("Settings"))
            Spacer(minLength: 0)
        }
        .padding(.leading, 10)
    }
}
