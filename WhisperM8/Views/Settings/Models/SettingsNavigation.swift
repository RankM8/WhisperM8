import Foundation

/// Launch-Klasse einer Einstellungsseite (Launch-Definition: Kern / Erweitert / Labs).
/// Die Reihenfolge der Fälle ist die Reihenfolge in der Seitenleiste.
enum SettingsLaunchClass: Int, Comparable {
    /// Gehört zum normalen Setup und steht zuerst.
    case core
    /// Sichtbar, aber ausdrücklich abgesetzt (Mehrere Konten, Hooks).
    case advanced
    /// Experimentell oder auf inoffiziellem Upstream — bewusst hinter „Labs“.
    case labs

    static func < (lhs: SettingsLaunchClass, rhs: SettingsLaunchClass) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct SettingsPageGroup: Identifiable, Equatable {
    /// Englischer Schlüssel (der Katalog liefert die Übersetzung).
    let title: String
    let launchClass: SettingsLaunchClass
    let pages: [SettingsPage]

    var id: String { title }
}

/// Reine Struktur der Seitenleiste (LR-ONB-012). Kein UI, damit Reihenfolge und
/// Profil-Filter testbar bleiben.
enum SettingsNavigation {
    /// Seiten, die nur mit Agent Chats / Claude Code zu tun haben. Im reinen
    /// Diktat-Profil stehen sie nicht in der Hauptliste — erreichbar bleiben sie
    /// über „Show Agent Chats settings“ und über Deep-Links.
    static let agentPages: [SettingsPage] = [
        .agentChats, .cli, .claudeAccounts, .claudeHooks, .gptBackend, .jarvis
    ]

    static func launchClass(of page: SettingsPage) -> SettingsLaunchClass {
        switch page {
        case .recording, .transcription, .aiOutput, .context, .output,
             .agentChats, .cli, .general, .permissions, .about:
            return .core
        case .claudeAccounts, .claudeHooks:
            return .advanced
        case .gptBackend, .voiceGate, .jarvis:
            return .labs
        }
    }

    /// Muss die Liste aufgeklappt sein, damit `page` in der Seitenleiste auftaucht?
    static func requiresReveal(_ page: SettingsPage, profile: AppUsageProfile) -> Bool {
        !profile.wantsAgentChats && agentPages.contains(page)
    }

    static func pageGroups(for profile: AppUsageProfile, revealAgentPages: Bool) -> [SettingsPageGroup] {
        let showAgentPages = profile.wantsAgentChats || revealAgentPages
        func visible(_ pages: [SettingsPage]) -> [SettingsPage] {
            pages.filter { showAgentPages || !agentPages.contains($0) }
        }

        let groups = [
            SettingsPageGroup(
                title: "Dictation", launchClass: .core,
                pages: [.recording, .transcription, .aiOutput, .context, .output]
            ),
            SettingsPageGroup(title: "Agent Chats", launchClass: .core, pages: visible([.agentChats, .cli])),
            SettingsPageGroup(title: "App", launchClass: .core, pages: [.general, .permissions, .about]),
            SettingsPageGroup(
                title: "Advanced", launchClass: .advanced,
                pages: visible([.claudeAccounts, .claudeHooks])
            ),
            SettingsPageGroup(
                title: "Labs", launchClass: .labs,
                pages: visible([.gptBackend]) + [.voiceGate] + visible([.jarvis])
            )
        ]
        return groups.filter { !$0.pages.isEmpty }
    }
}
