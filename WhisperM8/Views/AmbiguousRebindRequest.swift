import Foundation

/// Anfrage an die UI, einen Picker fuer ambigue Claude-`/resume`-Detection
/// anzuzeigen. Wird vom `ClaudeActiveSessionTracker` ausgeloest, wenn
/// mehr als ein plausibler Kandidat fuer den neuen Conversation-State
/// gefunden wurde.
struct AmbiguousRebindRequest: Equatable, Identifiable {
    let id = UUID()
    let localSessionID: UUID
    let candidates: [IndexedAgentSession]

    static func == (lhs: AmbiguousRebindRequest, rhs: AmbiguousRebindRequest) -> Bool {
        lhs.id == rhs.id
            && lhs.localSessionID == rhs.localSessionID
            && lhs.candidates == rhs.candidates
    }
}
