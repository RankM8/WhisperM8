import SwiftUI

/// Detail einer geplanten Aufgabe im Inhaltsbereich (Entwurf, Variante A):
/// Knöpfe oben, ein Kasten für Fehler, Arbeit oder Pause, dann Zeitplan, Konto,
/// Ordner, Rechte, Auftrag und die letzten Läufe mit Weg in ihren Chat.
///
/// `.equatable()` auf Aufgabe und Fenster: Das Fenster wertet seinen Body bei
/// jedem Statuswechsel eines Chats aus, das Detail nicht. Es beobachtet nur
/// `ScheduledTasksOverviewModel` und die Login-Fristen (stündlich).
struct ScheduledTaskDetailView: View, Equatable {
    let taskID: UUID
    var projects: () -> [ScheduledTaskEditorProject] = { [] }
    var onClose: () -> Void = {}
    /// `false` = Chat nicht gefunden (noch nicht eingelesen).
    var onOpenRun: (UUID) -> Bool = { _ in false }
    var model: ScheduledTasksOverviewModel = .shared
    var editorDependencies: ScheduledTaskEditorSheet.Dependencies = .live
    var loginEndsAt: (String) -> Date? = { ClaudeLoginExpiryStore.shared.entries[$0]?.endsAt }

    @AppStorage(PreferenceKeys.scheduledTasksEnabled) private var enabled = false
    @State private var editor: ScheduledTaskEditorTarget?
    @State private var message: String?
    @State private var isBusy = false

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.taskID == rhs.taskID
    }

    var body: some View {
        Group {
            if !enabled {
                // Schalter aus: zurück zu den Chats.
                Color.clear.onAppear(perform: onClose)
            } else if let overview = model.overview(id: taskID) {
                content(overview)
            } else if model.hasLoaded {
                missing
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(AgentTheme.background)
        .task { model.loadIfNeeded() }
        .sheet(item: $editor) { target in
            ScheduledTaskEditorSheet(
                target: target, projects: projects(), existing: model.snapshot.overviews.map(\.task),
                dependencies: editorDependencies, onDeleted: onClose)
        }
    }

    private var clock: ScheduledTaskTexts.Clock {
        ScheduledTaskTexts.Clock(now: model.loadedAt, calendar: .current, locale: .current)
    }

    private var missing: some View {
        VStack(spacing: 10) {
            Text("This scheduled task no longer exists.")
                .font(.system(size: 13))
                .foregroundStyle(AgentTheme.textSecondary)
            Button { onClose() } label: { Text("Back to chats") }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Inhalt

    private func content(_ overview: ScheduledTaskOverview) -> some View {
        let task = overview.task
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    ScheduledTaskStateDot(state: overview.state)
                    Text(task.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(AgentTheme.textPrimary)
                        .textSelection(.enabled)
                    Spacer(minLength: 8)
                    Button { onClose() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(AgentTheme.textSecondary)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "Close and go back to the chat"))
                    .accessibilityLabel(Text("Close"))
                }

                actions(overview)
                    .padding(.top, 10)
                    .padding(.bottom, 14)

                if let message {
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(AgentTheme.statusError)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 12)
                }

                stateBox(overview)

                meta(overview)
                    .padding(.bottom, 14)

                sectionTitle("Prompt")
                Text(task.prompt)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(AgentTheme.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(AgentTheme.surface, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(AgentTheme.border))
                    .padding(.bottom, 14)

                sectionTitle("Runs")
                runs(overview)

                Text("The sidebar shows the last three runs under the task.")
                    .font(.system(size: 11))
                    .foregroundStyle(AgentTheme.textTertiary)
                    .padding(.top, 10)
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, 26)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func actions(_ overview: ScheduledTaskOverview) -> some View {
        HStack(spacing: 6) {
            Button { runNow(overview) } label: { Text("Run now") }
                .disabled(isBusy || overview.state == .running || overview.task.paused)
                .help(runNowHelp(overview))
            Button { togglePause(overview) } label: {
                if overview.task.paused { Text("Resume runs") } else { Text("Pause runs") }
            }
            .disabled(isBusy)
            Button { editor = ScheduledTaskEditorTarget(task: overview.task) } label: { Text("Edit…") }
                .disabled(isBusy)
        }
        .controlSize(.small)
    }

    private func runNowHelp(_ overview: ScheduledTaskOverview) -> String {
        if overview.state == .running { return String(localized: "A run is working. Two runs of the same task never run at once.") }
        if overview.task.paused { return String(localized: "Paused tasks do not start, not even by hand.") }
        return String(localized: "Start a run now, outside the schedule.")
    }

    // MARK: Kasten

    @ViewBuilder
    private func stateBox(_ overview: ScheduledTaskOverview) -> some View {
        switch overview.state {
        case .failed:
            if let run = overview.latestResult {
                box(tint: AgentTheme.statusError) {
                    Text("Failed · \(ScheduledTaskTexts.dateTime(run.createdAt, clock: clock))")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AgentTheme.statusError)
                    Text(verbatim: ScheduledTaskTexts.failureText(run.outcome))
                        .font(.system(size: 12))
                        .foregroundStyle(AgentTheme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        if let session = run.sessionID {
                            Button { openChat(session) } label: { Text("Open the run’s chat") }
                        }
                        Button { runNow(overview) } label: { Text("Run again") }
                            .disabled(isBusy || overview.task.paused)
                    }
                    .controlSize(.small)
                    .padding(.top, 4)
                }
            }
        case .running:
            box(tint: AgentTheme.statusWorking) {
                HStack(spacing: 7) {
                    AgentStatusIndicator(status: .working)
                    if let run = overview.activeRun {
                        Text("Working since \(clock.time(run.createdAt))")
                            .font(.system(size: 12, weight: .semibold))
                    } else {
                        Text("Working")
                            .font(.system(size: 12, weight: .semibold))
                    }
                }
                Text("Its chat opens when the run is done. Two processes must never write to the same chat.")
                    .font(.system(size: 12))
                    .foregroundStyle(AgentTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .paused:
            box(tint: AgentTheme.textTertiary) {
                Text("Paused")
                    .font(.system(size: 12, weight: .semibold))
                Text("Nothing starts until you resume. “Run now” stays off too, so pausing really means quiet. Past dates are not caught up after resuming.")
                    .font(.system(size: 12))
                    .foregroundStyle(AgentTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .scheduled, .succeeded, .succeededWithNotes:
            EmptyView()
        }
    }

    private func box<Content: View>(tint: Color, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(tint.opacity(0.35)))
            .padding(.bottom, 14)
    }

    // MARK: Angaben

    private func meta(_ overview: ScheduledTaskOverview) -> some View {
        let task = overview.task
        return Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
            metaRow("Schedule", ScheduledTaskTexts.schedule(task.schedule, clock: clock))
            metaRow("Next run", nextText(overview))
            metaRow("Account", accountText(task.account))
            metaRow("Project", URL(fileURLWithPath: task.directory).lastPathComponent
                    + " · " + ScheduleCLIFormatter.homeAbbreviated(task.directory))
            metaRow("Permissions", ScheduledTaskTexts.permissions(task.permissions))
            metaRow("Missed runs", task.catchUp
                    ? String(localized: "caught up, up to 12 hours later")
                    : String(localized: "not caught up"))
        }
    }

    private func metaRow(_ key: LocalizedStringKey, _ value: String) -> some View {
        GridRow {
            Text(key)
                .font(.system(size: 12))
                .foregroundStyle(AgentTheme.textTertiary)
                .frame(width: 110, alignment: .leading)
            Text(verbatim: value)
                .font(.system(size: 12))
                .foregroundStyle(AgentTheme.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func nextText(_ overview: ScheduledTaskOverview) -> String {
        if overview.task.paused { return String(localized: "paused") }
        guard let next = overview.next else { return String(localized: "no date") }
        return ScheduledTaskTexts.dateTime(next, clock: clock)
    }

    private func accountText(_ account: String) -> String {
        guard let ends = loginEndsAt(account) else { return account }
        if ends <= clock.now { return String(localized: "\(account) · login expired") }
        return String(localized: "\(account) · login until \(clock.formatter("dMMM").string(from: ends))")
    }

    private func sectionTitle(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .textCase(.uppercase)
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(AgentTheme.textTertiary)
            .padding(.bottom, 6)
    }

    // MARK: Läufe

    @ViewBuilder
    private func runs(_ overview: ScheduledTaskOverview) -> some View {
        if overview.runs.isEmpty {
            Text("No runs yet. The first one starts \(nextText(overview)).")
                .font(.system(size: 12))
                .foregroundStyle(AgentTheme.textSecondary)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(overview.runs) { run in
                    runRow(run)
                    Divider()
                }
            }
        }
    }

    private func runRow(_ run: ScheduledTaskRunSummary) -> some View {
        HStack(alignment: .center, spacing: 10) {
            ScheduledTaskRunDot(outcome: run.outcome)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: ScheduledTaskTexts.dateTime(run.createdAt, clock: clock))
                    .font(.system(size: 12))
                    .foregroundStyle(AgentTheme.textPrimary)
                Text(verbatim: ScheduledTaskTexts.runLine(run))
                    .font(.system(size: 11))
                    .foregroundStyle(AgentTheme.textTertiary)
                if let detail = ScheduledTaskTexts.outcomeDetail(run.outcome) {
                    Text(verbatim: detail)
                        .font(.system(size: 11))
                        .foregroundStyle(run.outcome.isFailure ? AgentTheme.statusError : AgentTheme.textTertiary)
                        .lineLimit(2)
                        .help(detail)
                }
            }
            Spacer(minLength: 8)
            if run.outcome.isActive {
                Text("chat after the end")
                    .font(.system(size: 11))
                    .foregroundStyle(AgentTheme.textTertiary)
            } else if let session = run.sessionID {
                Button { openChat(session) } label: { Text("Open chat") }
                    .controlSize(.small)
            } else {
                Text("no chat")
                    .font(.system(size: 11))
                    .foregroundStyle(AgentTheme.textTertiary)
            }
        }
        .padding(.vertical, 7)
    }

    // MARK: Aktionen

    private func openChat(_ session: UUID) {
        if onOpenRun(session) {
            message = nil
        } else {
            message = String(localized: "This chat is not in the list yet. WhisperM8 picks it up within a few seconds; try again shortly.")
        }
    }

    private func runNow(_ overview: ScheduledTaskOverview) {
        perform { await model.runNow(overview.id) }
    }

    private func togglePause(_ overview: ScheduledTaskOverview) {
        let paused = !overview.task.paused
        perform { await model.setPaused(overview.id, paused: paused) }
    }

    private func perform(_ action: @escaping () async -> String?) {
        isBusy = true
        message = nil
        Task {
            message = await action()
            isBusy = false
        }
    }
}
