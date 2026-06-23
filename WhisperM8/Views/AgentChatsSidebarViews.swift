import Combine
import SwiftUI

struct ProjectChatGroup: View {
    let project: AgentProject
    let sessions: [AgentChatSession]
    let isExpanded: Bool
    let selectedSessionID: UUID?
    /// Sessions mit offenem Tab in der globalen Bar — werden heller
    /// dargestellt als geschlossene (Sidebar = Bestand, Tabs = aktiv).
    let openTabIDs: Set<UUID>
    var onSelectProject: () -> Void
    var onToggleExpanded: () -> Void
    var onSelectSession: (UUID) -> Void
    var onNewChat: () -> Void
    var onCloseSession: (AgentChatSession) -> Void
    var onPinSession: (UUID) -> Void
    var onForkSession: (AgentChatSession) -> Void
    var onRenameRequest: (AgentChatSession) -> Void
    var onAutoNameRequest: (AgentChatSession) -> Void
    var onRename: (UUID, String) -> Void
    var onSetColor: (UUID, String?) -> Void
    // P4: Wert-Daten statt Closures — Closures werden pro Parent-Render neu
    // gebaut und verhindern jedes Memoizing; Sets + die stabile
    // Store-Referenz lassen die Rows per Equatable skippen.
    let runningSessionIDs: Set<UUID>
    let statusStore: AgentSessionRuntimeStatusStore
    let awaitingInputSessionIDs: Set<UUID>
    let autoRenamingSessionIDs: Set<UUID>
    /// IDs abgeschlossener Sessions, deren Transkript fehlt — ausgegraut.
    var missingTranscriptSessionIDs: Set<UUID> = []
    var onRenameProjectRequest: (AgentProject) -> Void
    var onSetProjectColor: (UUID, String) -> Void
    var onChooseProjectIcon: (AgentProject) -> Void
    var onAutoDetectProjectIcon: (AgentProject) -> Void
    var onClearProjectIcon: (UUID) -> Void
    var onDeleteProject: (AgentProject) -> Void
    var onSessionDrop: (DraggableSession, _ beforeSessionID: UUID?, _ targetProjectID: UUID) -> Void
    var onProjectDrop: (DraggableProject, _ beforeProjectID: UUID?) -> Void

    @State private var isHeaderHovered = false
    @State private var isSessionDragOver = false
    @State private var isProjectDragOver = false

    /// Einmal pro View-Init gelesen statt pro Render — das Flag ist ein
    /// Escape-Hatch und aendert sich nur via `defaults write` + App-Neustart.
    private let isDragEnabled = AppPreferences.shared.isAgentSidebarDragEnabled

    /// Initiales Row-Limit pro Projekt; die "N weitere anzeigen"-Row hebt es
    /// an. Lebt pro Projekt-Identity (ForEach-id) und resettet bewusst, wenn
    /// das Projekt den Suchfilter verlässt oder die Sidebar getoggelt wird
    /// (View-Identity weg) — akzeptiertes Verhalten.
    static let defaultVisibleSessionLimit = 20
    @State private var visibleSessionLimit = ProjectChatGroup.defaultVisibleSessionLimit

    var body: some View {
        let _ = PerfSignposts.sidebar.emitEvent("sidebar.bodyEval.projectGroup")
        VStack(alignment: .leading, spacing: 0) {
            groupHeader

            if isExpanded && !sessions.isEmpty {
                let slice = Self.visibleSlice(of: sessions, limit: visibleSessionLimit)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(slice.visible) { session in
                        sessionRow(session)
                    }
                    if slice.hiddenCount > 0 {
                        showMoreRow(hiddenCount: slice.hiddenCount)
                    }
                    Color.clear
                        .frame(height: 8)
                        .contentShape(Rectangle())
                        .dropDestination(for: DraggableSession.self) { items, _ in
                            guard let dropped = items.first else { return false }
                            onSessionDrop(dropped, nil, project.id)
                            return true
                        }
                }
            }
        }
    }

    /// Pure Slice-Logik — testbar. Ersetzt die frühere stille prefix(20)-
    /// Kappung, bei der Sessions ab Platz 21 kommentarlos unsichtbar waren.
    static func visibleSlice(
        of sessions: [AgentChatSession],
        limit: Int
    ) -> (visible: ArraySlice<AgentChatSession>, hiddenCount: Int) {
        let visible = sessions.prefix(max(0, limit))
        return (visible, sessions.count - visible.count)
    }

    /// Bewusst KEINE Drag/Drop-Modifier an dieser Row. Der Container bleibt
    /// nicht-lazy (LazyVStack + .draggable = Mai-2026-Freeze, Fix 60ca683) —
    /// das initiale Limit hält die Row-Anzahl klein, damit non-lazy
    /// bezahlbar bleibt.
    private func showMoreRow(hiddenCount: Int) -> some View {
        Button {
            visibleSessionLimit += 50
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.down.circle")
                    .font(.system(size: 10, weight: .semibold))
                Text("\(hiddenCount) weitere anzeigen")
                    .font(.system(size: 11, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(AgentTheme.textTertiary)
            .padding(.leading, 28)
            .padding(.trailing, 8)
            .frame(minHeight: 24, maxHeight: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Weitere Sessions dieses Projekts einblenden")
    }

    @ViewBuilder
    private func sessionRow(_ session: AgentChatSession) -> some View {
        SessionListButton(
            session: session,
            isSelected: selectedSessionID == session.id,
            isOpenTab: openTabIDs.contains(session.id),
            accentColorHex: project.color,
            isRunning: runningSessionIDs.contains(session.id),
            statusStore: statusStore,
            isAwaitingInput: awaitingInputSessionIDs.contains(session.id),
            isAutoRenaming: autoRenamingSessionIDs.contains(session.id),
            isMissingTranscript: missingTranscriptSessionIDs.contains(session.id),
            onSelect: { onSelectSession(session.id) },
            onClose: { onCloseSession(session) }
        )
        // .equatable() VOR den Drag-Modifiern — die Modifier-Kette dahinter
        // bleibt byte-identisch zum reaktivierten Drag&Drop (7e84b7c).
        .equatable()
        .sidebarDraggable(
            DraggableSession(sessionID: session.id, sourceProjectID: project.id),
            enabled: isDragEnabled
        ) {
            sessionDragPreview(session)
        }
        .dropDestination(for: DraggableSession.self) { items, _ in
            guard let dropped = items.first else { return false }
            onSessionDrop(dropped, session.id, project.id)
            return true
        }
        .contextMenu {
            Button("Umbenennen…", systemImage: "pencil") {
                onRenameRequest(session)
            }
            Button("Titel automatisch generieren", systemImage: "sparkles") {
                onAutoNameRequest(session)
            }
            .disabled(session.externalSessionID == nil)
            if session.isForkable {
                Button("Forken", systemImage: "arrow.triangle.branch") {
                    onForkSession(session)
                }
            }
            Divider()
            Button("Anpinnen", systemImage: "pin") {
                onPinSession(session.id)
            }
            Divider()
            Menu("Tab-Farbe") {
                ForEach(AgentChatColor.palette, id: \.self) { color in
                    Button {
                        onSetColor(session.id, color)
                    } label: {
                        Label {
                            Text(AgentChatColorName.label(for: color))
                        } icon: {
                            Image(nsImage: colorSwatchImage(hex: color))
                        }
                    }
                }
                Divider()
                Button("Provider-Farbe verwenden", systemImage: "arrow.uturn.backward") {
                    onSetColor(session.id, nil)
                }
            }
            Divider()
            Button("Schließen", systemImage: "xmark", role: .destructive) {
                onCloseSession(session)
            }
        }
    }

    private var groupHeader: some View {
        Button(action: onSelectProject) {
            HStack(alignment: .center, spacing: 9) {
                Button(action: onToggleExpanded) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(AgentTheme.textTertiary)
                        .frame(width: 12, height: 12)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .animation(.easeOut(duration: 0.12), value: isExpanded)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                ProjectAvatar(project: project)

                VStack(alignment: .leading, spacing: 1) {
                    Text(project.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AgentTheme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 8))
                            .foregroundStyle(AgentTheme.textTertiary)
                        Text(project.lastBranch ?? "local")
                            .font(.system(size: 10))
                            .foregroundStyle(AgentTheme.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if !sessions.isEmpty {
                            Text("·")
                                .font(.system(size: 10))
                                .foregroundStyle(AgentTheme.textTertiary)
                            Text("\(sessions.count)")
                                .font(.system(size: 10, weight: .medium).monospacedDigit())
                                .foregroundStyle(AgentTheme.textTertiary)
                        }
                    }
                }

                Spacer(minLength: 6)

                if isHeaderHovered {
                    Button(action: onNewChat) {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(AgentTheme.textSecondary)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Neuen Codex Chat im Projekt starten")
                }
            }
            .padding(.leading, 8)
            .padding(.trailing, 8)
            .frame(minHeight: 36, maxHeight: 36)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSessionDragOver || isProjectDragOver
                        ? AgentTheme.selection
                        : headerBackground)
            )
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHeaderHovered = $0 }
        .sidebarDraggable(DraggableProject(projectID: project.id), enabled: isDragEnabled) {
            projectDragPreview
        }
        .dropDestination(for: DraggableProject.self) { items, _ in
            guard let dropped = items.first, dropped.projectID != project.id else { return false }
            onProjectDrop(dropped, project.id)
            return true
        } isTargeted: { isProjectDragOver = $0 }
        .dropDestination(for: DraggableSession.self) { items, _ in
            guard let dropped = items.first else { return false }
            onSessionDrop(dropped, nil, project.id)
            return true
        } isTargeted: { isSessionDragOver = $0 }
        .contextMenu {
            Button("Umbenennen…", systemImage: "pencil") {
                onRenameProjectRequest(project)
            }
            Menu("Farbe") {
                ForEach(AgentProjectColor.palette, id: \.self) { color in
                    Button {
                        onSetProjectColor(project.id, color)
                    } label: {
                        Label {
                            Text(AgentChatColorName.label(for: color))
                        } icon: {
                            Image(nsImage: colorSwatchImage(hex: color))
                        }
                    }
                }
            }
            Divider()
            Button("Icon wählen…", systemImage: "photo") {
                onChooseProjectIcon(project)
            }
            Button("Auto-Icon erkennen", systemImage: "sparkles.rectangle.stack") {
                onAutoDetectProjectIcon(project)
            }
            if project.resolvedIconURL != nil
                || project.iconRelativePath != nil
                || project.customIconAbsolutePath != nil {
                Button("Icon entfernen", systemImage: "xmark.circle", role: .destructive) {
                    onClearProjectIcon(project.id)
                }
            }
            Divider()
            Button("Projekt löschen…", systemImage: "trash", role: .destructive) {
                onDeleteProject(project)
            }
        }
    }

    /// Projekt-Header werden nicht mehr als „selektiert" hervorgehoben —
    /// genau EINE Markierung in der Sidebar: die aktive Chat-Zeile.
    private var headerBackground: Color {
        if isHeaderHovered { return AgentTheme.hover }
        return Color.clear
    }

    /// Leichtgewichtiges Drag-Preview statt System-Snapshot der Live-Row.
    /// Die Rows haben Animationen (`contentTransition`, Hover-States) — beim
    /// Mai-2026-Haenger war teures Preview-Rendering ein Verdaechtiger, daher
    /// bekommen Drags hier bewusst eine statische, billige Ansicht.
    private func sessionDragPreview(_ session: AgentChatSession) -> some View {
        HStack(spacing: 6) {
            ProviderIcon(provider: session.provider, size: 11, tint: AgentTheme.textSecondary)
            Text(session.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(AgentTheme.textPrimary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(AgentTheme.sidebar, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(AgentTheme.border, lineWidth: 1))
    }

    private var projectDragPreview: some View {
        HStack(spacing: 6) {
            ProjectAvatar(project: project)
            Text(project.name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AgentTheme.textPrimary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(AgentTheme.sidebar, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(AgentTheme.border, lineWidth: 1))
    }
}

extension View {
    /// Haengt `.draggable(payload, preview:)` nur an, wenn das Escape-Hatch
    /// `agentSidebarDragEnabled` nicht gezogen wurde (siehe `AppPreferences`).
    /// Hintergrund: `.draggable` + `LazyVStack` hat im Mai 2026 die ganze App
    /// eingefroren (gefixt in 60ca683). Der Sidebar-Container ist seitdem ein
    /// nicht-lazy `VStack` — sollte der Haenger trotzdem zurueckkommen, laesst
    /// sich das Feature per `defaults write` ohne Rebuild deaktivieren.
    @ViewBuilder
    func sidebarDraggable<Payload: Transferable, Preview: View>(
        _ payload: Payload,
        enabled: Bool,
        @ViewBuilder preview: () -> Preview
    ) -> some View {
        if enabled {
            self.draggable(payload, preview: preview)
        } else {
            self
        }
    }
}

struct SessionListButton: View {
    let session: AgentChatSession
    let isSelected: Bool
    /// `true` wenn der Chat gerade als Tab in der globalen Bar offen ist —
    /// offene Chats erscheinen heller als geschlossene (Sidebar = Bestand,
    /// Tab-Bar = aktive Auswahl).
    let isOpenTab: Bool
    /// Projektfarbe (Hex) für den Auswahl-Akzent im Einzug — ersetzt die
    /// frühere Connector-Linie.
    let accentColorHex: String?
    let isRunning: Bool
    /// Stabile Store-Referenz — bewusst KEIN @ObservedObject: Die Row
    /// subscribt per `onReceive` nur auf den Status IHRER Session
    /// (statusPublisher), statt bei jedem Tick irgendeiner Session neu zu
    /// rendern.
    let statusStore: AgentSessionRuntimeStatusStore
    /// "Needs Input" aus Notification-Hooks — übersteuert den
    /// Watcher-Status, gerade bei Background-Sessions ist die JSONL nicht
    /// immer aussagekräftig.
    let isAwaitingInput: Bool
    /// `true` waehrend der AutoNamer fuer diese Session einen
    /// `claude -p`-Subprocess laufen hat. UI zeigt Sparkles-Pulse statt
    /// des normalen Status-Dots.
    let isAutoRenaming: Bool
    /// `true` wenn das Transkript dieser (abgeschlossenen) Session nicht mehr
    /// auf der Platte liegt — „toter Zeiger" (z.B. von Claudes 30-Tage-Cleanup
    /// gelöscht). Row wird ausgegraut + bekommt einen Hinweis; nicht resumebar.
    var isMissingTranscript: Bool = false
    var onSelect: () -> Void
    var onClose: () -> Void

    @State private var isHovered = false
    /// Live-Status via Per-Item-Publisher; umgeht den Equatable-Skip korrekt
    /// (Updates kommen über @State, nicht über Parent-Re-Render).
    @State private var liveStatus: AgentSessionRuntimeStatus?

    private var customColor: Color? {
        guard let hex = session.color, !hex.isEmpty else { return nil }
        return Color(hex: hex)
    }

    var body: some View {
        let _ = PerfSignposts.sidebar.emitEvent("sidebar.bodyEval.sessionRow")
        Button(action: onSelect) {
            ZStack(alignment: .leading) {
                // Auswahl-Akzent in Projektfarbe im Einzug — genau eine
                // Markierung statt der gestapelten Boxen + Connector-Linie.
                if isSelected {
                    RoundedRectangle(cornerRadius: 1.25)
                        .fill(accentColor)
                        .frame(width: 2.5, height: 13)
                        .padding(.leading, 14)
                }

                HStack(spacing: 8) {
                    Group {
                        if let customColor {
                            Circle()
                                .fill(customColor.opacity(isSelected ? 0.95 : 0.7))
                                .frame(width: 6, height: 6)
                        } else {
                            ProviderIcon(provider: session.provider, size: 11, tint: AgentTheme.textTertiary)
                                .frame(width: 11, alignment: .center)
                        }
                    }
                    .opacity(isOpenTab || isSelected ? 1 : 0.55)

                    Text(session.title)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(titleColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(1)
                        // Smooth crossfade wenn der AutoNamer den Titel
                        // austauscht — statt eines harten Pops.
                        .contentTransition(.opacity)
                        .animation(.easeInOut(duration: 0.3), value: session.title)
                        .help(session.title)

                    if session.isBackgroundChat {
                        kindPill("BG", color: .indigo)
                            .help("Hintergrund-Agent · vom Claude-Supervisor gehostet")
                    } else if session.isAgentView {
                        kindPill("VIEW", color: .orange)
                            .help("Claude Agents View · Multi-Session-TUI")
                    }

                    Spacer(minLength: 0)

                    trailingIndicator
                        .frame(width: 18, alignment: .trailing)
                }
                .padding(.leading, 28)
                .padding(.trailing, 8)
            }
            .frame(maxWidth: .infinity, minHeight: 26, maxHeight: 26, alignment: .leading)
            .background(rowBackground, in: RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .onReceive(statusStore.statusPublisher(for: session.id)) { liveStatus = $0 }
    }

    private var accentColor: Color {
        guard let accentColorHex, !accentColorHex.isEmpty else {
            return AgentTheme.textSecondary
        }
        return Color(hex: accentColorHex)
    }

    private var titleColor: Color {
        if isMissingTranscript { return AgentTheme.textTertiary }
        return (isSelected || isOpenTab) ? AgentTheme.textPrimary : AgentTheme.textSecondary
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
                .help("Chat schließen")
        } else if isMissingTranscript {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(AgentTheme.textTertiary)
                .help("Transkript von Claude gelöscht – nicht mehr resumebar")
        } else {
            statusIndicator
        }
    }

    @ViewBuilder
    private var statusIndicator: some View {
        // Auto-Rename hat Vorrang ueber den Runtime-Status: der User soll
        // wissen warum sich gleich der Titel aendert.
        if isAutoRenaming {
            Image(systemName: "sparkles")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color.purple)
                .help("Titel wird automatisch generiert …")
        } else {
            statusDot
        }
    }

    @ViewBuilder
    private var statusDot: some View {
        let resolved = resolvedStatus
        switch resolved {
        case .working:
            Circle()
                .fill(Color.green)
                .frame(width: 5, height: 5)
                .help("Arbeitet …")
        case .awaitingInput:
            Circle()
                .fill(Color.orange)
                .frame(width: 5, height: 5)
                .help("Wartet möglicherweise auf User-Input")
        case .idle:
            Circle()
                .fill(Color.green.opacity(0.55))
                .frame(width: 5, height: 5)
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

    private var resolvedStatus: AgentSessionRuntimeStatus? {
        if isAwaitingInput { return .awaitingInput }
        if let liveStatus { return liveStatus }
        return isRunning ? .working : nil
    }

    private var rowBackground: Color {
        if isSelected { return AgentTheme.selection }
        if isHovered { return AgentTheme.hover }
        return Color.clear
    }

    /// Kleines Pill-Label rechts neben dem Titel, das die "Sonder-Kind" einer
    /// Session anzeigt (BG = Background-Agent, VIEW = Claude Agents View).
    /// Wird nur fuer `.backgroundChat` und `.agentView` gezeigt — normale
    /// `.chat`-Sessions bleiben minimalistisch.
    @ViewBuilder
    private func kindPill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .bold))
            .tracking(0.04)
            .foregroundStyle(color)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(color.opacity(0.16), in: RoundedRectangle(cornerRadius: 3))
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .stroke(color.opacity(0.30), lineWidth: 0.5)
            )
            .fixedSize()
    }
}

/// WICHTIG (Pflegefalle): Neue darstellungsrelevante Wert-Felder an
/// `SessionListButton` MÜSSEN hier ergänzt werden, sonst aktualisiert die Row
/// still nicht (`.equatable()` skippt den Body). Explizit NICHT verglichen:
/// `statusStore` (stabile Referenz; Live-Updates laufen über
/// onReceive+@State und umgehen den Skip korrekt) und die Action-Closures
/// (keine Render-Inputs). Abgesichert durch SessionListButtonEquatableTests.
extension SessionListButton: Equatable {
    nonisolated static func == (lhs: SessionListButton, rhs: SessionListButton) -> Bool {
        lhs.session == rhs.session
            && lhs.isSelected == rhs.isSelected
            && lhs.isOpenTab == rhs.isOpenTab
            && lhs.accentColorHex == rhs.accentColorHex
            && lhs.isRunning == rhs.isRunning
            && lhs.isAwaitingInput == rhs.isAwaitingInput
            && lhs.isAutoRenaming == rhs.isAutoRenaming
            && lhs.isMissingTranscript == rhs.isMissingTranscript
    }
}

/// Zeile der „Gepinnt"-Sektion: Repo-Badge (ProjectAvatar) statt
/// Provider-Icon, damit die Projektzugehörigkeit projektübergreifend auf
/// einen Blick erkennbar ist. Verhalten sonst wie `SessionListButton`.
struct PinnedSessionRow: View {
    let session: AgentChatSession
    let project: AgentProject?
    let isSelected: Bool
    let isRunning: Bool
    let statusStore: AgentSessionRuntimeStatusStore
    let isAwaitingInput: Bool
    /// `true` wenn das Transkript dieser Session nicht mehr auf der Platte
    /// liegt — toter Zeiger, ausgegraut + Hinweis (siehe `SessionListButton`).
    var isMissingTranscript: Bool = false
    var onSelect: () -> Void
    var onClose: () -> Void

    @State private var isHovered = false
    @State private var liveStatus: AgentSessionRuntimeStatus?

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                if let project {
                    ProjectAvatar(project: project, size: 14)
                        .help(project.name)
                } else {
                    ProviderIcon(provider: session.provider, size: 11, tint: AgentTheme.textTertiary)
                        .frame(width: 14, alignment: .center)
                }

                Text(session.title)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isMissingTranscript ? AgentTheme.textTertiary : AgentTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(isMissingTranscript ? "Transkript von Claude gelöscht – nicht mehr resumebar" : session.title)

                Spacer(minLength: 0)

                trailingIndicator
                    .frame(width: 18, alignment: .trailing)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 28, maxHeight: 28, alignment: .leading)
            .background(rowBackground, in: RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .onReceive(statusStore.statusPublisher(for: session.id)) { liveStatus = $0 }
    }

    @ViewBuilder
    private var trailingIndicator: some View {
        if isHovered {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(AgentTheme.textSecondary)
                .frame(width: 16, height: 16)
                .background(AgentTheme.hover, in: RoundedRectangle(cornerRadius: 3))
                .contentShape(Rectangle())
                .onTapGesture { onClose() }
                .help("Chat schließen")
        } else if isMissingTranscript {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(AgentTheme.textTertiary)
                .help("Transkript von Claude gelöscht – nicht mehr resumebar")
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

    private var rowBackground: Color {
        if isSelected { return AgentTheme.selection }
        if isHovered { return AgentTheme.hover }
        return Color.clear
    }
}

struct SidebarCommandRow: View {
    let icon: String
    let title: String
    var isActive: Bool = false
    var trailingIcon: String? = nil

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 16)
                .foregroundStyle(isActive ? AgentTheme.textPrimary : AgentTheme.textSecondary)
            Text(title)
                .font(.system(size: 12, weight: isActive ? .semibold : .medium))
                .foregroundStyle(isActive ? AgentTheme.textPrimary : AgentTheme.textSecondary)
                .lineLimit(1)
            Spacer()
            if let trailingIcon {
                Image(systemName: trailingIcon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AgentTheme.textTertiary)
                    .frame(width: 16)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

struct SidebarRowButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(rowBackground(pressed: configuration.isPressed))
            )
            .padding(.horizontal, 8)
            .onHover { hovering in
                isHovered = hovering
            }
            .animation(.easeOut(duration: 0.12), value: isHovered)
    }

    private func rowBackground(pressed: Bool) -> Color {
        if pressed { return AgentTheme.selectionStrong }
        if isHovered { return AgentTheme.hover }
        return Color.clear
    }
}
