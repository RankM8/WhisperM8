import SwiftUI

/// Workspace-Auswahl des Controllers (L2 halten im Raster): eine Zeile je
/// angelegtem Workspace mit Farbe, Name, Zahl der Chats und einem Punkt, wenn
/// dort ein Chat wartet. Der aktuelle Workspace trägt „current“. Reine
/// Darstellung des Modells — die Einträge entstehen beim Öffnen im
/// Ereignis-Pfad.
struct ControllerWorkspacePickerPanel: View {
    let picker: ControllerWorkspacePickerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ControllerPanelHeading(text: String(localized: "Switch workspace"))
            ForEach(picker.choices) { choice in
                row(choice, marked: choice.id == picker.selectedID)
            }
        }
        .controllerPanelChrome(width: 320)
    }

    private func row(_ choice: ControllerWorkspaceChoice, marked: Bool) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(hex: choice.colorHex))
                .frame(width: 15, height: 15)
                .overlay {
                    Text(verbatim: String(choice.name.prefix(1)).uppercased())
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                }
            Text(verbatim: choice.name)
                .font(.system(size: 13, weight: choice.isCurrent ? .semibold : .regular))
                .foregroundStyle(AppTheme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            if choice.isCurrent {
                Text("current")
                    .font(.system(size: 11))
                    .foregroundStyle(AppTheme.textTertiary)
            }
            Spacer(minLength: 0)
            if choice.hasWaitingChat {
                // Dasselbe Zeichen wie der Status-Punkt eines wartenden Chats.
                AgentStatusIndicator(status: .awaitingInput, compact: true)
            }
            Text(verbatim: ChatsUIStrings.chatCount(choice.chatCount))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(AppTheme.textTertiary)
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .controllerRowMarking(marked)
        .accessibilityElement(children: .combine)
    }
}
