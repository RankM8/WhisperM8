import Foundation

/// Reine Planungslogik für `list`/`overview`: entscheidet, WIE VIELE Sessions
/// überhaupt geprobt werden müssen, bevor das Limit greift.
///
/// Hintergrund (Perf-Befund 2026-07-25): `list` hat bisher ausnahmslos ALLE
/// Sessions des Scopes geprobt (`ChatsStatusProbe.probeAll` = stat + ggf.
/// Tail-Read pro Session) und danach im JSON-Pfad zusätzlich pro Ergebnis eine
/// Transcript-Vorschau gelesen — auch wenn am Ende 50 Zeilen ausgegeben
/// wurden. Bei ~2.700 Sessions kostete eine simple Agenten-Abfrage damit
/// mehrere Sekunden und ~2,3 MiB JSON.
///
/// Die Probe ist nur dann ergebnis-RELEVANT, wenn der Runtime-Status das
/// Ergebnis-Set oder dessen Reihenfolge bestimmt (`--status`, `--attention`,
/// `--sort attention`, Board-Format). Sonst entscheidet allein
/// `lastActivityAt` — dann kann vor dem Proben sortiert und limitiert werden.
///
/// Bewusst pur (kein I/O, keine Uhr) — die Reihenfolge-Entscheidung ist der
/// eigentliche Perf-Hebel und muss unit-testbar bleiben.
enum ChatsListPlanner {
    struct Plan: Equatable {
        /// Die Sessions, die tatsächlich geprobt werden.
        var candidates: [ChatsSessionEntry]
        /// Anzahl der Sessions im Scope VOR dem Limit — Grundlage der
        /// „Zeige N von M"-Meldung und des `totalInScope`-Feldes im JSON.
        var totalInScope: Int
        /// `true` = das Limit greift erst NACH Probe/Attention-Aufbau, weil
        /// der Runtime-Status das Ergebnis-Set mitbestimmt.
        var limitAfterProbe: Bool
        /// `true` = es wurden Sessions vor der Ausgabe abgeschnitten.
        var truncated: Bool
        /// `true` = die Attention-Zähler decken den vollen Scope ab. Im
        /// Fast-Path (vorab limitiert) beziehen sie sich nur auf die
        /// ausgegebenen Zeilen und dürfen nicht als Lagebild gelten.
        var countsCoverFullScope: Bool
    }

    /// `true`, wenn der Runtime-Status das Ergebnis-Set oder die Sortierung
    /// beeinflusst — dann ist Proben vor dem Limit unvermeidbar.
    static func requiresFullProbe(options: ChatsListOptions) -> Bool {
        options.status != nil
            || options.attentionOnly
            || options.sort == "attention"
            || options.format == "board"
    }

    /// - Parameter entries: bereits nach Scope/Projekt/Mitgliedschaft
    ///   gefilterte Sessions (reine Metadaten-Filter, kein Runtime nötig).
    static func plan(entries: [ChatsSessionEntry], options: ChatsListOptions) -> Plan {
        let total = entries.count

        guard !requiresFullProbe(options: options) else {
            return Plan(
                candidates: entries,
                totalInScope: total,
                limitAfterProbe: true,
                truncated: false,
                countsCoverFullScope: true
            )
        }

        // Fast-Path: Ergebnis-Set und Reihenfolge stehen allein über
        // `lastActivityAt` fest → vorsortieren und kürzen, bevor irgendein
        // Dateizugriff passiert.
        let sorted = entries.sorted { $0.session.lastActivityAt > $1.session.lastActivityAt }
        guard options.limit > 0, sorted.count > options.limit else {
            return Plan(
                candidates: sorted,
                totalInScope: total,
                limitAfterProbe: false,
                truncated: false,
                countsCoverFullScope: true
            )
        }
        return Plan(
            candidates: Array(sorted.prefix(options.limit)),
            totalInScope: total,
            limitAfterProbe: false,
            truncated: true,
            countsCoverFullScope: false
        )
    }
}
