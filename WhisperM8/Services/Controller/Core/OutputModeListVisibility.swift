import Foundation

/// Wann die Liste der Ausgabemodi an der Aufnahme-Pill zu sehen ist (Runde 2
/// nach dem Handtest): Jeder Moduswechsel per Controller zeigt sie, sie
/// blendet sich `hideDelay` nach dem letzten Wechsel aus und sofort mit dem
/// Ende der Aufnahme. Pur, die Zeit kommt als Parameter.
struct OutputModeListVisibility: Equatable, Sendable {
    static let hideDelay: TimeInterval = 1.5

    private(set) var lastChangeAt: TimeInterval?

    mutating func noteChange(at time: TimeInterval) {
        lastChangeAt = time
    }

    /// Aufnahme vorbei (Stopp, Verwerfen, Abbruch): sofort weg.
    mutating func recordingEnded() {
        lastChangeAt = nil
    }

    func isVisible(at time: TimeInterval) -> Bool {
        guard let hideAt else { return false }
        return time < hideAt
    }

    /// Zeitpunkt, an dem die Liste verschwindet; `nil`, wenn sie nicht zu sehen ist.
    var hideAt: TimeInterval? {
        lastChangeAt.map { $0 + Self.hideDelay }
    }
}
