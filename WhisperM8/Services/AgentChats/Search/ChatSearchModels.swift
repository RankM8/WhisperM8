import Foundation

/// Inhaltsklasse einer extrahierten Textspanne. Der entscheidende Hebel gegen
/// die False-Positive-Flut der alten Rohsuche: 8,1 GB Transcripts bestehen zu
/// ~97–99 % aus Tool-Output, System-Reminders und Harness-Injektionen — nur
/// `humanUser` und `assistantNarrative` sind das, was der Nutzer „mein Chat"
/// nennt. Die Suche indexiert alles, rankt aber standardmäßig nur diese beiden
/// und blendet den Rest ohne explizites Flag aus.
enum ChatSearchContentKind: String, CaseIterable, Equatable {
    /// Echte Tastatureingabe des Nutzers.
    case humanUser
    /// Fließtext des Agenten (kein Tool-Aufruf, kein Reasoning).
    case assistantNarrative
    case toolCall
    case toolResult
    case thinking
    /// `<system-reminder>`, Harness-Hinweise, injizierte Skill-/CLAUDE.md-Blöcke.
    case system
    /// Compact-/Session-Zusammenfassungen.
    case summary

    /// Die Klassen der Standardsuche.
    static let conversational: Set<ChatSearchContentKind> = [.humanUser, .assistantNarrative]

    /// Rang-Basisgewicht — je höher, desto weiter oben. Wird vom Ranker mit
    /// Recency und Trefferqualität kombiniert.
    var weight: Double {
        switch self {
        case .humanUser: return 1.0
        case .assistantNarrative: return 0.8
        case .summary: return 0.5
        case .toolCall: return 0.2
        case .toolResult: return 0.15
        case .thinking: return 0.15
        case .system: return 0.05
        }
    }
}

enum ChatSearchRole: String, Equatable {
    case user
    case assistant
}

/// Eine indexierbare Textspanne mit ihrer exakten Herkunft im Transcript.
/// `byteOffset` + `lineNumber` sind die Grundlage der stabilen Match-Referenz:
/// damit kann Kontext später gezielt nachgelesen werden, ohne die Datei erneut
/// vollständig zu scannen.
struct ChatSearchSpan: Equatable {
    var byteOffset: Int
    var lineNumber: Int
    /// Position innerhalb der Zeile — eine JSONL-Zeile kann mehrere
    /// Content-Blöcke tragen (Text + Tool-Use + Reminder).
    var blockIndex: Int
    var timestamp: Date?
    var role: ChatSearchRole
    var kind: ChatSearchContentKind
    var text: String
}
