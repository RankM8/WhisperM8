import Foundation

/// Pure Entscheidungslogik des Scroll-Locks im Normal-Buffer
/// (`QuietableTerminalView`): folgt die Ansicht dem Output, rastet sie am
/// Ende ein oder hält sie die Leseposition des Users?
///
/// Zeilenbasiert statt über einen Bruchteil der Scroll-Position: SwiftTerm
/// beendet seinen `userScrolling`-Zustand nur am EXAKTEN Ende. Die frühere
/// Toleranz (`position >= 0.985`, bei 10.000 Zeilen Scrollback ~150 Zeilen)
/// wertete „knapp drüber" als „folgt" — SwiftTerm folgte aber nicht, und der
/// Viewport blieb dauerhaft ein paar Zeilen über dem Ende stehen. Genau dort
/// zeichnete SwiftTerm v1.15 Neuzeichnungen an Ort und Stelle in die falschen
/// Zeilen (Fork-Backport #620): Eingaben erschienen erst nach einem Klick.
enum TerminalTailFollow {
    enum Decision: Equatable {
        /// Steht exakt am Ende — neuer Output bleibt sichtbar.
        case follow
        /// Abwärts-Scroll endete knapp vor dem Ende — exakt einrasten.
        case snapToTail
        /// User liest weiter oben — Position gegen Output-Sprünge halten.
        case detach
    }

    /// Bis zu so vielen Zeilen vor dem Ende rastet ein Abwärts-Scroll ein
    /// (Trackpad-Schwung endet gern ein, zwei Zeilen zu früh).
    static let snapRows = 3

    static func decide(distanceToTail: Int, movedDown: Bool) -> Decision {
        if distanceToTail <= 0 { return .follow }
        if movedDown && distanceToTail <= snapRows { return .snapToTail }
        return .detach
    }

    /// Zeilenabstand zum Ende aus SwiftTerms öffentlicher API — die
    /// Zeilenzahl des Puffers ist dort `internal`, aber
    /// `position = yDisp / maxScrollback` lässt sie exakt zurückrechnen.
    /// Ohne Scrollback (frischer oder geleerter Bildschirm) steht die Ansicht
    /// immer am Ende; SwiftTerm meldet dort `position == 0`, was der alte
    /// Bruchteil-Vergleich als „weit oben" missverstand.
    static func distanceToTail(yDisp: Int, position: Double, canScroll: Bool) -> Int {
        guard canScroll, position < 1 else { return 0 }
        guard yDisp > 0, position > 0 else { return Int.max }
        let maxScrollback = Int((Double(yDisp) / position).rounded())
        return max(0, maxScrollback - yDisp)
    }
}
