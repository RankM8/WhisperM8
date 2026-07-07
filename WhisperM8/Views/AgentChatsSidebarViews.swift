import Combine
import SwiftUI

struct ProjectChatGroup: View {
    let project: AgentProject
    let sessions: [AgentChatSession]
    let isExpanded: Bool
    let selectedSessionID: UUID?
    /// Mehrfach-Auswahl (geteilt mit der Tab-Leiste) — Cmd/Shift-Klick.
    let multiSelection: Set<UUID>
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
    let statusStore: AgentSessionRuntimeStatusStore
    let autoRenamingSessionIDs: Set<UUID>
    /// IDs abgeschlossener Sessions, deren Transkript fehlt — ausgegraut.
    var missingTranscriptSessionIDs: Set<UUID> = []
    /// Subagent-Kinder pro Parent-Row (lokale Session-ID) — rendern
    /// eingerückt direkt unter der Parent-Zeile, ohne Drag&Drop.
    var subagentChildrenByParent: [UUID: [AgentChatSession]] = [:]
    /// Anzahl AKTIVER Subagent-Kinder pro Parent — Zähler-Chip.
    var runningSubagentCountByParent: [UUID: Int] = [:]
    /// Subagent-Sessions mit ungelesenem Ergebnis — blauer Dot.
    var unreadSubagentSessionIDs: Set<UUID> = []
    /// Parents mit AUSGEKLAPPTEN Subagent-Kindern (Default: eingeklappt;
    /// ephemer im AgentWindowStore).
    var expandedSubagentParentIDs: Set<UUID> = []
    var onToggleSubagentChildren: (UUID) -> Void = { _ in }
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
    /// Sidebar-Drop-Indikator: Session-Row, über der die Einfügelinie steht
    /// (= „landet vor dieser Zeile"), bzw. der Append-Footer am Projektende.
    @State private var dropTargetedSessionID: UUID?
    @State private var isFooterDropTargeted = false

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
                let slice = Self.visibleSlice(of: sessions, limit: visibleSessionLimit, mustIncludeID: revealTargetID)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(slice.visible) { session in
                        sessionRow(session)
                        // Subagent-Kinder direkt unter der Parent-Row —
                        // eingerückt, ohne Drag&Drop, reduziertes Menü.
                        // Standardmäßig EINGEKLAPPT (Toggle-Chip an der
                        // Parent-Row); ein selektiertes Kind hält die Gruppe
                        // implizit offen (z.B. nach Notification-Klick).
                        let children = subagentChildrenByParent[session.id] ?? []
                        if !children.isEmpty,
                           expandedSubagentParentIDs.contains(session.id)
                            || children.contains(where: { $0.id == selectedSessionID }) {
                            ForEach(children) { child in
                                subagentChildRow(child)
                            }
                        }
                    }
                    if slice.hiddenCount > 0 {
                        showMoreRow(hiddenCount: slice.hiddenCount)
                    }
                    Color.clear
                        .frame(height: 8)
                        .contentShape(Rectangle())
                        .overlay(alignment: .top) {
                            if isFooterDropTargeted {
                                Capsule()
                                    .fill(AgentTheme.accent)
                                    .frame(height: 2)
                                    .padding(.horizontal, 8)
                                    .allowsHitTesting(false)
                            }
                        }
                        .dropDestination(for: DraggableSession.self) { items, _ in
                            isFooterDropTargeted = false
                            guard let dropped = items.first else { return false }
                            onSessionDrop(dropped, nil, project.id)
                            return true
                        } isTargeted: { isFooterDropTargeted = $0 }
                        .animation(.easeOut(duration: 0.1), value: isFooterDropTargeted)
                }
            }
        }
    }

    /// Row, die trotz Row-Limit sichtbar sein muss: die selektierte Session
    /// dieses Projekts — oder der Parent eines selektierten Subagent-Kindes
    /// (Kinder rendern nur unter einer sichtbaren Parent-Row; ohne Reveal
    /// bliebe die Selektion nach einem Notification-Klick unsichtbar).
    private var revealTargetID: UUID? {
        guard let selectedSessionID else { return nil }
        if sessions.contains(where: { $0.id == selectedSessionID }) { return selectedSessionID }
        return subagentChildrenByParent.first { _, children in
            children.contains { $0.id == selectedSessionID }
        }?.key
    }

    /// Pure Slice-Logik — testbar. Ersetzt die frühere stille prefix(20)-
    /// Kappung, bei der Sessions ab Platz 21 kommentarlos unsichtbar waren.
    /// `mustIncludeID` hebt das Limit bis zu dieser Row an (Selektions-Reveal)
    /// — unbekannte IDs ändern nichts.
    static func visibleSlice(
        of sessions: [AgentChatSession],
        limit: Int,
        mustIncludeID: UUID? = nil
    ) -> (visible: ArraySlice<AgentChatSession>, hiddenCount: Int) {
        var effectiveLimit = max(0, limit)
        if let mustIncludeID,
           let index = sessions.firstIndex(where: { $0.id == mustIncludeID }),
           index >= effectiveLimit {
            effectiveLimit = index + 1
        }
        let visible = sessions.prefix(effectiveLimit)
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

    /// Anzahl der Sessions, auf die eine Bulk-Aktion wirken würde (die Auswahl,
    /// wenn `session` Teil davon ist, sonst 1) — für die „N"-Menü-Labels.
    private func bulkCount(_ session: AgentChatSession) -> Int {
        multiSelection.contains(session.id) && multiSelection.count > 1 ? multiSelection.count : 1
    }

    /// Eingerückte Kind-Zeile eines Subagent-Jobs. Bewusst OHNE Drag&Drop
    /// (Kinder kleben an ihrem Parent) und mit reduziertem Kontextmenü.
    @ViewBuilder
    private func subagentChildRow(_ child: AgentChatSession) -> some View {
        SessionListButton(
            session: child,
            isSelected: selectedSessionID == child.id,
            isMultiSelected: false,
            isOpenTab: openTabIDs.contains(child.id),
            accentColorHex: project.color,
            statusStore: statusStore,
            isAutoRenaming: false,
            isMissingTranscript: false,
            indentAsSubagent: true,
            isUnreadSubagentResult: unreadSubagentSessionIDs.contains(child.id),
            onSelect: { onSelectSession(child.id) },
            onClose: { onCloseSession(child) }
        )
        .equatable()
        .contextMenu {
            Button("Umbenennen…", systemImage: "pencil") {
                onRenameRequest(child)
            }
            Divider()
            Button("Archivieren", systemImage: "archivebox") {
                onCloseSession(child)
            }
        }
    }

    @ViewBuilder
    private func sessionRow(_ session: AgentChatSession) -> some View {
        SessionListButton(
            session: session,
            isSelected: selectedSessionID == session.id,
            isMultiSelected: multiSelection.contains(session.id),
            isOpenTab: openTabIDs.contains(session.id),
            accentColorHex: project.color,
            statusStore: statusStore,
            isAutoRenaming: autoRenamingSessionIDs.contains(session.id),
            isMissingTranscript: missingTranscriptSessionIDs.contains(session.id),
            isUnreadSubagentResult: unreadSubagentSessionIDs.contains(session.id),
            runningChildCount: runningSubagentCountByParent[session.id] ?? 0,
            childCount: subagentChildrenByParent[session.id]?.count ?? 0,
            isChildrenExpanded: expandedSubagentParentIDs.contains(session.id),
            onSelect: { onSelectSession(session.id) },
            onClose: { onCloseSession(session) },
            onToggleChildren: { onToggleSubagentChildren(session.id) }
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
            dropTargetedSessionID = nil
            guard let dropped = items.first else { return false }
            onSessionDrop(dropped, session.id, project.id)
            return true
        } isTargeted: { targeted in
            if targeted {
                dropTargetedSessionID = session.id
            } else if dropTargetedSessionID == session.id {
                dropTargetedSessionID = nil
            }
        }
        // Einfügelinie „landet vor dieser Zeile" — analog zur Tab-Leiste.
        .overlay(alignment: .top) {
            if dropTargetedSessionID == session.id {
                Capsule()
                    .fill(AgentTheme.accent)
                    .frame(height: 2)
                    .padding(.horizontal, 8)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.1), value: dropTargetedSessionID)
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
            Button(bulkCount(session) > 1 ? "\(bulkCount(session)) anpinnen" : "Anpinnen", systemImage: "pin") {
                onPinSession(session.id)
            }
            Divider()
            Menu(bulkCount(session) > 1 ? "Farbe für \(bulkCount(session)) Tabs" : "Tab-Farbe") {
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
            Button(bulkCount(session) > 1 ? "\(bulkCount(session)) archivieren" : "Archivieren", systemImage: "archivebox") {
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

                // Einzeilig wie im Entwurf: Name · Branch · Count nebeneinander
                // — kompakter und im selben vertikalen Rhythmus wie die Zeilen.
                Text(project.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AgentTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)

                HStack(spacing: 3) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 8))
                    Text(project.lastBranch ?? "local")
                        .font(.system(size: 9.5))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .foregroundStyle(AgentTheme.textTertiary)

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
                } else if !sessions.isEmpty {
                    Text("\(sessions.count)")
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(AgentTheme.textTertiary)
                }
            }
            .padding(.leading, 8)
            .padding(.trailing, 8)
            .frame(minHeight: 30, maxHeight: 30)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSessionDragOver || isProjectDragOver
                        ? AgentTheme.selection
                        : headerBackground)
            )
            .padding(.horizontal, 8)
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
            AgentSessionIcon(session: session, size: 11, tint: AgentTheme.textSecondary)
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
    /// Teil einer Mehrfach-Auswahl (Cmd/Shift-Klick) — Akzent-Ring zusätzlich
    /// zur aktiven (`isSelected`) Zeile.
    var isMultiSelected: Bool = false
    /// `true` wenn der Chat gerade als Tab in der globalen Bar offen ist —
    /// offene Chats erscheinen heller als geschlossene (Sidebar = Bestand,
    /// Tab-Bar = aktive Auswahl).
    let isOpenTab: Bool
    /// Projektfarbe (Hex) für den Auswahl-Akzent im Einzug — ersetzt die
    /// frühere Connector-Linie.
    let accentColorHex: String?
    /// Stabile Store-Referenz — bewusst KEIN @ObservedObject: Die Row
    /// subscribt per `onReceive` nur auf den Status IHRER Session
    /// (statusPublisher), statt bei jedem Tick irgendeiner Session neu zu
    /// rendern. Der Status (inkl. awaitingInput) kommt vollständig aus dem
    /// `AgentSessionStatusCoordinator` — kein Fallback mehr auf „PTY läuft"
    /// (der ließ frische Chats ohne Prompt fälschlich pulsieren).
    let statusStore: AgentSessionRuntimeStatusStore
    /// `true` waehrend der AutoNamer fuer diese Session einen
    /// `claude -p`-Subprocess laufen hat. UI zeigt Sparkles-Pulse statt
    /// des normalen Status-Dots.
    let isAutoRenaming: Bool
    /// `true` wenn das Transkript dieser (abgeschlossenen) Session nicht mehr
    /// auf der Platte liegt — „toter Zeiger" (z.B. von Claudes 30-Tage-Cleanup
    /// gelöscht). Row wird ausgegraut + bekommt einen Hinweis; nicht resumebar.
    var isMissingTranscript: Bool = false
    /// Icon + Tooltip der Hover-Aktion rechts. Default = Archivieren; der
    /// Archiv-Modus der Sidebar nutzt dieselbe Row mit „Wiederherstellen".
    var closeIcon: String = "xmark"
    var closeHelp: String = "Archivieren"
    /// Subagent-Kind unter seiner Parent-Row: stärkerer Einzug (44 statt 28)
    /// + SUB-Pill. Kinder haben kein Drag&Drop (macht der Aufrufer).
    var indentAsSubagent: Bool = false
    /// Ungelesenes Subagent-Ergebnis (running→done/failed, noch nicht
    /// geöffnet): blauer Dot statt des grauen Idle-Punkts.
    var isUnreadSubagentResult: Bool = false
    /// Anzahl aktuell LAUFENDER Subagent-Kinder dieser Session — färbt den
    /// Toggle-Chip aktiv (Teal-Dot), solange > 0.
    var runningChildCount: Int = 0
    /// Gesamtzahl der Subagent-Kinder — der Toggle-Chip erscheint, sobald es
    /// welche gibt (Kinder sind standardmäßig eingeklappt).
    var childCount: Int = 0
    /// Sind die Kinder gerade ausgeklappt? Steuert das Chevron im Chip.
    var isChildrenExpanded: Bool = false
    var onSelect: () -> Void
    var onClose: () -> Void
    /// Klick auf den Kinder-Chip (Auf-/Einklappen). Closures sind — wie
    /// onSelect/onClose — bewusst NICHT Teil des Equatable-Vergleichs.
    var onToggleChildren: (() -> Void)?

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
                // Auswahl-Akzent (Indigo) im Einzug — genau eine Markierung,
                // einheitlich mit dem Indigo-Selektions-Hintergrund.
                if isSelected {
                    RoundedRectangle(cornerRadius: 1.25)
                        .fill(AgentTheme.accent)
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
                            AgentSessionIcon(session: session, size: 11, tint: AgentTheme.textTertiary)
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
                    } else if session.isSubagentJob {
                        kindPill("SUB", color: .teal)
                            .help("Codex-Subagent · superviselt vom whisperm8-CLI")
                    }

                    if childCount > 0 {
                        subagentChildrenChip
                    }

                    Spacer(minLength: 0)

                    trailingIndicator
                        .frame(minWidth: 28, alignment: .trailing)
                }
                .padding(.leading, indentAsSubagent ? 44 : 28)
                .padding(.trailing, 8)
            }
            .frame(maxWidth: .infinity, minHeight: 26, maxHeight: 26, alignment: .leading)
            .background(rowBackground, in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                if isMultiSelected {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(AgentTheme.accent.opacity(0.8), lineWidth: 1.5)
                }
            }
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .onReceive(statusStore.statusPublisher(for: session.id)) { liveStatus = $0 }
    }

    private var titleColor: Color {
        if isMissingTranscript { return AgentTheme.textTertiary }
        return (isSelected || isOpenTab) ? AgentTheme.textPrimary : AgentTheme.textSecondary
    }

    @ViewBuilder
    private var trailingIndicator: some View {
        if isHovered || isSelected {
            Image(systemName: closeIcon)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(AgentTheme.textSecondary)
                .frame(width: 16, height: 16)
                .background(AgentTheme.hover, in: RoundedRectangle(cornerRadius: 3))
                .contentShape(Rectangle())
                .onTapGesture { onClose() }
                .help(closeHelp)
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
        // Auto-Rename hat Vorrang über den Runtime-Status: der User soll
        // wissen warum sich gleich der Titel ändert.
        if isAutoRenaming {
            Image(systemName: "sparkles")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(AgentTheme.accent)
                .help("Titel wird automatisch generiert …")
        } else if isUnreadSubagentResult, resolvedStatus == .idle || resolvedStatus == nil {
            // Fertiger Subagent-Job mit ungelesenem Ergebnis: blauer Dot
            // statt des grauen Idle-Punkts (View-Wissen — kein eigener
            // RuntimeStatus-Fall).
            Circle()
                .fill(Color.blue)
                .frame(width: 7, height: 7)
                .help("Neues Subagent-Ergebnis — noch nicht angesehen")
        } else {
            switch resolvedStatus {
            case .working, .awaitingInput, .idle, .errored:
                AgentStatusIndicator(status: resolvedStatus)
            case .stopped, .none:
                // Kein Live-Status → „zuletzt aktiv" statt Indikator.
                Text(SidebarRelativeTime.short(session.lastActivityAt))
                    .font(.system(size: 9.5))
                    .monospacedDigit()
                    .foregroundStyle(AgentTheme.textTertiary)
            }
        }
    }

    /// Toggle-Chip an der Parent-Row: klappt die (standardmäßig
    /// eingeklappten) Subagent-Kinder auf/zu. Chevron zeigt den Zustand,
    /// der Teal-Dot pulst nur, solange mindestens ein Kind aktiv ist.
    private var subagentChildrenChip: some View {
        HStack(spacing: 3) {
            Image(systemName: isChildrenExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 6.5, weight: .bold))
            if runningChildCount > 0 {
                Circle()
                    .fill(Color.teal)
                    .frame(width: 4, height: 4)
            }
            Text("\(childCount)")
                .font(.system(size: 8, weight: .bold).monospacedDigit())
        }
        .foregroundStyle(Color.teal)
        .padding(.horizontal, 4)
        .padding(.vertical, 1.5)
        .background(Color.teal.opacity(0.16), in: RoundedRectangle(cornerRadius: 3))
        .overlay(
            RoundedRectangle(cornerRadius: 3)
                .stroke(Color.teal.opacity(0.30), lineWidth: 0.5)
        )
        .fixedSize()
        .contentShape(Rectangle())
        .onTapGesture { onToggleChildren?() }
        .help(runningChildCount > 0
            ? "\(childCount) Subagent\(childCount == 1 ? "" : "s") (\(runningChildCount) aktiv) — klicken zum \(isChildrenExpanded ? "Einklappen" : "Ausklappen")"
            : "\(childCount) Subagent\(childCount == 1 ? "" : "s") — klicken zum \(isChildrenExpanded ? "Einklappen" : "Ausklappen")")
    }

    private var resolvedStatus: AgentSessionRuntimeStatus? {
        liveStatus
    }

    private var rowBackground: Color {
        if isSelected { return AgentTheme.accentTint }
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
            && lhs.isAutoRenaming == rhs.isAutoRenaming
            && lhs.isMissingTranscript == rhs.isMissingTranscript
            && lhs.isMultiSelected == rhs.isMultiSelected
            && lhs.closeIcon == rhs.closeIcon
            && lhs.closeHelp == rhs.closeHelp
            && lhs.indentAsSubagent == rhs.indentAsSubagent
            && lhs.isUnreadSubagentResult == rhs.isUnreadSubagentResult
            && lhs.runningChildCount == rhs.runningChildCount
            && lhs.childCount == rhs.childCount
            && lhs.isChildrenExpanded == rhs.isChildrenExpanded
    }
}

/// Zeile der „Gepinnt"-Sektion: Repo-Badge (ProjectAvatar) statt
/// Provider-Icon, damit die Projektzugehörigkeit projektübergreifend auf
/// einen Blick erkennbar ist. Verhalten sonst wie `SessionListButton`.
struct PinnedSessionRow: View {
    let session: AgentChatSession
    let project: AgentProject?
    let isSelected: Bool
    var isMultiSelected: Bool = false
    let statusStore: AgentSessionRuntimeStatusStore
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
                    AgentSessionIcon(session: session, size: 11, tint: AgentTheme.textTertiary)
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
                    .frame(minWidth: 28, alignment: .trailing)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 28, maxHeight: 28, alignment: .leading)
            .background(rowBackground, in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                if isMultiSelected {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(AgentTheme.accent.opacity(0.8), lineWidth: 1.5)
                }
            }
            .padding(.horizontal, 8)
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
                .help("Archivieren")
        } else if isMissingTranscript {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(AgentTheme.textTertiary)
                .help("Transkript von Claude gelöscht – nicht mehr resumebar")
        } else {
            switch resolvedStatus {
            case .working, .awaitingInput, .idle, .errored:
                AgentStatusIndicator(status: resolvedStatus)
            case .stopped, .none:
                // Kein Live-Status → „zuletzt aktiv" statt Indikator.
                Text(SidebarRelativeTime.short(session.lastActivityAt))
                    .font(.system(size: 9.5))
                    .monospacedDigit()
                    .foregroundStyle(AgentTheme.textTertiary)
            }
        }
    }

    private var resolvedStatus: AgentSessionRuntimeStatus? {
        liveStatus
    }

    private var rowBackground: Color {
        if isSelected { return AgentTheme.accentTint }
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

/// Hover-/Press-Hintergrund für Zeilen in Popovers (z. B. Projekt-Picker des
/// „Neuer Chat"-Split-Buttons). Wie `SidebarRowButtonStyle`, aber ohne Einzug —
/// die Popover-Zeilen sollen über die volle Breite hovern.
struct PopoverRowButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(isHovered || configuration.isPressed ? AgentTheme.hover : Color.clear)
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.1), value: isHovered)
    }
}
