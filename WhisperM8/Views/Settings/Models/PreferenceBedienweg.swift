import Foundation

/// Welche `PreferenceKeys` bewusst KEINEN eigenen Schalter in den Einstellungen haben
/// (DoD „Kein `defaults write` als Bedienweg“, Launch-Readiness W6).
///
/// Regel: Jeder als Bedienung gedachte Schalter hat einen UI-Weg. Der Guard-Test
/// `PreferenceBedienwegGuardTests` prüft das gegen `AppPreferences`; alles, was hier
/// steht, ist eine begründete Ausnahme. Neue Schalter ohne UI-Weg fallen im Test auf —
/// entweder die UI ergänzen oder hier mit Begründung eintragen.
enum PreferenceBedienweg {
    struct Entry {
        let key: String
        let reason: String
    }

    /// Weitere Dateien (außer `Views/Settings/**` und `SettingsView`), die als
    /// Bedienfläche zählen, weil sie einen Schalter selbst anbieten.
    static let additionalSurfaces: [String] = [
        "WhisperM8/Views/OnboardingView.swift",
        "WhisperM8/Views/MenuBarView.swift",
        "WhisperM8/Views/SidebarAlertLevelButton.swift",
        "WhisperM8/Views/VoiceGateMenuSection.swift",
    ]

    /// Notbremsen: schalten ein fertiges, standardmäßig aktives Verhalten ab, falls es
    /// in der Praxis Probleme macht. Bewusst nicht in der Oberfläche — ein Nutzer soll
    /// sie nicht aus Versehen kippen, der Support nennt den `defaults write`-Befehl.
    static let killSwitches: [Entry] = [
        Entry(key: "agentEventDrivenWatchEnabled", reason: "Notbremse: zurück zum reinen 1,5-s-Polling des Transcript-Watchers."),
        Entry(key: "chatsPromptGuardEnabled", reason: "Notbremse: nimmt den Send-Guard (UserPromptSubmit-Hook) aus neuen Claude-Sessions."),
        Entry(key: "claudeRegistryStatusEnabled", reason: "Notbremse: Claude-Status wieder aus Hooks und Transcript statt aus Claudes Registry."),
        Entry(key: "claudeSharedMemoryEnabled", reason: "Notbremse: jedes Claude-Profil nutzt wieder sein eigenes Auto-Memory."),
        Entry(key: "accountSwitchAfterTurnEnabled", reason: "Notbremse: Kontowechsel überspringt laufende Chats wieder, statt nach dem Turn zu wechseln."),
        Entry(key: "accountBulkMoveEnabled", reason: "Notbremse: blendet den Mehrfach-Kontowechsel aus; der Einzel-Umzug bleibt."),
        Entry(key: "chatsNewProfileDefaultEnabled", reason: "Notbremse: neue Chats starten wieder im Haupt-Account statt im aktiven Profil."),
        Entry(key: "gptRouterAuthEnabled", reason: "Sicherheits-Notbremse: schaltet das lokale Router-Token des GPT-Backends ab."),
        Entry(key: "subagentJobRetentionEnabled", reason: "Notbremse: Subagent-Job-Spiegel werden nicht mehr nach der Frist aufgeräumt."),
        Entry(key: "subagentJobRetentionDays", reason: "Feinwert zur Notbremse der Subagent-Job-Aufbewahrung (Standard sieben Tage)."),
        Entry(key: "agentCrashRecoveryEnabled", reason: "Notbremse: keine automatische Wiederaufnahme der Chats nach einem Absturz."),
        Entry(key: "agentSidebarDragEnabled", reason: "Notbremse: schaltet Drag und Drop in der Sidebar ab, falls der Scroll-Hänger zurückkehrt."),
        Entry(key: "gptAccountProfilesEnabled", reason: "Notbremse: ein Proxy, ein Konto — ignoriert die GPT-Konto-Profile."),
        Entry(key: "chatGPTTranscriptionEnabled", reason: "Notbremse: blendet den Anbieter ChatGPT-Abo aus allen Pickern aus (gespeicherter Wert bleibt)."),
        Entry(key: "claudePluginEnabled", reason: "Notbremse: kein Claude-Code-Plugin, Skills wieder lose in ~/.claude/skills (die Seite CLI & Skills zeigt den Modus nur an)."),
        Entry(key: "agentStatusSoftPulseEnabled", reason: "Notbremse: schaltet den sanften Status-Puls ab (Render-Last)."),
    ]

    /// Zustand, den die App selbst führt (Migrations-Merker, Fensterposition, zuletzt
    /// Gewähltes) — kein Schalter, den ein Nutzer bedient.
    static let internalState: [Entry] = [
        Entry(key: "didMigrateLanguageDefault", reason: "Migrations-Merker, einmalig gesetzt."),
        Entry(key: "didMigrateMaxScreenshotsPerRecordingTo20", reason: "Migrations-Merker, einmalig gesetzt."),
        Entry(key: "claudeSharedMemoryMigrationDone", reason: "Einmal-Merker der Memory-Zusammenführung."),
        Entry(key: "claudePluginSkillMigrationDone", reason: "Einmal-Merker der Skill-Migration ins Plugin."),
        Entry(key: "subagentJobRetentionInitialPurgeDone", reason: "Einmal-Merker der Alt-Last-Bereinigung."),
        Entry(key: "tabCloseRunningNoticeShown", reason: "Merker, dass der Hinweis beim Schließen laufender Tabs gezeigt wurde."),
        Entry(key: "overlayPositionX", reason: "Letzte Position des Aufnahme-Overlays, wird durch Ziehen gesetzt."),
        Entry(key: "overlayPositionY", reason: "Letzte Position des Aufnahme-Overlays, wird durch Ziehen gesetzt."),
        Entry(key: "lastSelectedOutputModeID", reason: "Zuletzt gewählter Modus; die Auswahl selbst läuft über Overlay und Menü."),
        Entry(key: "claudeGPTRouterPort", reason: "Interner Port des Mix-Routers, abgeleitet vom Backend-Port; kein Nutzerwert."),
        Entry(key: "claudeGPTBackendDefaultModel", reason: "Veraltet: das Modell bestimmt Claude Code per /model, nicht die App."),
        Entry(key: "summaryStartupReconciliationEnabled", reason: "Auto-Zusammenfassungen beim Start; Default aus, die Karte erzeugt sie beim Anzeigen."),
    ]

    /// Der UI-Weg existiert, läuft aber über einen Manager oder eine Ansicht außerhalb der
    /// geprüften Dateien.
    static let indirectUI: [Entry] = [
        Entry(key: "selectedAudioDeviceUID", reason: "Mikrofon-Auswahl auf der Seite Recording und im Menüleisten-Menü über AudioDeviceManager."),
        Entry(key: "appearanceOverride", reason: "Theme-Auswahl auf der Seite General über ThemeManager."),
        Entry(key: "agentTabGroupingEnabled", reason: "Wird im Tab-Menü der Agent-Chats-Ansicht umgeschaltet."),
    ]

    /// Mess- und Entwicklerwerkzeuge: für Untersuchungen und A/B-Vergleiche, kein Bedienweg.
    static let measurementTools: [Entry] = [
        Entry(key: "agentStatusPulseEnabled", reason: "A/B-Schalter für die alte Dauerbewegung der Status-Punkte, nur für Lastmessungen."),
        Entry(key: "debugControlEnabled", reason: "Aktiviert den Debug-Control-Socket für Entwickler und QA (`whisperm8 debug`)."),
    ]
}
