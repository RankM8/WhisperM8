import AppKit
import SwiftUI

/// Blatt zum Anlegen und Ändern einer geplanten Aufgabe (Entwurf: alles auf
/// einer Seite, kein Assistent). Dieselben Felder wie `whisperm8 schedule add`;
/// kein Modell-Feld, das wählt Claude Code wie bei jedem Chat.
struct ScheduledTaskEditorSheet: View {
    struct Dependencies {
        /// Kontonamen, `main` zuerst. Liest `~/.claude-profiles` — nur abseits des Main Threads.
        var loadAccounts: @Sendable () -> [String]
        var loginEndsAt: @MainActor (String) -> Date?
        /// Dateisystem-Abfrage: nur abseits des Main Threads aufrufen.
        var directoryExists: @Sendable (String) -> Bool
        var chooseFolder: @MainActor () -> String?
        var save: @MainActor (ScheduledTaskDraft, UUID?) async -> Result<ScheduledTask, ScheduledTaskSaveError>
        var remove: @MainActor (UUID) async -> String?

        static var live: Dependencies {
            Dependencies(
                loadAccounts: { ClaudeAccountProfiles().profileNames() },
                loginEndsAt: { ClaudeLoginExpiryStore.shared.entries[$0]?.endsAt },
                directoryExists: { path in
                    var isDirectory: ObjCBool = false
                    return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
                },
                chooseFolder: {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.allowsMultipleSelection = false
                    panel.prompt = String(localized: "Choose")
                    return panel.runModal() == .OK ? panel.url?.path : nil
                },
                save: { draft, id in await ScheduledTasksOverviewModel.shared.save(draft, id: id) },
                remove: { id in await ScheduledTasksOverviewModel.shared.remove(id) }
            )
        }
    }

    let target: ScheduledTaskEditorTarget
    let projects: [ScheduledTaskEditorProject]
    /// Alle Aufgaben, für die Namensprüfung.
    let existing: [ScheduledTask]
    var dependencies: Dependencies = .live
    var now: Date = Date()
    var onSaved: (ScheduledTask) -> Void = { _ in }
    var onDeleted: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var form: ScheduledTaskEditorForm
    @State private var accounts: [String]?
    @State private var error: String?
    @State private var isSaving = false
    /// Der Planer schreibt gerade; dann geht Abbrechen nicht mehr (die
    /// Änderung käme trotzdem an).
    @State private var isSubmitting = false
    /// Abbrechen während der Ordnerprüfung (Prüfung WM8-110, K-B): Der
    /// laufende Speichern-Schritt sieht den Merker und speichert nicht. Ein
    /// Objekt statt `@State`-Wert, weil die Prüfung nach dem Schließen des
    /// Blatts weiterläuft.
    @State private var cancellation = ScheduledTaskEditorCancellation()
    @State private var confirmDelete = false

    init(target: ScheduledTaskEditorTarget, projects: [ScheduledTaskEditorProject], existing: [ScheduledTask],
         dependencies: Dependencies = .live, now: Date = Date(), accounts: [String]? = nil,
         onSaved: @escaping (ScheduledTask) -> Void = { _ in }, onDeleted: @escaping () -> Void = {}) {
        self.target = target
        self.projects = projects
        self.existing = existing
        self.dependencies = dependencies
        self.now = now
        self.onSaved = onSaved
        self.onDeleted = onDeleted
        var form = target.task.map(ScheduledTaskEditorForm.init(task:)) ?? ScheduledTaskEditorForm()
        if target.task == nil, let first = projects.first { form.directory = first.path }
        _form = State(initialValue: form)
        _accounts = State(initialValue: accounts)
    }

    private var isNew: Bool { target.task == nil }
    private var clock: ScheduledTaskTexts.Clock { ScheduledTaskTexts.Clock(now: now) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if isNew { Text("New scheduled task") } else { Text("Edit scheduled task") }
            }
            .font(.system(size: 15, weight: .semibold))
            .padding(.bottom, 14)

            ScrollView {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 12) {
                    GridRow {
                        label("Name")
                        TextField("", text: $form.name, prompt: Text("Morning status of the project"))
                            .textFieldStyle(.roundedBorder)
                    }
                    GridRow {
                        label("Prompt")
                        VStack(alignment: .leading, spacing: 4) {
                            TextEditor(text: $form.prompt)
                                .font(.system(size: 12, design: .monospaced))
                                .frame(minHeight: 64, maxHeight: 120)
                                .scrollContentBackground(.hidden)
                                .padding(4)
                                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(AgentTheme.border))
                            hint("Text, or a skill like /my-skill with its arguments. The run cannot ask questions: what it may not do (below), it skips and reports.")
                        }
                    }
                    GridRow {
                        label("Project folder")
                        VStack(alignment: .leading, spacing: 4) {
                            folderMenu
                            hint("The run starts here, and its chat appears under this project.")
                        }
                    }
                    GridRow {
                        label("Account")
                        accountPicker
                    }
                    GridRow {
                        label("Schedule")
                        scheduleFields
                    }
                    GridRow {
                        label("Permissions")
                        permissionFields
                    }
                    GridRow {
                        label("Missed runs")
                        Toggle(isOn: $form.catchUp) {
                            Text("Catch up if the Mac slept or WhisperM8 was closed (up to 12 hours later)")
                                .font(.system(size: 12))
                        }
                        .toggleStyle(.checkbox)
                    }
                    GridRow {
                        label("Old runs")
                        VStack(alignment: .leading, spacing: 4) {
                            Picker(selection: $form.runArchiveDays) {
                                Text("To the archive after 14 days").tag(14)
                                Text("To the archive after 7 days").tag(7)
                                Text("Keep").tag(0)
                            } label: {
                                EmptyView()
                            }
                            .labelsHidden()
                            .fixedSize()
                            hint("The sidebar always keeps the last three runs. The chats of archived runs stay.")
                        }
                    }
                }
                .padding(.trailing, 4)
            }

            if let error {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(AgentTheme.statusError)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
            }

            Divider().padding(.top, 12)
            footer.padding(.top, 12)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(width: 620)
        .frame(minHeight: 520, idealHeight: 600)
        .task {
            guard accounts == nil else { return }
            let load = dependencies.loadAccounts
            accounts = await Task.detached(priority: .userInitiated) { load() }.value
        }
        .alert(Text("Delete “\(form.name)”?"), isPresented: $confirmDelete) {
            Button(role: .destructive) { delete() } label: { Text("Delete") }
            Button(role: .cancel) {} label: { Text("Cancel") }
        } message: {
            Text("The chats of its runs stay. Its run records are removed unless a run is working.")
        }
    }

    // MARK: Felder

    private func label(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(.system(size: 12))
            .foregroundStyle(AgentTheme.textSecondary)
            .frame(width: 112, alignment: .leading)
            .gridColumnAlignment(.leading)
    }

    private func hint(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(.system(size: 11))
            .foregroundStyle(AgentTheme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var folderMenu: some View {
        Menu {
            ForEach(projects) { project in
                Button(project.name + " · " + ScheduleCLIFormatter.homeAbbreviated(project.path)) {
                    form.directory = project.path
                }
            }
            if !projects.isEmpty { Divider() }
            Button {
                if let path = dependencies.chooseFolder() { form.directory = path }
            } label: {
                Text("Other folder…")
            }
        } label: {
            Text(verbatim: folderTitle)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .menuStyle(.borderedButton)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var folderTitle: String {
        guard !form.directory.isEmpty else { return String(localized: "Choose a folder…") }
        let path = ScheduledTaskValidation.normalizedDirectory(form.directory)
        let name = projects.first { $0.path == path }?.name ?? URL(fileURLWithPath: path).lastPathComponent
        return name + " · " + ScheduleCLIFormatter.homeAbbreviated(path)
    }

    private var accountPicker: some View {
        let names = accountChoices
        return Picker(selection: $form.account) {
            ForEach(names, id: \.self) { name in
                Text(verbatim: accountTitle(name)).tag(name)
            }
        } label: {
            EmptyView()
        }
        .labelsHidden()
        .fixedSize()
    }

    private var accountChoices: [String] {
        var names = accounts ?? [ClaudeAccountProfiles.mainProfileName]
        if !names.contains(form.account) { names.append(form.account) }
        return names
    }

    private func accountTitle(_ name: String) -> String {
        if let accounts, !accounts.contains(name) {
            return String(localized: "\(name) (missing)")
        }
        guard let ends = dependencies.loginEndsAt(name) else { return name }
        if ends <= now { return String(localized: "\(name) · login expired") }
        return String(localized: "\(name) · login until \(clock.formatter("dMMM").string(from: ends))")
    }

    private var scheduleFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(selection: $form.kind) {
                Text("Daily").tag(ScheduledTaskSchedule.Kind.daily)
                Text("Weekdays").tag(ScheduledTaskSchedule.Kind.weekdays)
                Text("Weekly").tag(ScheduledTaskSchedule.Kind.weekly)
                Text("Hourly").tag(ScheduledTaskSchedule.Kind.hourly)
            } label: {
                EmptyView()
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()

            if form.kind == .weekly {
                HStack(spacing: 4) {
                    ForEach(1...7, id: \.self) { day in
                        Toggle(isOn: Binding(
                            get: { form.days.contains(day) },
                            set: { on in if on { form.days.insert(day) } else { form.days.remove(day) } }
                        )) {
                            Text(verbatim: ScheduledTaskTexts.dayName(day, clock: clock))
                                .font(.system(size: 11))
                        }
                        .toggleStyle(.button)
                    }
                }
            }

            HStack(spacing: 8) {
                if form.kind == .hourly {
                    Text("at minute")
                        .font(.system(size: 12))
                    TextField("", text: $form.minuteText, prompt: Text(verbatim: "15"))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 50)
                } else {
                    Text("at")
                        .font(.system(size: 12))
                    TextField("", text: $form.timesText, prompt: Text(verbatim: "07:00, 22:30"))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                    hint("Several times separated by commas.")
                }
            }
        }
    }

    private var permissionFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker(selection: $form.access) {
                Text("Read, and write in the project folder").tag(ScheduledTaskPermissions.Access.projectWrite)
                Text("Read only").tag(ScheduledTaskPermissions.Access.readOnly)
                Text("Only the tools listed below").tag(ScheduledTaskPermissions.Access.custom)
            } label: {
                EmptyView()
            }
            .labelsHidden()
            .pickerStyle(.radioGroup)

            hint(accessHint)
            hint("Permissions from the account’s settings.json do not apply to runs, nor do those of the project or the allowed-tools of a skill. A run may do exactly what this task allows.")

            HStack(spacing: 8) {
                if form.access == .custom { Text("Allowed tools").font(.system(size: 12)) } else { Text("Also allow").font(.system(size: 12)) }
                TextField("", text: $form.extraToolsText, prompt: Text(verbatim: "Bash(whisperm8 tickets *), mcp__linear__get_issue"))
                    .textFieldStyle(.roundedBorder)
            }
            hint("Bash, web, MCP and the tools that reach other sessions, the cloud or other folders (SendMessage, ListAgents, RemoteTrigger, CronCreate, CronDelete, PushNotification, DesignSync, EnterWorktree, ExitWorktree) stay blocked unless you name them here. An mcp__… entry loads only that MCP server. Paths: a leading / means the project folder, //… an absolute path, ~/… the home folder; for writing use Edit(…).")
        }
    }

    private var accessHint: LocalizedStringKey {
        switch form.access {
        case .projectWrite:
            return "Read, Glob, Grep, Edit and Skill. Reading covers the whole disk, not only the folder. Writing only in the project folder, never in .claude, .git or .mcp.json."
        case .readOnly:
            return "Read, Glob, Grep and Skill. Reading covers the whole disk. Read only holds only while Bash stays blocked."
        case .custom:
            return "Only the tools you list, nothing else."
        }
    }

    // MARK: Fuß

    private var footer: some View {
        HStack(spacing: 8) {
            Text(verbatim: nextRunText)
                .font(.system(size: 11.5))
                .foregroundStyle(AgentTheme.textSecondary)
                .lineLimit(2)
            if !isNew {
                Button(role: .destructive) { confirmDelete = true } label: { Text("Delete…") }
                    .disabled(isSaving)
            }
            Spacer(minLength: 8)
            Button { cancel() } label: { Text("Cancel") }
                .keyboardShortcut(.cancelAction)
                .disabled(isSubmitting)
            Button { save() } label: {
                if isNew { Text("Create") } else { Text("Save") }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(isSaving)
        }
    }

    private var nextRunText: String {
        if target.task?.paused == true { return String(localized: "Paused: nothing starts until you resume.") }
        guard case .success(let schedule) = form.schedule(),
              let next = ScheduledTaskCalendar.nextOccurrence(of: schedule, after: now, calendar: .current) else {
            return String(localized: "No next run yet.")
        }
        return String(localized: "Next run: \(ScheduledTaskTexts.dateTime(next, clock: clock)), in account \(form.account)")
    }

    // MARK: Aktionen

    private func cancel() {
        cancellation.isCancelled = true
        dismiss()
    }

    private func save() {
        let others = existing.filter { $0.id != target.task?.id }
        let form = form
        let accounts = accounts
        let exists = dependencies.directoryExists
        let cancellation = cancellation
        isSaving = true
        Task {
            // Der Ordner wird abseits des Main Threads geprüft (Netzlaufwerke).
            let directory = ScheduledTaskValidation.normalizedDirectory(form.directory)
            let directoryOK = form.directory.isEmpty
                ? false : await Task.detached(priority: .userInitiated) { exists(directory) }.value
            // Während der Prüfung abgebrochen: nichts speichern.
            guard !cancellation.isCancelled else { return }
            if let problem = form.problem(others: others, accounts: accounts, directoryExists: { _ in directoryOK }) {
                error = problem
                isSaving = false
                return
            }
            let draft: ScheduledTaskDraft
            switch form.draft(original: target.task) {
            case .success(let value): draft = value
            case .failure(let failure):
                error = failure.message
                isSaving = false
                return
            }
            if let task = target.task, draft.isEmpty {
                isSaving = false
                onSaved(task)
                dismiss()
                return
            }
            isSubmitting = true
            let result = await dependencies.save(draft, target.task?.id)
            isSubmitting = false
            isSaving = false
            switch result {
            case .success(let task):
                onSaved(task)
                dismiss()
            case .failure(let failure):
                error = failure.message
            }
        }
    }

    private func delete() {
        guard let id = target.task?.id else { return }
        isSaving = true
        Task {
            let message = await dependencies.remove(id)
            isSaving = false
            if let message {
                error = message
            } else {
                onDeleted()
                dismiss()
            }
        }
    }
}

/// Merker „Blatt abgebrochen“ für einen Speichern-Schritt, der gerade auf die
/// Ordnerprüfung wartet. Gelesen und gesetzt nur auf dem Main Thread.
final class ScheduledTaskEditorCancellation: @unchecked Sendable {
    var isCancelled = false
}
