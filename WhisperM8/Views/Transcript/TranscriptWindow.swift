import Foundation

/// Hart begrenztes, verschiebbares Render-Fenster über einer Item-Liste
/// (Runden der Timeline bzw. Messages der Roh-Ansicht).
///
/// Hintergrund (Hang-Report 2026-07-16, Codex-Jobs d5252179/f172aed9): Das
/// bisherige Fenster wuchs bei jedem „frühere anzeigen"-Klick additiv und
/// wurde nie wieder kleiner — die SwiftUI-Layout-Kosten wuchsen monoton, bis
/// ein einziger Layout-Pass Minuten dauerte (186-s-Hang, App-Kill). Dieses
/// Fenster hat eine harte Obergrenze (`maxSize`): Beim Blättern nach oben
/// fallen die neuesten Items aus dem Render-Baum, beim Zurückspringen die
/// ältesten. Die DATEN bleiben vollständig — begrenzt wird nur, was
/// gleichzeitig layoutet wird.
///
/// Pur und ohne UI-Abhängigkeit — vollständig unit-testbar.
struct TranscriptWindow: Equatable {
    /// Fenstergröße beim ersten Befüllen bzw. nach Reset (Tail-Fenster).
    let initialSize: Int
    /// Um wie viele Items ein Blättern das Fenster verschiebt/erweitert.
    let batchSize: Int
    /// Harte Obergrenze gleichzeitig gerenderter Items.
    let maxSize: Int

    private(set) var total = 0
    /// Fenster als [start, end) über der Gesamtliste.
    private(set) var start = 0
    private(set) var end = 0

    init(initialSize: Int, batchSize: Int, maxSize: Int) {
        self.initialSize = initialSize
        self.batchSize = batchSize
        self.maxSize = max(maxSize, initialSize)
    }

    /// Fenster klebt am Listen-Ende → Live-Wachstum wird mitverfolgt.
    var followsTail: Bool { end >= total }
    /// Items oberhalb des Fensters (im Speicher, aber nicht gerendert).
    var hiddenEarlierCount: Int { max(0, start) }
    /// Items unterhalb des Fensters (nach oben geblättert).
    var hiddenLaterCount: Int { max(0, total - end) }
    var count: Int { max(0, end - start) }

    /// Tail-Fenster mit Initialgröße (Erstbefüllung, Session-Wechsel).
    mutating func reset(total newTotal: Int) {
        total = max(0, newTotal)
        end = total
        start = max(0, end - initialSize)
    }

    /// Wachstum/Ersatz am Listen-ENDE (Live-Append) — folgt dem Ende nur,
    /// wenn das Fenster dort klebt; sonst bleibt die Position stabil und
    /// `hiddenLaterCount` wächst. Schrumpfen = Session-Wechsel → Reset.
    mutating func updateForTailChange(total newTotal: Int) {
        guard newTotal >= total else {
            reset(total: newTotal)
            return
        }
        if total == 0 {
            reset(total: newTotal)
            return
        }
        if followsTail {
            end = newTotal
            start = max(start, end - maxSize)
        }
        total = newTotal
    }

    /// Wachstum am Listen-ANFANG (Nachladen älteren Verlaufs von der Platte):
    /// dieselben Items bleiben sichtbar (Indizes verschieben sich um das
    /// Delta), danach wird eine Batch der neu geladenen Items aufgedeckt.
    mutating func updateForHeadGrowth(total newTotal: Int) {
        let delta = newTotal - total
        guard delta > 0 else {
            updateForTailChange(total: newTotal)
            return
        }
        start += delta
        end += delta
        total = newTotal
        pageUp()
    }

    /// Fenster um eine Batch nach oben schieben; überschreitet die Größe
    /// `maxSize`, fallen die neuesten Items hinten raus.
    @discardableResult
    mutating func pageUp() -> Bool {
        guard start > 0 else { return false }
        start = max(0, start - batchSize)
        if end - start > maxSize {
            end = start + maxSize
        }
        return true
    }

    /// Fenster um eine Batch Richtung Ende schieben (Gegenrichtung).
    @discardableResult
    mutating func pageDown() -> Bool {
        guard end < total else { return false }
        end = min(total, end + batchSize)
        if end - start > maxSize {
            start = end - maxSize
        }
        return true
    }

    /// Zurück ans Ende springen (Tail-Fenster mit Initialgröße).
    mutating func jumpToTail() {
        reset(total: total)
    }

    /// Der tatsächlich zu rendernde Ausschnitt — defensiv geclampt, falls
    /// die Liste kürzer ist als der Fensterzustand (Race beim Umschalten).
    func slice<T>(of items: [T]) -> ArraySlice<T> {
        guard !items.isEmpty else { return items[items.startIndex..<items.startIndex] }
        let safeStart = min(max(0, start), items.count)
        let safeEnd = min(max(safeStart, end), items.count)
        return items[safeStart..<safeEnd]
    }
}
