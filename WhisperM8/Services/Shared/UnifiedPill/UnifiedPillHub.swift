import Combine
import Foundation

/// Treffpunkt der beiden Hälften der vereinten Pille: Das Diktat
/// (`OverlayController`) meldet, auf welchem Bildschirm es gerade steht, der
/// Chat-Status (`NotchStatusController`) blendet sich dort aus und reicht die
/// Raute für wartende Chats herüber. Beide kennen sich so nicht direkt, und
/// die Diktat-Logik bleibt unberührt: Hier kommt nur Darstellung an.
///
/// Kostet nichts im Pegel-Takt: Werte ändern sich nur beim Ein- und Ausblenden
/// des Diktats bzw. wenn sich die Zähler ändern (gedrosselt auf 300 ms).
@MainActor
final class UnifiedPillHub: ObservableObject {
    static let shared = UnifiedPillHub()

    /// Bildschirm (`NSScreenNumber`), auf dem das Diktat gerade sichtbar ist;
    /// `nil` ohne sichtbares Diktat.
    @Published private(set) var dictationDisplayID: UInt32?
    /// Wartende Chats und Fehler für die Raute links in der Diktat-Pille.
    @Published private(set) var badge: DictationStatusBadge?

    /// Ob die vereinte Pille gilt. Gelesen an den Entscheidungsstellen (Diktat
    /// zeigen, Einstellungen anwenden), nie im Takt.
    var isEnabled: () -> Bool = { AppPreferences.shared.isUnifiedPillEnabled }

    /// Ruhebild der Status-Seite für einen Bildschirm (`UnifiedPillMorph`):
    /// Aus ihm wächst das Diktat, in es zieht es sich zurück. Gesetzt vom
    /// `NotchStatusController`, solange er läuft; gefragt nur beim Ein- und
    /// Ausblenden des Diktats.
    var restSnapshot: (UInt32) -> UnifiedPillRestSnapshot? = { _ in nil }
    /// Klick auf den Kern einer Pille, die sich gerade zurückzieht: Diktat
    /// wie per Hotkey. Gesetzt vom `NotchStatusController` (sein Weg).
    var startDictation: () -> Void = {}

    /// Übergang (`UnifiedPillMorph`): Bildschirm, auf dem der Inhalt der
    /// Status-Pille gerade unsichtbar ist, weil das Diktat-Fenster dort ihr
    /// Bild zeigt; `nil` sonst. Das Fenster selbst bleibt, wie es ist.
    private(set) var statusContentHiddenDisplayID: UInt32?
    /// Setzt die Sichtbarkeit sofort in der laufenden CATransaction um.
    /// Gesetzt vom `NotchStatusController`, solange er läuft.
    var applyStatusContentHidden: (UInt32?) -> Void = { _ in }

    /// Inhalt der Status-Pille auf diesem Bildschirm unsichtbar (`nil`: überall
    /// sichtbar). Nur der Übergang ruft das, jeweils im selben Bild wie den
    /// Gegenschritt am Diktat-Fenster.
    func setStatusContentHidden(onDisplay displayID: UInt32?) {
        guard statusContentHiddenDisplayID != displayID else { return }
        statusContentHiddenDisplayID = displayID
        applyStatusContentHidden(displayID)
    }

    func dictationDidShow(onDisplay displayID: UInt32) {
        if dictationDisplayID != displayID { dictationDisplayID = displayID }
    }

    /// Diktat-Pille auf einen anderen Bildschirm gezogen: Dort tritt die
    /// Status-Pille zurück. Ist ihr Inhalt wegen des Übergangs unsichtbar,
    /// wandert das mit: Auf dem alten Bildschirm ist sie wieder zu sehen, auf
    /// dem neuen beginnt das Zurückziehen wie dort üblich unsichtbar.
    func dictationMoved(toDisplay displayID: UInt32) {
        dictationDidShow(onDisplay: displayID)
        if statusContentHiddenDisplayID != nil { setStatusContentHidden(onDisplay: displayID) }
    }

    func dictationDidHide() {
        if dictationDisplayID != nil { dictationDisplayID = nil }
    }

    func updateBadge(_ badge: DictationStatusBadge?) {
        if self.badge != badge { self.badge = badge }
    }
}
