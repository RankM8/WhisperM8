import AppKit
import SwiftUI

struct ProviderTab: View {
    let provider: AgentProvider
    let isActive: Bool
    var action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                ProviderIcon(
                    provider: provider,
                    size: 12,
                    tint: isActive ? AgentTheme.textPrimary : AgentTheme.textTertiary
                )
                Text(provider.displayName)
                    .font(.system(size: 11, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(isActive ? AgentTheme.textPrimary : AgentTheme.textSecondary)
            }
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(background, in: RoundedRectangle(cornerRadius: 3))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    private var background: Color {
        if isActive { return AgentTheme.tabSelected }
        if isHovered { return AgentTheme.surface }
        return Color.clear
    }
}

struct ChatTabButton: View {
    let session: AgentChatSession
    let isSelected: Bool
    var onSelect: () -> Void
    var onClose: () -> Void

    @State private var isHovered = false

    private var customColor: Color? {
        guard let hex = session.color, !hex.isEmpty else { return nil }
        return Color(hex: hex)
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 6) {
                if let customColor {
                    Rectangle()
                        .fill(customColor.opacity(isSelected ? 0.85 : 0.55))
                        .frame(width: 3, height: 14)
                } else {
                    ProviderIcon(provider: session.provider, size: 11, tint: AgentTheme.textTertiary)
                }

                Text(session.title)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? AgentTheme.textPrimary : AgentTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                trailingIndicator
                    .frame(width: 18, alignment: .trailing)
            }
            .padding(.horizontal, 7)
            .frame(minWidth: 90, maxWidth: 200, minHeight: 22, maxHeight: 22)
            .background(tabBackground, in: RoundedRectangle(cornerRadius: 3))
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .stroke(borderColor, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 3))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }

    @ViewBuilder
    private var trailingIndicator: some View {
        if isHovered || isSelected {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(AgentTheme.textSecondary)
                .frame(width: 16, height: 16)
                .background(AgentTheme.hover, in: RoundedRectangle(cornerRadius: 3))
                .contentShape(Rectangle())
                .onTapGesture { onClose() }
                .help("Tab schließen")
        } else if session.status == .running {
            Circle()
                .fill(AgentTheme.textTertiary)
                .frame(width: 4, height: 4)
        } else if session.status != .archived {
            Text(session.status.displayName)
                .font(.system(size: 9))
                .foregroundStyle(AgentTheme.textTertiary)
                .lineLimit(1)
        } else {
            Color.clear.frame(width: 1, height: 1)
        }
    }

    private var tabBackground: Color {
        if isSelected { return AgentTheme.tabSelected }
        if isHovered { return AgentTheme.surface }
        return Color.clear
    }

    private var borderColor: Color {
        isSelected ? AgentTheme.borderStrong : AgentTheme.border
    }
}

enum AgentChatColorName {
    static let map: [String: String] = [
        "#32D74B": "Grün",
        "#FF9F0A": "Orange",
        "#0A84FF": "Blau",
        "#BF5AF2": "Lila",
        "#FF453A": "Rot",
        "#64D2FF": "Türkis",
        "#FFD60A": "Gelb",
        "#AC8E68": "Sand"
    ]

    static func label(for hex: String) -> String {
        map[hex] ?? hex
    }
}

func colorSwatchImage(hex: String, size: CGFloat = 12) -> NSImage {
    let nsColor = NSColor(Color(hex: hex))
    let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
        nsColor.setFill()
        NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
        NSColor.black.withAlphaComponent(0.25).setStroke()
        let stroke = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
        stroke.lineWidth = 0.5
        stroke.stroke()
        return true
    }
    image.isTemplate = false
    return image
}

struct ProjectAvatar: View {
    let project: AgentProject
    var size: CGFloat = 18

    var body: some View {
        if let icon = loadedIcon() {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(hex: project.color))
                .frame(width: size, height: size)
                .overlay(
                    Text(project.name.prefix(1).uppercased())
                        .font(.system(size: max(8, size * 0.55), weight: .bold))
                        .foregroundStyle(.white)
                )
        }
    }

    private func loadedIcon() -> NSImage? {
        guard let url = project.resolvedIconURL else { return nil }
        return NSImage(contentsOf: url)
    }
}

struct TitlebarIconButton: View {
    let systemImage: String
    let help: String
    var isActive: Bool = false
    var isDisabled: Bool = false
    var action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(foreground)
                .frame(width: 24, height: 22)
                .background(background, in: RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .help(help)
        .onHover { isHovered = $0 && !isDisabled }
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }

    private var foreground: Color {
        if isDisabled { return AgentTheme.textTertiary.opacity(0.6) }
        if isActive { return AgentTheme.textPrimary }
        return AgentTheme.textSecondary
    }

    private var background: Color {
        if isDisabled { return Color.clear }
        if isActive { return AgentTheme.selection }
        if isHovered { return AgentTheme.hover }
        return Color.clear
    }
}

struct BranchTag: View {
    let branch: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 9, weight: .bold))
            Text(formattedBranch)
                .font(.system(size: 10, weight: .semibold).monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(Color(red: 0.78, green: 0.62, blue: 1.0))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Color(red: 0.78, green: 0.62, blue: 1.0).opacity(0.10), in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(red: 0.78, green: 0.62, blue: 1.0).opacity(0.25), lineWidth: 1))
        .frame(maxWidth: 180)
    }

    private var formattedBranch: String {
        branch.hasPrefix("/") ? branch : "/\(branch)"
    }
}

struct HeaderIconButton: View {
    let systemImage: String
    let help: String
    var isActive: Bool = false
    var action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isActive ? AgentTheme.textPrimary : AgentTheme.textSecondary)
                .frame(width: 24, height: 24)
                .background(background, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(AgentTheme.border, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }

    private var background: Color {
        if isActive { return AgentTheme.selection }
        if isHovered { return AgentTheme.surface }
        return AgentTheme.headerTab
    }
}
