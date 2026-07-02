import AppKit
import SwiftUI

/// Wendet ein `AppUsageProfile` zur Laufzeit an: persistiert die Wahl, schaltet die
/// Aktivierungs-Policy (Dock vs. Menüleiste) und gibt das Agent-Chats-Primärfenster frei
/// bzw. sperrt es. Das eigentliche Öffnen/Schließen der Agent-Chats-Fenster bleibt beim
/// Aufrufer (SwiftUI `openWindow`/`dismissWindow` bzw. `WindowRequestCenter`), da dafür
/// der View-Kontext nötig ist.
///
/// Gemeinsam genutzt von Onboarding-Abschluss und dem Profil-Switch in den Settings.
@MainActor
enum AppProfileActivator {
    static func apply(_ profile: AppUsageProfile) {
        AppPreferences.shared.usageProfile = profile
        NSApp.setActivationPolicy(profile.activationPolicy)
        WindowRequestCenter.shared.allowsAgentChatsPrimaryWindow = profile.wantsAgentChats
    }

    /// Schließt ALLE Agent-Chats-Fenster: das Primärfenster und alle abgelösten
    /// Sekundärfenster (Tabs in eigenen Fenstern). Für den Wechsel in ein
    /// Menüleisten-Profil — nur das Primärfenster zu schließen würde verwaiste
    /// Sekundärfenster zurücklassen. Der Store-State (offene Tabs) bleibt erhalten,
    /// sodass ein Rückwechsel zu „Full" alles wiederherstellt.
    static func closeAgentChatWindows(using dismissWindow: DismissWindowAction) {
        let store = AgentWindowStore.shared
        // Programmatisches Schliessen: das willClose-Tracking wuerde die Fenster
        // sonst als „vom User geschlossen" werten und aus dem Store werfen — der
        // Rueckwechsel zu „Full" soll sie aber wiederherstellen. dismissWindow
        // schliesst die NSWindows u. U. erst in einem spaeteren Runloop-Zyklus,
        // deshalb Resume verzoegert statt synchron. Die Kollisionsflaeche ist
        // praktisch null: direkt nach dem Wechsel existiert kein Agent-Fenster
        // mehr, das der User in diesem Zeitfenster manuell schliessen koennte.
        store.suspendCloseTracking()
        dismissWindow(id: WindowRequest.agentChats.targetWindowID)
        for windowID in store.secondaryWindowIDs {
            dismissWindow(id: WindowRequest.agentChatWindowGroupID, value: windowID)
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            store.resumeCloseTracking()
        }
    }
}
