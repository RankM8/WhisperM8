import AppKit
import SwiftUI

/// Was die Seitenspalte „Board-Chat“ zeigt (WM8-113). Reine Daten, damit
/// Snapshots die Spalte ohne Fenster und Terminal rendern.
struct BoardChatColumnState: Equatable {
    enum Content: Equatable {
        /// Der Chat ist ein Tab dieses Fensters: sein Terminal steht hier.
        case terminal
        /// Tab eines anderen Fensters. Verschoben wird nur auf Klick.
        case otherWindow(number: Int)
        /// In keinem Fenster offen.
        case notOpen
        /// Das Projekt hat keinen Jarvis und keine Wahl.
        case noChat
    }

    /// Titel des Board-Chats; `nil` ohne Chat.
    var title: String?
    /// Automatisch gewählt (der Jarvis des Projekts) oder von Hand.
    var isAutomatic: Bool
    var content: Content
    /// Prozess läuft. Ohne laufenden Prozess bietet der Kopf Start/Fortsetzen.
    var isRunning: Bool = true
    /// Hat der Chat schon einen Verlauf (dann „Fortsetzen“, sonst „Starten“)?
    var canResume: Bool = true
}

/// Knöpfe der Spalte. Alles, was einen Chat verschiebt oder startet, geht nur
/// von einem Klick aus.
struct BoardChatColumnActions {
    var moveHere: () -> Void = {}
    var openHere: () -> Void = {}
    var openAsTab: () -> Void = {}
    var start: () -> Void = {}
    var setCollapsed: (Bool) -> Void = { _ in }

    static let none = BoardChatColumnActions()
}

/// Die Spalte rechts neben Board und Triage. Das Terminal kommt als Inhalt
/// herein; die Spalte selbst kennt weder Registry noch Fenster.
struct BoardChatColumnView<StatusDot: View, Terminal: View>: View {
    let state: BoardChatColumnState
    let actions: BoardChatColumnActions
    /// Unter dem Terminal: Bezug und Hinweise (Teil b). Nur bei `.terminal`.
    var inputBar: AnyView? = nil
    @ViewBuilder let statusDot: () -> StatusDot
    @ViewBuilder let terminal: () -> Terminal

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(AgentTheme.border)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if state.content == .terminal, let inputBar { inputBar }
            footer
        }
        .background(AgentTheme.background)
    }

    // MARK: Kopf

    private var header: some View {
        HStack(spacing: 6) {
            Text("Board chat")
                .textCase(.uppercase)
                .font(.system(size: 11, weight: .semibold))
                .kerning(0.5)
                .foregroundStyle(AgentTheme.textTertiary)
                .fixedSize()
            if let title = state.title {
                HStack(spacing: 6) {
                    statusDot()
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AgentTheme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(AgentTheme.surface, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(AgentTheme.borderStrong))
                .help(title)
                .layoutPriority(1)
            }
            Spacer(minLength: 4)
            if state.title != nil, state.content == .terminal, !state.isRunning {
                headerButton(systemImage: "play.fill",
                             help: state.canResume ? String(localized: "Resume") : String(localized: "Start"),
                             action: actions.start)
            }
            if state.title != nil, state.content == .terminal {
                headerButton(systemImage: "arrow.up.left.and.arrow.down.right",
                             help: String(localized: "Open as tab"), action: actions.openAsTab)
            }
            headerButton(systemImage: "sidebar.right", help: String(localized: "Hide board chat")) {
                actions.setCollapsed(true)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
        .background(AgentTheme.header)
    }

    private func headerButton(systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AgentTheme.textSecondary)
                .frame(width: 22, height: 22)
                .background(AgentTheme.hover, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    // MARK: Inhalt

    @ViewBuilder
    private var content: some View {
        switch state.content {
        case .terminal:
            terminal()
                .padding(.top, 8)
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
        case .otherWindow(let number):
            notice(
                headline: Text("Running in window \(number)"),
                detail: Text("A chat lives in one window at a time. Moving it here takes its tab out of window \(number)."),
                button: String(localized: "Bring here"),
                accessibility: String(localized: "Bring \(state.title ?? "") to this window"),
                action: actions.moveHere)
        case .notOpen:
            notice(
                headline: Text("Not open in any window"),
                detail: Text("Open it here as a tab. The tickets stay open."),
                button: String(localized: "Open here"),
                accessibility: String(localized: "Open \(state.title ?? "") here"),
                action: actions.openHere)
        case .noChat:
            VStack(spacing: 8) {
                Text("No Jarvis found")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AgentTheme.textSecondary)
                Text("A chat of this project whose title starts with “Jarvis” appears here as soon as it runs or is open as a tab.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(AgentTheme.textTertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
        }
    }

    private func notice(headline: Text, detail: Text, button: String, accessibility: String,
                        action: @escaping () -> Void) -> some View {
        VStack(spacing: 8) {
            if let title = state.title {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AgentTheme.textSecondary)
                    .lineLimit(1)
            }
            headline
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AgentTheme.textPrimary)
            detail
                .font(.system(size: 11.5))
                .foregroundStyle(AgentTheme.textTertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button(button, action: action)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel(accessibility)
        }
        .padding(20)
    }

    // MARK: Fuß

    @ViewBuilder
    private var footer: some View {
        if state.title != nil {
            (state.isAutomatic
                ? Text("Chosen automatically: this project's Jarvis.")
                : Text("Chosen by you for this project."))
                .font(.system(size: 11))
                .foregroundStyle(AgentTheme.textTertiary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
                .padding(.top, 2)
        }
    }
}

/// Zugeklappte Spalte: eine schmale Leiste am rechten Rand, immer sichtbar,
/// mit einem Knopf zum Aufklappen (kein Hover nötig).
struct BoardChatCollapsedRail<StatusDot: View>: View {
    let title: String?
    let expand: () -> Void
    @ViewBuilder let statusDot: () -> StatusDot

    var body: some View {
        VStack(spacing: 10) {
            Button(action: expand) {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AgentTheme.textSecondary)
                    .frame(width: 24, height: 24)
                    .background(AgentTheme.hover, in: RoundedRectangle(cornerRadius: 5))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(String(localized: "Show board chat"))
            .accessibilityLabel(String(localized: "Show board chat"))
            if title != nil { statusDot() }
            Spacer()
        }
        .padding(.top, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AgentTheme.header)
    }
}

/// Breite, Rand und Ziehen der Spalte. Eigener Modifier, damit nur er den
/// Zustand der Triage beobachtet: Blättern mit J/K wertet so weder das
/// Fenster noch das Terminal neu aus, nur diese Breitenrechnung.
struct BoardChatColumnFrame: ViewModifier {
    let isTriage: () -> Bool
    let storedWidth: Double?
    let isCollapsed: Bool
    let available: Double
    let setWidth: (Double) -> Void

    @State private var dragStart: Double?
    @State private var dragTranslation: Double = 0

    func body(content: Content) -> some View {
        let width = isCollapsed
            ? BoardChatRules.collapsedWidth
            : BoardChatRules.width(stored: storedWidth, isTriage: isTriage(), available: available)
        content
            .frame(width: width)
            .frame(maxHeight: .infinity)
            .overlay(alignment: .leading) {
                Rectangle().fill(AgentTheme.border).frame(width: 1)
            }
            .overlay(alignment: .leading) {
                if !isCollapsed { resizeHandle(width: width) }
            }
    }

    /// Ziehen am linken Rand. Während des Ziehens steht nur eine Linie an der
    /// neuen Kante; die Spalte (und damit das Terminal) ändert ihre Breite
    /// erst beim Loslassen. Sonst bekäme die TUI bei jedem Mausschritt eine
    /// neue Fenstergröße und zeichnete alles neu.
    private func resizeHandle(width: Double) -> some View {
        let preview = dragStart.map { BoardChatRules.draggedWidth(from: $0, translation: dragTranslation, available: available) }
        return Color.clear
            .frame(width: 7)
            .contentShape(Rectangle())
            .overlay(alignment: .leading) {
                if let preview {
                    Rectangle()
                        .fill(AgentTheme.accent)
                        .frame(width: 2)
                        .offset(x: width - preview)
                        .allowsHitTesting(false)
                }
            }
            .background(BoardChatResizeCursor())
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .onChanged { value in
                        if dragStart == nil { dragStart = width }
                        dragTranslation = value.translation.width
                    }
                    .onEnded { value in
                        let start = dragStart ?? width
                        dragStart = nil
                        dragTranslation = 0
                        setWidth(BoardChatRules.draggedWidth(from: start, translation: value.translation.width, available: available))
                    }
            )
            .help(String(localized: "Drag to resize the board chat"))
            .accessibilityHidden(true)
    }
}
