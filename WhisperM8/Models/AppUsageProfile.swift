import AppKit

/// Nutzungsprofil der App — im Onboarding gewählt, in den Settings umstellbar.
/// Steuert zwei Achsen: (a) ob Codex-Enrichment (alle Modi außer Raw) verfügbar ist und
/// (b) ob Agent Chats aktiv ist (Dock-App vs. reine Menüleisten-Utility).
///
/// Default (auch für Bestandsnutzer ohne gesetztes Profil) ist `.full` — exakt das heutige
/// Verhalten, damit ein Update niemanden überrascht.
enum AppUsageProfile: String, CaseIterable, Codable {
    /// Nur Raw-Diktat. Kein Codex, keine Agent Chats → reine Menüleisten-Utility.
    case dictationRaw
    /// Diktat + Codex-Enrichment (Modi), aber keine Agent Chats → Menüleisten-Utility.
    case dictationEnrichment
    /// Vollausbau: Dock-App mit Agent Chats + Codex-Enrichment (heutiges Verhalten).
    case full

    /// Empfohlenes Default-Profil. Bewusst `.full`, damit Bestandsnutzer unverändert bleiben.
    static let defaultProfile: AppUsageProfile = .full

    /// Codex-Enrichment (Post-Processing-Modi außer Raw) erlaubt.
    var wantsCodexEnrichment: Bool {
        switch self {
        case .dictationRaw: return false
        case .dictationEnrichment, .full: return true
        }
    }

    /// Agent Chats aktiv (Dock-App, Primärfenster öffnet bei Launch/Reopen).
    var wantsAgentChats: Bool {
        self == .full
    }

    /// Aktivierungs-Policy: Voll-Profil = reguläre Dock-App, sonst reine Menüleisten-App
    /// (kein Dock-Icon, kein Cmd-Tab). Wird zur Laufzeit via `NSApp.setActivationPolicy`
    /// angewandt.
    var activationPolicy: NSApplication.ActivationPolicy {
        wantsAgentChats ? .regular : .accessory
    }

    /// Kurzer, nutzersichtbarer Titel (englische UI).
    var displayName: String {
        switch self {
        case .dictationRaw: return "Dictation only"
        case .dictationEnrichment: return "Dictation + AI enrichment"
        case .full: return "Full (with Agent Chats)"
        }
    }

    /// Kurze Erklärung für Onboarding-/Settings-Auswahl.
    var summary: String {
        switch self {
        case .dictationRaw:
            return "Just transcription. Lives in the menu bar. No Codex, no Agent Chats — the only setup is a Groq or OpenAI key."
        case .dictationEnrichment:
            return "Transcription plus AI rewrite modes (Clean, Email, Slack …) via Codex. Menu-bar app; connect Codex when you want the extra modes."
        case .full:
            return "Everything: dictation, AI enrichment, and the Agent Chats hub for Claude Code / Codex. Runs as a regular Dock app."
        }
    }
}
