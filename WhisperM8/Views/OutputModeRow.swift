import SwiftUI

/// Eine Zeile der Modes-Sidebar in `OutputModesView` — rein praesentational.
///
/// Alle abgeleiteten Werte (Summary, Toggle-Status/-Hilfetext, Default-/Selektions-
/// Flags, Divider) werden vom Parent berechnet und hereingereicht. So bleiben die
/// zwischen Sidebar und `modeEditor` geteilten Helfer (`canDisable`,
/// `modeEnabledBinding`) im Parent — kein Verhaltenswechsel, nur Extraktion.
struct OutputModeRow: View {
    let mode: OutputMode
    let isSelected: Bool
    let isDefault: Bool
    let summary: String
    @Binding var isEnabled: Bool
    let canToggle: Bool
    let toggleHelp: String
    let showDivider: Bool
    /// Modus ist Codex-abhängig, aber Enrichment ist im aktuellen Profil aus →
    /// ausgegraut + Schloss statt Toggle. Rein visuell/informativ.
    var isLocked: Bool = false
    let onSelect: () -> Void

    var body: some View {
        Button {
            onSelect()
        } label: {
            HStack(spacing: 10) {
                Circle()
                    .fill(indicatorColor)
                    .frame(width: 8, height: 8)

                VStack(alignment: .leading, spacing: 2) {
                    Text(mode.name)
                        .font(.body.weight(.semibold))
                    Text(isLocked ? "Needs AI enrichment (Codex)" : summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                if isLocked {
                    Image(systemName: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("Enable an AI-enrichment profile to unlock this mode.")
                } else {
                    Toggle("Enabled", isOn: $isEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .disabled(!canToggle)
                        .help(toggleHelp)
                }

                if isDefault {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .opacity(isLocked ? 0.55 : 1)
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
        )

        if showDivider {
            Divider()
                .padding(.leading, 30)
        }
    }

    private var indicatorColor: Color {
        if isLocked { return Color.secondary.opacity(0.25) }
        return mode.isEnabled ? Color.green : Color.secondary.opacity(0.35)
    }
}
