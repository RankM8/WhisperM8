import Foundation
import Observation

/// Fläche, die eine offene Jarvis-Notizkarte im Raster über dem Terminal
/// belegt, gemessen ab der linken Kante der Kachel und der Unterkante des
/// Kachelkopfs.
struct JarvisNoteCardFootprint: Equatable {
    var trailingEdge: CGFloat
    var bottomEdge: CGFloat

    /// So weit beginnt das Terminal in der Kachel eingerückt (links und unter
    /// dem Kopf), wie `AgentChatsView.gridPaneContentInset`.
    static let terminalInset: CGFloat = 14
}

/// Welche Notizkarten gerade offen sind und wie groß (WM8-123): Die Pille
/// „Meldung wartet“ weicht ihnen aus. Nur Speicher; geschrieben von der Karte
/// beim Öffnen, Schließen und bei Größenänderung, gelesen nur von der Pille
/// desselben Chats. Die Kachel selbst liest es nicht.
@MainActor
@Observable
final class JarvisNoteCardFootprints {
    static let shared = JarvisNoteCardFootprints()

    private(set) var footprints: [UUID: JarvisNoteCardFootprint] = [:]

    func set(_ footprint: JarvisNoteCardFootprint?, for sessionID: UUID) {
        // Nur bei echter Änderung: Jede Zuweisung weckt die Pille.
        guard footprints[sessionID] != footprint else { return }
        footprints[sessionID] = footprint
    }
}
