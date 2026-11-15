import Foundation

/// Faltzeile „N gestoppt“ der Seitenleiste je Projekt (WM8-80). Gespeichert
/// im UI-Zustand, damit sie Scope-Wechsel und Neustart übersteht und
/// Controller wie Tastatur mit demselben sichtbaren Stand rechnen.
extension AgentWindowStore {
    /// `true`/`false` = von Hand geöffnet/geschlossen, `nil` = Vorgabe.
    var stoppedFoldOverrides: [UUID: Bool] {
        var result: [UUID: Bool] = [:]
        for id in state.openedStoppedFoldProjectIDs { result[id] = true }
        for id in state.closedStoppedFoldProjectIDs { result[id] = false }
        return result
    }

    func setStoppedFold(open: Bool, for projectID: UUID) {
        mutate { state in
            state.openedStoppedFoldProjectIDs.removeAll { $0 == projectID }
            state.closedStoppedFoldProjectIDs.removeAll { $0 == projectID }
            if open {
                state.openedStoppedFoldProjectIDs.append(projectID)
            } else {
                state.closedStoppedFoldProjectIDs.append(projectID)
            }
        }
    }
}
