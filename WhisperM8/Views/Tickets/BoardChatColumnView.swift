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
    /// Knöpfe im Kopf (Teil c): Jarvis, Produkt-Chat, hineingezogener Chat.
    /// Leer: Der Kopf zeigt nur den Titel.
    var choices: [BoardChatChoice] = []
    /// Erklärung unter dem Chat, nur bis sie einmal dastand (WM8-124).
    var showsIntro = false
    /// Breite von Hand gezogen: Der Kopf zeigt dann den Weg zurück zur Vorgabe.
    var hasCustomWidth = false
    /// Liste unter „Anderer Chat …“ (WM8-126): Chats dieses Projekts, die
    /// Board-Chat werden können, ohne den, der schon dasteht.
    var others: [BoardChatHeadOption] = []
}

/// Knöpfe der Spalte. Alles, was einen Chat verschiebt oder startet, geht nur
/// von einem Klick aus.
struct BoardChatColumnActions {
    var moveHere: () -> Void = {}
    var openHere: () -> Void = {}
    var openAsTab: () -> Void = {}
    var start: () -> Void = {}
    var setCollapsed: (Bool) -> Void = { _ in }
    /// Klick auf einen Knopf im Kopf.
    var choose: (UUID) -> Void = { _ in }
    /// Ein Chat wurde auf die Spalte gezogen (ID, Zahl der Chats im Zug); `false` lehnt ab.
    var drop: (UUID, Int) -> Bool = { _, _ in false }
    /// Die Erklärung wurde gelesen (OK) oder stand beim Schließen schon da.
    var introSeen: () -> Void = {}
    /// Zurück zur Vorgabebreite (40 %).
    var resetWidth: () -> Void = {}

    static let none = BoardChatColumnActions()
}

/// Die Spalte rechts neben Board und Triage. Das Terminal kommt als Inhalt
/// herein; die Spalte selbst kennt weder Registry noch Fenster.
struct BoardChatColumnView<StatusDot: View, Terminal: View>: View {
    let state: BoardChatColumnState
    let actions: BoardChatColumnActions
    /// Unter dem Terminal: Bezug und Hinweise (Teil b). Nur bei `.terminal`.
    var inputBar: AnyView? = nil
    /// Board des Fensters: Auswahl von Controller und Tastatur im Kopf
    /// (WM8-126). Nur Ring und Liste lesen sie, nicht der Kopf selbst.
    var headFocus: TicketBoardViewModel? = nil
    @ViewBuilder let statusDot: () -> StatusDot
    @ViewBuilder let terminal: () -> Terminal

    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(AgentTheme.border)
            // Liste „Anderer Chat …“ unter dem Kopf, nicht darüber: Über dem
            // Terminal (ein NSView) läge sie nicht verlässlich obenauf.
            BoardChatOtherChatsList(model: headFocus, options: state.others, choose: actions.choose)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Auch ohne Terminal: Hinweise (etwa „anderes Projekt“) müssen sichtbar sein.
            if let inputBar { inputBar }
            if state.showsIntro, state.title != nil, state.content == .terminal {
                BoardChatIntro(isAutomatic: state.isAutomatic, done: actions.introSeen)
            }
        }
        .background(AgentTheme.background)
        // Chat aus Seitenleiste oder Tab-Leiste hierher ziehen (Teil c).
        .dropDestination(for: DraggableSession.self) { items, _ in
            guard let item = items.first else { return false }
            return actions.drop(item.sessionID, max(items.count, item.groupMemberIDs?.count ?? 1))
        } isTargeted: { isDropTargeted = $0 }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(AgentTheme.accent.opacity(0.7), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: Kopf

    private var header: some View {
        HStack(spacing: 6) {
            // Bleibt immer stehen, sonst sagt nichts mehr, was die Spalte ist.
            Text("Board chat")
                .textCase(.uppercase)
                .font(.system(size: 11, weight: .semibold))
                .kerning(0.5)
                .foregroundStyle(AgentTheme.textTertiary)
                .fixedSize()
            if !state.choices.isEmpty {
                ForEach(state.choices) { choice in
                    choiceButton(choice).boardChatHeadRing(.choice(choice.id), model: headFocus)
                }
            } else if let title = state.title {
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
            otherChatButton
                .boardChatHeadRing(.otherChat, model: headFocus)
            Spacer(minLength: 4)
            if state.title != nil, state.content == .terminal, !state.isRunning {
                headerButton(systemImage: "play.fill",
                             help: state.canResume ? String(localized: "Resume") : String(localized: "Start"),
                             action: actions.start)
            }
            if state.hasCustomWidth {
                // Sichtbar, solange eine eigene Breite gilt; Doppelklick auf den Griff tut dasselbe.
                headerButton(systemImage: "arrow.left.and.right.square",
                             help: String(localized: "Back to the default width"), action: actions.resetWidth)
            }
            if state.title != nil, state.content == .terminal {
                headerButton(systemImage: "arrow.up.left.and.arrow.down.right",
                             help: String(localized: "Open as tab"), action: actions.openAsTab)
                    .boardChatHeadRing(.openAsTab, model: headFocus, cornerRadius: 6)
            }
            headerButton(systemImage: "sidebar.right", help: String(localized: "Hide board chat")) {
                actions.setCollapsed(true)
            }
            .boardChatHeadRing(.hide, model: headFocus, cornerRadius: 6)
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
        .background(AgentTheme.header)
    }

    private func choiceButton(_ choice: BoardChatChoice) -> some View {
        Button { if !choice.isSelected { actions.choose(choice.id) } } label: {
            HStack(spacing: 6) {
                if choice.isSelected { statusDot() }
                Text(verbatim: choice.kind == .product ? "\(choice.name) · " + String(localized: "Product") : choice.name)
                    .font(.system(size: 12, weight: choice.isSelected ? .semibold : .regular))
                    .foregroundStyle(choice.isSelected ? AgentTheme.textPrimary : AgentTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(choice.isSelected ? AgentTheme.surface : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .strokeBorder(choice.isSelected ? AgentTheme.borderStrong : AgentTheme.border))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(choice.title)
        .accessibilityLabel(choice.isSelected
            ? String(localized: "\(choice.title), shown as board chat")
            : String(localized: "Show \(choice.title) as board chat"))
        .layoutPriority(choice.isSelected ? 1 : 0.5)
    }

    /// „Anderer Chat …“ (WM8-126): öffnet die Liste darunter. Ohne passenden
    /// Chat steht der Knopf blass da und sagt, warum.
    private var otherChatButton: some View {
        let hasOthers = !state.others.isEmpty
        return Button {
            headFocus?.openOtherChatsByMouse(hasOptions: hasOthers)
        } label: {
            HStack(spacing: 3) {
                Text("Other chat…")
                    .font(.system(size: 12))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(hasOthers ? AgentTheme.textSecondary : AgentTheme.textTertiary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(AgentTheme.border))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(hasOthers ? String(localized: "Show another chat as board chat")
                        : String(localized: "No other chat of this project is open or running"))
        .accessibilityLabel(String(localized: "Show another chat as board chat"))
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
                Text("A chat of this project whose title starts with “Jarvis” appears here as soon as it runs or is open as a tab. Or drag any chat here.")
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
}

/// Erklärung unter dem Board-Chat, einmal (WM8-124): wer hier steht und was
/// die Bezug-Marke tut. Danach bleibt unter dem Chat nur die Marke. Gilt als
/// gelesen nach OK oder sobald sie einmal da war und wieder verschwindet.
struct BoardChatIntro: View {
    let isAutomatic: Bool
    let done: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                (isAutomatic
                    ? Text("Chosen automatically: this project's Jarvis. Drag another chat here to switch.")
                    : Text("Chosen by you for this project. Drag another chat here to switch."))
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: "Re:")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AgentTheme.accent)
                    Text("Goes in front of your next dictation: number, title and link.")
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(AgentTheme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("OK", action: done)
                .buttonStyle(SettingsButtonStyle.standard)
                .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(AgentTheme.surface)
        .overlay(alignment: .top) { Rectangle().fill(AgentTheme.border).frame(height: 1) }
        .onDisappear(perform: done)
    }
}

/// Zugeklappte Spalte: eine schmale Leiste am rechten Rand, immer sichtbar,
/// mit einem Knopf zum Aufklappen (kein Hover nötig).
struct BoardChatCollapsedRail<StatusDot: View>: View {
    let title: String?
    let expand: () -> Void
    /// Auswahl von Controller und Tastatur (WM8-126): Ring am Knopf.
    var headFocus: TicketBoardViewModel? = nil
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
            .boardChatHeadRing(.show, model: headFocus, cornerRadius: 6)
            if title != nil { statusDot() }
            Spacer()
        }
        .padding(.top, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AgentTheme.header)
    }
}

/// Breite, Rand und Ziehen der Spalte. Hängt nicht am Zustand der Triage:
/// Board und Triage zeigen die Spalte gleich breit (WM8-124), Blättern mit
/// J/K wertet weder diese Rechnung noch das Terminal neu aus.
struct BoardChatColumnFrame: ViewModifier {
    let storedWidth: Double?
    let isCollapsed: Bool
    let available: Double
    let setWidth: (Double) -> Void
    /// Doppelklick auf den Griff: zurück zur Vorgabe (WM8-124).
    var resetWidth: () -> Void = {}

    @State private var dragStart: Double?
    @State private var dragTranslation: Double = 0

    func body(content: Content) -> some View {
        let width = isCollapsed
            ? BoardChatRules.collapsedWidth
            : BoardChatRules.width(stored: storedWidth, available: available)
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

    /// Ziehen am linken Rand. Der Griff (ein senkrechter Strich mitten auf der
    /// Kante) steht immer da, nicht erst beim Überfahren. Während des Ziehens
    /// steht nur eine Linie an der neuen Kante; die Spalte (und damit das
    /// Terminal) ändert ihre Breite erst beim Loslassen. Sonst bekäme die TUI
    /// bei jedem Mausschritt eine neue Fenstergröße und zeichnete alles neu.
    private func resizeHandle(width: Double) -> some View {
        let preview = dragStart.map { BoardChatRules.draggedWidth(from: $0, translation: dragTranslation, available: available) }
        return Color.clear
            .frame(width: 9)
            .contentShape(Rectangle())
            .overlay {
                BoardChatResizeGrip(isActive: preview != nil)
                    .allowsHitTesting(false)
            }
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
            .simultaneousGesture(TapGesture(count: 2).onEnded { resetWidth() })
            .help(String(localized: "Drag to resize the board chat. Double-click for the default width."))
            .accessibilityHidden(true)
    }
}

/// Der sichtbare Griff auf der linken Kante: ein Strich mit zwei Kerben,
/// in beiden Erscheinungsbildern deutlich vom Rand abgesetzt.
struct BoardChatResizeGrip: View {
    var isActive = false

    var body: some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(isActive ? AgentTheme.accent : AgentTheme.textTertiary)
            .frame(width: 4, height: 36)
            .overlay {
                VStack(spacing: 3) {
                    ForEach(0..<3, id: \.self) { _ in
                        Rectangle().fill(AgentTheme.background.opacity(0.7)).frame(width: 2, height: 1)
                    }
                }
            }
    }
}
