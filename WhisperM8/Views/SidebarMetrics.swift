import Foundation

/// Gemeinsame Einzugs-Grammatik der Agent-Chats-Sidebar — die EINE Quelle
/// für alle horizontalen Fluchtlinien von GEPINNT, WORKSPACES und CHATS.
///
/// Grundprinzip: Einzug entsteht IMMER über den Inhalts-Einzug innerhalb
/// der Row (`.padding(.leading, …)` am Inhalt), nie über äußeres Padding an
/// der ganzen Row — Hover-/Selektions-Hintergründe laufen dadurch in jeder
/// Ebene über die volle Sidebar-Breite. (Genau das war der Bug der
/// Workspace-Sektion: 10 pt Außen-Einzug ließen die Kind-Rows links aus
/// ihrem Gruppen-Header herausragen.)
///
/// Fluchtlinien (x ab Sidebar-Kante): Gruppen-Avatar/-Swatch bei
/// `rowOuterInset + groupHeaderContentInset + groupChevronWidth +
/// groupHeaderSpacing` = 37; Ebene-1-Icons bei `rowOuterInset +
/// level1ContentInset` = 36 (linksbündig darunter).
enum SidebarMetrics {
    /// Außenrand aller Rows und Gruppen-Header — die Hintergrund-Kante.
    static let rowOuterInset: CGFloat = 8
    /// Sektions-Label (GEPINNT / WORKSPACES / CHATS).
    static let sectionLabelInset: CGFloat = 14
    /// Gruppen-Header (Ebene 0): Inhalts-Einzug innerhalb des Hintergrunds.
    static let groupHeaderContentInset: CGFloat = 8
    /// Breite des Auf-/Zuklapp-Chevrons im Gruppen-Header.
    static let groupChevronWidth: CGFloat = 12
    /// Element-Abstand im Gruppen-Header (Chevron ↔ Avatar ↔ Titel).
    static let groupHeaderSpacing: CGFloat = 9
    /// Ebene 1: Chat-Row unter einem Gruppen-Header — Icon fluchtet mit dem
    /// Gruppen-Avatar/-Swatch.
    static let level1ContentInset: CGFloat = 28
    /// Ebene 2: Subagent-Kind-Row unter einer Chat-Row.
    static let level2ContentInset: CGFloat = 44
    /// „N fertig"-Fußzeile der Subagent-Ebene: bündig mit den Kind-Zeilen
    /// darüber (`rowOuterInset + level2ContentInset`).
    static let subagentFooterInset: CGFloat = 52
    /// Top-Level-Row ohne Gruppen-Header (GEPINNT).
    static let topLevelContentInset: CGFloat = 10
}
