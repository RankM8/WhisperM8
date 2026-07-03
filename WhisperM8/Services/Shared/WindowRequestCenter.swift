import AppKit
import SwiftUI

enum WindowRequest: String, Equatable {
    case settings
    /// Öffnet das Settings-Fenster direkt in der Output-Sektion (Overview mit
    /// Default Output, Codex-Status und History-Einstieg).
    case settingsOutput = "settings-output"
    case onboarding
    case agentChats = "agent-chats"

    static let agentChatWindowGroupID = "agent-chat-window"

    var targetWindowID: String {
        switch self {
        case .settings, .settingsOutput:
            return "settings"
        case .agentChats:
            // Primaerfenster ist eine Single-`Window`-Scene (nicht die
            // UUID-WindowGroup) — die kann sich beim Launch/Reopen nicht
            // duplizieren. Die WindowGroup-ID ist nur fuer Sekundaerfenster.
            return rawValue
        case .onboarding:
            return rawValue
        }
    }

    var settingsSectionID: String? {
        switch self {
        case .settings:
            return "api"
        case .settingsOutput:
            return "outputOverview"
        case .agentChats, .onboarding:
            return nil
        }
    }
}

/// Fokus-Wunsch auf einen konkreten Agent-Chat (z. B. Klick auf eine
/// macOS-Notification). `requestID` macht wiederholte Wünsche auf dieselbe
/// Session unterscheidbar (Publisher-Dedup).
struct AgentSessionFocusRequest: Equatable {
    let requestID: UUID
    let sessionID: UUID
    /// Ziel-Fenster (bereits aufgelöst): Fenster mit offenem Tab, sonst Primär.
    let windowID: UUID
    let isPrimaryWindow: Bool
}

@MainActor
final class WindowRequestCenter: ObservableObject {
    static let shared = WindowRequestCenter()

    /// Distributed-Notification-Name: über `DistributedNotificationCenter`
    /// können wir einer bereits laufenden Instanz „mach Hauptfenster auf"
    /// mitteilen. Der Name ist historisch (`openSettings`); inhaltlich öffnen
    /// wir mittlerweile Agent-Chats. Wir behalten den String, damit ältere
    /// installierte Builds, die noch parallel laufen könnten, kompatibel
    /// bleiben.
    static let distributedNotificationName = Notification.Name("com.whisperm8.app.openSettings")
    static let localNotificationName = Notification.Name("WindowRequestCenter.request")

    @Published private(set) var latestRequest: WindowRequest?
    /// Letzter Session-Fokus-Wunsch (Notification-Klick). Der
    /// `WindowRequestHandler` öffnet/fokussiert daraufhin das Ziel-Fenster;
    /// Tab + Selektion sind zu diesem Zeitpunkt bereits im `AgentWindowStore`
    /// gesetzt (SSoT — die Views folgen von selbst).
    @Published private(set) var sessionFocusRequest: AgentSessionFocusRequest?

    /// Ob das Agent-Chats-Primärfenster angezeigt werden darf. In den Menüleisten-Profilen
    /// (`AppUsageProfile` ohne Agent Chats) wird der automatische Launch-Open unterdrückt;
    /// ein expliziter `.agentChats`-Request (Menüleiste, Onboarding-„Done", Profilwechsel)
    /// hebt das auf. Voll-Profil startet mit `true`.
    @Published var allowsAgentChatsPrimaryWindow: Bool = AppPreferences.shared.usageProfile.wantsAgentChats

    private var distributedObserver: NSObjectProtocol?

    private init() {
        distributedObserver = DistributedNotificationCenter.default().addObserver(
            forName: Self.distributedNotificationName,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                // Agent-Chats ist das neue Default-Hauptfenster; Settings wurde
                // beim Übergang zur Dock-App auf manuell zurückgestuft.
                Self.shared.request(.agentChats)
            }
        }
    }

    deinit {
        if let distributedObserver {
            DistributedNotificationCenter.default().removeObserver(distributedObserver)
        }
    }

    func request(_ request: WindowRequest) {
        // Ein expliziter Agent-Chats-Wunsch gibt das Primärfenster frei (auch in
        // Menüleisten-Profilen, z. B. via Menüleisten-Eintrag oder Profilwechsel).
        if request == .agentChats {
            allowsAgentChatsPrimaryWindow = true
        }
        latestRequest = request
        NotificationCenter.default.post(name: Self.localNotificationName, object: request.rawValue)
    }

    /// Bringt den Chat `sessionID` in den Vordergrund: Ziel ist das Fenster,
    /// das ihn bereits als Tab zeigt, sonst das Primärfenster (Tab wird dort
    /// geöffnet + selektiert). Einstieg für den Notification-Klick.
    func requestSessionFocus(sessionID: UUID) {
        let windowStore = AgentWindowStore.shared
        let targetWindowID = windowStore.windowID(containingTab: sessionID)
            ?? windowStore.primaryWindowID
        let isPrimary = targetWindowID == windowStore.primaryWindowID
        if isPrimary {
            allowsAgentChatsPrimaryWindow = true
        }
        // Tab + Selektion im SSoT setzen — idempotent, die Fenster folgen.
        windowStore.openTab(sessionID, in: targetWindowID, select: true)
        sessionFocusRequest = AgentSessionFocusRequest(
            requestID: UUID(),
            sessionID: sessionID,
            windowID: targetWindowID,
            isPrimaryWindow: isPrimary
        )
    }

    func resetForTesting() {
        latestRequest = nil
    }

    /// Triggert in einer bereits laufenden Instanz das Öffnen des
    /// Agent-Chats-Fensters. Wird beim Single-Instance-Check vom
    /// frisch gestarteten (zweiten) Process aufgerufen, bevor er sich selbst
    /// terminiert.
    static func notifyRunningInstanceToOpenAgentChats() {
        DistributedNotificationCenter.default().postNotificationName(
            distributedNotificationName,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }
}

struct WindowRequestHandler: View {
    @Environment(\.openWindow) private var openWindow
    @StateObject private var requestCenter = WindowRequestCenter.shared
    @State private var didRestoreAgentChatWindows = false

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                restoreAgentChatWindowsIfNeeded()
            }
            .onReceive(requestCenter.$latestRequest.compactMap { $0 }) { request in
                // Alle Ziele sind Single-`Window`-Scenes (inkl. Agent-Chats
                // Primaerfenster) → ohne value oeffnen/fokussieren.
                openWindow(id: request.targetWindowID)
                WindowActivationService.activateApp()
            }
            .onReceive(requestCenter.$sessionFocusRequest.compactMap { $0 }.removeDuplicates()) { request in
                // Notification-Klick: Ziel-Fenster öffnen bzw. fokussieren —
                // Tab/Selektion stehen bereits im AgentWindowStore.
                if request.isPrimaryWindow {
                    openWindow(id: WindowRequest.agentChats.targetWindowID)
                } else {
                    openWindow(id: WindowRequest.agentChatWindowGroupID, value: request.windowID)
                }
                WindowActivationService.activateApp()
            }
    }

    /// Stellt persistierte Sekundaerfenster (abgeloeste Tabs) beim Launch
    /// wieder her. Das Primaerfenster oeffnet SwiftUI als erste Scene selbst —
    /// hier werden NUR die Nicht-Primaerfenster der WindowGroup geoeffnet.
    private func restoreAgentChatWindowsIfNeeded() {
        guard !didRestoreAgentChatWindows else { return }
        didRestoreAgentChatWindows = true
        // In Menüleisten-Profilen (Dictation-only / Enrichment) werden keine
        // Agent-Chats-Fenster wiederhergestellt — genau wie das Primärfenster
        // unterdrückt wird. Erst ein expliziter Aufruf öffnet Agent Chats.
        guard AppPreferences.shared.usageProfile.wantsAgentChats else { return }
        // Sekundaerfenster live aus dem Store (Single Source of Truth) — das
        // Primaerfenster oeffnet SwiftUI als erste Scene selbst.
        for windowID in AgentWindowStore.shared.secondaryWindowIDs {
            openWindow(id: WindowRequest.agentChatWindowGroupID, value: windowID)
        }
    }
}

struct AppWindowRequestHost: View {
    var body: some View {
        WindowRequestHandler()
    }
}

enum WindowActivationService {
    static func activateApp() {
        NSApp.activate(ignoringOtherApps: true)
    }
}
