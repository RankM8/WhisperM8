import Combine
import SwiftUI

// MARK: - Jarvis-Notiz: Karte am Kachelkopf im Grid
//
// Daten: `JarvisNotesStore` (Board-Einträge, nur bei lebendem Jarvis).
// Regeln fürs Auf- und Zuklappen: `JarvisNoteExpansion`. Entwurf und
// Entscheidungen: docs/design/randnotiz-karte.html, docs/plans/jarvis-randnotizen.md.

/// Umgedrehte `ChromeTabShape`: Die Karte hängt am Kachelkopf, oben mit
/// konkaven Füßen, unten mit runden Ecken. `closed` = Füllfläche (oben über
/// die volle Breite geschlossen), sonst der Umriss ohne Oberkante — so läuft
/// der Strich aus dem Kopf heraus, um die Karte und zurück, wie bei den Tabs.
///
/// Der `rect` umfasst Karte UND Füße; die Kartenkanten liegen um `footRadius`
/// eingerückt (Aufrufer: `.padding(.horizontal, -footRadius)`).
struct HangingNoteShape: Shape {
    var cornerRadius: CGFloat = 7
    var footRadius: CGFloat = ChromeTabMetrics.footSize
    var closed = true

    func path(in rect: CGRect) -> Path {
        let left = rect.minX + footRadius
        let right = rect.maxX - footRadius
        guard right > left, rect.height > footRadius + cornerRadius else { return Path(rect) }

        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addArc(
            tangent1End: CGPoint(x: left, y: rect.minY),
            tangent2End: CGPoint(x: left, y: rect.minY + footRadius),
            radius: footRadius
        )
        path.addLine(to: CGPoint(x: left, y: rect.maxY - cornerRadius))
        path.addArc(
            tangent1End: CGPoint(x: left, y: rect.maxY),
            tangent2End: CGPoint(x: left + cornerRadius, y: rect.maxY),
            radius: cornerRadius
        )
        path.addLine(to: CGPoint(x: right - cornerRadius, y: rect.maxY))
        path.addArc(
            tangent1End: CGPoint(x: right, y: rect.maxY),
            tangent2End: CGPoint(x: right, y: rect.maxY - cornerRadius),
            radius: cornerRadius
        )
        path.addLine(to: CGPoint(x: right, y: rect.minY + footRadius))
        path.addArc(
            tangent1End: CGPoint(x: right, y: rect.minY),
            tangent2End: CGPoint(x: rect.maxX, y: rect.minY),
            radius: footRadius
        )
        if closed { path.closeSubpath() }
        return path
    }
}

// MARK: - Zustand einer Kachel

/// Gemeinsamer Zustand für Pfeil und Karte einer Kachel: Notiz und Handklick
/// je Session aus dem Store, Standard aus `@AppStorage`. Eigene kleine
/// Ansichten statt Lesen im Grid-Body, damit eine Notiz-Änderung nur sie neu
/// zeichnet (siehe `JarvisNotesStore`).
private struct JarvisNoteSubscription: ViewModifier {
    let sessionID: UUID
    let windowID: UUID
    @Binding var note: JarvisBoardEntry?
    @Binding var override: Bool?

    func body(content: Content) -> some View {
        content
            .onReceive(JarvisNotesStore.shared.notePublisher(for: sessionID)) { note = $0 }
            .onReceive(JarvisNotesStore.shared.overridePublisher(windowID: windowID, sessionID: sessionID)) {
                override = $0
            }
    }
}

// MARK: - Pfeil im Kachelkopf

struct JarvisNoteChevron: View {
    let sessionID: UUID
    let windowID: UUID
    let isFocused: Bool
    /// Maus über dem Pfeil: Der Klick soll nur klappen, nicht die Kachel
    /// fokussieren — der Fokuswechsel liefe beim Drücken, die Knopf-Aktion erst
    /// beim Loslassen, und das Ergebnis hinge davon ab, was dazwischen gezeichnet wurde.
    let onHoverChanged: (Bool) -> Void

    @AppStorage(PreferenceKeys.jarvisNotesDefaultOpen) private var defaultOpen = true
    @State private var note: JarvisBoardEntry?
    @State private var override: Bool?

    var body: some View {
        Group {
            if let note {
                let open = JarvisNoteExpansion.isOpen(
                    hasNote: true, override: override, isFocused: isFocused, defaultOpen: defaultOpen)
                Button {
                    JarvisNotesStore.shared.setOverride(!open, windowID: windowID, sessionID: sessionID)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .foregroundStyle(note.light == .needsYou ? AgentTheme.statusError : AgentTheme.textTertiary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover(perform: onHoverChanged)
                .onDisappear { onHoverChanged(false) }
                .animation(.easeOut(duration: 0.2), value: open)
                .help(open ? "Jarvis-Notiz einklappen" : "Jarvis-Notiz aufklappen")
                .accessibilityLabel(open ? "Jarvis-Notiz einklappen" : "Jarvis-Notiz aufklappen")
            }
        }
        .modifier(JarvisNoteSubscription(sessionID: sessionID, windowID: windowID, note: $note, override: $override))
    }
}

// MARK: - Karte über dem Terminal

/// Liegt als Overlay über der ganzen Kachel und zeichnet die Karte direkt
/// unter dem Kopf — über dem Terminal, ohne es zu verschieben (kein PTY-Resize).
struct JarvisNoteCardOverlay: View {
    let sessionID: UUID
    let windowID: UUID
    let isFocused: Bool
    let headerHeight: CGFloat
    /// Deckkraft des Kopf-Graus dieser Kachel — die Karte setzt die Fläche fort.
    let headerOpacity: Double
    /// Maus über der Karte: Der Klick soll die Kachel nicht fokussieren (das
    /// klappte die Karte sofort wieder zu).
    let onHoverChanged: (Bool) -> Void

    @AppStorage(PreferenceKeys.jarvisNotesDefaultOpen) private var defaultOpen = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var note: JarvisBoardEntry?
    @State private var override: Bool?

    static let leadingInset: CGFloat = 10
    static let maxWidth: CGFloat = 420
    static let widthFraction: CGFloat = 0.72
    static let maxHeightFraction: CGFloat = 0.6
    /// Unter dieser Höhe wäre die Karte nur noch Scrollen.
    static let preferredMinHeight: CGFloat = 120
    static let bottomMargin: CGFloat = 8

    /// 60 % der Fläche unter dem Kopf, in flachen Kacheln bis 120 pt — aber nie
    /// über die Kachel hinaus (sonst deckte sie den nächsten Kachelkopf zu).
    static func maxCardHeight(paneHeight: CGFloat, headerHeight: CGFloat) -> CGFloat {
        let available = max(0, paneHeight - headerHeight - bottomMargin)
        return min(available, max(preferredMinHeight, available * maxHeightFraction))
    }

    var body: some View {
        let open = JarvisNoteExpansion.isOpen(
            hasNote: note != nil, override: override, isFocused: isFocused, defaultOpen: defaultOpen)
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                if open, let note {
                    JarvisNoteCard(
                        entry: note,
                        width: min(geometry.size.width * Self.widthFraction, Self.maxWidth),
                        maxHeight: Self.maxCardHeight(paneHeight: geometry.size.height, headerHeight: headerHeight),
                        headerOpacity: headerOpacity,
                        isOwnNote: isFocused
                    )
                    .onHover(perform: onHoverChanged)
                    .onDisappear { onHoverChanged(false) }
                    .padding(.leading, Self.leadingInset)
                    .padding(.top, headerHeight)
                    .transition(reduceMotion ? .opacity : .asymmetric(
                        insertion: .modifier(active: TopReveal(progress: 0), identity: TopReveal(progress: 1))
                            .combined(with: .opacity),
                        removal: .modifier(active: TopReveal(progress: 0), identity: TopReveal(progress: 1))
                            .combined(with: .opacity)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: open)
        }
        // Sicherheitsnetz: nie über die eigene Kachel hinaus zeichnen.
        .clipped()
        .modifier(JarvisNoteSubscription(sessionID: sessionID, windowID: windowID, note: $note, override: $override))
        // Handklick verwerfen beim Hineingehen/Verlassen: fensterweit in
        // `AgentChatsView` (`JarvisNotesStore.selectionChanged`), nicht hier —
        // die Einzelansicht hat keine Kacheln, wechselt aber Chats.
    }
}

/// Deckt die Karte von oben nach unten auf — wie sie aus dem Kopf wächst,
/// ohne den Text zu stauchen.
private struct TopReveal: ViewModifier, Animatable {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content.mask(alignment: .top) {
            GeometryReader { geometry in
                Rectangle().frame(height: geometry.size.height * progress)
            }
        }
    }
}

/// Die Karte selbst: hängende Form plus Inhalt. Eigenständig, damit Snapshots
/// sie ohne Store zeigen können.
struct JarvisNoteCard: View {
    let entry: JarvisBoardEntry
    let width: CGFloat
    let maxHeight: CGFloat
    var headerOpacity: Double = 1
    /// Notiz der Kachel, in der der User arbeitet (bewusst geöffnet): Umriss im Akzent.
    var isOwnNote = false
    var now: Date?

    private var foot: CGFloat { ChromeTabMetrics.footSize }
    /// Gemessene Höhe des Inhalts: Die Karte ist so hoch wie ihr Inhalt und
    /// scrollt erst über `maxHeight` (ein `frame(maxHeight:)` allein füllte
    /// immer die ganze Maximalhöhe).
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollView(.vertical) {
            content
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(key: JarvisNoteHeightKey.self, value: geometry.size.height)
                    }
                }
        }
        .scrollDisabled(contentHeight <= maxHeight)
        .scrollIndicators(contentHeight > maxHeight ? .automatic : .never)
        .frame(width: width, height: min(max(contentHeight, 1), maxHeight), alignment: .top)
        .onPreferenceChange(JarvisNoteHeightKey.self) { contentHeight = $0 }
        .background(alignment: .top) {
            ZStack {
                HangingNoteShape().fill(AgentTheme.background)
                HangingNoteShape().fill(AgentTheme.header.opacity(headerOpacity))
                HangingNoteShape(closed: false)
                    .stroke(isOwnNote ? AgentTheme.accent.opacity(0.55) : AgentTheme.borderStrong, lineWidth: 1)
            }
            .padding(.horizontal, -foot)
        }
        .padding(.horizontal, foot)
        .contentShape(Rectangle())
    }

    private var content: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            JarvisNoteCardContent(entry: entry, now: now ?? context.date)
        }
    }
}

private struct JarvisNoteHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Inhalt der Karte: Arbeitspaket, Eingriff, Blockade, Ziel, drei Meilensteine.
struct JarvisNoteCardContent: View {
    let entry: JarvisBoardEntry
    let now: Date

    static let visibleMilestones = 3
    @State private var showsAllMilestones = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            lead
            if !entry.needs.isEmpty {
                callout(entry.needs, color: AgentTheme.statusError)
            }
            if !entry.blocker.isEmpty {
                callout(entry.blocker, color: AgentTheme.statusAwaiting)
            }
            if !entry.mission.isEmpty, !entry.work.isEmpty {
                section("Ziel") {
                    Text(entry.mission)
                        .font(.system(size: 12))
                        .foregroundStyle(AgentTheme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !entry.milestones.isEmpty {
                section("Meilensteine") { milestones }
            }
            Text("Aktualisiert \(entry.updatedAt.formatted(date: .omitted, time: .shortened)) · Jarvis")
                .font(.system(size: 10))
                .foregroundStyle(AgentTheme.textTertiary)
        }
        .padding(.horizontal, 13)
        .padding(.top, 9)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Arbeitspaket fett; fehlt es, steht das Ziel an seiner Stelle.
    private var lead: some View {
        let text = entry.work.isEmpty ? entry.mission : entry.work
        return (Text(text.isEmpty ? "Noch keine Notiz" : text)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(AgentTheme.textPrimary)
                + Text("  · \(SidebarRelativeTime.short(entry.updatedAt, now: now))")
                    .font(.system(size: 11))
                    .foregroundStyle(AgentTheme.textTertiary))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func callout(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 5))
    }

    private func section<Body: View>(_ title: String, @ViewBuilder body: () -> Body) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased())
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(AgentTheme.textTertiary)
            body()
        }
    }

    private var milestones: some View {
        let shown = showsAllMilestones ? entry.milestones : Array(entry.milestones.prefix(Self.visibleMilestones))
        let hidden = entry.milestones.count - shown.count
        return VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(shown.enumerated()), id: \.offset) { _, milestone in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(milestone.at.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(AgentTheme.textTertiary)
                        .frame(minWidth: 34, alignment: .leading)
                    Text(milestone.text)
                        .font(.system(size: 11.5))
                        .foregroundStyle(AgentTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if hidden > 0 || showsAllMilestones, entry.milestones.count > Self.visibleMilestones {
                Button {
                    showsAllMilestones.toggle()
                } label: {
                    Text(showsAllMilestones ? "▴ weniger" : "▸ \(hidden) ältere")
                        .font(.system(size: 11))
                        .foregroundStyle(AgentTheme.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Schalter in der Workspace-Leiste

/// Standard „Notizen auf/zu" umschalten (Knopf und ⌥⌘N): App-weit, löscht die
/// Handklicks dieses Fensters.
@MainActor
enum JarvisNotesShortcut {
    static let keyCodeN: UInt16 = 45

    /// `store` als Optional: Ein Default-Argument `= .shared` würde außerhalb
    /// des Main Actor ausgewertet (Swift-6-Fehler).
    static func toggleDefault(windowID: UUID, preferences: AppPreferences = .shared,
                              store: JarvisNotesStore? = nil) {
        preferences.jarvisNotesDefaultOpen.toggle()
        (store ?? .shared).clearOverrides(windowID: windowID)
    }
}

/// „Notizen auf/zu": Standard für alle Notiz-Karten (App-weit). Nur sichtbar,
/// wenn ein Chat des Workspaces eine Notiz hat. ⌥⌘N über den Tasten-Monitor
/// des Fensters (`handleJarvisNotesShortcut`).
struct JarvisNotesToggleButton: View {
    let windowID: UUID
    let sessionIDs: Set<UUID>

    @AppStorage(PreferenceKeys.jarvisNotesDefaultOpen) private var defaultOpen = true
    @State private var notedSessions: Set<UUID> = []

    var body: some View {
        Group {
            if !notedSessions.isDisjoint(with: sessionIDs) {
                Button {
                    JarvisNotesShortcut.toggleDefault(windowID: windowID)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "note.text")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Notizen")
                        Text(defaultOpen ? "auf" : "zu")
                            .foregroundStyle(defaultOpen ? AgentTheme.accent : AgentTheme.textTertiary)
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(defaultOpen ? AgentTheme.accent : AgentTheme.textSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(defaultOpen ? AgentTheme.accentTintSoft : Color.clear,
                                in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .stroke(defaultOpen ? AgentTheme.accent.opacity(0.45) : AgentTheme.borderStrong, lineWidth: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Jarvis-Notizen standardmäßig \(defaultOpen ? "zuklappen" : "aufklappen") (⌥⌘N)")
                .accessibilityLabel("Jarvis-Notizen \(defaultOpen ? "zuklappen" : "aufklappen")")
            }
        }
        .onReceive(JarvisNotesStore.shared.notedSessionsPublisher) { notedSessions = $0 }
    }
}
