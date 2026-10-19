import Foundation

/// Welches Projekt „Neuer Chat“ trifft, wenn keins ausdrücklich gewählt ist.
///
/// Nur manuell hinzugefügte Projekte kommen als Rückfall in Frage (LR-AU-004):
/// Der Indexer importiert Projekte aus `~/.claude/projects` (z. B. `$HOME`
/// oder ein altes Repo). Die Sidebar zeigt die nicht — mit `projects.first`
/// startete „Neuer Chat“ trotzdem in einem unsichtbaren, zufälligen Ordner,
/// während dort „Noch keine Projekte“ stand. Eine ausdrückliche Auswahl
/// (z. B. über einen Chat unter „Alle“) bleibt gültig.
enum AgentProjectSelectionResolver {
    static func project(selectedID: UUID?, in projects: [AgentProject]) -> AgentProject? {
        if let selectedID, let selected = projects.first(where: { $0.id == selectedID }) {
            return selected
        }
        return fallbackProject(in: projects)
    }

    static func fallbackProject(in projects: [AgentProject]) -> AgentProject? {
        AgentSessionStore.sortedProjects(projects.filter(\.isManuallyAdded)).first
    }

    /// Anfangs aufgeklappte Projekte: die ersten drei sichtbaren.
    static func initiallyExpandedIDs(in projects: [AgentProject]) -> Set<UUID> {
        Set(AgentSessionStore.sortedProjects(projects.filter(\.isManuallyAdded)).prefix(3).map(\.id))
    }
}
