# Plan: Jarvis-Randnotizen — Notiz-Karte am Kachelkopf

**Stand:** 2026-10-17 · **Status:** Slices 1–5 umgesetzt, manuelle QA nach `make dev` offen · **Scope:** Jarvis-Board (Datenmodell, Socket, CLI, Mod/Tool), Grid-Workspace (Kachelkopf), Jarvis-Skill
**Bezug:** `docs/features/jarvis-board.md` (Board `wm8.board/1`, Mod), `docs/plans/whisperm8-plugin.md`.
**Entwurf:** `docs/design/randnotiz-karte.html` (klickbar, verbindlich für Verhalten und Form), Bildrunden in
`docs/design/imagegen-randnotizen/` und `…/runde-2/` (nur Stilreferenz; die zweite Notizzeile darin ist verworfen).

## Ziel

Im Grid-Workspace sieht der User an jedem Chat, den Jarvis betreut, auf einen Blick: **woran der Chat
arbeitet, wozu, was zuletzt fertig wurde und ob er gebraucht wird**, ohne in den Chat zu gehen.
Die Notiz hängt als aufklappbare Karte direkt am Kachelkopf (Chat-Name), Jarvis schreibt sie.

## Entscheidungen (User, 17.10.2026)

| Nr | Entscheidung |
|---|---|
| E1 | **Nur Jarvis steuert.** Eine Notiz hat nur, wer auf dem Board einer aktiven Jarvis-Session steht. Ohne Jarvis gibt es keine Notizen und keine App-Automatik, die welche erzeugt. Kein eigener „Bot“: Jarvis ist der Schreiber. |
| E2 | **Karte am Kachelkopf**, keine zweite Notizzeile darunter. Form = umgedrehte `ChromeTabShape` (konkave Füße oben 7 px, Ecken unten 7 px), Grau des Kopfes fließt in die Karte, die Haarlinie unter dem Kopf ist dort unterbrochen. Die Karte liegt über dem Terminal, das Terminal wird nicht verschoben (kein PTY-Resize). |
| E3 | **Schalter „Notizen auf/zu“** = Standard für alle Notizen; Klick auf einen Kachelkopf klappt nur diesen Chat. Ort: Workspace-Leiste neben dem Kapazitäts-Picker, dazu ⌥⌘N. |
| E4 | **In einen Chat gehen klappt dessen Notiz zu.** Beim Verlassen folgt sie wieder dem Standard. Sonst keine Automatik (auch kein Selbst-Aufklappen bei „wartet auf dich“). |
| E5 | **Grober Inhalt, keine Mikro-Updates.** Arbeitspaket-Ebene statt Einzelschritte, kein „live“-Feld, Jarvis schreibt nur bei Ereignissen, nie nach der Uhr. |
| E6 | **`work` ersetzt `next`** (Board-Band zeigt dann ebenfalls das Arbeitspaket). |
| E7 | **Drei Meilensteine** sichtbar, ältere hinter „▸ ältere“. |
| E8 | **Claudes Rückblick als Lesehilfe** für Jarvis über die CLI. |

Offen, mit Empfehlung (nicht beantwortet): Gilt der Schalter für alle Workspaces gemeinsam oder pro
Workspace? **Empfehlung: gemeinsam** (eine Einstellung, App-weit).

## Ausgangslage

- **Board vorhanden:** `JarvisBoardStore.swift` mit `JarvisBoardEntry { sessionID, light, mission, needs, next, updatedAt }`,
  Datei `Application Support/WhisperM8/jarvis-board.json`, Schema `wm8.board/1`. Die App ist einziger Schreiber
  (`AgentControlRequestHandler+Board.swift`, Methoden `board.set|remove|clear|activate|deactivate`), jede
  Änderung ist ein Journal-Ereignis (`kind: "board"`). Texte werden auf 160 Zeichen gekürzt und einzeilig gemacht
  (`JarvisBoardLogic.sanitized`).
- **Vertrag:** `ChatsBoardCommand.swift` hält fest „Felder nur ergänzen, nie umbenennen“, weil die Mod
  (`Resources/claude-plugin/hooks/register.tsx`) das JSON liest. Die Mod zeigt im Band `e.next || e.mission`
  (bzw. `needs` bei `needsYou`), im Panel Auftrag/Braucht/Weiter; das Tool `mcp__whisperm8__board` kennt
  `mission`, `needs`, `next`.
- **App-UI kennt das Board nicht:** Keine View liest `JarvisBoardStore`. Der Kachelkopf ist
  `gridPaneHeader(…)` in `Views/AgentChatsView+Grid.swift`, Fokus = `session.id == selectedSession?.id`.
  Die Workspace-Leiste ist `gridWorkspaceStatusRow(entity:)` (Name, „N/M belegt“, Kapazitäts-Picker).
- **Tab-Form vorhanden:** `ChromeTabShape` + `ChromeTabMetrics.footSize = 7` in `Views/AgentChatChromeViews.swift`.
- **Claudes Rückblick:** Claude Code schreibt bei Abwesenheit des Users Einträge
  `{"type":"system","subtype":"away_summary","content":"Ziel ist … Zuletzt … Als Nächstes …"}` ins Transcript
  (geprüft an echten Sessions, bis zu 19 pro Session). Nicht dokumentiert, abschaltbar in `/config`, Codex hat
  nichts Vergleichbares. Heute liest niemand diese Einträge.

## Inhaltsregeln (gehen wörtlich in den Jarvis-Skill)

| Feld | Inhalt | Ändert sich | Gut | Zu detailliert |
|---|---|---|---|---|
| `mission` (Ziel) | Auftrag des Chats, ein Satz | nur bei Missionswechsel (dann auch Name) | „Intro-Qualität der Lead-Mails verbessern“ | – |
| `work` (Arbeitspaket, fetter Satz oben) | Ergebnis, das in 30 min bis wenigen Stunden fertig wird | erst, wenn das Paket fertig ist / ein neues beginnt | „Baut die letzte Variante der Lead-Ansicht (L22)“ | „Macht Screenshots“, „liest Datei X“, „führt Tests aus“ |
| `milestones` | nur Ergebnisse: Commit, Tests grün, Entscheidung gefallen, Blocker gelöst, übergeben | wenn eins erreicht ist | „Intro-Regeln gelockert, 1.090 Tests grün, committet“ | „Bash ausgeführt“ |
| `needs` (Eingriff) | nur bei `needsYou`: Frage/Entscheidung an den User | entsteht / erledigt | „Entscheidung: Ticket mit Eli erstellen“ | – |
| `blocker` | was den Chat aufhält, ohne dass der User gefragt ist | entsteht / erledigt | „Wartet auf Staging-Deploy von Sam“ | – |

- **Faustregel:** Würde sich der Satz in 10 Minuten wieder ändern, ist er zu detailliert.
- **Schreibzeitpunkt:** nur wenn Jarvis ohnehin geweckt wird (Turn-Ende oder „wartet“ eines Board-Chats, die Mod
  bündelt auf höchstens einen Prompt pro Minute) und nur, wenn sich `work`, ein Meilenstein, `needs` oder
  `blocker` geändert hat. Höchstens ein `set` und ein `milestone` je Chat und Weckruf. Nie zeitgesteuert.
- **Lesen:** zuerst `chats show <ref> --recap` (Slice 3), erst bei Bedarf den Tail.
- **Erwartung:** ein bis drei Änderungen pro Chat und Stunde.

## Datenmodell (additiv, Schema bleibt `wm8.board/1`)

```jsonc
{
  "sessionID": "…", "light": "running", "updatedAt": "…",
  "mission": "Intro-Qualität der Lead-Mails verbessern",
  "work": "Schließt die Intro-Regeln ab: Push von ListM8 und Plugin",   // neu
  "next": "Schließt die Intro-Regeln ab: Push von ListM8 und Plugin",   // Alias = work (Kompatibilität)
  "needs": "",
  "blocker": "",                                                        // neu
  "milestones": [                                                       // neu, neueste zuerst, max. 20
    { "at": "2026-10-17T13:20:00Z", "text": "Intro-Regeln gelockert, 1.090 Tests grün, committet" }
  ]
}
```

- **`work` statt `next` (E6) ohne Bruch:** Beim Lesen gilt `work = work ?? next`. Beim Schreiben setzt die App
  beide Felder gleich, damit ältere Mods und CLI-Binaries weiter funktionieren. `--next` bleibt als Alias für
  `--work` erhalten (Hilfetext: veraltet). Entfernen von `next` frühestens, wenn keine alte Mod mehr läuft —
  eigener Schritt, nicht in diesem Plan.
- **Meilensteine:** Die App setzt `at` (nie der Aufrufer), kürzt `text` wie die übrigen Felder, verwirft einen
  Eintrag, der wörtlich dem neuesten gleicht, und behält die 20 neuesten. `set` ändert Meilensteine nie.
- **Neue Operation `milestone`** (`board.milestone`, Journal-Signal `board.milestone`). Steht der Chat noch nicht
  auf dem Board, schlägt sie fehl (`not_on_board`), statt still einen Eintrag anzulegen.
- **`remove`** löscht den Eintrag samt Meilensteinen (Notiz verschwindet).

## Slice 1 — Datenmodell, Store, Socket, CLI

**Änderungen**
- `JarvisBoardEntry`: `work`, `blocker`, `milestones: [JarvisBoardMilestone]`; tolerantes Decoding (fehlend = leer,
  `work` fällt auf `next` zurück); Encoding schreibt `next = work`.
- `JarvisBoardPatch`: `work`, `blocker`; `next` im Parser auf `work` abbilden.
- `JarvisBoardLogic`: `appendMilestone(_:owner:sessionID:text:now:)` (Dedupe, Kappung 20), `sanitized` für neue Felder.
- `AgentControlRequestHandler+Board.swift`: `board.milestone` in `boardMethods`, gleiche Owner-/Token-Prüfung.
- `ChatsBoardCommand.swift`: `set … --work … --blocker …`, neu `milestone <ref> "<text>"`; Lese-Ausgabe (Text und
  `--json`) mit `work`, `blocker`, `milestones`. `AgentChatsCLICommand.swift`: Hilfetext.

**Tests** (`JarvisBoardTests`, CLI-Parser-Tests)
- Alte Datei ohne neue Felder lädt; `next` wird zu `work`; Schreiben erzeugt beide Felder.
- `milestone`: Zeitstempel von der App, Dedupe, Kappung bei 20, Fehler `not_on_board`, `changed == false` bei Dublette (kein Journal-Ereignis).
- Parser: `--work`, `--blocker`, `--next` als Alias, `milestone` mit fehlendem Text → Fehler.
- Owner-Prüfung für `board.milestone` wie für `board.set`.

## Slice 2 — Mod und Tool

- `register.tsx`: Tool-Schema um `work`, `blocker` und `action: milestone` (+ `text`) erweitern, Beschreibung auf die
  Inhaltsregeln kürzen („Arbeitspaket, keine Einzelschritte“). Band zeigt `e.work || e.next || e.mission`. Panel
  (`/board`): Ziel, Arbeitspaket, Braucht, Blockade, letzte drei Meilensteine.
- `board.test.ts`: Band mit `work`, Rückfall auf `next`, Panel mit Meilensteinen.
- `make plugin-test` grün.

## Slice 3 — Claudes Rückblick als Lesehilfe (E8)

- `ClaudeTranscriptReader`: Rückblicke (`type == "system"`, `subtype == "away_summary"`) aus dem Tail lesen
  (begrenzte Bytes wie `readTail`, kein Vollscan), neueste zuerst, mit Zeitstempel; Endung „(disable recaps in /config)“ abschneiden.
- CLI: `whisperm8 chats show <ref> --recap [--json]` liefert die letzten drei Rückblicke. Codex-Chats und Chats ohne
  Rückblick: leere Liste plus Hinweis, kein Fehler.
- Fail-soft: unbekanntes oder fehlendes Format → leer. Das Feld ist inoffiziell und darf nie etwas brechen.
- Tests mit Fixture-JSONL (mehrere Rückblicke, abgeschnittene letzte Zeile, Codex-Datei, kein Rückblick).

## Slice 4 — App-UI: Notiz-Karte im Grid

**Daten in die UI**
- Neu `JarvisNotesUIModel` (`@MainActor`, `@Observable`): Projektion `sessionID → Notiz` aus allen **aktiven** Boards;
  steht ein Chat auf mehreren, gewinnt der zuletzt geänderte Eintrag. Gefüttert beim Start (einmal laden) und nach
  jeder erfolgreichen Board-Mutation im Handler (die App ist einziger Schreiber, also kein Datei-Beobachter nötig).
- Pro Kachel nur der eigene Eintrag beobachtet (Muster `statusPublisher(for:)`), damit eine Änderung nicht das ganze
  Grid neu auswertet (Regel aus der Sidebar-Messung). Kein I/O und kein `.contextMenu` im Karten-Body.

**Aufklapp-Logik (pur, unit-getestet)**
- `JarvisNoteExpansion.isOpen(hasNote:, override:, isFocused:, defaultOpen:)`: keine Notiz → zu; Override gesetzt → Override;
  fokussiert → zu; sonst Standard.
- Overrides ephemer pro Fenster (`AgentWindowStore`, nicht persistiert). Fokuswechsel löscht den Override der
  verlassenen und der betretenen Kachel (E4). Umschalten des Standards löscht alle Overrides.
- Standard `jarvisNotesDefaultOpen` in `AppPreferences` (Empfehlung: App-weit), Default `true`.

**Darstellung**
- `gridPaneHeader`: Chevron rechts neben dem Konto-Badge, nur wenn eine Notiz existiert; Klick auf den Kopf klappt
  (Doppelklick bleibt Maximieren, Drag-Quelle bleibt der Kopf). `needsYou` färbt nur den Status-Punkt, kein Selbst-Aufklappen.
- Karte als `.overlay(alignment: .topLeading)` unter dem Kopf, ~72 % Kachelbreite (max. 420 pt), 10 pt Einzug;
  Form `HangingNoteShape` = umgedrehte `ChromeTabShape` mit `ChromeTabMetrics.footSize`; Füllung `AgentTheme.header`,
  Umriss `AgentTheme.borderStrong`, flach; die Kopf-Haarlinie wird unter der Karte ausgespart.
- Inhalt in dieser Reihenfolge: `work` fett (+ Alter), Eingriff-Box rot (`needs`), Blockade-Box bernstein (`blocker`),
  ZIEL, MEILENSTEINE (drei, dann „▸ ältere“ klappt innerhalb der Karte), Fußzeile „Aktualisiert HH:MM · Jarvis“.
- Animation: Aufklappen von oben (~0,25 s, ease-out), Inhalt blendet leicht verzögert ein; respektiert „Bewegung reduzieren“.
- Workspace-Leiste: Knopf „Notizen auf/zu“ links neben dem Kapazitäts-Picker; ⌥⌘N. Nur sichtbar, wenn mindestens ein
  Chat des Workspaces eine Notiz hat.
- Einzelansicht und maximierte Kachel: keine Karte (dort ist der Chat ohnehin fokussiert).

**Tests**
- `JarvisNoteExpansionTests` (alle Kombinationen, Fokuswechsel, Standard umschalten).
- `JarvisNotesUIModelTests` (inaktive Boards ignoriert, Mehrfach-Board, `remove` entfernt Notiz).
- `HangingNoteShape`: Pfad schließt an Kopf-Unterkante an, Füße tangential (wie `ChromeTabShape`-Tests).
- Snapshot-Fixture in `UISnapshotGallery.swift` (offen, zu, `needsYou`, Blockade, ohne Notiz), `make snapshots`
  hell + dunkel ansehen.

**Kill-Switch:** `defaults write com.whisperm8.app jarvisNotesEnabled -bool NO` (keine Karten, kein Knopf; Board unberührt).

## Slice 5 — Jarvis-Skill und Doku

- `Resources/whisperm8-jarvis-skill.md`, Abschnitt 6: Felder `mission`/`work`/`needs`/`blocker`/`milestone`,
  Inhaltsregeln und Schreibzeitpunkt aus diesem Plan, Beispiele gut/zu detailliert, Lesen per `show --recap`.
- `Resources/whisperm8-chats-skill.md`: neue Befehle und Flags.
- `docs/features/jarvis-board.md`: Abschnitt „Randnotizen“ (Datenfluss, Aufklapp-Regeln, Kill-Switch).
- `CLAUDE.md`: eine Zeile im Jarvis-Board-Absatz.

## Abnahme (manuell nach `make dev`, macht der User)

1. Jarvis setzt `work` und einen Meilenstein für einen Chat → Karte erscheint an dessen Kachel, Band zeigt dasselbe Arbeitspaket.
2. In die Kachel klicken → Karte klappt zu; andere Kachel anklicken → klappt wieder auf (bei Standard „auf“).
3. „Notizen zu“ → alle zu; einzelne per Kopf öffnen; Standard wieder „auf“ → alle offen.
4. Jarvis-Board deaktivieren → alle Karten und der Knopf verschwinden.
5. Eine Stunde normaler Betrieb: Notizen ändern sich nur bei Ergebnissen, nicht bei jedem Turn.

## Risiken

- **Jarvis führt nicht nach** → Notiz veraltet. Gegenmittel: Alter sichtbar („Aktualisiert 13:20“), Regeln im Skill;
  kein automatisches „veraltet“-Etikett (wäre Automatik, E1).
- **Viele offene Karten verdecken Terminaltext** → Standard „zu“ per Schalter; Karte max. ~45 % der Kachelhöhe, darüber scrollt sie.
- **Inoffizielles `away_summary`** kann sich ändern → nur Lesehilfe, fail-soft, nie in der UI angezeigt.
- **Alte Mod/CLI** schreibt `next` → Alias-Regel hält beide Felder gleich.
- **Token-Kosten bei Jarvis:** zusätzliche Tool-Aufrufe nur bei Änderungen; erwartbar wenige pro Stunde und Chat.

## Nicht Teil dieses Plans

Notizen in der Sidebar, in der Einzelansicht oder an Tabs; Selbst-Aufklappen bei „wartet auf dich“; von der App
erzeugte Notizen ohne Jarvis; Rückblicke für Codex; Entfernen des `next`-Felds.

## Reihenfolge und Aufwand (grob)

1. Slice 1 (klein) → 2. Slice 2 (klein) → 3. Slice 3 (klein) und Slice 4 (mittel) parallel möglich → 4. Slice 5 (klein).
Slice 4 baut auf dem HTML-Entwurf auf; vor dem Swift-Bau keine weitere Bildrunde nötig.

## Umsetzungsstand (17.10.2026)

Alle fünf Slices gebaut und getestet (volle Suite 2997 Tests grün, Mod-Tests 18/18); Abweichungen vom Plan:

- **Owner muss leben:** Notizen erscheinen nur, solange die Jarvis-Session des
  Boards läuft (Live-Status arbeitet/wartet/ruht) — sonst stünden nach dem
  Schließen von Jarvis veraltete Karten im Grid. Die Projektion beobachtet dafür
  den Status jedes Owners (`JarvisNotesStore`).
- **Kein `JarvisNotesUIModel` mit `@Observable`:** Die Kachelköpfe sind
  Funktionen im Body von `AgentChatsView`; Notizen und Handklicks kommen deshalb
  über Publisher je Session (`JarvisNotesStore`), die Handklicks liegen dort
  statt im `AgentWindowStore`.
- **Einzeln klappen per Pfeil**, nicht per Klick auf den ganzen Kopf: Ein
  einfacher Klick auf den Kopf fokussiert schon die Kachel, ein Doppelklick
  maximiert.
- **⌥⌘N** über den Tasten-Monitor des Fensters (greift auch bei Fokus im
  Terminal), nicht als `.keyboardShortcut`.
- **Rückblick:** Rückwärtssuche nach dem Merkmal statt festem Tail-Fenster —
  der jüngste Rückblick lag im Feld 1,1 MB vor dem Ende einer 172-MB-Datei.
- **Zusätzlich (Wunsch des Users während der Umsetzung):** Status-Punkt im
  Chat-/Kachelkopf und am Tab zeigen dieselbe Logik wie die Sidebar
  (`SessionHeaderStatus`, `AgentStatusIndicator(compact:)`).

