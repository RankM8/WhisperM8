import SwiftUI

/// Wach-Knopf in der Sidebar-Fußzeile: Aus → am Strom, solange ein Chat
/// arbeitet → immer wach → Aus. Das Symbol zeigt die Stufe, die Farbe, ob der
/// Mac gerade wirklich wach gehalten wird.
struct SidebarStayAwakeButton: View {
    @ObservedObject private var controller = StayAwakeController.shared

    var body: some View {
        Button {
            controller.cycle()
        } label: {
            Group {
                if controller.isAwaitingPermission {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: Self.symbolName(for: controller.mode))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(tint)
                }
            }
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(controller.isAwaitingPermission)
        .help(Self.helpText(
            mode: controller.mode,
            isHolding: controller.isHoldingAwake,
            alwaysSince: controller.alwaysSince,
            lastEnd: controller.lastEndReason
        ))
        .accessibilityLabel(Text("Keep Mac awake"))
        .accessibilityValue(Text(Self.title(for: controller.mode)))
        .onAppear { controller.start() }
    }

    private var tint: Color {
        switch controller.mode {
        case .off: return AgentTheme.textSecondary
        case .whileWorking: return controller.isHoldingAwake ? AgentTheme.accent : AgentTheme.textSecondary
        case .always: return .orange
        }
    }

    static func symbolName(for mode: StayAwakeMode) -> String {
        switch mode {
        case .off: return "moon.zzz"
        case .whileWorking: return "powerplug"
        case .always: return "sun.max.fill"
        }
    }

    static func title(for mode: StayAwakeMode) -> String {
        switch mode {
        case .off: return String(localized: "Mac sleeps as usual")
        case .whileWorking: return String(localized: "Awake on power while a chat works, even with the lid closed")
        case .always: return String(localized: "Always awake, also on battery and with the lid closed")
        }
    }

    static func helpText(mode: StayAwakeMode, isHolding: Bool, alwaysSince: Date?, lastEnd: StayAwakeEndReason?) -> String {
        var lines = [title(for: mode)]
        switch mode {
        case .off:
            break
        case .whileWorking:
            lines.append(isHolding ? String(localized: "Right now: keeping the Mac awake.") : String(localized: "Right now: no chat is working or not on power."))
        case .always:
            if let alwaysSince {
                let end = alwaysSince.addingTimeInterval(StayAwakePolicy.alwaysTimeLimit)
                let time = end.formatted(date: .omitted, time: .shortened)
                lines.append(String(localized: "Ends at \(time), or earlier on low battery or when the Mac gets hot."))
            }
        }
        if let lastEnd, mode != .always {
            lines.append(endText(lastEnd))
        }
        let action: String
        switch mode.next {
        case .off: action = String(localized: "let the Mac sleep")
        case .whileWorking: action = String(localized: "awake while chats work")
        case .always: action = String(localized: "always awake")
        }
        lines.append(String(localized: "Click: \(action)"))
        return lines.joined(separator: "\n")
    }

    static func endText(_ reason: StayAwakeEndReason) -> String {
        switch reason {
        case .lowBattery: return String(localized: "“Always awake” ended: battery at 20 %.")
        case .hot: return String(localized: "“Always awake” ended: the Mac got too hot.")
        case .timeLimit: return String(localized: "“Always awake” ended after 4 hours.")
        }
    }
}
