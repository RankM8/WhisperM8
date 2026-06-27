import Foundation

/// Pure Merge-Logik fuer das nachgereichte Kontext-Capture (P5): Der Capture
/// laeuft seit dem Sofort-Start parallel zur Aufnahme — beim Eintreffen darf
/// er nur noch LEERE Slots fuellen und keine User-Edits ueberschreiben, die
/// waehrenddessen im Overlay passiert sind.
enum ContextCaptureMerge {
    /// - Parameters:
    ///   - captured: das (ggf. leere) Selected-Text-Ergebnis des Captures
    ///   - tail: der gelesene Agent-Chat-Tail, falls vorhanden
    ///   - bundle: der aktuelle Bundle-Stand (inkl. User-Edits)
    ///   - userClearedSelectedText: User hat waehrend des Captures den
    ///     Kontext geleert — dann wird nichts nachgereicht
    static func apply(
        captured: SelectedContext,
        tail: String?,
        into bundle: TranscriptContextBundle,
        userClearedSelectedText: Bool
    ) -> TranscriptContextBundle {
        var result = bundle

        if !userClearedSelectedText, result.selectedText.isEmpty, !captured.isEmpty {
            result.selectedText = captured
        }

        // Tail nur nachreichen, wenn die Agent-Chat-Ref noch da ist (User
        // kann sie via removeAgentChatFromContext entfernt haben) und noch
        // kein Tail gesetzt wurde.
        if result.agentChat != nil, result.agentChatTail == nil, let tail {
            result.agentChatTail = tail
        }

        return result
    }
}
