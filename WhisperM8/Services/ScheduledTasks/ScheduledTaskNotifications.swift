import Foundation
import UserNotifications

// MARK: - Mitteilung bei Fehlschlag (WM8-110, Paket 3)

/// Ein Lauf ist fehlgeschlagen: Ende mit Fehler, abgebrochen oder vom Planer
/// gar nicht erst gestartet (Login abgelaufen, Ordner fehlt …). Verpasste und
/// übersprungene Termine sind kein Fehlschlag.
struct ScheduledTaskFailureNotice: Equatable {
    var taskID: UUID
    var taskName: String
    var runID: String
    /// Sitzung des Laufs; `nil` = nicht gestartet, kein Chat.
    var sessionID: UUID?
    var outcome: ScheduledTaskRunOutcome

    init?(record: ScheduledTaskRunRecord, outcome: ScheduledTaskRunOutcome) {
        guard outcome.isFailure else { return nil }
        taskID = record.taskID
        taskName = record.taskName
        runID = record.runID
        sessionID = record.notStarted == nil ? record.sessionID : nil
        self.outcome = outcome
    }

    var title: String { String(localized: "Scheduled task failed") }
    var body: String { ScheduledTaskTexts.failureText(outcome) }
}

/// Mitteilung wie die Fertig-Mitteilung eines Chats, mit zwei Knöpfen
/// (Entwurf): direkt in den Chat des Laufs oder zur Aufgabe. Ein Klick auf die
/// Mitteilung selbst öffnet das Detail der Aufgabe; dort stehen Fehler und Weg
/// in den Chat.
enum ScheduledTaskNotifications {
    static let taskIDKey = "whisperm8.scheduledTaskID"
    static let sessionIDKey = "whisperm8.scheduledSessionID"
    static let categoryWithChat = "whisperm8.scheduledTaskFailed.chat"
    static let categoryWithoutChat = "whisperm8.scheduledTaskFailed"
    static let openChatAction = "whisperm8.scheduledTask.openChat"
    static let showTaskAction = "whisperm8.scheduledTask.showTask"

    /// Kategorien mit den beiden Knöpfen anmelden. Ergänzt die vorhandenen,
    /// statt sie zu ersetzen.
    static func registerCategories() {
        let openChat = UNNotificationAction(identifier: openChatAction, title: String(localized: "Open chat"), options: [.foreground])
        let showTask = UNNotificationAction(identifier: showTaskAction, title: String(localized: "Show task"), options: [.foreground])
        let ours: Set<UNNotificationCategory> = [
            UNNotificationCategory(identifier: categoryWithChat, actions: [openChat, showTask], intentIdentifiers: []),
            UNNotificationCategory(identifier: categoryWithoutChat, actions: [showTask], intentIdentifiers: []),
        ]
        let center = UNUserNotificationCenter.current()
        center.getNotificationCategories { existing in
            let others = existing.filter { $0.identifier != categoryWithChat && $0.identifier != categoryWithoutChat }
            center.setNotificationCategories(others.union(ours))
        }
    }

    static func post(_ notice: ScheduledTaskFailureNotice) {
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.subtitle = notice.taskName
        content.body = notice.body
        var userInfo: [String: String] = [taskIDKey: notice.taskID.uuidString]
        if let session = notice.sessionID { userInfo[sessionIDKey] = session.uuidString }
        content.userInfo = userInfo
        content.categoryIdentifier = notice.sessionID == nil ? categoryWithoutChat : categoryWithChat
        // Je Lauf eine Mitteilung; derselbe Lauf ersetzt seine eigene.
        let request = UNNotificationRequest(identifier: "scheduled-task-" + notice.runID, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                Logger.scheduledTasks.warning("failure_notification_failed error=\(error.localizedDescription, privacy: .public)")
            }
        }
        Logger.scheduledTasks.info("failure_notified run=\(notice.runID, privacy: .public)")
    }

    /// Ziel eines Klicks, rein und getestet.
    enum Route: Equatable {
        case task(UUID)
        case chat(session: UUID, task: UUID)
    }

    static func route(userInfo: [AnyHashable: Any], actionIdentifier: String) -> Route? {
        guard let raw = userInfo[taskIDKey] as? String, let taskID = UUID(uuidString: raw) else { return nil }
        if actionIdentifier == openChatAction,
           let rawSession = userInfo[sessionIDKey] as? String, let session = UUID(uuidString: rawSession) {
            return .chat(session: session, task: taskID)
        }
        return .task(taskID)
    }

    /// Klick auf die Mitteilung oder einen Knopf. Den Chat findet die App über
    /// die Sitzung des Laufs; hat der Indexer ihn noch nicht, öffnet das Detail.
    @MainActor
    static func open(_ route: Route) {
        let windowStore = AgentWindowStore.shared
        switch route {
        case .chat(let session, let taskID):
            let external = session.uuidString.lowercased()
            if let chat = AgentWorkspaceUIModel.shared.workspace.sessions.first(where: { $0.externalSessionID?.lowercased() == external }) {
                WindowRequestCenter.shared.requestSessionFocus(sessionID: chat.id)
                return
            }
            AgentScanCoordinator.shared.requestScan(reason: .manual)
            open(.task(taskID))
        case .task(let taskID):
            let window = windowStore.primaryWindowID
            windowStore.showScheduledTask(taskID, in: window)
            WindowRequestCenter.shared.requestWindowFocus(windowID: window)
        }
    }
}
