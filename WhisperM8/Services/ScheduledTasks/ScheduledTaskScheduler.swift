import Foundation

// MARK: - Planer der geplanten Aufgaben

/// Einziger Schreiber von `scheduled-tasks.json` und einziger Starter von
/// Läufen. Ein Actor, damit Termin, Nachholen und Handstart nie gleichzeitig
/// dieselbe Aufgabe anfassen.
///
/// Kein Lauf startet doppelt:
/// - Ein fälliger Termin wird in `lastSlot` gespeichert, BEVOR der Lauf startet
///   (höchstens einmal, auch wenn die App dazwischen abstürzt).
/// - Arbeitet der vorige Lauf derselben Aufgabe noch (auch über einen
///   App-Neustart hinweg, erkannt an PID und Startzeit), wird der Termin als
///   „übersprungen“ eingetragen statt ein zweiter Lauf gestartet.
/// - Nur eine App-Instanz plant (`scheduler.lock`, `flock`).
actor ScheduledTaskScheduler {
    struct Environment {
        var store: ScheduledTaskStore
        var now: () -> Date
        var calendar: () -> Calendar
        var isEnabled: () -> Bool
        var claudePath: () -> String?
        /// Umgebung für das Konto (`CLAUDE_CONFIG_DIR`), `nil` = Konto gibt es nicht.
        var accountEnvironment: (String) -> [String: String]?
        /// Grund-Umgebung jedes Laufs (Login-Shell-PATH, Plugin, Test-Instanz).
        var baseEnvironment: () -> [String: String]
        var authStatus: (_ claudePath: String, _ environment: [String: String], _ directory: String) async
            -> ScheduledTaskLauncher.AuthStatus?
        var supportsNativeName: () -> Bool
        var directoryExists: (String) -> Bool
        var spawn: (ScheduledTaskLauncher.SpawnPlan) throws -> Int32
        var processStartTime: (Int32) -> Date?
        var isProcessAlive: (Int32, Date?) -> Bool
        /// Meldet das Ende eines Prozesses (auch eines fremden Kindes nach Neustart).
        var watchExit: (Int32, @escaping @Sendable () -> Void) -> Void
    }

    /// Fehler des Planers als Fälle (Prüfung WM8-110, K4): Die CLI bekommt
    /// über den Socket `errorDescription` (deutsch wie ihre übrigen Texte),
    /// die Ansicht übersetzt mit `ScheduledTaskTexts.schedulerError`.
    enum SchedulerError: LocalizedError, Equatable {
        case disabled
        case notLeader
        case notFound(String)
        case invalid(ScheduledTaskValidationProblem)
        /// Ein Lauf der Aufgabe arbeitet noch.
        case conflict(taskName: String)
        case storage(StorageProblem)

        enum StorageProblem: Equatable {
            /// Der Ordner für einen neuen Lauf ließ sich nicht anlegen.
            case runFolder
            case store(ScheduledTaskStore.StoreError)
            case other(String)
        }

        var errorDescription: String? {
            switch self {
            case .disabled:
                return "Geplante Aufgaben sind aus. Einschalten unter Einstellungen › Labs › Scheduled tasks."
            case .notLeader:
                return "Eine andere WhisperM8-Instanz plant die Aufgaben gerade; diese ändert nichts."
            case .notFound(let ref): return "Keine geplante Aufgabe \(ref)."
            case .invalid(let problem): return problem.cliText
            case .conflict(let name):
                return "Ein Lauf von „\(name)“ arbeitet noch. Zwei Läufe derselben Aufgabe gibt es nicht."
            case .storage(.runFolder): return "Der Lauf-Ordner ließ sich nicht anlegen."
            case .storage(.store(let error)): return error.errorDescription
            case .storage(.other(let message)): return message
            }
        }
    }

    private let env: Environment
    private var lockDescriptor: Int32 = -1
    private var isLeader = false
    /// Aufgaben, deren Start gerade läuft (Login-Prüfung), gegen Doppelstarts.
    private var launching: Set<UUID> = []
    /// Von uns gestartete Wrapper, die noch abgeholt werden müssen (`waitpid`).
    private var spawnedPIDs: Set<Int32> = []
    private var watchedRunIDs: Set<String> = []

    init(environment: Environment) {
        env = environment
    }

    deinit {
        if lockDescriptor >= 0 { close(lockDescriptor) }
    }

    // MARK: Start

    /// Sperre nehmen und laufende Läufe aus der Zeit vor dem Neustart
    /// wiedererkennen. Gibt `false` zurück, wenn eine andere Instanz plant.
    @discardableResult
    func start() -> Bool {
        if !isLeader { isLeader = acquireLock() }
        guard isLeader else {
            Logger.scheduledTasks.info("scheduler_not_leader")
            return false
        }
        recognizeActiveRuns()
        return true
    }

    private func acquireLock() -> Bool {
        do { try ScheduledTaskStore.ensureDirectory(env.store.dataDirectory) } catch { return false }
        let fd = open(env.store.lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return false }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return false
        }
        lockDescriptor = fd
        return true
    }

    /// Nach einem App-Neustart: Läufe, deren Wrapper noch lebt, beobachten.
    private func recognizeActiveRuns() {
        guard let file = try? env.store.load() else { return }
        for task in file.tasks {
            // Je Aufgabe arbeitet höchstens ein Lauf, und nur ein gestarteter;
            // Einträge „übersprungen“ oder „verpasst“ dahinter zählen nicht.
            if let run = env.store.latestStartedRun(for: task.id) {
                let outcome = ScheduledTaskRunEvaluator.outcome(of: run, now: env.now(), isProcessAlive: env.isProcessAlive)
                guard outcome == .running, let pid = run.record.pid else { continue }
                Logger.scheduledTasks.info("run_recognized task=\(task.shortID, privacy: .public) run=\(run.record.runID, privacy: .public) pid=\(pid)")
                watch(pid: pid, runDirectory: run.directory, runID: run.record.runID)
            }
        }
    }

    // MARK: Termine

    /// Fällige Termine starten, verpasste eintragen. Gibt den nächsten Termin
    /// zurück (für den Zeitgeber), `nil` = keiner oder Planer inaktiv.
    @discardableResult
    func evaluate(reason: String) async -> Date? {
        guard env.isEnabled() else { return nil }
        // Eine andere Instanz hielt die Sperre; vielleicht ist sie inzwischen beendet.
        guard isLeader || start() else { return nil }
        reapChildren()
        let now = env.now()
        let calendar = env.calendar()
        let claims: [Claim]
        do {
            claims = try claimDueSlots(now: now, calendar: calendar)
        } catch {
            Logger.scheduledTasks.error("evaluate_failed reason=\(reason, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            return nil
        }
        for claim in claims {
            switch claim.action {
            case .start(let trigger):
                _ = await launch(claim.task, trigger: trigger, slot: claim.slot)
            case .skip(let reason, let message):
                writeNotStarted(claim.task, trigger: .schedule, slot: claim.slot, reason: reason, message: message)
            }
        }
        guard let file = try? env.store.load() else { return nil }
        return ScheduledTaskCalendar.nextWake(for: file.tasks, after: env.now(), calendar: calendar)
    }

    private struct Claim {
        enum Action {
            case start(ScheduledTaskRunRecord.Trigger)
            case skip(ScheduledTaskRunRecord.NotStarted, String)
        }
        var task: ScheduledTask
        var slot: Date
        var action: Action
    }

    /// Ein synchroner Abschnitt: entscheiden und `lastSlot` speichern, bevor
    /// irgendetwas startet. Danach sieht jeder weitere Aufruf den Termin als erledigt.
    private func claimDueSlots(now: Date, calendar: Calendar) throws -> [Claim] {
        var claims: [Claim] = []
        try mutate { file in
            for index in file.tasks.indices {
                let task = file.tasks[index]
                switch ScheduledTaskCalendar.decide(task, now: now, calendar: calendar) {
                case .run(let slot, let catchUp):
                    file.tasks[index].lastSlot = slot
                    if isActive(task.id, now: now) {
                        claims.append(Claim(task: task, slot: slot, action: .skip(
                            .stillRunning, "Termin \(self.slotText(slot)) übersprungen: Der vorige Lauf arbeitete noch.")))
                    } else {
                        claims.append(Claim(task: task, slot: slot, action: .start(catchUp ? .catchUp : .schedule)))
                    }
                case .missed(let slot):
                    file.tasks[index].lastSlot = slot
                    let why = task.catchUp
                        ? "Termin \(self.slotText(slot)) verpasst, mehr als 12 Stunden her (Mac schlief oder App war zu)."
                        : "Termin \(self.slotText(slot)) verpasst; Nachholen ist für diese Aufgabe aus."
                    claims.append(Claim(task: task, slot: slot, action: .skip(.missed, why)))
                case .paused, .wait:
                    continue
                }
            }
        }
        for claim in claims {
            Logger.scheduledTasks.info("slot_claimed task=\(claim.task.shortID, privacy: .public) slot=\(claim.slot.timeIntervalSince1970)")
        }
        return claims
    }

    // MARK: Ändern (über `whisperm8 schedule …`)

    func add(_ draft: ScheduledTaskDraft) throws -> ScheduledTask {
        try requireWritable()
        let now = env.now()
        guard let name = draft.name, let prompt = draft.prompt, let directory = draft.directory,
              let account = draft.account, let schedule = draft.schedule else {
            throw SchedulerError.invalid(.fieldsMissing)
        }
        var task = ScheduledTask(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
            directory: ScheduledTaskValidation.normalizedDirectory(directory), account: account,
            schedule: schedule,
            permissions: ScheduledTaskPermissions(access: draft.access ?? .projectWrite, extraTools: draft.extraTools ?? []),
            catchUp: draft.catchUp ?? true, paused: draft.paused ?? false, createdAt: now)
        task.lastSlot = nil
        try mutate { file in
            try self.validate(task, in: file)
            file.tasks.append(task)
        }
        Logger.scheduledTasks.info("task_added task=\(task.shortID, privacy: .public)")
        return task
    }

    func edit(id: UUID, draft: ScheduledTaskDraft) throws -> ScheduledTask {
        try requireWritable()
        let now = env.now()
        let calendar = env.calendar()
        return try mutate { file in
            guard let index = file.tasks.firstIndex(where: { $0.id == id }) else {
                throw SchedulerError.notFound(id.uuidString.lowercased())
            }
            let old = file.tasks[index]
            var task = old
            if let name = draft.name { task.name = name.trimmingCharacters(in: .whitespacesAndNewlines) }
            if let prompt = draft.prompt { task.prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines) }
            if let directory = draft.directory { task.directory = ScheduledTaskValidation.normalizedDirectory(directory) }
            if let account = draft.account { task.account = account }
            if let schedule = draft.schedule { task.schedule = schedule }
            if let access = draft.access { task.permissions.access = access }
            if let tools = draft.extraTools { task.permissions.extraTools = tools }
            if let catchUp = draft.catchUp { task.catchUp = catchUp }
            if let paused = draft.paused { task.paused = paused }
            // Neuer Zeitplan oder fortgesetzt: Was schon vorbei ist, startet nicht sofort.
            if task.schedule != old.schedule || (old.paused && !task.paused) {
                task.lastSlot = ScheduledTaskCalendar.slotMarker(for: task, now: now, calendar: calendar)
            }
            task.updatedAt = now
            try self.validate(task, in: file)
            file.tasks[index] = task
            Logger.scheduledTasks.info("task_edited task=\(task.shortID, privacy: .public)")
            return task
        }
    }

    func setPaused(id: UUID, paused: Bool) throws -> ScheduledTask {
        try edit(id: id, draft: ScheduledTaskDraft(paused: paused))
    }

    /// Entfernt die Aufgabe. Die Chats ihrer Läufe bleiben; die Lauf-Ordner
    /// gehen mit, sofern gerade keiner arbeitet.
    func remove(id: UUID) throws -> ScheduledTask {
        try requireWritable()
        let now = env.now()
        let removed: ScheduledTask = try mutate { file in
            guard let index = file.tasks.firstIndex(where: { $0.id == id }) else {
                throw SchedulerError.notFound(id.uuidString.lowercased())
            }
            return file.tasks.remove(at: index)
        }
        if !isActive(id, now: now) {
            try? FileManager.default.removeItem(at: env.store.runsDirectory(for: id))
        }
        Logger.scheduledTasks.info("task_removed task=\(removed.shortID, privacy: .public)")
        return removed
    }

    /// Startet sofort, ohne den Zeitplan zu berühren. Verweigert, solange ein
    /// Lauf derselben Aufgabe arbeitet.
    func runNow(id: UUID) async throws -> ScheduledTaskRunRecord {
        try requireWritable()
        guard let task = try loadFile().tasks.first(where: { $0.id == id }) else {
            throw SchedulerError.notFound(id.uuidString.lowercased())
        }
        guard !isActive(id, now: env.now()) else {
            throw SchedulerError.conflict(taskName: task.name)
        }
        guard let record = await launch(task, trigger: .manual, slot: nil) else {
            throw SchedulerError.storage(.runFolder)
        }
        return record
    }

    // MARK: Lauf starten

    /// Legt den Lauf-Ordner an, prüft Ordner, Konto, Claude und Login und
    /// startet losgelöst. Gibt den geschriebenen Eintrag zurück.
    private func launch(_ task: ScheduledTask, trigger: ScheduledTaskRunRecord.Trigger, slot: Date?) async -> ScheduledTaskRunRecord? {
        launching.insert(task.id)
        defer { launching.remove(task.id) }
        let now = env.now()
        let runID = ScheduledTaskRunRecord.makeRunID(now: now)
        let runDirectory = env.store.runsDirectory(for: task.id).appendingPathComponent(runID, isDirectory: true)
        var record = ScheduledTaskRunRecord(
            runID: runID, taskID: task.id, taskName: task.name, sessionID: UUID(), account: task.account,
            directory: task.directory, trigger: trigger, slot: slot, createdAt: now)
        do {
            try env.store.writeRecord(record, in: runDirectory)
        } catch {
            Logger.scheduledTasks.error("run_record_failed task=\(task.shortID, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            return nil
        }

        func notStarted(_ reason: ScheduledTaskRunRecord.NotStarted, _ message: String) -> ScheduledTaskRunRecord {
            record.notStarted = reason
            record.message = message
            record.sessionID = nil
            try? env.store.writeRecord(record, in: runDirectory)
            Logger.scheduledTasks.info("run_not_started task=\(task.shortID, privacy: .public) reason=\(reason.rawValue, privacy: .public)")
            return record
        }

        guard env.directoryExists(task.directory) else {
            return notStarted(.folderMissing, "Projektordner fehlt: \(task.directory)")
        }
        guard let accountEnvironment = env.accountEnvironment(task.account) else {
            return notStarted(.accountMissing, "Das Claude-Konto „\(task.account)“ gibt es nicht mehr.")
        }
        guard let claudePath = env.claudePath() else {
            return notStarted(.claudeMissing, "Claude Code ist nicht installiert oder nicht im PATH.")
        }
        var environment = env.baseEnvironment().merging(accountEnvironment) { _, account in account }
        if let auth = await env.authStatus(claudePath, environment, task.directory) {
            let expired = auth.loginExpiresAt.map { $0 <= env.now() } ?? false
            if !auth.loggedIn || expired {
                return notStarted(.loginExpired,
                                  "Login von \(task.account) abgelaufen. Erneuern unter Einstellungen › Accounts.")
            }
        }

        guard let sessionID = record.sessionID else { return record }
        for key in ScheduledTaskLauncher.inheritedChatEnvironmentKeys { environment.removeValue(forKey: key) }
        environment[ScheduledTaskLauncher.taskIDEnvironmentKey] = task.id.uuidString.lowercased()
        environment[ScheduledTaskLauncher.runIDEnvironmentKey] = runID
        let name = env.supportsNativeName() ? ScheduledTaskLauncher.sessionName(taskName: task.name, date: now) : nil
        let plan = ScheduledTaskLauncher.SpawnPlan(
            claudePath: claudePath,
            claudeArguments: ScheduledTaskLauncher.claudeArguments(
                prompt: task.prompt, sessionID: sessionID, name: name, permissions: task.permissions),
            environment: environment, workingDirectory: task.directory, runDirectory: runDirectory)
        let pid: Int32
        do {
            pid = try env.spawn(plan)
        } catch {
            return notStarted(.launchFailed, error.localizedDescription)
        }
        spawnedPIDs.insert(pid)
        record.pid = pid
        record.processStartedAt = env.processStartTime(pid)
        try? env.store.writeRecord(record, in: runDirectory)
        Logger.scheduledTasks.info("run_started task=\(task.shortID, privacy: .public) run=\(runID, privacy: .public) trigger=\(trigger.rawValue, privacy: .public) pid=\(pid)")
        watch(pid: pid, runDirectory: runDirectory, runID: runID)
        return record
    }

    private func writeNotStarted(_ task: ScheduledTask, trigger: ScheduledTaskRunRecord.Trigger, slot: Date,
                                 reason: ScheduledTaskRunRecord.NotStarted, message: String) {
        let now = env.now()
        let runID = ScheduledTaskRunRecord.makeRunID(now: now)
        let record = ScheduledTaskRunRecord(
            runID: runID, taskID: task.id, taskName: task.name, sessionID: nil, account: task.account,
            directory: task.directory, trigger: trigger, slot: slot, createdAt: now,
            notStarted: reason, message: message)
        let directory = env.store.runsDirectory(for: task.id).appendingPathComponent(runID, isDirectory: true)
        try? env.store.writeRecord(record, in: directory)
        Logger.scheduledTasks.info("run_not_started task=\(task.shortID, privacy: .public) reason=\(reason.rawValue, privacy: .public)")
    }

    // MARK: Ende eines Laufs

    private func watch(pid: Int32, runDirectory: URL, runID: String) {
        guard watchedRunIDs.insert(runID).inserted else { return }
        env.watchExit(pid) { [weak self] in
            Task { await self?.runEnded(pid: pid, runDirectory: runDirectory, runID: runID) }
        }
    }

    private func runEnded(pid: Int32, runDirectory: URL, runID: String) {
        watchedRunIDs.remove(runID)
        reap(pid)
        guard let files = env.store.readRun(at: runDirectory) else { return }
        let outcome = ScheduledTaskRunEvaluator.outcome(of: files, isProcessAlive: { _, _ in false })
        Logger.scheduledTasks.info("run_ended run=\(runID, privacy: .public) outcome=\(outcome.label, privacy: .public)")
    }

    private func reap(_ pid: Int32) {
        guard spawnedPIDs.contains(pid) else { return }
        var status: Int32 = 0
        if waitpid(pid, &status, WNOHANG) != 0 { spawnedPIDs.remove(pid) }
    }

    /// Sicherheitsnetz, falls ein Ende-Ereignis fehlte: tote Kinder abholen.
    private func reapChildren() {
        for pid in spawnedPIDs { reap(pid) }
    }

    // MARK: Helfer

    /// Arbeitet gerade ein Lauf der Aufgabe (oder startet er)?
    private func isActive(_ taskID: UUID, now: Date) -> Bool {
        if launching.contains(taskID) { return true }
        // Der jüngste Ordner ist oft ein „übersprungen“ ohne Prozess; zählt
        // nur der jüngste gestartete Lauf.
        guard let latest = env.store.latestStartedRun(for: taskID) else { return false }
        return ScheduledTaskRunEvaluator.outcome(of: latest, now: now, isProcessAlive: env.isProcessAlive).isActive
    }

    private func requireWritable() throws {
        guard env.isEnabled() else { throw SchedulerError.disabled }
        guard isLeader || start() else { throw SchedulerError.notLeader }
    }

    private func loadFile() throws -> ScheduledTasksFile {
        do { return try env.store.load() } catch { throw SchedulerError.storage(Self.storageProblem(error)) }
    }

    /// Laden, ändern, speichern in einem synchronen Stück (kein `await`).
    private func mutate<T>(_ body: (inout ScheduledTasksFile) throws -> T) throws -> T {
        var file = try loadFile()
        let result = try body(&file)
        do { try env.store.save(file) } catch { throw SchedulerError.storage(Self.storageProblem(error)) }
        return result
    }

    private static func storageProblem(_ error: Error) -> SchedulerError.StorageProblem {
        (error as? ScheduledTaskStore.StoreError).map(SchedulerError.StorageProblem.store) ?? .other(error.localizedDescription)
    }

    private func validate(_ task: ScheduledTask, in file: ScheduledTasksFile) throws {
        if let problem = ScheduledTaskValidation.problem(
            in: task, others: file.tasks.filter { $0.id != task.id },
            directoryExists: env.directoryExists,
            accountExists: { self.env.accountEnvironment($0) != nil }) {
            throw SchedulerError.invalid(problem)
        }
    }

    private func slotText(_ date: Date) -> String {
        ScheduledTaskCalendar.shortText(date, calendar: env.calendar())
    }
}

// MARK: - Änderungswunsch (CLI → App)

/// Felder einer neuen oder geänderten Aufgabe. `nil` = unverändert (Ändern)
/// bzw. Standard (Anlegen). Geht als JSON über den Socket.
struct ScheduledTaskDraft: Codable, Equatable {
    var name: String?
    var prompt: String?
    var directory: String?
    var account: String?
    var schedule: ScheduledTaskSchedule?
    var access: ScheduledTaskPermissions.Access?
    /// Ersetzt die Liste der zusätzlich erlaubten Werkzeuge.
    var extraTools: [String]?
    var catchUp: Bool?
    var paused: Bool?

    var isEmpty: Bool { self == ScheduledTaskDraft() }
}

// MARK: - Prüfung

enum ScheduledTaskValidation {
    static let maxNameLength = 80

    static func normalizedDirectory(_ raw: String) -> String {
        let expanded = (raw.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    /// Erster Fehler oder `nil`. Text: `cliText` (CLI) bzw.
    /// `ScheduledTaskTexts.problem` (Ansicht).
    static func problem(in task: ScheduledTask, others: [ScheduledTask],
                        directoryExists: (String) -> Bool, accountExists: (String) -> Bool) -> ScheduledTaskValidationProblem? {
        if task.name.isEmpty { return .nameMissing }
        if task.name.count > maxNameLength { return .nameTooLong(maxNameLength) }
        if task.name.contains(where: \.isNewline) { return .nameMultiline }
        if others.contains(where: { $0.name.caseInsensitiveCompare(task.name) == .orderedSame }) {
            return .nameTaken(task.name)
        }
        if task.prompt.isEmpty { return .promptMissing }
        if task.prompt.hasPrefix("-") { return .promptStartsWithDash }
        if !task.directory.hasPrefix("/") { return .directoryNotAbsolute }
        if !directoryExists(task.directory) { return .directoryMissing(task.directory) }
        if !accountExists(task.account) { return .accountMissing(task.account) }
        if let problem = task.schedule.validationProblem { return .schedule(problem) }
        if task.permissions.extraTools.contains(where: { $0.contains(where: \.isNewline) || $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            return .toolEmptyOrMultiline
        }
        if task.permissions.extraTools.contains(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("-") }) {
            return .toolStartsWithDash
        }
        if task.permissions.access == .custom, task.permissions.allowedTools.isEmpty {
            return .customListEmpty
        }
        return nil
    }
}

/// Warum eine Aufgabe so nicht gespeichert wird (Prüfung WM8-110, K4).
enum ScheduledTaskValidationProblem: Equatable {
    case fieldsMissing
    case nameMissing
    case nameTooLong(Int)
    case nameMultiline
    case nameTaken(String)
    case promptMissing
    case promptStartsWithDash
    case directoryNotAbsolute
    case directoryMissing(String)
    case accountMissing(String)
    case schedule(ScheduledTaskSchedule.Problem)
    case toolEmptyOrMultiline
    case toolStartsWithDash
    case customListEmpty

    /// Deutsch für die CLI, wie ihre übrigen Texte.
    var cliText: String {
        switch self {
        case .fieldsMissing: return "Zum Anlegen fehlen Angaben: Name, Auftrag, Ordner, Konto und Zeitplan sind Pflicht."
        case .nameMissing: return "Name fehlt."
        case .nameTooLong(let max): return "Name ist länger als \(max) Zeichen."
        case .nameMultiline: return "Name darf keinen Zeilenumbruch enthalten."
        case .nameTaken(let name): return "Es gibt schon eine Aufgabe „\(name)“."
        case .promptMissing: return "Auftrag fehlt."
        case .promptStartsWithDash: return "Der Auftrag darf nicht mit „-“ beginnen (Claude läse ihn als Option)."
        case .directoryNotAbsolute: return "Ordner muss ein absoluter Pfad sein."
        case .directoryMissing(let path): return "Ordner gibt es nicht: \(path)"
        case .accountMissing(let account): return "Claude-Konto „\(account)“ gibt es nicht."
        case .schedule(let problem): return problem.cliText
        case .toolEmptyOrMultiline: return "Ein erlaubtes Werkzeug ist leer oder enthält einen Zeilenumbruch."
        case .toolStartsWithDash: return "Ein erlaubtes Werkzeug darf nicht mit „-“ beginnen (Claude läse es als Option)."
        case .customListEmpty: return "Eigene Liste braucht mindestens ein Werkzeug (--allow)."
        }
    }
}
