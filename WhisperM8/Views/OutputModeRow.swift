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
    let onSelect: () -> Void

    var body: some View {
        Button {
            onSelect()
        } label: {
            HStack(spacing: 10) {
                Circle()
                    .fill(mode.isEnabled ? Color.green : Color.secondary.opacity(0.35))
                    .frame(width: 8, height: 8)

                VStack(alignment: .leading, spacing: 2) {
                    Text(mode.name)
                        .font(.body.weight(.semibold))
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Toggle("Enabled", isOn: $isEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(!canToggle)
                    .help(toggleHelp)

                if isDefault {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
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
}
