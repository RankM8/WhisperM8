import SwiftUI

extension ControllerMenuItem {
    var title: String {
        switch self {
        case .continueWork: return String(localized: "Send “Continue”")
        case .slashCommands: return String(localized: "Commands …")
        case .cycleMode: return String(localized: "Switch mode")
        case .compact: return String(localized: "Summarize")
        case .closeTab: return String(localized: "Close tab")
        case .showBindings: return String(localized: "Show button layout")
        case .pause: return String(localized: "Pause controller")
        }
    }

    /// Kurzer Hinweis rechts, was dabei in den Chat geht.
    var hint: String? {
        switch self {
        case .slashCommands: return "/"
        case .cycleMode: return "⇧⇥"
        case .compact: return "/compact"
        default: return nil
        }
    }

    /// Trennlinie vor diesem Eintrag.
    var startsGroup: Bool { self == .closeTab }
}

/// Menü auf Options: kurze Liste mit Markierung, bedient mit Stick oder
/// Steuerkreuz. Einträge, die Text senden, sind bei offener Rückfrage aus.
struct ControllerMenuPanel: View {
    let heading: String
    let menu: ControllerMenuModel
    let dialogOpen: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: heading)
                .font(.system(size: 11, weight: .semibold))
                .textCase(.uppercase)
                .tracking(0.6)
                .foregroundStyle(AppTheme.textTertiary)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 4)
            ForEach(menu.items(dialogOpen: dialogOpen), id: \.item) { entry in
                if entry.item.startsGroup {
                    Rectangle().fill(AppTheme.border).frame(height: 1).padding(.horizontal, 8).padding(.vertical, 4)
                }
                row(entry.item, enabled: entry.enabled, marked: entry.item == menu.selected)
            }
        }
        .padding(6)
        .frame(width: 300)
        .background(AppTheme.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(AppTheme.borderStrong, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.25), radius: 16, y: 8)
    }

    private func row(_ item: ControllerMenuItem, enabled: Bool, marked: Bool) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: item.title)
                .font(.system(size: 13))
                .foregroundStyle(enabled ? AppTheme.textPrimary : AppTheme.textTertiary)
            Spacer(minLength: 0)
            if let hint = item.hint {
                Text(verbatim: hint)
                    .font(.system(size: 11))
                    .foregroundStyle(AppTheme.textTertiary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background {
            if marked {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(AppTheme.accentTint)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(AppTheme.accent, lineWidth: 2)
                    )
            }
        }
    }
}

/// Zeigt das Menü im aktiven Agent-Chats-Fenster. Eigene kleine View, damit
/// nur sie das `ControllerUIModel` beobachtet.
struct ControllerMenuHost: View {
    let windowID: UUID
    @State private var model = ControllerUIModel.shared
    @State private var windows = AgentWindowStore.shared

    var body: some View {
        if let menu = model.menu, windows.keyAgentChatWindowID == windowID {
            ControllerMenuPanel(
                heading: model.targetTitle ?? String(localized: "Menu"),
                menu: menu,
                dialogOpen: model.menuDialogOpen
            )
            .padding(.bottom, ControllerLegendBar.height + 12)
            .transition(.opacity)
        }
    }
}
