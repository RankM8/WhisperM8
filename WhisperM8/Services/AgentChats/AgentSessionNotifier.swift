import Foundation
import UserNotifications

/// Fertig aufbereitete User-Notification für ein Session-Ereignis.
/// Entsteht im `AgentSessionStatusCoordinator` aus State-Machine-Effekten.
struct AgentSessionUserNotification: Equatable {
    enum Kind: Equatable {
        case turnCompleted
        case inputRequested(AwaitingInputKind)
        /// Codex-Subagent-Job fertig (Report liegt vor).
        case subagentCompleted
        /// Codex-Subagent-Job fehlgeschlagen.
        case subagentFailed
    }

    var kind: Kind
    var localSessionID: UUID
    /// Session-Titel (Sidebar-Name).
    var title: String
    /// Projektname als Kontextzeile.
    var projectName: String?

    var body: String {
        switch kind {
        case .turnCompleted:
            return "Agent ist fertig und wartet auf dich."
        case .inputRequested(let reason):
            return "Agent \(reason.notificationLabel)."
        case .subagentCompleted:
            return "Subagent ist fertig — Report liegt vor."
        case .subagentFailed:
            return "Subagent ist fehlgeschlagen."
        }
    }
}

/// Seam fürs Posten — Tests injizieren einen Spy statt UNUserNotificationCenter.
protocol AgentUserNotificationPosting {
    func post(_ notification: AgentSessionUserNotification)
}

/// Produktions-Poster über `UNUserNotificationCenter`. Kein `content.sound`:
/// der Fertig-Ton läuft separat über `NSSound` (konfigurierbar, spielt auch
/// bei App im Vordergrund); Rückfrage-Notifications sind bewusst lautlos.
struct UNAgentUserNotificationPoster: AgentUserNotificationPosting {
    static let localSessionIDUserInfoKey = "localSessionID"

    func post(_ notification: AgentSessionUserNotification) {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        if let projectName = notification.projectName, !projectName.isEmpty {
            content.subtitle = projectName
        }
        content.body = notification.body
        content.userInfo = [
            Self.localSessionIDUserInfoKey: notification.localSessionID.uuidString
        ]
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                Logger.claudeBinding.warning("notification_post_failed error=\(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

/// Flatter-Schutz: identische Ereignisse (gleiche Session, gleiche Art) werden
/// innerhalb `minimumInterval` nur einmal gepostet. Unterschiedliche Arten
/// (Rückfrage → kurz darauf fertig) laufen ungedrosselt — das sind echte,
/// getrennte Informationen. Pur & testbar.
struct AgentNotificationThrottle {
    var minimumInterval: TimeInterval
    private var lastPosted: [UUID: (kind: AgentSessionUserNotification.Kind, at: Date)] = [:]

    init(minimumInterval: TimeInterval = 2.0) {
        self.minimumInterval = minimumInterval
    }

    mutating func shouldPost(_ notification: AgentSessionUserNotification, now: Date) -> Bool {
        if let last = lastPosted[notification.localSessionID],
           last.kind == notification.kind,
           now.timeIntervalSince(last.at) < minimumInterval {
            return false
        }
        lastPosted[notification.localSessionID] = (notification.kind, now)
        return true
    }
}
