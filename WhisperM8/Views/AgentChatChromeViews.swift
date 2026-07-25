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

/// Vollständige Chrome-Tab-Silhouette als EIN durchgehender Pfad: konkaver
/// linker Fuß, linke Seite, abgerundete Oberkante, rechte Seite, konkaver
/// rechter Fuß. Die Unterkante bleibt offen.
///
/// Bewusst ein einziger Pfad statt Tab + zwei separate Füße: als Stroke ist
/// die Gruppenfarbe dadurch ein ununterbrochener Zug von der Bodenlinie um
/// den aktiven Tab herum und zurück — getrennte Shapes hinterlassen an der
/// Abzweigung einen sichtbaren Sporn.
///
/// Der `rect` umfasst Tab UND beide Füße; die Tab-Kanten liegen deshalb um
/// `footRadius` eingerückt (Aufrufer: `.padding(.horizontal, -footRadius)`).
/// Tangenten-Bögen statt Winkelangaben — die Anschlusspunkte ergeben sich
/// so zwangsläufig und können nicht um Bruchteile auseinanderlaufen.
struct ChromeTabShape: Shape {
    var cornerRadius: CGFloat = 7
    var footRadius: CGFloat = ChromeTabMetrics.footSize

    func path(in rect: CGRect) -> Path {
        let left = rect.minX + footRadius
        let right = rect.maxX - footRadius
        guard right > left else { return Path(rect) }

        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addArc(
            tangent1End: CGPoint(x: left, y: rect.maxY),
            tangent2End: CGPoint(x: left, y: rect.maxY - footRadius),
            radius: footRadius
        )
        path.addLine(to: CGPoint(x: left, y: rect.minY + cornerRadius))
        path.addArc(
            tangent1End: CGPoint(x: left, y: rect.minY),
            tangent2End: CGPoint(x: left + cornerRadius, y: rect.minY),
            radius: cornerRadius
        )
        path.addLine(to: CGPoint(x: right - cornerRadius, y: rect.minY))
        path.addArc(
            tangent1End: CGPoint(x: right, y: rect.minY),
            tangent2End: CGPoint(x: right, y: rect.minY + cornerRadius),
            radius: cornerRadius
        )
        path.addLine(to: CGPoint(x: right, y: rect.maxY - footRadius))
        path.addArc(
            tangent1End: CGPoint(x: right, y: rect.maxY),
            tangent2End: CGPoint(x: rect.maxX, y: rect.maxY),
            radius: footRadius
        )
        return path
    }
}

enum ChromeTabMetrics {
    /// Seitliche Ausstellung der Fußkurven über die Tab-Breite hinaus.
    static let footSize: CGFloat = 7
}

/// Chip-Text: Weiß oder Schwarz — je nachdem, was auf der Gruppenfarbe
/// tatsächlich den höheren Kontrast liefert. Bewusst über die WCAG-
/// Relativluminanz (linearisiertes sRGB) statt über gamma-kodierte Luma:
/// kräftige Mitteltöne wie Grün oder Orange bekämen sonst weißen Text mit
/// unter 2:1 Kontrast.
func chipTextColor(forHex hex: String) -> Color {
    let scanner = Scanner(string: hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")))
    var rgb: UInt64 = 0
    scanner.scanHexInt64(&rgb)

    func linear(_ channel: Double) -> Double {
        channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
    }
    let red = linear(Double((rgb >> 16) & 0xFF) / 255.0)
    let green = linear(Double((rgb >> 8) & 0xFF) / 255.0)
    let blue = linear(Double(rgb & 0xFF) / 255.0)
    let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue

    let contrastOnWhite = 1.05 / (luminance + 0.05)
    let contrastOnBlack = (luminance + 0.05) / 0.05
    return contrastOnBlack >= contrastOnWhite
        ? Color.black.opacity(0.86)
        : Color.white.opacity(0.97)
}

/// Gruppen-Label im Chrome-Stil: aufgeklappt ein GEFÜLLTER Farbchip,
/// eingeklappt ein umrandeter Chip (wie Chromes kollabierte Gruppen).
/// Der Chip sitzt vertikal mittig vor den vollhohen Mitglieds-Tabs.
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
            HStack(spacing: 4) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 110)
                    .fixedSize(horizontal: true, vertical: false)
                Text("\(count)")
                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                    .opacity(0.75)
                    .fixedSize()
            }
            .foregroundStyle(
                isCollapsed
                    ? groupColor
                    : chipTextColor(forHex: colorHex).opacity(isHovered ? 1 : 0.94)
            )
            .padding(.horizontal, 7)
            .frame(height: 19)
            .background {
                if isCollapsed {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(groupColor.opacity(isHovered ? 0.14 : 0))
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(groupColor, lineWidth: 1.5)
                } else {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isHovered ? groupColor.opacity(0.86) : groupColor)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .padding(.leading, 2)
        .padding(.trailing, 5)
        .padding(.bottom, 4.5)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .animation(.easeOut(duration: 0.12), value: isCollapsed)
        .help(
            isCollapsed
                ? "Tab-Gruppe aufklappen · Ziehen verschiebt die ganze Gruppe"
                : "Tab-Gruppe einklappen · Ziehen verschiebt die ganze Gruppe"
        )
    }
}

/// Tab der globalen Tab-Bar im Chrome-Stil: der aktive Tab trägt die
/// Header-Fläche, ist unten komplett offen und „steht" mit konkaven
/// Fußkurven auf dem Header. In einer Gruppe umschließt ihn die
/// Gruppenfarbe als Kontur, die über die Füße in die Bodenlinie mündet.
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

    /// Silhouette des AKTIVEN Tabs samt Füßen. Wird über
    /// `.padding(.horizontal, -footSize)` seitlich ausgestellt, ohne das
    /// Layout zu verändern.
    private var chromeShape: ChromeTabShape { ChromeTabShape() }
    private var foot: CGFloat { ChromeTabMetrics.footSize }

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
                        // Fläche INKLUSIVE der beiden Fußkurven — der Tab
                        // steht damit auf dem Header statt an ihm zu enden.
                        chromeShape.fill(AgentTheme.header)
                            .padding(.horizontal, -foot)
                        if groupColor == nil, let customColor {
                            // Custom-Farbe eines Einzel-Tabs: 2pt-Kappe oben.
                            chromeShape.stroke(customColor, lineWidth: 2)
                                .padding(.horizontal, -foot)
                                .mask(Rectangle().padding(.bottom, 2))
                        }
                        if isMultiSelected {
                            chromeShape.fill(AgentTheme.accentTint.opacity(0.20))
                                .padding(.horizontal, -foot)
                        }
                    } else if isHovered {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(AgentTheme.surface.opacity(0.72))
                    }

                    if isMultiSelected, !isSelected {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(AgentTheme.accentTint.opacity(0.42))
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(AgentTheme.accent.opacity(0.75), lineWidth: 1.4)
                    }
                }
            }
            // Gruppen-Kontur: EIN Zug von der Bodenlinie um den Tab und
            // zurück — Seiten, Oberkante und beide Fußbögen in einem Pfad.
            .overlay {
                if isSelected, let groupColor {
                    chromeShape
                        .stroke(groupColor, lineWidth: 2)
                        .padding(.horizontal, -foot)
                        .allowsHitTesting(false)
                }
            }
            // Mehrfach-Auswahl am aktiven Tab: derselbe offene Pfad statt
            // eines geschlossenen Rings — ein Ring quer über die Unterkante
            // würde die nahtlose Fläche zum Header zerschneiden.
            .overlay {
                if isSelected, isMultiSelected {
                    chromeShape
                        .stroke(AgentTheme.accent.opacity(0.75), lineWidth: 1.4)
                        .padding(.horizontal, -foot)
                        .padding(groupColor == nil ? 0 : 2)
                        .allowsHitTesting(false)
                }
            }
            // Hairline-Trenner nur zwischen INAKTIVEN Gruppen-Mitgliedern.
            .overlay(alignment: .trailing) {
                if !isSelected, groupColor != nil {
                    Rectangle().fill(AgentTheme.border.opacity(0.55)).frame(width: 0.6, height: 15)
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
