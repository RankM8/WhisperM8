import SwiftUI

struct ProjectChatGroup: View {
    let project: AgentProject
    let sessions: [AgentChatSession]
    let isExpanded: Bool
    let selectedProjectID: UUID?
    let selectedSessionID: UUID?
    var onSelectProject: () -> Void
    var onToggleExpanded: () -> Void
    var onSelectSession: (UUID) -> Void
    var onNewChat: () -> Void
    var onCloseSession: (AgentChatSession) -> Void
    var onRenameRequest: (AgentChatSession) -> Void
    var onAutoNameRequest: (AgentChatSession) -> Void
    var onRename: (UUID, String) -> Void
    var onSetColor: (UUID, String?) -> Void
    var isRunning: (UUID) -> Bool
    var runtimeStatus: (UUID) -> AgentSessionRuntimeStatus?
    var isAutoRenaming: (UUID) -> Bool
    var onRenameProjectRequest: (AgentProject) -> Void
    var onSetProjectColor: (UUID, String) -> Void
    var onChooseProjectIcon: (AgentProject) -> Void
    var onAutoDetectProjectIcon: (AgentProject) -> Void
    var onClearProjectIcon: (UUID) -> Void
    var onSessionDrop: (DraggableSession, _ beforeSessionID: UUID?, _ targetProjectID: UUID) -> Void
    var onProjectDrop: (DraggableProject, _ beforeProjectID: UUID?) -> Void

    @State private var isHeaderHovered = false
    @State private var isSessionDragOver = false
    @State private var isProjectDragOver = false

    private var isSelected: Bool {
        selectedProjectID == project.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            groupHeader

            if isExpanded && !sessions.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(sessions.prefix(20)) { session in
                        sessionRow(session)
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

    @ViewBuilder
    private func sessionRow(_ session: AgentChatSession) -> some View {
        SessionListButton(
            session: session,
            isSelected: selectedSessionID == session.id,
            isRunning: isRunning(session.id),
            runtimeStatus: runtimeStatus(session.id),
            isAutoRenaming: isAutoRenaming(session.id),
            onSelect: { onSelectSession(session.id) },
            onClose: { onCloseSession(session) }
        )
        .draggable(DraggableSession(sessionID: session.id, sourceProjectID: project.id))
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
            .background(headerBackground.overlay(
                isSessionDragOver || isProjectDragOver
                    ? AgentTheme.selection.opacity(0.5)
                    : Color.clear
            ))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHeaderHovered = $0 }
        .draggable(DraggableProject(projectID: project.id))
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
        }
    }

    private var headerBackground: Color {
        if isSelected { return AgentTheme.selection }
        if isHeaderHovered { return AgentTheme.hover }
        return Color.clear
    }
}

struct SessionListButton: View {
    let session: AgentChatSession
    let isSelected: Bool
    let isRunning: Bool
    let runtimeStatus: AgentSessionRuntimeStatus?
    /// `true` waehrend der AutoNamer fuer diese Session einen
    /// `claude -p`-Subprocess laufen hat. UI zeigt Sparkles-Pulse statt
    /// des normalen Status-Dots.
    let isAutoRenaming: Bool
    var onSelect: () -> Void
    var onClose: () -> Void

    @State private var isHovered = false
    @State private var pulsePhase = false

    private static let connectorX: CGFloat = 18

    private var customColor: Color? {
        guard let hex = session.color, !hex.isEmpty else { return nil }
        return Color(hex: hex)
    }

    var body: some View {
        Button(action: onSelect) {
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(isSelected ? AgentTheme.connectorActive : AgentTheme.connector)
                    .frame(width: 1)
                    .frame(maxHeight: .infinity)
                    .padding(.leading, Self.connectorX)

                HStack(spacing: 8) {
                    if let customColor {
                        Circle()
                            .fill(customColor.opacity(isSelected ? 0.95 : 0.7))
                            .frame(width: 6, height: 6)
                    } else {
                        ProviderIcon(provider: session.provider, size: 11, tint: AgentTheme.textTertiary)
                            .frame(width: 11, alignment: .center)
                    }

                    Text(session.title)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? AgentTheme.textPrimary : AgentTheme.textSecondary)
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
            .background(rowBackground)
            .contentShape(Rectangle())
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
                .help("Chat schließen")
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
                .foregroundStyle(Color.purple.opacity(pulsePhase ? 1.0 : 0.45))
                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulsePhase)
                .onAppear { pulsePhase = true }
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
                .opacity(pulsePhase ? 1.0 : 0.45)
                .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulsePhase)
                .onAppear { pulsePhase = true }
                .help("Arbeitet …")
        case .awaitingInput:
            Circle()
                .fill(Color.orange)
                .frame(width: 5, height: 5)
                .opacity(pulsePhase ? 1.0 : 0.4)
                .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: pulsePhase)
                .onAppear { pulsePhase = true }
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
        if let runtimeStatus { return runtimeStatus }
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
