import AppKit
import SwiftUI
import SwiftTerm

/// Read-only Anzeige eines persistierten Terminal-Snapshots.
///
/// Rendert die `AgentTerminalLine`-Runs als monospace `AttributedString` mit
/// den korrekten ANSI-Farben aus `AgentTerminalPalette` — wir adaptieren das
/// Farbschema beim Open je nach aktueller Light/Dark-Einstellung, sodass der
/// Snapshot konsistent zum aktuellen Theme aussieht.
struct AgentTerminalSnapshotView: View {
    let snapshot: AgentTerminalSnapshot
    let session: AgentChatSession

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            statusBanner

            ScrollView(.vertical) {
                terminalBody
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Snapshot-View beim Oeffnen automatisch ans Ende scrollen —
            // genauso wie ein echtes Terminal beim Reopen die juengste
            // Ausgabe zeigt. macOS 14+ unterstuetzt das nativ ueber den
            // default-anchor; wir brauchen keinen ScrollViewReader.
            .defaultScrollAnchor(.bottom)
            .background(snapshotBackground)
        }
        .background(snapshotBackground)
    }

    @ViewBuilder
    private var terminalBody: some View {
        let palette = AgentTerminalPalette.palette(for: colorScheme)
        Text(attributedBody(palette: palette))
            .font(.system(size: 12, design: .monospaced))
            .textSelection(.enabled)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var snapshotBackground: SwiftUI.Color {
        let palette = AgentTerminalPalette.palette(for: colorScheme)
        return SwiftUI.Color(nsColor: palette.background)
    }

    /// Baut den `AttributedString` aus den Runs aller Zeilen. Newlines werden
    /// zwischen Zeilen eingefuegt.
    private func attributedBody(palette: AgentTerminalPalette.Resolved) -> AttributedString {
        var result = AttributedString()
        for (index, line) in snapshot.lines.enumerated() {
            for run in line.runs {
                var fragment = AttributedString(run.text)
                let resolved = resolveColor(run.fg, palette: palette, isBackground: false)
                fragment.foregroundColor = resolved
                if run.bg != .defaultBg {
                    fragment.backgroundColor = resolveColor(run.bg, palette: palette, isBackground: true)
                }
                if run.bold {
                    fragment.font = .system(size: 12, weight: .bold, design: .monospaced)
                }
                if run.italic {
                    fragment.font = .system(size: 12, design: .monospaced).italic()
                }
                if run.underline {
                    fragment.underlineStyle = .single
                }
                if run.inverse {
                    let bg = resolveColor(run.fg, palette: palette, isBackground: false)
                    let fg = resolveColor(run.bg, palette: palette, isBackground: true)
                    fragment.backgroundColor = bg
                    fragment.foregroundColor = fg
                }
                if run.dim {
                    fragment.foregroundColor = resolved.opacity(0.6)
                }
                result.append(fragment)
            }
            if index < snapshot.lines.count - 1 {
                result.append(AttributedString("\n"))
            }
        }
        return result
    }

    /// `AgentTerminalCellColor` → SwiftUI Color. ANSI 0-15 kommt aus unserer
    /// Palette (light/dark-aware); 16-255 + truecolor sind theme-unabhaengig.
    private func resolveColor(
        _ color: AgentTerminalCellColor,
        palette: AgentTerminalPalette.Resolved,
        isBackground: Bool
    ) -> SwiftUI.Color {
        switch color {
        case .defaultFg:
            return SwiftUI.Color(nsColor: palette.foreground)
        case .defaultBg:
            return SwiftUI.Color(nsColor: palette.background)
        case .ansi(let code) where code < 16:
            let swiftTermColor = palette.ansi16[Int(code)]
            return SwiftUI.Color(
                .sRGB,
                red: Double(swiftTermColor.red) / 65535.0,
                green: Double(swiftTermColor.green) / 65535.0,
                blue: Double(swiftTermColor.blue) / 65535.0
            )
        case .ansi(let code):
            let rgb = Self.ansi256RGB(code)
            return SwiftUI.Color(.sRGB, red: Double(rgb.r) / 255.0, green: Double(rgb.g) / 255.0, blue: Double(rgb.b) / 255.0)
        case .rgb(let r, let g, let b):
            return SwiftUI.Color(.sRGB, red: Double(r) / 255.0, green: Double(g) / 255.0, blue: Double(b) / 255.0)
        }
    }

    /// Standard-256-Color-Palette fuer ANSI-Codes 16-255 (theme-unabhaengig).
    /// 16-231: 6x6x6 color cube. 232-255: 24-step grayscale.
    static func ansi256RGB(_ code: UInt8) -> (r: UInt8, g: UInt8, b: UInt8) {
        if code < 16 {
            // Sollte nie aufgerufen werden (Palette uebernimmt), aber sicher.
            let basic: [(UInt8, UInt8, UInt8)] = [
                (0, 0, 0), (170, 0, 0), (0, 170, 0), (170, 85, 0),
                (0, 0, 170), (170, 0, 170), (0, 170, 170), (170, 170, 170),
                (85, 85, 85), (255, 85, 85), (85, 255, 85), (255, 255, 85),
                (85, 85, 255), (255, 85, 255), (85, 255, 255), (255, 255, 255)
            ]
            let t = basic[Int(code)]
            return (t.0, t.1, t.2)
        }
        if code < 232 {
            let n = Int(code) - 16
            let r = (n / 36) % 6
            let g = (n / 6) % 6
            let b = n % 6
            return (
                r == 0 ? 0 : UInt8(55 + r * 40),
                g == 0 ? 0 : UInt8(55 + g * 40),
                b == 0 ? 0 : UInt8(55 + b * 40)
            )
        }
        // 232-255: grayscale ramp
        let gray = UInt8(8 + (Int(code) - 232) * 10)
        return (gray, gray, gray)
    }

    @ViewBuilder
    private var statusBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "moon.zzz")
                .foregroundStyle(AgentTheme.textTertiary)
            VStack(alignment: .leading, spacing: 2) {
                Text(headlineText)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AgentTheme.textPrimary)
                Text("Resume oben in der Header-Leiste startet \(session.provider.displayName) Code erneut.")
                    .font(.system(size: 11))
                    .foregroundStyle(AgentTheme.textSecondary)
            }
            Spacer()
            Text(relativeTimestamp)
                .font(.system(size: 11))
                .foregroundStyle(AgentTheme.textTertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(AgentTheme.surface)
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundStyle(AgentTheme.border),
            alignment: .bottom
        )
    }

    private var headlineText: String {
        if snapshot.processWasRunning {
            return "Letzter Zustand wiederhergestellt"
        }
        if let code = snapshot.exitCode, code != 0 {
            return "Letzter Lauf endete mit Code \(code)"
        }
        return "Letzter Lauf beendet"
    }

    private var relativeTimestamp: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: snapshot.capturedAt, relativeTo: Date())
    }
}
