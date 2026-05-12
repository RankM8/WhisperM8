import Foundation

/// Unifizierte Repraesentation einer Claude- oder Codex-Konversation, geparst
/// aus dem JSONL-File, das beide CLI-Tools live auf Disk schreiben.
///
/// Wird vom `ClaudeTranscriptReader` und `CodexTranscriptReader` produziert
/// und vom `AgentChatTranscriptView` gerendert — das ist die kanonische
/// "geschlossene Session"-Anzeige (Snapshot-Layer entfaellt).
struct AgentChatTranscript: Equatable {
    var messages: [AgentChatMessage]
    /// Optionaler Hint, ob die Quell-Datei gerade noch wachsen koennte
    /// (Session laeuft). `false` heisst: definitiv "fertig geschrieben".
    var isLiveSourcePossible: Bool

    static let empty = AgentChatTranscript(messages: [], isLiveSourcePossible: false)

    var isEmpty: Bool { messages.isEmpty }
}

/// Eine einzelne Message im Transcript — entweder User-Prompt oder
/// Assistant-Response. Sub-Strukturen wie Tool-Calls werden als `blocks`
/// dargestellt (zumindest semantisch typisiert).
struct AgentChatMessage: Identifiable, Equatable {
    let id: UUID
    var role: Role
    var timestamp: Date?
    var blocks: [AgentChatBlock]

    enum Role: String, Equatable {
        case user
        case assistant
        case system
    }
}

/// Inhaltsbaustein einer Message. Wir behalten die semantische Trennung
/// (Text vs Tool-Call vs Image vs Thinking) damit die UI sie unterschiedlich
/// rendern kann.
enum AgentChatBlock: Equatable {
    /// Klartext / Markdown. Wird gerendert als selektierbares Text-Element.
    case text(String)
    /// Tool-Aufruf: Name + Input als JSON-String oder formatiertes Snippet.
    case toolUse(name: String, input: String)
    /// Ergebnis eines Tool-Aufrufs (in User-Messages eingebettet bei Claude).
    case toolResult(content: String, isError: Bool)
    /// Eingebettetes Bild — wir speichern hier nur Metadata (Format + Bytes),
    /// nicht die rohen Bytes selbst um Memory zu schonen. Die UI zeigt einen
    /// Platzhalter mit Groessenangabe; tatsaechliches Decoden waere ein
    /// separater Schritt (lazy on tap).
    case imagePlaceholder(mediaType: String, byteSize: Int)
    /// Claude's Thinking-Block — standardmaessig zusammengeklappt.
    case thinking(String)
}
