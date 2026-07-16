# Transcript-Feed: Performance-Härtung & Ziel-Architektur

**Stand:** 2026-07-16 · **Status:** Stufe 1+2 UMGESETZT (Render-Deckel v2.11.1, Sliding-Window + Topologie-Budgets danach), Stufe 3-5 OFFEN
**Quellen:** Apple-Hang-Report 2026-07-16 (186 s Hang, `WhisperM8_2026-07-16-204657.hang`, v2.10.0) + zwei Codex-Analyse-Jobs (`d5252179` Root-Cause read-only, `f172aed9` Architektur read-only).

## Root-Cause (belegt)

Der Hang war ein CPU-gebundener SwiftUI-Layout-Pass (41/41 Stackshot-Samples in EINER
ViewGraph-Transaktion: `GeometryReaderLayout.placeSubviews → StackLayout.sizeThatFits`-Rekursion,
`LazyLayoutViewCache.updateItemPhases`). Drei Strukturursachen:

1. **Additiv wachsendes, bottom-verankertes Fenster:** `visibleCount` wuchs pro
   „frühere anzeigen"-Klick und wurde nie kleiner; `.defaultScrollAnchor(.bottom)` lässt
   Höhenkorrekturen beim Hochscrollen auf den gesamten verankerten Inhalts-Extent zurückwirken.
2. **Grobe Lazy-Granularität:** Eine LazyVStack-Zeile = ganze Runde; darunter alles eager
   (Antworten → Markdown-Blöcke → Listen/Tabellen-Grid-Zellen → Steps) — View-Anzahl pro Zeile
   war unbegrenzt (Zeichen-Caps von v2.11.1 deckeln nur Text-GRÖSSE).
3. **Proposal-Kaskade:** fensterweiter `GeometryReader` (`AgentChatsView.swift:444`, Grid:
   `AgentGridSplitContainer.swift:58`) + `frame(maxWidth:)`-Ketten + verschachtelte flexible
   Stacks → wiederholtes `sizeThatFits` bis in die Blätter.

## Umgesetzt

- **v2.11.1 (`6e29514`):** Zeichen-Render-Deckel (Prompt 12k/Markdown 40k/Roh 20k), NSCache für
  Markdown-Parse + Inline-AttributedStrings, statischer DateFormatter, Nachlade-Fenster-Cap 32 MiB.
- **Sliding-Window + Topologie-Budgets:** `TranscriptWindow` (pur, `TranscriptWindowTests`) mit
  harter Obergrenze (Timeline max. 160 Runden, Roh max. 600 Messages gleichzeitig im Render-Baum);
  Blättern verschiebt das Fenster (Anker-Restore via `ScrollViewReader.scrollTo`), „Zu den
  neuesten …"-Pill für den Rücksprung; Kopf- vs. Tail-Wachstum via Erste-Item-Identität.
  Budgets: max. 200 Markdown-Blöcke/Antwort, 200 Listen-Items, Tabellen > 120 Zeilen oder
  > 16 Spalten → Monospace-Fallback, max. 80 Roh-Blöcke/Message (`TranscriptRenderLimits`).

Damit ist die Layout-Arbeit pro Pass hart gedeckelt: O(maxFenster × Budget) statt O(unbegrenzt).

## Offene Ziel-Architektur (Codex-Empfehlung: Option B+D — kein List/NSTableView-Umbau)

3. **Flaches Feed-Modell (M):** Render-Item = Prompt | Aktivitäts-Summary | einzelner
   Markdown-Block (statt ganze Runde) mit stabilen IDs + Revisionswerten; Breite EINMAL am Feed
   statt 660→560/460-Ketten; `textSelection` am Container. Neu: `TranscriptRenderItem` +
   `TranscriptRenderItemBuilder` (off-main, wie TimelineBuilder).
4. **Bottom-Anker ersetzen (M/L):** `.defaultScrollAnchor(.bottom)` → einmaliges
   `scrollTo(bottomSentinel)` + Follow nur wenn User am Ende (Bottom-Sentinel-Sichtbarkeit);
   „Neue Aktivität"-Indikator statt Auto-Yank. Sprungfreies Prepend via kleinem
   NSViewRepresentable-Messadapter am NSScrollView (Bounds vor/nach Prepend).
5. **Echte JSONL-Seiten (L):** feste rückwärts gelesene Byte-Seiten + Append-Cursor für
   Live-Zeilen statt ×4-Tail-Rereads; IDs aus stabilen Zeilen-Offsets. Macht den 32-MiB-Cap
   obsolet. Vorher Mess-Gates definieren (Signposts: Main-Thread-Spitze < 50 ms bei
   Scroll/Prepend, konstante Row-Anzahl).

`SwiftUI List`/NSTableView (Optionen A/C) nur als Spike, falls die Mess-Gates nach Stufe 5
scheitern — `List` garantiert kein kontrollierbares Bottom-Following/Prepend, NSTableView
kostet eine zweite Rendering-Schicht für Markdown/Selektion/Expansion.
