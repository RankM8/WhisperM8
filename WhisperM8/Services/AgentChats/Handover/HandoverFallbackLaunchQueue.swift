import Foundation

// MARK: - Rückfall der Übernahme: auch unterdrückte Grid-Panes starten

/// Chats, die der Rückfall der Übernahme fortsetzen will (Befund 3, Dex).
///
/// Im Grid startet sonst nur die Fokus-Pane einen vorgemerkten Chat
/// (`suppressesAutoActivation`, Plan F9); nach einem Rückfall blieben gerade
/// die Chats stehen, die der Neustart retten sollte. Nur Chats aus dieser
/// Warteschlange dürfen deshalb auch in einer unterdrückten Pane starten,
/// nacheinander mit kurzem Abstand. Absturz-Wiederaufnahme, Preset-Wechsel und
/// normales Öffnen eines Grids füllen sie nie und bleiben, wie sie sind.
@MainActor
final class HandoverFallbackLaunchQueue {
    static let shared = HandoverFallbackLaunchQueue()

    private let now: () -> Date
    /// Abstand zwischen zwei Starts.
    let spacing: TimeInterval
    /// Danach zählt ein Eintrag nicht mehr (Pane erst viel später geöffnet).
    let lifetime: TimeInterval
    private var queued: [UUID: Date] = [:]
    private var nextSlot = Date.distantPast
    /// In diesem Start zum Fortsetzen vorgemerkt (der Rückfall kommt in zwei
    /// Schüben); zählt für den Sammelstart-Planer wie ein laufender Chat.
    private(set) var scheduledThisLaunch: Set<UUID> = []

    init(now: @escaping () -> Date = Date.init, spacing: TimeInterval = 0.5, lifetime: TimeInterval = 300) {
        self.now = now
        self.spacing = spacing
        self.lifetime = lifetime
    }

    func schedule(_ ids: [UUID]) {
        let at = now()
        for id in ids {
            queued[id] = at
            scheduledThisLaunch.insert(id)
        }
    }

    /// Verzögerung für den Start einer unterdrückten Pane, oder `nil`, wenn
    /// der Chat nicht (mehr) vom Rückfall vorgemerkt ist. Jeder Eintrag gilt
    /// genau einmal.
    func takeLaunchSlot(for id: UUID) -> TimeInterval? {
        guard let at = queued.removeValue(forKey: id) else { return nil }
        let current = now()
        guard current.timeIntervalSince(at) < lifetime else { return nil }
        let start = max(current, nextSlot)
        nextSlot = start.addingTimeInterval(spacing)
        return start.timeIntervalSince(current)
    }

    /// Der Chat startete auf anderem Weg (Fokus-Pane, Tab): Eintrag verwerfen.
    func forget(_ id: UUID) {
        queued[id] = nil
    }
}
