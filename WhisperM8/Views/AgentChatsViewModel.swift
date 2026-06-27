import Foundation

/// Phase-3 (S7-A): testbare, View-unabhängige Geschäftslogik aus `AgentChatsView`.
/// Erste Gruppe = rein `AgentSessionStore`-mutierende Aktionen. Jede Methode gibt
/// bei Fehler die Meldung zurück (`nil` = Erfolg); die View setzt damit ihr
/// `errorMessage` — so bleibt die Fehleranzeige Single-Source in der View.
///
/// State-Ownership (Tabs/Selektion/Pins) liegt weiterhin im `AgentWindowStore`;
/// diese Gruppe fasst ihn bewusst nicht an. Spätere Gruppen können hier
/// zustandsbehaftete Logik (create/fork/delete) ergänzen.
@MainActor
final class AgentChatsViewModel {
    private let store: AgentSessionStore

    init(store: AgentSessionStore) {
        self.store = store
    }

    @discardableResult
    func renameSession(id: UUID, title: String) -> String? {
        result { try store.renameSession(id: id, title: title) }
    }

    @discardableResult
    func setSessionGroup(id: UUID, groupName: String?) -> String? {
        result { try store.setSessionGroup(id: id, groupName: groupName) }
    }

    @discardableResult
    func setSessionColor(id: UUID, color: String?) -> String? {
        result { try store.setSessionColor(id: id, color: color) }
    }

    @discardableResult
    func renameProject(id: UUID, name: String) -> String? {
        result { try store.renameProject(id: id, name: name) }
    }

    @discardableResult
    func setProjectColor(id: UUID, color: String) -> String? {
        result { try store.setProjectColor(id: id, color: color) }
    }

    /// Führt eine werfende Store-Mutation aus; gibt die Fehlermeldung zurück
    /// (`nil` = Erfolg).
    private func result(_ mutate: () throws -> Void) -> String? {
        do {
            try mutate()
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
