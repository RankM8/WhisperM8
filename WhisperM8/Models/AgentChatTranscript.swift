import CryptoKit
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
    /// `true` wenn dieses Transcript per Tail-Read entstand und die Datei
    /// VOR dem Lesefenster noch weiteren Verlauf hat — die UI bietet dann
    /// "Früheren Verlauf laden" an (progressives Nachladen statt Voll-Parse;
    /// 17-MB-Chats froren die App beim Voll-Read ein).
    var hasTruncatedHead: Bool = false

    static let empty = AgentChatTranscript(messages: [], isLiveSourcePossible: false)

    var isEmpty: Bool { messages.isEmpty }
}

/// Eine einzelne Message im Transcript — entweder User-Prompt oder
/// Assistant-Response. Sub-Strukturen wie Tool-Calls werden als `blocks`
/// dargestellt (zumindest semantisch typisiert).
struct AgentChatMessage: Identifiable, Equatable {
    var id: UUID
    var role: Role
    var timestamp: Date?
    var blocks: [AgentChatBlock]

    enum Role: String, Equatable {
        case user
        case assistant
        case system
    }
}

/// Vergibt INHALTSBASIERTE, deterministische Message-IDs (SHA256 → UUID).
/// Warum: `UUID()` beim Parsen macht jeden Live-Reload zu komplett neuen
/// Identitäten — SwiftUI kann nicht diffen, die Liste wird voll neu gebaut
/// und die Scroll-Position springt. Mit stabilen IDs bleiben unveränderte
/// Messages über readTail-Reloads identisch, unabhängig vom Tail-Fenster.
///
/// Identische Messages (z.B. zweimal „ok") werden über einen Occurrence-
/// Zähler PRO PARSE-LAUF disambiguiert — sonst kollidierte `ForEach`.
/// Randfall: rutscht ein früheres Duplikat aus dem Tail-Fenster, verschieben
/// sich die Occurrence-Indizes der späteren — einmaliges Re-Rendern genau
/// dieser Duplikate, kein Korrektheitsproblem.
struct TranscriptStableIDGenerator {
    private var occurrenceByDigest: [String: Int] = [:]

    /// Ersetzt die ID der Message durch die stabile Inhalts-ID.
    mutating func assign(_ message: AgentChatMessage) -> AgentChatMessage {
        var seed = message.role.rawValue
        seed += "|"
        seed += message.timestamp.map { String($0.timeIntervalSince1970) } ?? "-"
        for block in message.blocks {
            seed += "|"
            switch block {
            case .text(let text): seed += "t:" + text
            case .toolUse(let name, let input): seed += "u:" + name + ":" + input
            case .toolResult(let content, let isError): seed += "r:\(isError):" + content
            case .imagePlaceholder(let mediaType, let byteSize): seed += "i:\(mediaType):\(byteSize)"
            case .thinking(let text): seed += "k:" + text
            }
        }
        let baseDigest = SHA256.hash(data: Data(seed.utf8))
        let baseKey = baseDigest.map { String(format: "%02x", $0) }.joined()
        let occurrence = occurrenceByDigest[baseKey, default: 0]
        occurrenceByDigest[baseKey] = occurrence + 1

        let finalDigest = SHA256.hash(data: Data((seed + "|#\(occurrence)").utf8))
        var result = message
        result.id = Self.uuid(fromDigest: finalDigest)
        return result
    }

    private static func uuid(fromDigest digest: SHA256.Digest) -> UUID {
        let bytes = Array(digest.prefix(16))
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
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
