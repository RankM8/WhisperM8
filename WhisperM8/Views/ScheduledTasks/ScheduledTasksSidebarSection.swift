import SwiftUI

/// Abschnitt „Geplant“ ganz unten in der Seitenleiste (WM8-110, Entscheidung E1):
/// zuklappbar wie Workspaces und Chats, je Aufgabe eine Zeile wie ein Chat,
/// darunter ihre letzten drei Läufe zum Aufklappen. Ein Klick auf die Aufgabe
/// öffnet ihr Detail, ein Klick auf einen Lauf seinen Chat.
///
/// Kosten im Renderpfad: Der Abschnitt beobachtet nur
/// `ScheduledTasksOverviewModel` (ändert sich bei Termin, Lauf-Ende und Aktion)
/// und nie den Status-Speicher der Chats. `.equatable()` mit zwei Werten: Das
/// Fenster wertet seinen Body bei jedem Statuswechsel aus, dieser Abschnitt
/// dann nicht. Zeiten kommen fertig aus der Übersicht, kein I/O, kein Zähler.
struct ScheduledTasksSidebarSection: View, Equatable {
    /// Aufgabe, deren Detail dieses Fenster zeigt.
    let selectedTaskID: UUID?
    /// Externe Sitzung des gewählten Chats (klein geschrieben), für die Markierung des Laufs.
    let selectedRunSessionID: String?
    var projects: () -> [ScheduledTaskEditorProject] = { [] }
    var onSelectTask: (UUID) -> Void = { _ in }
    /// `false` = Chat nicht gefunden (noch nicht eingelesen).
    var onOpenRun: (UUID) -> Bool = { _ in false }
    var model: ScheduledTasksOverviewModel

    @AppStorage(PreferenceKeys.scheduledTasksEnabled) private var enabled = false
    @AppStorage("agentScheduledTasksSectionCollapsed") private var collapsed = false
    @State private var expandedTaskIDs: Set<UUID>
    @State private var editor: ScheduledTaskEditorTarget?

    @MainActor
    init(selectedTaskID: UUID?, selectedRunSessionID: String?,
         projects: @escaping () -> [ScheduledTaskEditorProject] = { [] },
         onSelectTask: @escaping (UUID) -> Void = { _ in }, onOpenRun: @escaping (UUID) -> Bool = { _ in false },
         model: ScheduledTasksOverviewModel? = nil, expandedTaskIDs: Set<UUID> = []) {
        self.selectedTaskID = selectedTaskID
        self.selectedRunSessionID = selectedRunSessionID
        self.projects = projects
        self.onSelectTask = onSelectTask
        self.onOpenRun = onOpenRun
        self.model = model ?? .shared
        _expandedTaskIDs = State(initialValue: expandedTaskIDs)
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.selectedTaskID == rhs.selectedTaskID && lhs.selectedRunSessionID == rhs.selectedRunSessionID
    }

    var body: some View {
        if enabled {
            VStack(alignment: .leading, spacing: 2) {
                header(count: model.snapshot.overviews.count)
                if !collapsed { content(model) }
            }
            .padding(.top, 8)
            .task { model.loadIfNeeded() }
            .sheet(item: $editor) { target in
                ScheduledTaskEditorSheet(target: target, projects: projects(), existing: model.snapshot.overviews.map(\.task)) { saved in
                    onSelectTask(saved.id)
                }
            }
        }
    }

    // MARK: Kopf

    private func header(count: Int) -> some View {
        HStack(spacing: 5) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { collapsed.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .rotationEffect(.degrees(collapsed ? 0 : 90))
                    Image(systemName: "clock")
                        .font(.system(size: 8, weight: .bold))
                    Text("SCHEDULED")
                        .font(.system(size: 11, weight: .bold))
                        .tracking(0.6)
                    if collapsed, count > 0 {
                        Text("\(count)")
                            .font(.system(size: 11, weight: .bold).monospacedDigit())
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(collapsed ? String(localized: "Show scheduled tasks") : String(localized: "Hide scheduled tasks"))

            Button {
                editor = ScheduledTaskEditorTarget(task: nil)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(String(localized: "New scheduled task…"))
            .accessibilityLabel(Text("New scheduled task…"))
        }
        .foregroundStyle(AgentTheme.textTertiary)
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.top, 6)
        .padding(.bottom, 2)
    }

    // MARK: Inhalt

    @ViewBuilder
    private func content(_ model: ScheduledTasksOverviewModel) -> some View {
        let clock = ScheduledTaskTexts.Clock(now: model.loadedAt)
        if let error = model.snapshot.loadError {
            Text(error)
                .font(.system(size: 11))
                .foregroundStyle(AgentTheme.statusError)
                .lineLimit(3)
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
        } else if model.hasLoaded, model.snapshot.overviews.isEmpty {
            Button {
                editor = ScheduledTaskEditorTarget(task: nil)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .semibold))
                    Text("New scheduled task…")
                        .font(.system(size: 12))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(AgentTheme.textSecondary)
                .padding(.leading, 28)
                .frame(height: 26)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
        } else {
            ForEach(model.snapshot.overviews) { overview in
                ScheduledTaskSidebarRow(
                    overview: overview,
                    trailing: ScheduledTaskTexts.sidebarTrailing(overview, clock: clock),
                    isSelected: overview.id == selectedTaskID,
                    isExpanded: expandedTaskIDs.contains(overview.id),
                    onSelect: { onSelectTask(overview.id) },
                    onToggle: { toggle(overview.id) }
                )
                if expandedTaskIDs.contains(overview.id) {
                    runRows(overview, clock: clock)
                }
            }
        }
    }

    @ViewBuilder
    private func runRows(_ overview: ScheduledTaskOverview, clock: ScheduledTaskTexts.Clock) -> some View {
        if overview.runs.isEmpty {
            Text("No runs yet")
                .font(.system(size: 11))
                .foregroundStyle(AgentTheme.textTertiary)
                .padding(.leading, 46)
                .frame(height: 22)
        }
        ForEach(overview.runs.prefix(3)) { run in
            ScheduledTaskRunSidebarRow(
                run: run,
                label: ScheduledTaskTexts.runShort(run.createdAt, clock: clock) + " · " + ScheduledTaskTexts.outcomeShort(run.outcome),
                isSelected: selectedTaskID == nil && run.sessionID.map { $0.uuidString.lowercased() == selectedRunSessionID } == true,
                onSelect: {
                    // Ohne Chat, während er arbeitet, oder noch nicht eingelesen: das Detail erklärt es.
                    guard let session = run.sessionID, !run.outcome.isActive, onOpenRun(session) else {
                        onSelectTask(overview.id)
                        return
                    }
                }
            )
        }
        if overview.runs.count > 3 {
            Button {
                onSelectTask(overview.id)
            } label: {
                Text("\(overview.runs.count - 3) older in the detail")
                    .font(.system(size: 11))
                    .foregroundStyle(AgentTheme.textTertiary)
                    .padding(.leading, 46)
                    .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func toggle(_ id: UUID) {
        withAnimation(.easeOut(duration: 0.12)) {
            if expandedTaskIDs.contains(id) { expandedTaskIDs.remove(id) } else { expandedTaskIDs.insert(id) }
        }
    }
}

// MARK: - Zeilen

/// Zeile einer Aufgabe, gebaut wie die Chat-Zeile (`SessionListButton`): 26 pt,
/// Auswahl-Akzent im Einzug, Titel 12 pt, rechts ein ruhiger Zusatz in 11 pt.
struct ScheduledTaskSidebarRow: View {
    let overview: ScheduledTaskOverview
    let trailing: String
    let isSelected: Bool
    let isExpanded: Bool
    var onSelect: () -> Void
    var onToggle: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onToggle) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .foregroundStyle(AgentTheme.textTertiary)
                    .frame(width: 18, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isExpanded ? String(localized: "Hide runs") : String(localized: "Show runs"))
            .accessibilityLabel(isExpanded ? Text("Hide runs") : Text("Show runs"))

            Button(action: onSelect) {
                HStack(spacing: 8) {
                    ScheduledTaskStateDot(state: overview.state)
                        .frame(width: 11)
                    Text(overview.task.name)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? AgentTheme.textPrimary : AgentTheme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(1)
                        .help(overview.task.name)
                    Spacer(minLength: 4)
                    Text(trailing)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(trailingColor)
                        .lineLimit(1)
                        .fixedSize()
                }
                .padding(.trailing, 8)
                .frame(maxWidth: .infinity, minHeight: 26, maxHeight: 26, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: overview.task.name + ", " + trailing))
        }
        .padding(.leading, 10)
        .background(background, in: RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .leading) {
            if isSelected {
                RoundedRectangle(cornerRadius: 1.25)
                    .fill(AgentTheme.accent)
                    .frame(width: 2.5, height: 13)
                    .padding(.leading, 4)
            }
        }
        .padding(.horizontal, 8)
        .onHover { isHovered = $0 }
    }

    private var trailingColor: Color {
        switch overview.state {
        case .failed: return AgentTheme.statusError
        case .running: return AgentTheme.statusWorking
        default: return AgentTheme.textTertiary
        }
    }

    private var background: Color {
        if isSelected { return AgentTheme.accentTint }
        return isHovered ? AgentTheme.hover : .clear
    }
}

/// Lauf unter seiner Aufgabe: Datum und Ergebnis, Klick öffnet den Chat.
struct ScheduledTaskRunSidebarRow: View {
    let run: ScheduledTaskRunSummary
    let label: String
    let isSelected: Bool
    var onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 7) {
                ScheduledTaskRunDot(outcome: run.outcome)
                    .frame(width: 9)
                Text(label)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(run.hasChat ? AgentTheme.textSecondary : AgentTheme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
            }
            .padding(.leading, 38)
            .padding(.trailing, 8)
            .frame(maxWidth: .infinity, minHeight: 24, maxHeight: 24, alignment: .leading)
            .background(isSelected ? AgentTheme.accentTint : (isHovered ? AgentTheme.hover : .clear),
                        in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .onHover { isHovered = $0 }
        .help(run.hasChat ? String(localized: "Open the chat of this run") : String(localized: "This run did not start, so there is no chat"))
    }
}

// MARK: - Punkte

/// Zustand einer Aufgabe. Grün nur für „arbeitet“ (über `AgentStatusIndicator`),
/// Fehler als roter Ring wie bei einem Chat, pausiert als grauer Ring.
struct ScheduledTaskStateDot: View {
    let state: ScheduledTaskOverview.State

    var body: some View {
        switch state {
        case .running:
            AgentStatusIndicator(status: .working)
        case .failed:
            AgentStatusIndicator(status: .errored)
        case .succeededWithNotes:
            RoundedRectangle(cornerRadius: 1.5)
                .fill(AgentTheme.statusAwaiting)
                .frame(width: 6, height: 6)
                .rotationEffect(.degrees(45))
                .accessibilityLabel(Text("Succeeded with notes"))
        case .paused:
            Circle()
                .strokeBorder(AgentTheme.textTertiary, lineWidth: 1.5)
                .frame(width: 7, height: 7)
                .accessibilityLabel(Text("Paused"))
        case .scheduled, .succeeded:
            Circle()
                .fill(AgentTheme.textTertiary.opacity(0.75))
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
        }
    }
}

/// Ergebnis eines Laufs: geklappt = Akzent, Hinweis = gelbe Raute, Fehler = roter
/// Ring, verpasst/übersprungen = grauer Ring, arbeitet = grün.
struct ScheduledTaskRunDot: View {
    let outcome: ScheduledTaskRunOutcome

    var body: some View {
        switch outcome {
        case .starting, .running:
            AgentStatusIndicator(status: .working, compact: true)
        case .succeeded:
            Circle().fill(AgentTheme.accent).frame(width: 6, height: 6)
        case .succeededWithNotes:
            RoundedRectangle(cornerRadius: 1.5)
                .fill(AgentTheme.statusAwaiting)
                .frame(width: 5.5, height: 5.5)
                .rotationEffect(.degrees(45))
        case .failed, .aborted, .notStarted:
            if outcome.isFailure {
                Circle().strokeBorder(AgentTheme.statusError, lineWidth: 1.5).frame(width: 7, height: 7)
            } else {
                Circle().strokeBorder(AgentTheme.textTertiary, lineWidth: 1.2).frame(width: 6, height: 6)
            }
        }
    }
}
