import Foundation

/// Was die Abfragen dieses Prozesses bei Linear gekostet haben und was vom
/// Budget übrig ist. Linear zählt je Key und Stunde Anfragen und
/// „Complexity“-Punkte und nennt beides in den Kopfzeilen jeder Antwort.
///
/// Derselbe Key trägt die Ansicht in der App und jeden `tickets`-Befehl aller
/// Chats: Ist das Budget weg, steht beides. Deshalb wird hier mitgezählt und
/// geloggt (`linear_cost`), und `tickets doctor` nennt die Zahlen.
struct LinearCost: Equatable {
    /// Anfragen und Punkte dieses Prozesses, seit er läuft.
    var requests = 0
    var complexity = 0
    /// Punkte der letzten Anfrage.
    var lastComplexity: Int?
    /// Stand des Budgets laut letzter Antwort; je Key, also je Workspace.
    var remainingRequests: Int?
    var remainingComplexity: Int?
}

final class LinearCostMeter: @unchecked Sendable {
    static let shared = LinearCostMeter()

    private let lock = NSLock()
    private var cost = LinearCost()

    var snapshot: LinearCost {
        lock.lock(); defer { lock.unlock() }
        return cost
    }

    /// Liest die Kopfzeilen einer Antwort. Der Schlüssel steht nicht darin.
    func record(header: (String) -> String?) {
        let complexity = header("X-Complexity").flatMap(Int.init)
        let remainingRequests = header("X-RateLimit-Requests-Remaining").flatMap(Int.init)
        let remainingComplexity = header("X-RateLimit-Complexity-Remaining").flatMap(Int.init)
        lock.lock()
        cost.requests += 1
        cost.complexity += complexity ?? 0
        cost.lastComplexity = complexity
        if let remainingRequests { cost.remainingRequests = remainingRequests }
        if let remainingComplexity { cost.remainingComplexity = remainingComplexity }
        lock.unlock()
        Logger.debug("linear_cost complexity=\(complexity.map(String.init) ?? "-") "
            + "remaining_complexity=\(remainingComplexity.map(String.init) ?? "-") "
            + "remaining_requests=\(remainingRequests.map(String.init) ?? "-")")
    }

    /// Kosten zwischen zwei Ständen, als Satz für `tickets doctor`.
    static func describe(from before: LinearCost, to after: LinearCost) -> String? {
        let requests = after.requests - before.requests
        guard requests > 0 else { return nil }
        var text = "Abruf: \(requests) Anfragen, \(after.complexity - before.complexity) Punkte"
        if let left = after.remainingRequests, let points = after.remainingComplexity {
            text += "; übrig in dieser Stunde \(left) Anfragen, \(points) Punkte"
        }
        return text
    }
}
