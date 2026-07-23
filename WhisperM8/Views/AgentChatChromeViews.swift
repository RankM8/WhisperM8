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

private final class WindowDragExclusionNSView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }
}

struct WindowDragExclusionView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = WindowDragExclusionNSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
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

/// Kompaktes Chrome-artiges Gruppenlabel links vor den Mitglieds-Tabs.
/// Die Gruppe selbst bekommt keine Außenkarte und kein Padding; Farbe dient
/// nur als Herkunftsmarke, während aktive/inaktive Zustände über Fläche und
/// Kontur lesbar bleiben.
struct ChatTabGroupLabel: View {
    let title: String
    let count: Int
    let colorHex: String
    let isCollapsed: Bool
    let isActive: Bool
    let onToggle: () -> Void

    @State private var isHovered = false

    private var groupColor: Color { Color(hex: colorHex) }

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 5) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                Circle()
                    .fill(groupColor)
                    .frame(width: 6, height: 6)
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 110, alignment: .leading)
                Text("\(count)")
                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                    .foregroundStyle(AgentTheme.textTertiary)
                    .fixedSize()
            }
            .foregroundStyle(AgentTheme.textPrimary)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(
                groupColor.opacity(isActive ? 0.18 : (isHovered ? 0.13 : 0.09)),
                in: Capsule()
            )
            .overlay(
                Capsule().strokeBorder(
                    groupColor.opacity(isActive ? 0.58 : 0.30),
                    lineWidth: isActive ? 1.2 : 0.8
                )
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .animation(.easeOut(duration: 0.12), value: isCollapsed)
        .help(isCollapsed ? "Tab-Gruppe aufklappen" : "Tab-Gruppe einklappen")
    }
}

/// Tab der globalen Tab-Bar. Die aktive Fläche ist unten bewusst offen und
/// geht ohne Zwischenraum in den Chat-Header über — wie ein aktiver Chrome-Tab.
/// Gruppenfarbe und optionale Custom-Farbe erscheinen nur als feine Marker;
/// die früher vollflächige Tönung entfällt zugunsten einer ruhigen Palette.
struct ChatTabButton: View {
    let session: AgentChatSession
    /// Projekt der Session fürs Repo-Badge. `nil` (Workspace-Inkonsistenz)
    /// fällt auf das Provider-Icon zurück.
    let project: AgentProject?
    let isSelected: Bool
    /// Teil einer Mehrfach-Auswahl (Cmd/Shift-Klick) — Akzent-Ring zusätzlich
    /// zum aktiven (`isSelected`) Tab.
    let isMultiSelected: Bool
    let statusStore: AgentSessionRuntimeStatusStore
    /// Herkunftsfarbe der sichtbaren Workspace-/Projektgruppe. `nil` bei
    /// Einzel-Tabs oder deaktivierter Gruppierung.
    var groupColor: Color? = nil
    var onSelect: () -> Void
    var onClose: () -> Void

    @State private var isHovered = false
    @State private var liveStatus: AgentSessionRuntimeStatus?

    private var customColor: Color? {
        guard let hex = session.color, !hex.isEmpty else { return nil }
        return Color(hex: hex)
    }

    private var markerColor: Color {
        groupColor ?? customColor ?? AgentTheme.accent
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 6) {
                if let project {
                    ProjectAvatar(project: project, size: 13)
                        .help(project.name)
                } else {
                    AgentSessionIcon(session: session, size: 11, tint: AgentTheme.textTertiary)
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
            .frame(minWidth: 100, maxWidth: 190, minHeight: 28, maxHeight: 28)
            .background {
                ZStack {
                    if isSelected {
                        UnevenRoundedRectangle(
                            topLeadingRadius: 7,
                            bottomLeadingRadius: 0,
                            bottomTrailingRadius: 0,
                            topTrailingRadius: 7
                        )
                        .fill(AgentTheme.header)
                    } else if isHovered {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(AgentTheme.surface.opacity(0.72))
                    }

                    if isMultiSelected {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(AgentTheme.accentTint.opacity(isSelected ? 0.20 : 0.42))
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(AgentTheme.accent.opacity(0.75), lineWidth: 1.4)
                    }
                }
            }
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(markerColor.opacity(isSelected ? 0.95 : 0.55))
                    .frame(height: isSelected ? 2 : 1)
            }
            .overlay(alignment: .leading) {
                if isSelected {
                    Rectangle().fill(AgentTheme.borderStrong.opacity(0.65)).frame(width: 0.7)
                }
            }
            .overlay(alignment: .trailing) {
                if isSelected {
                    Rectangle().fill(AgentTheme.borderStrong.opacity(0.65)).frame(width: 0.7)
                } else {
                    Rectangle().fill(AgentTheme.border.opacity(0.55)).frame(width: 0.6, height: 15)
                }
            }
            .overlay(alignment: .bottom) {
                if isSelected {
                    // Überdeckt die Trennkante zum Header: der Tab öffnet sich
                    // optisch nach unten statt als freistehende Pille zu enden.
                    Rectangle()
                        .fill(AgentTheme.header)
                        .frame(height: 2)
                        .offset(y: 1)
                }
            }
            .contentShape(Rectangle())
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
        liveStatus
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
        // Symbol-Only-Control: der Hilfetext ist zugleich das
        // VoiceOver-Label (sonst liest VoiceOver nur den Symbolnamen vor).
        .accessibilityLabel(help)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }

    private var background: Color {
        if isActive { return AgentTheme.selection }
        if isHovered { return AgentTheme.surface }
        return AgentTheme.headerTab
    }
}

/// Kleiner Live-Status-Dot für die selektierte Session (Topbar). Eigene
/// Komponente mit Per-Item-Subscription, damit Status-Änderungen die Farbe
/// zuverlässig invalidieren (der Parent-Body darf `.statuses` nicht lesen).
struct SessionLiveStatusDot: View {
    let sessionID: UUID
    /// PTY-Prozess läuft (Terminal offen) — grün, solange kein needs-input.
    let isProcessRunning: Bool
    let statusStore: AgentSessionRuntimeStatusStore

    @State private var liveStatus: AgentSessionRuntimeStatus?

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .onReceive(statusStore.statusPublisher(for: sessionID)) { liveStatus = $0 }
    }

    private var color: Color {
        if liveStatus == .awaitingInput { return .orange }
        if isProcessRunning { return .green }
        return AgentTheme.textTertiary
    }
}
