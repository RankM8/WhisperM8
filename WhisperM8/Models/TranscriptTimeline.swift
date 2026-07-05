import Foundation

/// Runden-Projektion eines `AgentChatTranscript` für die Timeline-Ansicht
/// (Variante E aus docs/design/agent-transcript-timeline.html): eine Runde =
/// User-Prompt → Aktivität (Tool-Steps, Thinking, Zwischentexte) → Antwort.
///
/// Bewusst verlustfrei: JEDER Block des Quell-Transcripts landet in genau
/// einer Runde (Prompt, Step, Attachment oder Antwort) — die Timeline ist
/// eine Umsortierung, kein Filter. Erzeugt vom `TranscriptTimelineBuilder`.
struct TranscriptTimeline: Equatable {
    var rounds: [TranscriptRound]
    /// Durchgereicht vom Quell-Transcript (Session könnte noch wachsen).
    var isLiveSourcePossible: Bool
    /// Nachrichtenzahl des Quell-Transcripts — für die Meta-Zeile
    /// („119 Nachrichten · 7 Runden"), ohne das Transcript mitzuschleppen.
    var totalMessageCount: Int

    static let empty = TranscriptTimeline(rounds: [], isLiveSourcePossible: false, totalMessageCount: 0)

    var isEmpty: Bool { rounds.isEmpty }
}

/// Eine Gesprächsrunde. `id` ist stabil (Message-ID des Prompts bzw. der
/// ersten Runden-Message), damit SwiftUI bei Live-Reloads diffen kann statt
/// alles neu aufzubauen.
struct TranscriptRound: Identifiable, Equatable {
    let id: String
    /// `nil` bei einer tail-angeschnittenen Runde (Fenster beginnt mitten in
    /// der Aktivität) — die View zeigt dann einen „Runde unvollständig"-Kopf.
    var prompt: TranscriptPrompt?
    var steps: [TranscriptStep]
    /// Trailing-Assistant-Texte NACH dem letzten Aktivitäts-Step — das ist
    /// „die Antwort". Zwischentexte mitten in der Arbeit werden zu
    /// `.note`-Steps (Reihenfolge bleibt nachvollziehbar).
    var answers: [TranscriptAnswer]
    var stats: TranscriptActivityStats

    var isIncomplete: Bool { prompt == nil }
    var hasActivity: Bool { !steps.isEmpty }
}

struct TranscriptPrompt: Equatable {
    var text: String
    var attachments: [TranscriptAttachment]
    var timestamp: Date?
}

/// Bild-Anhang eines Prompts (nur Metadaten, wie im Quell-Block).
struct TranscriptAttachment: Equatable {
    var mediaType: String
    var byteSize: Int
}

struct TranscriptAnswer: Identifiable, Equatable {
    let id: String
    var text: String
    var timestamp: Date?
}

/// Ein Eintrag in der aufklappbaren Aktivität einer Runde.
struct TranscriptStep: Identifiable, Equatable {
    let id: String
    var kind: Kind
    var timestamp: Date?

    enum Kind: Equatable {
        case tool(TranscriptToolStep)
        case thinking(String)
        /// Assistant-Zwischentext mitten in der Arbeit („Ich prüfe erst …").
        case note(String)
        /// System-Meldung (Role .system) — selten, aber verlustfrei behalten.
        case system(String)
    }

    var isError: Bool {
        if case .tool(let tool) = kind { return tool.isError }
        return false
    }
}

/// Ein Tool-Aufruf inkl. gepaartem Ergebnis. `subject` ist die Kurzform für
/// die Zeile (Dateiname/Kommando), `input`/`result` tragen den VOLLEN Inhalt
/// für die Step-Aufklappung — nichts wird weggeworfen.
struct TranscriptToolStep: Equatable {
    var name: String
    var op: TranscriptOp
    var subject: String
    /// Sekundäre Meta-Info neben dem Subject (z.B. Verzeichnis, Exit-Code).
    var detail: String?
    var input: String
    var result: String?
    var isError: Bool
}

/// Grobe Operations-Klasse eines Tool-Aufrufs — bestimmt Glyph + Farbe in
/// der Detail-Zeile (W/E/R/$ wie im Design-Prototyp).
enum TranscriptOp: String, Equatable {
    case read
    case edit
    case write
    case bash
    case search
    case web
    case task
    case mcp
    case other

    /// Kurz-Glyph der Detail-Zeile.
    var glyph: String {
        switch self {
        case .read: return "R"
        case .edit: return "E"
        case .write: return "W"
        case .bash: return "$"
        case .search: return "G"
        case .web: return "@"
        case .task: return "T"
        case .mcp: return "M"
        case .other: return "·"
        }
    }
}

/// Aggregierte Kennzahlen einer Runde — Basis der stillen Summary-Zeile
/// („9 Tool-Aufrufe · 6 Dateien · 2 Min").
struct TranscriptActivityStats: Equatable {
    var toolCallCount: Int = 0
    /// Distinkte Datei-Subjects der Read/Edit/Write-Steps.
    var fileCount: Int = 0
    var errorCount: Int = 0
    var thinkingCount: Int = 0
    var noteCount: Int = 0
    /// Erster → letzter Timestamp der Runde; `nil` wenn nicht bestimmbar.
    var duration: TimeInterval?
}
