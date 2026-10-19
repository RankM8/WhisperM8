import Foundation
import UserNotifications

/// Kurzer, nicht-modaler Hinweis des Diktats (Mitteilung) für Fälle, in denen
/// kein Overlay mehr steht — etwa wenn das Auto-Paste nicht stattfand.
enum DictationNotice {
    static func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                Logger.paste.warning("dictation_notice_failed error=\(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
