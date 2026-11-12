import CoreGraphics
import Foundation

/// Was die ruhende Pille an einer Stelle gerade zeigt, damit die Diktat-Pille
/// genau so beginnt und genau so endet (Übergang ohne Sprung). Rein, aus dem
/// Zustand der Status-Pille berechnet, auch während sie ausgeblendet ist.
enum UnifiedPillRestLook: Equatable {
    /// Pille ohne Notch: grauer Kern, daneben Zähler bzw. „braucht dich“.
    case pill(summary: NotchSummary, alert: NotchAlert?)
    /// An der Notch mit Anzeige: Zeile unter der Aussparung, so breit wie dort.
    case notch(summary: NotchSummary, alert: NotchAlert?, bodyWidth: CGFloat)
    /// An der Notch ohne Anzeige: nur das schwarze Band in der Aussparung, die
    /// Diktat-Zeile wächst darunter heraus.
    case notchBand

    var isNotch: Bool {
        if case .pill = self { return false }
        return true
    }

    /// Höhe der Zeile unter dem Band bzw. der Pille.
    var rowHeight: CGFloat {
        switch self {
        case .pill: return PillMetrics.height
        case .notch: return NotchGeometry.chinHeight
        case .notchBand: return 0
        }
    }
}

/// Ruhebild samt Mittelpunkt der Pille (globale Cocoa-Koordinaten). Ohne
/// Notch beginnt die Diktat-Pille genau dort; an der Notch zählt nur das Bild.
struct UnifiedPillRestSnapshot: Equatable {
    var look: UnifiedPillRestLook
    var center: CGPoint?
}

/// Ablauf des Übergangs zwischen ruhender Pille und Diktat auf einem
/// Bildschirm, rein und ohne Fenster testbar. Der `OverlayController` meldet
/// Ereignisse und führt die zurückgegebenen Schritte aus.
///
/// Ablauf mit Übergang: `idle` → `handoverIn` (Diktat-Fenster zeigt das
/// Ruhebild über der Status-Pille) → `growing` (Status-Pille weg, die Pille
/// wächst zum Diktat) → `dictation` → `shrinking` (zurück ins Ruhebild) →
/// `handoverOut` (Status-Pille wieder da) → `idle` (Diktat-Fenster zu).
/// Ohne ruhende Pille an der Stelle (anderer Bildschirm, Status aus, Liste
/// offen, Vollbild, Kill-Switch) erscheint das Diktat wie bisher direkt.
///
/// Die Aufnahme selbst wartet nie auf diese Schritte: Sie startet und endet
/// im Coordinator, hier geht es nur ums Bild.
struct UnifiedPillMorph: Equatable {
    enum Phase: Equatable {
        case idle
        case handoverIn
        case growing
        case dictation
        case shrinking
        case handoverOut
    }

    /// Folgeschritte, die der Controller zeitversetzt meldet.
    enum Step: Equatable {
        /// Das Fenster hat sein aktuelles Bild gezeichnet (ein Bild später).
        case frameDrawn
        /// Die Breitenanimation ist durch.
        case animationDone
    }

    enum Effect: Equatable {
        /// Diktat-Fenster zeigt das Ruhebild (ohne Animation).
        case showRestLook
        /// Animiert vom Ruhebild ins Diktat.
        case grow
        /// Animiert vom Diktat zurück ins Ruhebild.
        case shrink
        /// Status-Pille an dieser Stelle ausblenden (Hub: Diktat steht hier).
        case hideStatus
        /// Status-Pille wieder zeigen (Hub: Diktat weg).
        case showStatus
        /// Diktat-Fenster schließen.
        case closeWindow
        /// Folgeschritt melden, sobald er eingetreten ist.
        case schedule(Step, generation: Int)
    }

    private(set) var phase: Phase = .idle
    /// Zählt jeden Wechsel; ein geplanter Schritt mit älterer Generation ist
    /// überholt und wird verworfen.
    private(set) var generation = 0

    /// Das Fenster steht noch, das Diktat ist aber schon vorbei (es zieht
    /// sich zurück). Ein neues Diktat übernimmt es.
    var isRetiring: Bool { phase == .shrinking || phase == .handoverOut }

    /// Ein Diktat soll erscheinen. `morph`: an dieser Stelle steht eine
    /// ruhende Pille, aus der es wachsen kann.
    mutating func show(morph: Bool) -> [Effect] {
        switch phase {
        case .idle:
            if morph {
                enter(.handoverIn)
                return [.showRestLook, .schedule(.frameDrawn, generation: generation)]
            }
            enter(.dictation)
            return [.hideStatus]
        case .shrinking:
            // Neues Diktat, während sich das alte zurückzieht: aus dem
            // jetzigen Stand wieder wachsen, die Status-Pille ist noch weg.
            enter(.growing)
            return [.grow, .schedule(.animationDone, generation: generation)]
        case .handoverOut:
            enter(.growing)
            return [.hideStatus, .grow, .schedule(.animationDone, generation: generation)]
        case .handoverIn, .growing, .dictation:
            return []
        }
    }

    /// Ein geplanter Schritt ist eingetreten.
    mutating func step(_ step: Step, generation stepGeneration: Int) -> [Effect] {
        guard stepGeneration == generation else { return [] }
        switch (phase, step) {
        case (.handoverIn, .frameDrawn):
            enter(.growing)
            return [.hideStatus, .grow, .schedule(.animationDone, generation: generation)]
        case (.growing, .animationDone):
            enter(.dictation)
            return []
        case (.shrinking, .animationDone):
            enter(.handoverOut)
            return [.showStatus, .schedule(.frameDrawn, generation: generation)]
        case (.handoverOut, .frameDrawn):
            enter(.idle)
            return [.closeWindow]
        default:
            return []
        }
    }

    /// Das Diktat ist vorbei. `morph`: an dieser Stelle gibt es ein Ruhebild,
    /// in das es sich zurückziehen kann.
    mutating func hide(morph: Bool) -> [Effect] {
        switch phase {
        case .idle, .shrinking, .handoverOut:
            return []
        case .handoverIn:
            // Noch nicht gewachsen, die Status-Pille steht noch: einfach weg.
            enter(.idle)
            return [.closeWindow]
        case .growing, .dictation:
            if morph {
                enter(.shrinking)
                return [.shrink, .schedule(.animationDone, generation: generation)]
            }
            enter(.idle)
            return [.closeWindow, .showStatus]
        }
    }

    /// Fenster sofort weg (Bildschirm geändert, Kill-Switch, neues Fenster
    /// an anderer Stelle). Steht die Status-Pille noch aus, kommt sie zurück.
    mutating func abort() -> [Effect] {
        let wasHidingStatus = phase == .growing || phase == .dictation || phase == .shrinking
        let hadWindow = phase != .idle
        enter(.idle)
        var effects: [Effect] = []
        if hadWindow { effects.append(.closeWindow) }
        if wasHidingStatus { effects.append(.showStatus) }
        return effects
    }

    /// Zurück auf Anfang, ohne Schritte (das Diktat baut nach einem
    /// Bildschirmwechsel an anderer Stelle neu auf und steht dort direkt).
    /// Die Generation zählt weiter: Alte geplante Schritte verpuffen.
    mutating func reset() {
        enter(.idle)
    }

    private mutating func enter(_ next: Phase) {
        phase = next
        generation += 1
    }
}
