import AppKit
import SwiftUI

/// Fängt Mittelklick (Mausrad-Klick) auf der überlagerten View ab, ohne
/// Links-/Rechtsklicks oder Drags zu blockieren. Der Trick: `hitTest` gibt
/// nur für `otherMouse`-Events (Button 2 = Mitte) `self` zurück, sonst
/// `nil` — das Event fällt dann an die darunterliegende SwiftUI-View durch
/// (Klick zum Auswählen, Drag zum Umsortieren, Rechtsklick-Kontextmenü, X).
private final class MiddleClickNSView: NSView {
    var onMiddleClick: () -> Void = {}

    /// Auch der aktivierende Mittelklick auf einem nicht-fokussierten Fenster
    /// soll als echter Klick zählen — sonst aktiviert der erste Mittelklick nur
    /// das Fenster und das `otherMouseUp` geht verloren (Tab schließt erst beim
    /// zweiten Klick).
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        event?.type == .otherMouseDown && event?.buttonNumber == 2
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApp.currentEvent else { return nil }
        switch event.type {
        case .otherMouseDown, .otherMouseUp:
            return event.buttonNumber == 2 ? self : nil
        default:
            return nil
        }
    }

    override func otherMouseDown(with event: NSEvent) {
        // Down beanspruchen, damit das zugehörige Up hier ankommt.
        guard event.buttonNumber == 2 else { super.otherMouseDown(with: event); return }
    }

    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2 else { super.otherMouseUp(with: event); return }
        onMiddleClick()
    }
}

struct MiddleClickCatcher: NSViewRepresentable {
    var onMiddleClick: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = MiddleClickNSView()
        view.onMiddleClick = onMiddleClick
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? MiddleClickNSView)?.onMiddleClick = onMiddleClick
    }
}

extension View {
    /// Schließt-per-Mittelklick & Co.: legt einen transparenten Catcher über
    /// die View, der ausschließlich Mittelklicks behandelt.
    func onMiddleClick(_ action: @escaping () -> Void) -> some View {
        overlay(MiddleClickCatcher(onMiddleClick: action))
    }
}

/// Spiegelt das native Titelleisten-Verhalten beim Doppelklick: liest die
/// globale Einstellung „Doppelklick auf Titelleiste" (NSGlobalDomain) und
/// führt die passende Aktion aus. Default „Maximize" = Zoom, falls der Key
/// nicht gesetzt ist. Aufgerufen vom leftMouseDown-Monitor in AgentChatsView,
/// weil `hiddenTitleBar` + `fullSizeContentView` die native Titelleiste mit
/// dem Tab-Strip überdecken und macOS den Doppelklick dort nicht mehr selbst
/// auswertet.
enum TitleBarZoom {
    static func performSystemDoubleClickAction(on window: NSWindow) {
        let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
        switch action {
        case "Minimize":
            window.miniaturize(nil)
        case "None":
            break
        default:
            // „Maximize" = Zoom auf den sichtbaren Bildschirm (kein Vollbild).
            window.zoom(nil)
        }
    }
}

/// Tab der globalen Tab-Bar. Trägt ein Repo-Badge (ProjectAvatar) zur
/// Projektzuordnung — die Tabs sind projektübergreifend gemischt. Eine
/// gesetzte Custom-Farbe tönt den GANZEN Tab dezent (inaktiv schwach,
/// aktiv kräftiger ins Tab-Grau gemischt) statt nur einen Farbstreifen
/// zu zeigen. Keine Border — der aktive Tab hebt sich über die Fläche ab.
struct ChatTabButton: View {
    let session: AgentChatSession
    /// Projekt der Session fürs Repo-Badge. `nil` (Workspace-Inkonsistenz)
    /// fällt auf das Provider-Icon zurück.
    let project: AgentProject?
    let isSelected: Bool
    let isRunning: Bool
    /// Stabile Store-Referenz — Live-Status via Per-Item-Publisher,
    /// gleiche Mechanik wie `SessionListButton`.
    let statusStore: AgentSessionRuntimeStatusStore
    let isAwaitingInput: Bool
    var onSelect: () -> Void
    var onClose: () -> Void

    @State private var isHovered = false
    @State private var liveStatus: AgentSessionRuntimeStatus?

    private var customColor: Color? {
        guard let hex = session.color, !hex.isEmpty else { return nil }
        return Color(hex: hex)
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 6) {
                if let project {
                    ProjectAvatar(project: project, size: 13)
                        .help(project.name)
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
            .padding(.horizontal, 8)
            .frame(minWidth: 100, maxWidth: 200, minHeight: 24, maxHeight: 24)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: 6).fill(tabBackground)
                    if let customColor {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(customColor.opacity(tintOpacity))
                    }
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .onReceive(statusStore.statusPublisher(for: session.id)) { liveStatus = $0 }
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
        } else {
            switch resolvedStatus {
            case .working:
                Circle().fill(Color.green).frame(width: 5, height: 5)
                    .help("Arbeitet …")
            case .awaitingInput:
                Circle().fill(Color.orange).frame(width: 5, height: 5)
                    .help("Wartet möglicherweise auf User-Input")
            case .idle:
                Circle().fill(Color.green.opacity(0.55)).frame(width: 5, height: 5)
                    .help("Bereit")
            case .errored:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.red.opacity(0.8))
                    .help("Mit Fehler beendet")
            case .stopped, .none:
                Color.clear.frame(width: 1, height: 1)
            }
        }
    }

    private var resolvedStatus: AgentSessionRuntimeStatus? {
        if isAwaitingInput { return .awaitingInput }
        if let liveStatus { return liveStatus }
        return isRunning ? .working : nil
    }

    private var tabBackground: Color {
        if isSelected { return AgentTheme.tabSelected }
        if isHovered { return AgentTheme.surface }
        return Color.clear
    }

    private var tintOpacity: Double {
        if isSelected { return 0.24 }
        if isHovered { return 0.17 }
        return 0.11
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
