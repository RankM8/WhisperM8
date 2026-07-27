import Foundation

// MARK: - Sichtbarkeits-Darstellung für Workspaces

/// Pure Formulierungslogik für den Sichtbarkeitszustand eines Grid-Workspace.
///
/// Der Wortlaut ist hier die eigentliche Arbeit, nicht das Format: Der Store
/// kennt nur LOGISCHE Sichtbarkeit (welches Fenster hält den Workspace, zeigt
/// es gerade das Grid). Er weiß NICHT, ob dieses Fenster auf dem Bildschirm
/// steht — ein geschlossenes Primärfenster bleibt im Zustand erhalten, und
/// minimiert, verdeckt oder auf einem anderen Space ist gar nicht abbildbar.
///
/// Deshalb sagt die Ausgabe „im Grid angeordnet", niemals „du siehst".
enum ChatsWorkspaceViewSupport {
    /// Kurzsuffix für die Textzeile von `workspace list`.
    /// Leer, wenn der Workspace keinem Fenster zugeordnet ist.
    static func suffix(for workspace: ChatsControlJSON) -> String {
        let slots = workspace["slots"]?.arrayValue ?? []
        let capacity = workspace["capacity"]?.intValue ?? slots.count
        let occupied = slots.filter { $0["sessionID"]?.stringValue != nil }.count
        let notRendered = slots.filter {
            $0["sessionID"]?.stringValue != nil && $0["rendered"]?.boolValue == false
        }.count

        guard workspace["hostWindowID"]?.stringValue != nil else {
            return occupied > 0 ? "  (\(occupied)/\(capacity) belegt · keinem Fenster zugeordnet)" : ""
        }
        let visible = workspace["gridVisible"]?.boolValue == true
        var parts = ["\(occupied)/\(capacity) belegt"]
        // „Grid angeordnet" statt „sichtbar": Der Store belegt nur, dass das
        // Fenster das Grid zeigt — nicht, dass es vor Augen steht.
        parts.append(visible ? "Grid angeordnet" : "Einzelansicht")
        if notRendered > 0 {
            parts.append("\(notRendered) Slot(s) in anderem Fenster")
        }
        return "  (" + parts.joined(separator: " · ") + ")"
    }

    /// Einzeiler für `window list`. Leer, wenn kein Workspace zugeordnet ist.
    static func windowSuffix(for window: ChatsControlJSON) -> String {
        guard let name = window["activeWorkspaceName"]?.stringValue, !name.isEmpty else { return "" }
        let showsGrid = window["showsGrid"]?.boolValue == true
        return showsGrid ? "  · Grid „\(name)\"" : "  · Einzelansicht (aus „\(name)\")"
    }
}
