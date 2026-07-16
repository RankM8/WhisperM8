import Foundation

/// Wo ein Session-Kontextmenü angezeigt wird. Steuert über
/// `SessionMenuPolicy.plan(for:traits:)`, welche Sektionen sichtbar sind —
/// damit alle Menü-Quellen (Tab-Leiste, Einzelansicht, Sidebar, Workspace,
/// Grid) dieselbe Struktur zeigen statt acht driftender Kopien.
/// Ziel-Matrix + Produktentscheidungen: docs/plans/kontextmenu-vereinheitlichung.md.
enum SessionMenuContext: CaseIterable {
    /// Rechtsklick auf einen Tab der oberen Tab-Leiste.
    case tab
    /// „…"-Menü im Header der Einzelansicht (Entscheidung: strikt singulär).
    case headerMenu
    /// Gepinnte, flache oder projektgruppierte Sidebar-Zeile.
    case sidebarRow
    /// Chat-Zeile innerhalb einer Workspace-Gruppe in der Sidebar.
    case workspaceRow
    /// Pane-Header im sichtbaren Grid.
    case gridPane
    /// Eingerückte Subagent-Kind-Zeile (Entscheidung: reduziert —
    /// Umbenennen + Job-Stop + Archivieren).
    case subagentChild
}

/// Session-Eigenschaften, die die Menü-Sichtbarkeit beeinflussen — pur und
/// ohne Store-/SwiftUI-Abhängigkeit, damit die Policy unit-testbar bleibt.
/// Live-Ableitung: `AgentChatsView.sessionMenuTraits(for:)`.
struct SessionMenuTraits: Equatable {
    /// Session ist gerade als Tab geöffnet — steuert „Tab schließen" und
    /// „In neues Fenster" außerhalb der Tab-/Header-Kontexte.
    var isTabOpen = false
    /// `claude --bg`-Session → Background-Lifecycle-Sektion.
    var isBackgroundChat = false
    /// Start/Resume/Restart verfügbar (Subagent-Jobs erst nach Übernahme).
    var supportsRuntime = true
    /// Laufender Codex-Subagent-Job mit Supervisor-PID → „Job stoppen".
    var canStopSubagentJob = false
}

/// Sichtbare Sektionen/Einträge eines Session-Kontextmenüs. Die
/// Property-Reihenfolge entspricht der Anzeige-Reihenfolge. Umbenennen und
/// Archivieren erscheinen in JEDEM Kontext und haben deshalb kein Flag.
struct SessionMenuPlan: Equatable {
    /// „Tab schließen" (Kontext-Kopf).
    var showsCloseTab: Bool
    /// „Aus Workspace „X" entfernen" als erster Eintrag (Workspace-Zeile,
    /// Grid-Pane — die Call-Site liefert die Workspace-Entity mit).
    var showsWorkspaceRemovalHead: Bool
    /// „Maximieren" (nur Grid-Pane).
    var showsMaximize: Bool
    /// „Titel automatisch generieren".
    var showsAutoTitle: Bool
    /// Start/Resume/Restart.
    var showsRuntime: Bool
    /// „Job stoppen" für laufende Subagent-Kinder.
    var showsSubagentStop: Bool
    /// Forken + Zu Account verschieben.
    var showsManagement: Bool
    /// Fenster-/Workspace-Sektion insgesamt.
    var showsWindowWorkspace: Bool
    /// „In neues Fenster verschieben" (braucht einen offenen Tab).
    var showsWindowMove: Bool
    /// Entfernen-Einträge im Workspace-Mitgliedschaftsmenü (aus, wenn der
    /// Kontext-Kopf das Entfernen für die eigene Gruppe schon zeigt).
    var includesMembershipRemoval: Bool
    /// Anpinnen/Loslösen + Tab-Farbe.
    var showsAppearance: Bool
    /// Background-Lifecycle (Logs/Stoppen/Respawn/Vom Supervisor entfernen).
    var showsBackground: Bool
    /// Bulk-Labels/-Wirkung („N …") erlaubt. `.headerMenu` ist per
    /// Entscheidung strikt singulär; Grid-Panes und Subagent-Kinder sind
    /// nie Teil der Mehrfachauswahl.
    var allowsBulk: Bool
}

enum SessionMenuPolicy {
    static func plan(for context: SessionMenuContext, traits: SessionMenuTraits) -> SessionMenuPlan {
        switch context {
        case .tab:
            return SessionMenuPlan(
                showsCloseTab: true,
                showsWorkspaceRemovalHead: false,
                showsMaximize: false,
                showsAutoTitle: true,
                showsRuntime: traits.supportsRuntime,
                showsSubagentStop: false,
                showsManagement: true,
                showsWindowWorkspace: true,
                showsWindowMove: true,
                includesMembershipRemoval: true,
                showsAppearance: true,
                showsBackground: traits.isBackgroundChat,
                allowsBulk: true
            )
        case .headerMenu:
            return SessionMenuPlan(
                showsCloseTab: true,
                showsWorkspaceRemovalHead: false,
                showsMaximize: false,
                showsAutoTitle: true,
                showsRuntime: traits.supportsRuntime,
                showsSubagentStop: false,
                showsManagement: true,
                showsWindowWorkspace: true,
                showsWindowMove: true,
                includesMembershipRemoval: true,
                showsAppearance: true,
                showsBackground: traits.isBackgroundChat,
                allowsBulk: false
            )
        case .sidebarRow:
            return SessionMenuPlan(
                showsCloseTab: traits.isTabOpen,
                showsWorkspaceRemovalHead: false,
                showsMaximize: false,
                showsAutoTitle: true,
                showsRuntime: traits.supportsRuntime,
                showsSubagentStop: false,
                showsManagement: true,
                showsWindowWorkspace: true,
                showsWindowMove: traits.isTabOpen,
                includesMembershipRemoval: true,
                showsAppearance: true,
                showsBackground: traits.isBackgroundChat,
                allowsBulk: true
            )
        case .workspaceRow:
            return SessionMenuPlan(
                showsCloseTab: traits.isTabOpen,
                showsWorkspaceRemovalHead: true,
                showsMaximize: false,
                showsAutoTitle: true,
                showsRuntime: traits.supportsRuntime,
                showsSubagentStop: false,
                showsManagement: true,
                showsWindowWorkspace: true,
                showsWindowMove: traits.isTabOpen,
                includesMembershipRemoval: false,
                showsAppearance: true,
                showsBackground: traits.isBackgroundChat,
                allowsBulk: true
            )
        case .gridPane:
            // Bewusst KEIN „Tab schließen" an der Pane (⊖ leert nur den
            // Slot; Tabs schließt die Tab-Leiste) — vgl. Kommentar am
            // Pane-Header-Minus-Button.
            return SessionMenuPlan(
                showsCloseTab: false,
                showsWorkspaceRemovalHead: true,
                showsMaximize: true,
                showsAutoTitle: true,
                showsRuntime: traits.supportsRuntime,
                showsSubagentStop: false,
                showsManagement: true,
                showsWindowWorkspace: true,
                showsWindowMove: traits.isTabOpen,
                includesMembershipRemoval: false,
                showsAppearance: true,
                showsBackground: traits.isBackgroundChat,
                allowsBulk: false
            )
        case .subagentChild:
            return SessionMenuPlan(
                showsCloseTab: false,
                showsWorkspaceRemovalHead: false,
                showsMaximize: false,
                showsAutoTitle: false,
                showsRuntime: false,
                showsSubagentStop: traits.canStopSubagentJob,
                showsManagement: false,
                showsWindowWorkspace: false,
                showsWindowMove: false,
                includesMembershipRemoval: false,
                showsAppearance: false,
                showsBackground: traits.isBackgroundChat,
                allowsBulk: false
            )
        }
    }
}
