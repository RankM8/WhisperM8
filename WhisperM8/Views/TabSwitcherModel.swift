import AppKit
import Foundation
import Observation

/// Pure State-Machine des Ctrl+Tab-Switchers: hält die Tab-Reihenfolge und
/// das aktuell hervorgehobene Highlight während eines Durchlaufs (Control
/// gehalten). Ephemer — lebt im `TabSwitcherRunState` der `AgentChatsView`
/// und wird nie persistiert. Window-frei → unit-testbar.
///
/// Die Reihenfolge wird bei jedem Schritt frisch hereingereicht (der Umfang
/// aus `TabSwitcherScope` kann sich extern ändern, z. B. durch Archivierung
/// oder Workspace-Prune) — verschwindet der hervorgehobene Tab, fällt das
/// Highlight über `adjacentTabID` auf den ersten Tab zurück statt zu hängen.
struct TabSwitcherModel: Equatable {
    private(set) var highlightedID: UUID?

    /// Aktivierung: braucht ≥ 2 Tabs (mit einem Tab gibt es nichts
    /// umzuschalten). Das Highlight startet beim aktuellen Tab und macht
    /// sofort einen Schritt in `direction` — so wirkt der schnelle „Tap"
    /// (Ctrl+Tab drücken, sofort loslassen) als direkter Nachbar-Wechsel.
    static func begin(order: [UUID], current: UUID?, direction: Int) -> TabSwitcherModel? {
        guard order.count >= 2 else { return nil }
        var model = TabSwitcherModel(highlightedID: current ?? order.first)
        model.advance(direction, order: order)
        return model
    }

    /// Ein Schritt weiter/zurück mit Wrap-around (gleiche Mathematik wie
    /// ⌘⌥←/→, siehe `adjacentTabID`).
    mutating func advance(_ direction: Int, order: [UUID]) {
        highlightedID = adjacentTabID(in: order, current: highlightedID, direction: direction)
    }

    /// Springt direkt auf ein Ziel (Pfeiltasten im Grid: geometrisch über
    /// `GridFocusNavigator` statt linear). Nur Ziele im Umfang — sonst bleibt
    /// das Highlight, wo es ist.
    mutating func highlight(_ id: UUID, order: [UUID]) {
        guard order.contains(id) else { return }
        highlightedID = id
    }

    /// Commit-Ziel beim Loslassen von Control — `nil`, wenn der hervorgehobene
    /// Tab inzwischen nicht mehr existiert (dann bleibt die Selektion, wie
    /// sie ist, statt auf einen willkürlichen Tab zu springen).
    func commitTarget(order: [UUID]) -> UUID? {
        guard let highlightedID, order.contains(highlightedID) else { return nil }
        return highlightedID
    }
}

/// Beobachtungswert des laufenden Ctrl+Tab-Durchlaufs für Mini-Map (B) und
/// Projekt-Liste (C) — Gegenstück zum `TabSwitcherGridMarkingState` (A).
///
/// Warum kein `@State var tabSwitcher` mehr in der AgentChatsView: Ihr Body
/// las ihn (`if tabSwitcher != nil`, `.animation(value:)`, Overlay-Argumente)
/// — jeder Ctrl+Tab-Schritt wertete so den GANZEN Body samt Sidebar
/// (nicht-lazy `VStack`, teuer bei Scope „Alle") neu aus. Jetzt liest der
/// Body nur `isActive`, das sich nur beim Öffnen/Schließen ändert;
/// `highlightedID`, `sessions` und `miniMapWorkspace` liest ausschließlich
/// der kleine `TabSwitcherOverlayHost`.
///
/// Die Durchlauf-Maschine selbst (`model`) ist `@ObservationIgnored`: Die
/// Event-Handler lesen sie ständig, keine View hängt an ihr. Jeder Write
/// spiegelt diff-gated in die beobachteten Werte — `@Observable` meldet sonst
/// auch gleiche Werte als Änderung.
@MainActor
@Observable
final class TabSwitcherRunState {
    /// Pure Durchlauf-Maschine (nil = inaktiv). Nur im Event-Pfad lesen.
    @ObservationIgnored var model: TabSwitcherModel? {
        didSet { syncFromModel() }
    }
    /// Zuletzt gesehener Modifier-Zustand (keyDown/flagsChanged im
    /// Durchlauf) — Grundlage für `TabSwitcherShortcut.flagsChangeAction`.
    /// Nur Event-Pfad, nie beobachtet.
    @ObservationIgnored var lastModifiers: NSEvent.ModifierFlags = []

    /// Einziger Wert, den der AgentChatsView-Body liest.
    private(set) var isActive = false
    private(set) var highlightedID: UUID?
    /// Ziel-Sessions in Umfangs-Reihenfolge — Snapshot aus dem
    /// Key-Event-Pfad (`refreshTabSwitcherScope`).
    private(set) var sessions: [AgentChatSession] = []
    /// Situation B: Workspace für die Mini-Map, sonst `nil`.
    private(set) var miniMapWorkspace: AgentGridWorkspace?

    func setSessions(_ newValue: [AgentChatSession]) {
        if sessions != newValue { sessions = newValue }
    }

    func setMiniMapWorkspace(_ newValue: AgentGridWorkspace?) {
        if miniMapWorkspace != newValue { miniMapWorkspace = newValue }
    }

    private func syncFromModel() {
        let active = model != nil
        if isActive != active { isActive = active }
        let highlighted = model?.highlightedID
        if highlightedID != highlighted { highlightedID = highlighted }
    }
}

/// Berechnete Maße der Projekt-Liste (Situation C).
struct TabSwitcherListMetrics: Equatable {
    var rows: Int
    /// Zeilen, die ohne Scrollen ins Overlay passen.
    var visibleRows: Int
    var width: CGFloat
    var height: CGFloat

    var needsScroll: Bool { rows > visibleRows }
}

/// Pure Layout-Mathematik der Projekt-Liste (Situation C, Plan
/// `docs/plans/tab-switcher-workspace.md`): eine Spalte Kacheln in voller
/// Listenbreite, je ~56 pt hoch. Erst wenn die Zeilen den verfügbaren Platz
/// sprengen, scrollt die Liste (`needsScroll`). Window-frei → unit-testbar.
enum TabSwitcherListLayout {
    static let rowHeight: CGFloat = 56
    static let spacing: CGFloat = 6
    /// Listenbreite: so breit wie lesbar, aber kein Zeilenband über den
    /// ganzen Bildschirm.
    static let minWidth: CGFloat = 320
    static let maxWidth: CGFloat = 560
    /// Chrome um die Liste: Overlay-Padding + Karten-Padding + Footer-Zeile.
    /// Wird vom verfügbaren Platz abgezogen, bevor Breite/Zeilen berechnet
    /// werden.
    static let horizontalChrome: CGFloat = 96
    static let verticalChrome: CGFloat = 132

    static func metrics(count: Int, availableSize: CGSize) -> TabSwitcherListMetrics {
        guard count > 0 else {
            return TabSwitcherListMetrics(rows: 0, visibleRows: 0, width: 0, height: 0)
        }
        let availableWidth = max(0, availableSize.width - horizontalChrome)
        let width = min(maxWidth, max(minWidth, availableWidth))

        let availableHeight = max(0, availableSize.height - verticalChrome)
        let fittingRows = Int((availableHeight + spacing) / (rowHeight + spacing))
        let visibleRows = max(1, min(count, fittingRows))

        return TabSwitcherListMetrics(
            rows: count,
            visibleRows: visibleRows,
            width: width,
            height: CGFloat(visibleRows) * rowHeight + CGFloat(visibleRows - 1) * spacing
        )
    }
}

/// Bedien-Hinweise der Switcher-Fußzeilen — an einer Stelle, damit Liste und
/// Mini-Map gleich formuliert bleiben. Situation A (Grid-Markierung) hat kein
/// Overlay und damit keine Fußzeile.
enum TabSwitcherHint {
    /// Situation C: ↑/↓ (und ←/→) = ein Schritt in der Liste.
    static let list = "⌃Tab weiter · ⇧ zurück · ↑↓ wählen · Esc"
    /// Situation B: Pfeile springen räumlich wie ⌃⌘-Pfeile im Grid.
    static let miniMap = "⌃Tab weiter · ⇧ zurück · Pfeile räumlich · Esc"
}
