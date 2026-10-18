---
status: aktiv
updated: 2026-10-17
description: CPU-Last unter Betrieb (45–87 % App, ~50 % WindowServer) — Ursachen mit Datei/Zeile, Lösungen nach Nutzen. Grundlage 5-s-Sample vom 17.10.2026 (Build vom 11.10.), Code-Stand main 001ce26.
---

# CPU-Last unter Betrieb

**Messung:** `sample` der laufenden App (5 s, 1976 Samples je Thread) am 17.10.2026 um 19:58.
Rohdaten: `/private/tmp/claude-501/-Users-giulianocosta-Downloads/wm8-perf-2026-10-17/`.
Lage beim Sample:
- 5 Chats `working`, 12 offene Sessions.
- Mac voll ausgelastet: Load ~70 auf 8 Kernen, 12,8 GB Swap.

Gesampelt wurde der installierte Build vom 11.10. Alle Ursachen bestehen im aktuellen Code (main `001ce26`) weiter. Die Status-Punkte sind durch `e8e8d12` eher schlechter geworden. Nur gelesen, nichts geändert.

## Übersicht nach Nutzen

| Rang | Register | Ursache | Gewinn (geschätzt) | Aufwand | Wen betrifft es |
|---|---|---|---|---|---|
| 1 | LR-AK-033 | Session-Indexer parst wachsende Transcripts bei jedem Scan neu, langsamer Titel-Scan, FSEvent-Dauerschleife | ein Kern von 100 % auf < 5 % | S–M | alle mit Agent Chats |
| 2 | LR-AU-002 | Dauer-Pulse der Status-Punkte halten die Layout-Schleife des ganzen Fensters am Laufen | bis ~30 % Main-Thread, dazu WindowServer | S | alle mit Agent Chats |
| 3 | LR-GPT-008 | Mix-Router parst jeden Request-Body 3–4× vollständig | ~65–70 % der Router-CPU | S–M | nur GPT-Backend (Labs) |
| 4 | LR-AU-003 | Ressourcen-Anzeiger forkt alle 10 s `ps -ax` und zusätzlich bei jedem Statuswechsel | Systemlast (Fork), kaum App-CPU | S | alle mit laufenden Chats |

## 1 · Session-Indexer (LR-AK-033)

**Beleg:** Ein Utility-Thread lag 100 % der 5 s in `parseSessionFile`, das sind 1958 Samples:
- `NativeSessionTitle.claudeTitle`: 1357 Samples, fast alles in `StringProtocol.contains` (`NativeSessionTitle.swift:52-53`).
- `BoundedJSONLReader.lines` (String-`split` über 1 MB): 536 Samples.

Log der laufenden App:

| Scan | Dauer | Gelesen |
|---|---|---|
| Claude-Scan | 12,9 s | nur 5 Dateien, je genau 1 MB |
| Gesamt-Scan (Grund `fsEvent`) | 15,3 s | |

**Ursache:**
- **Cache verfehlt aktive Dateien:** Der Cache (`agent-session-index-cache.json`) prüft Pfad, Größe und mtime (`AgentSessionIndexer.swift:60-67`). Ein wachsendes Transcript verfehlt ihn bei jedem Scan. Dann wird der unveränderte Kopf (1 MB bzw. 200 Zeilen, `ClaudeSessionIndexer.swift:149`) komplett neu geparst, und das dauert etwa 2,5 s pro Datei.
- **Zeichenweise Suche:** Die Titelsuche läuft zeichenweise über `Substring.contains`, einmal in `ClaudeSessionIndexer.swift:179` und einmal in `NativeSessionTitle.swift:52`.
- **Kopf doppelt verarbeitet:** Pro Zeile per `JSONSerialization` und noch einmal über `lines.joined` (Z. 187).
- **FSEvent-Dauerschleife:** `AgentDirectoryEventMonitor.swift:42-128` wertet keine Event-Flags aus. Jede Änderung eines Transcripts, das nicht beobachtet wird, stößt einen Scan an. Dazu gehören externe Sessions, andere Profile und `--bg`. Ablauf: 5 s Ruhe, Scan, 10 s Cooldown, nächster Scan.
- **Nebenbefund:** `agent_index_merge updates=1055` bei jedem Scan auf dem MainActor (`AgentScanCoordinator.swift:187`), obwohl nur 5–8 Dateien neu sind.

**Lösung (nach Nutzen):**

| Maßnahme | Was | Gewinn | Aufwand | Risiko |
|---|---|---|---|---|
| A | Parse-Kern auf Bytes umstellen: Zeilen per `memmem` vorfiltern, nur Treffer an `JSONSerialization`, keine doppelte Verarbeitung. Gleiche Semantik (custom > ai > erster Prompt). Der Auto-Namer profitiert mit. | ~90 % je Parse | S–M | — |
| B | Kopf gilt als fertig, wenn das Fenster beim letzten Parse voll war (Flag im Cache, Schema 3→4). Bei Wachstum nur `lastActivityAt`, Größe und mtime nachziehen. | ~95 % des Befunds | S | Umschreiben am Dateianfang mit größerer Datei (selten). Abhilfe: Vergleich der ersten 4 KB. |
| C | FSEvents nur bei `ItemCreated`/`ItemRenamed` bzw. für Pfade, die nicht im Cache stehen. | Dauerschleife weg | S | Externe Session, die nur wächst, taucht nicht auf. Neue Sessions sind ohnehin Created. |
| D | Cooldown abhängig von der Scandauer (≥ 3 × Dauer) als Sicherheitsnetz. | — | S | — |

Empfehlung: A + B zusammen, C danach.

## 2 · Dauer-Pulse der Status-Punkte (LR-AU-002)

**Beleg:** Der Main-Thread ist zu 53 % belegt. Etwa 640 Samples davon sind Layout und Render des ganzen `NSHostingView`, verteilt auf viele Frames. Dazu kommen 714 Samples `CA::Transaction::commit`.
- SwiftTerm macht unter 3 % aus.
- Es gibt keinen `body.getter` einer WhisperM8-View. Neu ausgewertet werden also keine Bodies, sondern der Frame-Abgleich (`DisplayList.ViewUpdater`).
- Aktive `RepeatAnimation`/`AnimatableAttribute` im Graph.

**Ursache, stark nahegelegt, Gegenprobe steht aus:**
- `PulsingDot` (`Views/AgentStatusIndicator.swift:59-62, ~100-108`) läuft mit `repeatForever` je arbeitendem Chat. Er sitzt in der Sidebar-Zeile, in der angepinnten Zeile und seit `e8e8d12` (17.10.) auch in jedem Kachelkopf (`AgentChatChromeViews.swift:565` → `AgentChatsView+Grid.swift:902`).
- Dazu kommt `SubagentRoad` mit `TimelineView(.animation(minimumInterval: 1/30))` (`AgentChatsSidebarViews.swift:630`).
- Jede Dauer-Animation hält die Frame-Schleife des Fensters am Laufen. Jeder Frame gleicht die ganze Display-List ab, und der WindowServer komponiert mit.

**Lösung:**

| Maßnahme | Was | Gewinn | Aufwand | Risiko |
|---|---|---|---|---|
| 1 | Erst A/B-Messung mit Schalter „Pulse aus“, dann den Puls bei `working` statisch oder einmalig beim Wechsel. Kachelkopf und Tab ohne Puls. | bis ~30 % Main-Thread | S | — |
| 2 | `SubagentRoad` auf langsamen Takt oder statisch. | — | S | — |
| 3 | Animationen nur im sichtbaren, aktiven Fenster (`occlusionState`). | — | M | — |
| 4 | Dynamische Farbe in `AgentChatsWindowAccessor.swift:54` statisch machen. | ~0,5 % | S | — |

Achtung, Projektregel [[kein-hover-only-ui]]: Der Zustand bleibt sichtbar. Nur die Dauerbewegung entfällt.

## 3 · Mix-Router (LR-GPT-008)

**Beleg:** Drei Router-Threads, etwa 2100 Samples reines `_NSJSONReader parseData`, etwa 500 Samples Kopieren. Unter Swap entfällt ein Großteil davon auf `vm_copy`.

**Ursache:** `ClientConnection.forward` (`ClaudeGPTMixRouter.swift:873ff`) parst den ganzen Body mehrfach:
- Z. 890 `resolvingAutoModel`
- Z. 891 `model(in:)`
- Z. 892 `upstream(for:)` → `model(in:)`
- bei `gpt-*` zusätzlich `sanitizingToolSchemas` (Z. 440ff)

Das gilt auch für reine `claude-*`-Durchreichungen. Dazu kommen volle Kopien (`Data(buffer.prefix)`, `httpBody`). Außerdem kostet `HTTPURLResponse.allHeaderFields` pro Response 652 Samples (Z. 999ff). Der Router läuft nur bei aktivem GPT-Backend (Labs).

**Lösung:**

| Maßnahme | Was | Gewinn | Aufwand | Risiko |
|---|---|---|---|---|
| 1 | `model` einmal per Byte-Scan des Top-Level-Felds bestimmen, Fallback auf Parse. | ~65–70 % | S–M | — |
| 2 | Sanitizer nur bei `gpt-*` und Substring `\p{`/`\P{`. | — | S | — |
| 3 | Kopien vermeiden (`reserveCapacity`, kein Zwischenpuffer). | ~20 % | S | — |
| 4 | Gezielte Header-Lookups statt `allHeaderFields`. | — | S | — |

## 4 · Ressourcen-Anzeiger (LR-AU-003)

**Beleg:** 831 Samples in `snapshot`, davon 792 Warten in `readDataToEndOfFile`. Das ist Wartezeit auf den `ps`-Kindprozess, keine CPU der App. Die CPU fällt im Kindprozess an.

**Ursache:**
- `AgentResourceMonitor.currentProcessSamples()` (~Z. 150) forkt `/bin/ps -axo …` über **alle** Prozesse des Systems. Das läuft alle 10 s, bei offenem Popover alle 2 s (`AgentResourceSummaryButton.swift:59-75`).
- Zusätzlich läuft es bei jedem `onChange(of: descriptors)` (Z. 55-58), also bei jedem Status- und Titelwechsel.
- Off-main, pausiert bei inaktivem Fenster.

**Lösung:**

| Maßnahme | Was | Aufwand |
|---|---|---|
| sofort | `ps -p <Chat-PIDs>` plus Kinder, `onChange` entprellen, Badge-Takt 30 s. | S |
| sauber | `proc_listchildpids` + `proc_pidinfo` ohne Fork. | M |

Nicht launch-kritisch.

## Einordnung für den Launch

- **Rang 1 und 2 betreffen jeden Nutzer mit Agent Chats.**
  - Auf einem normalen Laien-Mac mit weniger Last sind die absoluten Zahlen kleiner.
  - Der Mechanismus bleibt aber gleich: Dauerscans bei wachsenden Transcripts, Frame-Schleife bei jedem arbeitenden Chat.
  - Beide sind billig zu beheben und gehören in die erste Performance-Welle.
- **Rang 3** betrifft nur Labs.
- **Rang 4** ist Politur.

Umsetzung erst nach Freigabe durch den User.
