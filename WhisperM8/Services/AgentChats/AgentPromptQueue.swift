import Foundation

/// Ein vorgemerkter Folgeauftrag für einen Chat.
///
/// Hintergrund (Untersuchung 2026-07-26): Claude Code HAT eine native
/// Prompt-Pufferung — sie protokolliert `queue-operation`-Zeilen mit
/// `enqueue`/`dequeue` ins Transcript. Sie ist aber für einen Orchestrator
/// unbrauchbar: von außen nicht abfragbar (man sieht sie erst nachträglich im
/// Transcript), ohne sichtbare Reihenfolge, ohne Storno — und empirisch
/// verlustbehaftet: über 695 echte Transcripts tauchten **12,8 % der
/// gequeueten Nutzer-Prompts nie als User-Message auf** (139 von 1.090).
/// Codex kennt gar kein Queue-Konzept im Rollout-Format.
///
/// Deshalb eine eigene, explizite Warteschlange VOR der PTY: Was hier steht,
/// ist sichtbar, sortiert, stornierbar und überlebt einen App-Neustart.
struct QueuedPrompt: Codable, Equatable, Identifiable {
    enum State: String, Codable, Equatable {
        /// Wartet auf ein Turn-Ende der Ziel-Session.
        case pending
        /// Zustellung läuft gerade (zwischen Reservierung und Paste).
        case delivering
        case delivered
        /// Vom Aufrufer zurückgezogen.
        case cancelled
        /// Zustellung endgültig gescheitert (Ziel weg, PTY tot, …).
        case failed
        /// Die App wurde mitten in der Zustellung beendet. Ob der Prompt
        /// ankam, ist NICHT feststellbar — bewusst kein Auto-Retry: eine
        /// doppelte Beauftragung ist schlimmer als eine sichtbare Rückfrage.
        case unknown
    }

    var id: UUID = UUID()
    /// Monoton wachsende Einstell-Nummer. Der Zeitstempel taugt NICHT als
    /// Ordnung: zwei Aufträge in derselben Millisekunde fielen sonst auf eine
    /// zufällige Reihenfolge zurück — genau das, was eine Warteschlange
    /// ausschließen muss.
    var sequence: Int = 0
    var sessionID: UUID
    var prompt: String
    var enqueuedAt: Date
    /// Wer den Auftrag eingestellt hat (`projekt/titel` oder `external`).
    var enqueuedBy: String
    var state: State = .pending
    var deliveredAt: Date?
    var lastError: String?

    /// Wartet noch auf Zustellung. `unknown` gehört bewusst NICHT dazu — es
    /// wird nie zugestellt und dürfte sonst als „wartet" gezählt werden.
    var isOpen: Bool { state == .pending || state == .delivering }

    /// Braucht eine menschliche Entscheidung: Die Zustellung wurde von einem
    /// App-Ende unterbrochen, der Ausgang ist unbekannt. Wird getrennt von
    /// `isOpen` geführt, muss aber genauso sichtbar sein — sonst wäre der Fall
    /// versteckt statt gelöst.
    var needsReview: Bool { state == .unknown }

    /// Toleranter Decode: fehlt `sequence` (Datei einer älteren Fassung),
    /// wird 0 angenommen statt die GESAMTE Warteschlange zu verwerfen — ein
    /// Decode-Fehler wäre exakt der Auftragsverlust, den es zu verhindern gilt.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        sequence = try container.decodeIfPresent(Int.self, forKey: .sequence) ?? 0
        sessionID = try container.decode(UUID.self, forKey: .sessionID)
        prompt = try container.decode(String.self, forKey: .prompt)
        enqueuedAt = try container.decode(Date.self, forKey: .enqueuedAt)
        enqueuedBy = try container.decodeIfPresent(String.self, forKey: .enqueuedBy) ?? "unbekannt"
        state = try container.decodeIfPresent(State.self, forKey: .state) ?? .pending
        deliveredAt = try container.decodeIfPresent(Date.self, forKey: .deliveredAt)
        lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
    }

    init(id: UUID = UUID(), sequence: Int = 0, sessionID: UUID, prompt: String,
         enqueuedAt: Date, enqueuedBy: String, state: State = .pending,
         deliveredAt: Date? = nil, lastError: String? = nil) {
        self.id = id
        self.sequence = sequence
        self.sessionID = sessionID
        self.prompt = prompt
        self.enqueuedAt = enqueuedAt
        self.enqueuedBy = enqueuedBy
        self.state = state
        self.deliveredAt = deliveredAt
        self.lastError = lastError
    }
}

/// Reine Warteschlangen-Logik: Reihenfolge, Zustandsübergänge, Auswahl des
/// nächsten Auftrags. Kein I/O, keine Uhr, kein App-Zustand — die
/// Zustellgarantien sind der heikle Teil und müssen ohne laufende App prüfbar
/// sein.
enum AgentPromptQueueLogic {
    /// Offene Aufträge einer Session in Einstell-Reihenfolge (FIFO) — nach der
    /// monotonen `sequence`, nicht nach der Uhr.
    static func openPrompts(for sessionID: UUID, in all: [QueuedPrompt]) -> [QueuedPrompt] {
        all.filter { $0.sessionID == sessionID && $0.isOpen }
            .sorted(by: isOrderedBefore)
    }

    /// Gemeinsame Ordnung aller Listen: `sequence`, bei Gleichstand (Altdaten
    /// ohne Nummer) Zeit und zuletzt die ID — nie zufällig.
    static func isOrderedBefore(_ lhs: QueuedPrompt, _ rhs: QueuedPrompt) -> Bool {
        if lhs.sequence != rhs.sequence { return lhs.sequence < rhs.sequence }
        if lhs.enqueuedAt != rhs.enqueuedAt { return lhs.enqueuedAt < rhs.enqueuedAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    /// Der als Nächstes zuzustellende Auftrag — oder `nil`.
    ///
    /// Liefert NICHTS, solange bereits eine Zustellung läuft (`delivering`):
    /// zwei gleichzeitige Pastes in dieselbe PTY würden die Reihenfolge
    /// zerstören und könnten Text ineinander schieben.
    static func nextDeliverable(for sessionID: UUID, in all: [QueuedPrompt]) -> QueuedPrompt? {
        let open = openPrompts(for: sessionID, in: all)
        guard !open.contains(where: { $0.state == .delivering }) else { return nil }
        return open.first { $0.state == .pending }
    }

    /// Aufträge mit unklarem Ausgang — müssen angesehen werden.
    static func reviewPrompts(for sessionID: UUID, in all: [QueuedPrompt]) -> [QueuedPrompt] {
        all.filter { $0.sessionID == sessionID && $0.needsReview }
            .sorted(by: isOrderedBefore)
    }

    /// Alles, was in `show`/`queue` sichtbar sein muss: wartende Aufträge
    /// zuerst, danach die mit unklarem Ausgang.
    static func visiblePrompts(for sessionID: UUID, in all: [QueuedPrompt]) -> [QueuedPrompt] {
        openPrompts(for: sessionID, in: all) + reviewPrompts(for: sessionID, in: all)
    }

    /// Anzahl offener Aufträge je Session — Grundlage der `queued`-Anzeige in
    /// `show`/`overview`.
    static func openCounts(in all: [QueuedPrompt]) -> [UUID: Int] {
        var counts: [UUID: Int] = [:]
        for prompt in all where prompt.isOpen {
            counts[prompt.sessionID, default: 0] += 1
        }
        return counts
    }

    /// Anzahl klärungsbedürftiger Aufträge je Session.
    static func reviewCounts(in all: [QueuedPrompt]) -> [UUID: Int] {
        var counts: [UUID: Int] = [:]
        for prompt in all where prompt.needsReview {
            counts[prompt.sessionID, default: 0] += 1
        }
        return counts
    }

    /// Beim App-Start: Was beim Beenden mitten in der Zustellung stand, ist von
    /// unbekanntem Ausgang. Nicht erneut zustellen — als `unknown` markieren,
    /// damit der Aufrufer entscheidet.
    static func reconcileAfterRestart(_ all: [QueuedPrompt]) -> [QueuedPrompt] {
        all.map { prompt in
            guard prompt.state == .delivering else { return prompt }
            var recovered = prompt
            recovered.state = .unknown
            recovered.lastError = "App wurde während der Zustellung beendet — Ausgang unbekannt"
            return recovered
        }
    }

    /// Aufräumen: abgeschlossene Aufträge nach einer Karenzzeit entfernen.
    /// `unknown` bleibt bewusst liegen — es ist genau der Fall, den jemand
    /// ansehen muss.
    static func pruned(_ all: [QueuedPrompt], now: Date, keepFor: TimeInterval = 3600) -> [QueuedPrompt] {
        all.filter { prompt in
            switch prompt.state {
            case .pending, .delivering, .unknown:
                return true
            case .delivered, .cancelled, .failed:
                let reference = prompt.deliveredAt ?? prompt.enqueuedAt
                return now.timeIntervalSince(reference) < keepFor
            }
        }
    }
}
