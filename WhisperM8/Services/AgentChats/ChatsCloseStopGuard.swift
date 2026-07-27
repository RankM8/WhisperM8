import Foundation

/// Schutz arbeitender Agenten für `close --stop`.
///
/// Bewusst pur (kein App-State, kein MainActor) — die Entscheidung „darf hier
/// ein laufender Turn abgebrochen werden?" ist die sicherheitsrelevante Stelle
/// des Befehls und muss ohne laufende App testbar sein.
///
/// Semantik: **alles-oder-nichts**. Arbeitet auch nur EIN Ziel des Batches,
/// wird der gesamte Request abgelehnt — sonst entstünde ein Teilzustand, in
/// dem die Hälfte der Tabs schon zu ist und der Aufrufer nachbessern muss.
enum ChatsCloseStopGuard {
    /// - Parameter force: hebt den Schutz auf (explizite Nutzerentscheidung).
    /// - Parameter isWorking: Runtime-Status des Ziels ist `.working`.
    /// - Parameter label: Anzeigename `projekt/titel` für die Fehlermeldung.
    /// - Returns: Namen der blockierenden Ziele. Leer = Stop ist erlaubt.
    static func blockingTargets(
        targetIDs: [UUID],
        force: Bool,
        isWorking: (UUID) -> Bool,
        label: (UUID) -> String?
    ) -> [String] {
        guard !force else { return [] }
        return targetIDs
            .filter(isWorking)
            .map { label($0) ?? $0.uuidString }
    }

    /// Einheitliche Konflikt-Meldung. Nennt die Ziele beim Namen und die drei
    /// Auswege — eine reine „Konflikt"-Meldung ließe den Aufrufer raten.
    static func conflictMessage(blocking: [String]) -> String {
        "Arbeitet gerade: \(blocking.joined(separator: ", ")) — kein Tab wurde geschlossen. "
            + "Warte das Turn-Ende ab, nutze `interrupt` oder erzwinge es mit --stop --force."
    }
}
