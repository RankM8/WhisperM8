---
status: Plan, Bau startet nach dem Merge von touchpad, steuerkreuz und l2-zurueck in main
stand: 2026-11-12
feature: Controller Runde 5 (Limits in der Insel, App-Schalter, Schreiben mit Steuerkreuz, Einfügen, Wiederöffnen, Forschungspunkte R1–R8)
branch: feat/controller-runde5
---

# Controller Runde 5: Bauplan

Freigegeben ist der Entwurf `docs/design/controller-runde5.html` (Branch `docs/controller-runde5-entwurf`)
mit „alles ja“ und den Antworten auf seine offenen Fragen, dazu die Forschungspunkte R1–R8. Dieser Plan
sagt, was wo gebaut wird, welche puren Typen Tests bekommen, wie Insel, Legende und Menü sich ändern, welche
Schutzregeln gelten und in welcher Reihenfolge committet wird. Punkt 5 des Entwurfs (Vibration als
Limit-Warnung) bleibt zurückgestellt.

Feature-Doku: [`../features/controller.md`](../features/controller.md). Entwürfe:
[`../design/controller-insel.html`](../design/controller-insel.html), Runde 5 auf dem Entwurfs-Branch.

## Ausgangslage

- Basis ist `main` mit `feat/controller-touchpad` (schon drin), `feat/controller-steuerkreuz` und
  `feat/controller-l2-zurueck`. Phase 2 beginnt mit `git merge main` in `feat/controller-runde5`.
- Nach dem Steuerkreuz-Branch gibt das Steuerkreuz in jedem lebenden Chat Pfeile ins Terminal
  (`arrowsAllowed == acceptsKeys`), und jeder Pfeil zählt als frische Eingabe
  (`ControllerTerminalMarks.recordControllerKey`). Der Vorschlag rechts (`suggestionAcceptAllowed`) ist dort
  entfallen. R2 schränkt die frische Eingabe wieder ein (siehe unten).
- Nach dem L2-Branch trägt `ControllerChatState` ein `backTarget`, und die Legende nennt das Ziel von L2.
- Touchpad: L2 + Touchpad öffnet den Verlauf, das Options-Menü hat „Zwischenablage“. Die L2-Insel zeigt das
  schon; Runde 5 ergänzt dort nur □.
- Ebenen liefern alle Tasten als `.inLayer(layer, .press(button))`, das Steuerkreuz und den linken Stick als
  `.inLayer(layer, .move(…, isRepeat:))` mit Wiederholung. Neue Kombinationen brauchen also keine Änderung am
  Erkenner, nur an der Belegung (`ControllerBindingResolver+Layers.swift`).

## Geprüfte Fakten (Phase 1, 12.11.2026)

Geprüft ohne interaktive Sitzung: Claude Code 2.1.322 (`~/.local/share/claude/versions/2.1.322`, Bun-Bundle
im Mach-O, per `strings` gelesen), Codex CLI 0.160.1 (natives Binary aus `@openai/codex-darwin-arm64`,
Quelltext des Tags `rust-v0.160.1` aus `codex-rs/tui`), Transkripte unter `~/.claude*/projects`.

**Claude Code 2.1.322, Standard-Belegung** (Tabelle `i6` im Bundle, macOS):

- Chat: `escape` → `chat:cancel`, `ctrl+l` → `chat:clearInput`, `cmd+k` → `chat:clearScreen`,
  `enter` → `chat:submit`, `ctrl+x enter` → `chat:queueSubmit`, `ctrl+x ctrl+s` und `ctrl+enter` →
  `chat:sendNow`, `ctrl+j` → `chat:newline`, `up`/`down` → `history:previous/next`, `ctrl+_` (dazu `ctrl+-`
  und die Shift-Varianten) → `chat:undo`, `ctrl+s` → `chat:stash`, `ctrl+v` → `chat:imagePaste`, `space` →
  `voice:pushToTalk`.
- Global: `ctrl+o` → `app:toggleTranscript`, `ctrl+t` → Aufgaben, `ctrl+r` → Verlaufssuche.
- Footer: Pfeile wählen, `enter` öffnet, `escape` → `footer:clearSelection`, `x` schließt.
- Transcript: `escape`, `q`, `ctrl+c` → `transcript:exit`.
- `app:toggleTeammatePreview` gibt es nicht mehr. `app:redraw` gibt es als Aktion, aber ohne Taste.

**Ctrl+L zeichnet in Claude neu, es leert den Entwurf nicht.** `chat:clearInput` und `chat:clearScreen`
haben denselben Handler: `{"chat:clearScreen":Cw,"chat:clearInput":Cw,…}`, `Cw` zählt einen Zähler hoch, und
der Effekt ruft `forceRedraw()`. Den Entwurf leert doppeltes Esc („double tap esc to clear input“). Codex:
Ctrl+L ist `clear_terminal`, leert die sichtbare Oberfläche und zeichnet den Kopf neu (Entwurf bleibt), also
kein reines Neuzeichnen.

**Leertaste:** `voice:pushToTalk` greift nur bei eingeschalteter Sprachfunktion (`if(!ae){…break}` mit der
Voice-Prüfung). In `~/.claude/settings.json` steht `"voiceEnabled": false`, also tippt Leertaste (Dreieck)
ein Leerzeichen. Schaltet der Nutzer Voice in Claude ein, wird Dreieck zum Sprechknopf. Das kommt als
Grenze in die Doku.

**Wortsprung ohne ESC geht in beiden CLIs.**
- Claude: Der Parser kennt `case"\x1B[1;5D":return Ii(n,"left",!0)` (rechts analog), und das Eingabefeld
  springt bei `ctrl` über `backwardWord()`/`forwardWord()`. ESC b/f werden zu Meta (verboten, s. u.).
- Codex: `move_word_left` = `alt-b`, Alt+←, Ctrl+←; `move_word_right` analog (`keymap.rs`,
  `built_in_defaults`); crossterm liest `ESC [ 1 ; 5 D/C` als Ctrl+←/→.
- Gesendet wird `ESC [ 1 ; 5 D` bzw. `… C` als ein Block. Das ist eine vollständige CSI-Sequenz, kein
  einzelnes ESC; ein arbeitender Chat bricht davon nicht ab.

**Hoch/runter im mehrzeiligen Entwurf:**
- Claude: `up` springt nur aus der ersten Zeile in den Verlauf (`At()` prüft `getPosition().line`), sonst
  eine sichtbare Zeile hoch; `down` nur aus der letzten Zeile. Hoch in der ersten Zeile holt also den
  letzten Prompt — dagegen schützt nur das Wissen, in welcher Zeile der Cursor steht.
- Codex: Hoch/runter bewegen den Cursor; Verlauf nur bei leerem Entwurf oder einem unveränderten, aus dem
  Verlauf geholten Entwurf mit Cursor am Anfang oder Ende (`chat_composer_history.rs`).
- Claudes Renderer parkt den Terminal-Cursor an der Schreibmarke (`cursorDeclaration` im Ink-Renderer, für
  IME und Screenreader). Ob SwiftTerms Cursor (`getCursorLocation`) im eingebetteten PTY wirklich dort steht,
  ist im ersten Bauschritt am Gerät zu prüfen (siehe Punkt 6).

**Rückgängig:** Claude `ctrl+_` (0x1F) ist Standard. Codex hat im Standard-Editor kein Undo (nur im
Vim-Modus `u`); 0x1F kommt dort als Ctrl+7 an, das Alias von Ctrl+/ für die Nebenunterhaltung, und Ctrl+Z
hält den Prozess an. → R6 nur für Claude.

**Jetzt senden (Claude):** `chat:sendNow` auf `ctrl+x ctrl+s` und `ctrl+enter`. Leerer Entwurf: schickt die
Warteschlange sofort (`sendQueuedNow`). Mit Entwurf: sendet ihn, und läuft danach noch derselbe Turn, auch
gleich die Warteschlange. Bei ruhendem Chat mit Entwurf wirkt es wie Enter. Codex: Enter während eines Turns
lenkt sofort ein (Steer), Tab stellt in die Warteschlange; `ctrl+x` ist dort Sprach-Stumm, `ctrl+s`
Verlaufssuche. → 0x18 0x13 nie an Codex.

**Transkript:** Claude Ctrl+O (0x0F, global). Codex: Ctrl+O kopiert die letzte Antwort, das Transkript liegt
auf Ctrl+T. → R4 nur für Claude.

**Bild einfügen:** Claude `ctrl+v` → `chat:imagePaste`; Codex `fixed.paste_image` = Ctrl+V. Beide lesen das
Bild selbst aus der Zwischenablage, 0x16 reicht als Auslöser.

**Hinweistexte am unteren Rand** (Komponente baut `` `${key} to ${action}` ``, getrennt mit „ · “; der
knappe Stil schreibt Kleinbuchstaben ohne „to“, etwa `esc close`):

| Ansicht | Text | eindeutig? |
|---|---|---|
| Transkript (Ctrl+O) | `Showing detailed transcript` (dazu `ctrl+o to toggle`) | ja |
| `/workflows` | Titel `Dynamic workflows`; `… · x to stop · s to save · Esc to close` | `s to save` ja |
| `/tasks` | Titel `Background`; `↑/↓ to select · Enter to view · x to stop · Esc to close`, im Detail `Esc to go back`; leer `No tasks currently running` | nur zusammen: `to stop` + `Esc to close`/`esc close` |
| Zurückspulen | Titel `Rewind`; `Enter to continue · Esc to cancel`; `Confirm you want to restore`, `Nothing to rewind to yet.` | nur zusammen mit `Rewind`/`restore` |
| Auswahl in der Fußzeile | `Esc to collapse`, `ctrl+x ctrl+k to stop all agents` | ja |
| Subagent-/Teammate-Ansicht | kein fester Hinweis; während der Agent läuft steht `esc to interrupt` | **nicht erkennbar** |

In allen erkennbaren Ansichten fängt die Ansicht Escape ab (Transcript `transcript:exit`, Footer
`footer:clearSelection`, Dialoge schließen). In der Subagent-Ansicht dagegen würde Escape laut Hinweis den
Chat unterbrechen. Sie bleibt deshalb draußen (siehe R2).

**Warteschlange im Transkript** (Schreiber im Bundle): `{"type":"queue-operation","operation":…,
"timestamp":…,"sessionId":…, content?, reason?, commandUuid?, deliveryId?}`. Stichprobe der 150 neuesten
Transkripte: `enqueue` 3.489, `remove` 1.900 (Gründe `absorbed_mid_turn`, `delivered_to_agent`), `dequeue`
1.446 (ohne Inhalt), `popAll` 13. Enqueue-Inhalte sind meist `<task-notification>` (2.233), eigener Text 511,
743 ohne Inhalt. „Eigener Prompt wartet“ heißt: ein `enqueue`, dessen Inhalt nicht mit `<` beginnt und den
noch kein `remove`, `dequeue` oder `popAll` aufgelöst hat. 2.1.322 nimmt Wartendes meist schon an der
nächsten Tool-Grenze auf; der Zustand ist oft kurz.

**Wo WhisperM8 Transkripte schon günstig liest:** `AgentSessionRuntimeWatcher.pollSnapshot` liest bei jeder
Änderung (Ereignis plus Stat-first) die letzten 64 KB und zieht daraus `AgentTranscriptActivityExtractor`.
Dort hängt die Warteschlange ohne zusätzliches I/O an.

**Terminal-Bildschirm lesen:** SwiftTerm `Terminal.getLine(row:)` liest relativ zur angezeigten Stelle
(`yDisp`). Lebendige untere Zeilen sind das nur, wenn der Puffer der Alternate-Puffer ist, nicht scrollen
kann oder ganz unten steht (`isCurrentBufferAlternate || !canScroll || scrollPosition >= 1`, alles
öffentlich). Hat der Nutzer hochgescrollt, gilt „unbekannt“. Kein Eingriff in den Fork nötig.

**Wiederöffnen:** `AgentWindowStore.recentlyClosedTabs` (LIFO, höchstens 20, nicht persistiert, also nur
dieser App-Start) mit `reopenLastClosedTab(isEligible:)`, genutzt von `chats reopen`
(`AgentControlRequestHandler.sessionReopen`). Ein Tastenkürzel ⇧⌘T gibt es in der App nicht, nur Kommentare
nennen es. Chat schließen aus der Seitenleiste („Aktiv“: beenden) läuft über `closeTab` und landet in der
Liste; Archivierte und gelöschte Shells fallen über `isEligible` heraus.

## keybindings.json: Befund und Empfehlung

`~/.claude/keybindings.json` (24.04.2026) ist eine alte Kopie der damaligen Standardbelegung. Alle fünf Profile
(`~/.claude-profiles/{ai,ai2,PowerUser,PowerUser2,RankM8}/keybindings.json`) zeigen per Symlink darauf.
Claude legt die Datei **über** die Standardbelegung (`[...defaults, ...user]`); fehlende Einträge (97 Stück,
darunter `ctrl+x ctrl+s`, `ctrl+enter`, `ctrl+x enter`) gelten deshalb trotzdem.

| Eintrag | Befund | Wirkung |
|---|---|---|
| Global `ctrl+shift+o` → `app:toggleTeammatePreview` | Aktion gibt es nicht mehr | ignoriert, Warnung beim Start und in `/doctor` |
| Settings `enter` → `settings:close` | ungültige Aktion | ignoriert, Standard `select:accept` gilt |
| Kontext `Doctor`, `f` → `doctor:fix` | Kontext und Aktion unbekannt | Fehler „Unknown context“ |
| Confirmation `ctrl+e` → `confirm:toggleExplanation` | ungültig | ignoriert |
| `MessageSelector`-Block, DiffDialog `enter` → `diff:viewDetails` | alte Namen | werden auf `select:*` umgeschrieben, wirken |
| Confirmation `y` → `confirm:yes`, `n` → `confirm:no` | gültig, aber kein Standard mehr | ein getipptes y oder n beantwortet einen Freigabe-Dialog |
| `ctrl+l`, `space`, `ctrl+s`, `ctrl+v`, `ctrl+o`, `ctrl+_`, `enter`, `escape` | gleich dem Standard | keine Wirkung |

Für den Controller bricht die Datei nichts: Keine riskante Taste ist anders belegt als im Standard, und
`ctrl+x ctrl+s` bleibt erreichbar. Was sie kostet: Warnungen bei jedem Start und die y/n-Tasten in
Freigabe-Dialogen (ein Tippfehler im falschen Moment erteilt eine Freigabe).

**Empfehlung:** Datei sichern (`keybindings.json.bak-2026-11-12`) und durch eine leere Liste ersetzen, damit
nur noch die Standardbelegung gilt:

```json
{
  "$schema": "https://www.schemastore.org/claude-code-keybindings.json",
  "$docs": "https://code.claude.com/docs/en/keybindings",
  "bindings": []
}
```

Verloren geht dabei nur y/n im Freigabe-Dialog; wer das behalten will, lässt allein den
`Confirmation`-Block mit diesen zwei Zeilen stehen. Eine Datei reicht für alle fünf Profile (Symlinks). Die
Änderung macht der Nutzer selbst; die App schreibt diese Datei nicht (Invariante „fremde Daten unter
`~/.claude*` nur lesen“).

## Belegung nach Runde 5

| Ebene | Taste | Wirkung | Neu |
|---|---|---|---|
| R1 | ▲ | Limits-Karte (alle Claude- und GPT-Konten), solange R1 gehalten | ja |
| | ◀ | Mitteilungen eine Stufe weiter (wie die Glocke), Insel bleibt offen | ja |
| | ▶ | Wach bleiben eine Stufe weiter (wie der Wach-Knopf), Insel bleibt offen | ja |
| | ▼ | Archiv an/aus (wie der Archiv-Knopf), Insel bleibt offen | ja |
| | ✕ | „Weiter“; bei arbeitendem Claude-Chat mit eigenem Prompt in der Warteschlange oder frischem Entwurf „Jetzt senden“ (R1) | geändert |
| | L3 | ausführliches Transkript an/aus (Claude, Ctrl+O) (R4) | ja |
| | △ □ ○ | wie bisher | |
| L1 | ◀ ▶ | Wort zurück/vor (Ctrl+←/→) | ja |
| | ▲ ▼ | Zeile hoch/runter, nur im mehrzeiligen Entwurf | ja |
| | ✕ | neuesten Eintrag der Zwischenablage einfügen, Bilder wie ⌘V | ja |
| | ○ | genau ein Escape, unabhängig vom Status (R3) | ja |
| | L3 | Rückgängig (Claude Ctrl+_, Codex nicht) (R6) | ja |
| | □ △ | wie bisher | |
| L2 | □ | zuletzt geschlossenen Chat wieder öffnen, wiederholt weiter zurück | ja |
| ohne Ebene | ○ tippen | bei offener Claude-Ansicht Escape auch bei „arbeitet“ und ohne 1-s-Sperre (R2) | geändert |
| Menü | Befehle › | zusätzlich `/tasks`, `/workflows`, `/rewind` (R5) | ja |
| Tastatur | Ctrl+Return | in Claude-Chats `0x18 0x13` (R8) | ja |

## Was sich gegenüber dem Auftrag ändert

- **R2 ohne Subagent-/Teammate-Ansicht.** Sie hat keinen festen Hinweis am unteren Rand, und während der
  Agent läuft steht dort `esc to interrupt`: Escape würde den Chat unterbrechen. Erkannt werden Transkript,
  `/workflows`, `/tasks`, Zurückspulen und die Auswahl in der Fußzeile.
- **R6 nur Claude.** Codex hat kein Undo im Standard-Editor, und 0x1F öffnet dort die Nebenunterhaltung.
  In Codex steht L1 + L3 ausgegraut („in Codex nicht“).
- **R4 nur Claude.** In Codex wäre Ctrl+O „letzte Antwort kopieren“. Ctrl+T (Codex-Transkript) wäre
  möglich, ist aber nicht beauftragt; in Codex ausgegraut.
- **R7 „Neu zeichnen“ nur für Claude, mit Ctrl+L.** Die Annahme, Ctrl+L leere die Eingabe, stimmt für
  2.1.322 nicht (gleicher Handler wie `clearScreen`, `forceRedraw`). In Codex leert Ctrl+L die sichtbare
  Oberfläche, deshalb dort aus. In Shells aus (zsh leert den Bildschirm, Vollbild-Programme deuten es
  anders).
- **L1 ▲▼ nur mit erkannter Cursorzeile.** Mehrzeilig allein reicht bei Claude nicht: Hoch in der ersten
  Zeile holt den letzten Prompt. ▲ geht nur, wenn der Cursor nicht in der ersten Entwurfszeile steht, ▼ nur,
  wenn er nicht in der letzten steht. Ist das nicht sicher ablesbar, steht ▲▼ ausgegraut. Bestätigt der
  Gerätetest in Schritt 6 nicht, dass SwiftTerms Cursor an der Schreibmarke steht, entfällt ▲▼ bei Claude
  (Codex behält es, dort holt Hoch im geänderten Entwurf nie den Verlauf).
- **Konto-Menü, Startpunkt der Markierung.** „Startet auf dem aktuellen Konto, wie heute“ — heute steht die
  Markierung aber auf dem ersten *wählbaren* Konto, weil das aktuelle nicht wählbar ist
  (`ControllerListMenu.normalize`). Geplant ist, was der Satz sagt: Start auf der Zeile des aktuellen Kontos
  (ausgegraut, Kreuz dort „geht nicht“), der erste Schritt springt auf das nächste wählbare. Dafür bekommt
  `ControllerListMenu` einen Startpunkt, der ausgegraut sein darf. Soll es beim heutigen Verhalten bleiben,
  entfällt nur diese Änderung.
- **Prozentangaben überall „verbraucht“.** Das Konto-Menü zeigt also nicht „frei“ wie der Entwurf, sondern
  verbraucht (5 Std. · Woche); „am meisten frei“ bleibt als Markierung (kleinster Wert von max(5h, Woche)).

## Bausteine, die mehrere Punkte brauchen

### A. Neue Terminal-Tasten (`TerminalControlKey`)

Datei `Services/AgentChats/TerminalControlKey.swift`. Neue Fälle, Bytes, Tastencode für den Entwurfs-Tracker
und Freigabe in `controllerAllows`:

| Fall | Bytes | `controllerAllows` | Tracker |
|---|---|---|---|
| `wordLeft` / `wordRight` | `1B 5B 31 3B 35 44` / `… 43` (fest, unabhängig von DECCKM) | Claude, Codex; nicht in Rückfrage | wie Pfeil, ändert den Entwurf nicht |
| `sendNow` | `18 13` | nur Claude; nicht in Rückfrage | zählt als Absenden (`recordSubmitted`, `lastEnterAt`) |
| `toggleTranscript` | `0F` | nur Claude | neutral |
| `undo` | `1F` | nur Claude; nicht in Rückfrage | Entwurf möglich (`mayHaveUnsentInput` bleibt) |
| `imagePaste` | `16` | Claude, Codex; nicht in Rückfrage | Entwurf vorhanden |
| `redraw` | `0C` | nur Claude | neutral |

Tests: `TerminalControlKeyTests` (Bytes, Freigabe je Profil und Status, nie ein einzelnes `1B` am Anfang
einer Sequenz außer `escape`; ein Test prüft, dass keine neue Taste mit `1B` endet oder nur aus `1B` besteht).
`ControllerTerminalMarks.recordControllerKey`: `sendNow` setzt `lastEnterAt` und schließt „Auswahl offen“,
die übrigen schließen sie ebenfalls (sie ändern das Feld oder die Ansicht).

### B. Bildschirm-Lesen (für R2 und L1 ▲▼)

- **Kern, pur:** `Core/ControllerScreenReading.swift`
  - `enum ControllerOpenView: String { case transcript, workflows, tasks, rewind, footerSelection }`
  - `static func openView(bottomLines: [String]) -> ControllerOpenView?` mit den Texten aus der Tabelle oben,
    in beiden Stilen (`Esc to close` und `esc close`). Reihenfolge der Prüfung: Transkript, Workflows,
    Rewind, Tasks, Fußzeile.
  - `struct ControllerDraftLayout { rows: Int; cursorRow: Int? }` und
    `static func draftLayout(lines: [String], cursorRow: Int?) -> ControllerDraftLayout?`: sucht von unten die
    Eingabebox (Trennlinien `─` über und unter dem Feld, Prompt-Zeichen `❯`/`>` in der ersten Zeile), zählt
    die Zeilen dazwischen und ordnet den Cursor zu. Nichts eindeutig → `nil`.
  - Tests mit Bildschirm-Fixtures als Text (`ControllerScreenReadingTests`): jede Ansicht in beiden Stilen,
    Fehlalarme (Chat-Text, der „Esc to cancel“ zitiert, ohne `Rewind`), Box mit 1, 3 und 12 Zeilen, Cursor
    oben/mitten/unten, abgeschnittene Box.
- **Live:** `ControllerTerminalState` bekommt `openView` und `draftLayout`, gelesen in
  `LiveControllerTerminals.state(of:)` nur für Claude (Box auch für Codex) und nur, wenn der Puffer lebendig
  unten steht (Fakten oben). Gelesen werden höchstens die unteren 12 Zeilen per
  `getLine(row:)?.translateToString(trimRight: true)`.
- **Kosten:** `state(of:)` läuft je diskreter Geste (beim Halten höchstens zehnmal je Sekunde), nie je
  Abtastwert und nie in einem Body. 12 Zeilen übersetzen kostet Mikrosekunden. Zähler in
  `PerformanceCounters` (`controllerScreenReads`), kein eigenes Signpost an dieser häufigen Stelle; liegt im
  bestehenden Ereignis-Pfad. Die Legende fragt `state(of:)` bei Statuswechseln über `refreshContext` — ebenfalls
  ereignisgetrieben.
- `ControllerChatState` bekommt `openView: ControllerOpenView?` und `draftLayout`.

### C. Limits-Stand (`ControllerLimitsStore`)

Heute holen die Popover ihre Zahlen selbst (`ClaudeUsagePopoverView.load/update`, `CodexUsagePopoverView.load`)
und behalten sie in `@State`. Die Insel braucht dieselben Zahlen sofort beim Öffnen.

- Neuer `@MainActor`-Dienst `Services/Shared/AccountLimitsStore.swift` mit dem letzten Stand je Konto
  (`claude[name]`, `gpt[name]`, Zeitpunkt, `isLoading`) und zwei Wegen, die die Popover-Logik **übernehmen,
  nicht kopieren**:
  - `load()` = bisheriges `load()` beider Popover (passiv: Claude `fetchUsage` je angemeldetem Profil,
    GPT-Backend-Konten über `CodexUsagePopoverTargets` + `fetchLiveUsage`), parallel, abseits des Main Thread.
  - `refresh()` = bisheriges ↻ (Claude `ClaudeUsageUpdateFlow.run` mit CLI-Ping, GPT `load`).
- Die Popover lesen und schreiben ab dann denselben Store (Zahlen bleiben gleich, ↻ bleibt gleich). Das
  Codex-CLI-Konto des Diktats bleibt allein im Popover (nicht in der Insel, freigegeben „schlank“).
- Pure Abbildung im Kern: `Core/ControllerLimits.swift` mit `ControllerAccountLimit { kind, name, fiveHour,
  week, fiveHourResetsAt, weekResetsAt, problem? }`, `ControllerLimitsCard` (Zeilen, Abschnitte Claude/GPT,
  Markierung „dieser Chat“, Scroll-Fenster wie `ControllerIslandList`) und `ControllerLimitLevel`
  (Ampel wie `UsageGaugeLine`: < 50 grün, ab 50 gelb, ab 80 rot). Tests: Reihenfolge, Markierung, Scrollen am
  Rand, Ampelgrenzen, Problemzeile statt Balken, Rücksetzzeit-Text (< 1 Tag Dauer, sonst Tag/Uhrzeit, gleiche
  Regel wie `UsageResetDateFormat`).
- Wann geladen wird: beim Öffnen der R1-Insel nur, wenn der Stand älter als 60 s ist, im Hintergrund; die
  Insel zeigt sofort den alten Stand und zieht nach (`present()` nur bei offener Insel). Ohne Stand: „—“.
  Nie im Body, nie je Geste.

## Die Punkte

### 1. R1: zweite Raute (App-Schalter) und neuer Kopf

- **Belegung** (`ControllerBindingResolver+Layers.swift`, `quickDrawLayer`): `.move(.up, .dpad, false)` →
  `.islandLimits`; `.move(.left, .dpad, false)` → `.appToggle(.alertLevel)`; rechts → `.appToggle(.stayAwake)`;
  unten → `.appToggle(.archive)`. Wiederholungen beim Halten ignorieren (jeder Druck eine Stufe). Neue Fälle in
  `ControllerAction`: `islandLimits`, `islandScroll(step:)`, `appToggle(ControllerAppToggle)`; `ControllerAppToggle`
  im Kern.
- **Ausführer** (`ControllerActionDispatcher+Island.swift`, neu `+AppToggles.swift`): Schalter laufen über
  neue Methoden von `ControllerAppEnvironment`:
  - `cycleAlertLevel()` setzt `AgentAlertLevel.next(soundStageHasEffect:)` wie `SidebarAlertLevelButton` (die
    Logik dafür zieht in eine statische Funktion, die Knopf und Controller teilen, inklusive
    `SpeechCalloutCenter.discardAll()` und Log).
  - `cycleStayAwake() -> ControllerToggleResult`: Ist die Admin-Freigabe nicht `.ready` und braucht die
    nächste Stufe sie, kein Dialog, sondern `.needsPermission` → Insel „Erst in der Seitenleiste freigeben“,
    Vibration „geht nicht“. Dafür bekommt `StayAwakeController` ein lesbares `needsPermission(for:)`.
  - `toggleArchive()` über einen neuen Befehl `AgentChatsCommand.toggleArchiveMode` an das Fenster
    (`archiveModeActive`, `exitArchiveMode()`), wie der Knopf.
- **Insel:** Schalter lassen die Insel offen (kein `spendIsland`), zeigen eine Bestätigungszeile („Ton aus,
  Mitteilungen an · ◀ noch mal: alles aus“) und einen leichten Impuls (`ControllerHapticPattern.toggle`, neu,
  kurz). Befehle rechts schließen wie bisher.
- **Modell** (`ControllerIsland.swift`): `ControllerQuickDrawSlots` bekommt `appState:
  ControllerAppTogglesState` (Stufe Glocke, Stufe Wach, Archiv an/aus, Wach-Freigabe fehlt), `confirmation:
  ControllerToggleConfirmation?` und `header: ControllerIslandAccountBadge?` (Kontoname, 5-h-Wert verbraucht,
  Ampel). Der Kopf gilt für jede Ebene, steht aber nur bei R1 (Entwurf).
- **Konto des Chats:** GPT-Chat ⇔ `session.claudeBackendModel != nil`; dann GPT-Konto
  (`gptProfileName ?? main`), sonst Claude-Konto (`claudeProfileName ?? main`). Kommt über
  `ControllerChatActionInfo` (neue Felder `claudeAccount`, `gptAccount`, `usesGPTBackend`), gebaut in
  `AgentChatsView+ControllerActions.swift`.
- **Ansicht:** `ControllerIslandView` wird aufgeteilt (`+QuickDraw.swift`, `+Writing.swift`, `+Limits.swift`),
  zwei verschränkte Rauten wie im Entwurf (vier halbe Spalten à 76 pt, Zeilen 44 pt), Breite rund 700 pt
  (`ControllerIslandDisplay.bodyWidth` für `.quickDraw`). Symbole wie in der Seitenleiste
  (`SidebarAlertLevelButton.symbolName`, `SidebarStayAwakeButton.symbolName`, `archivebox`).
- **Tests:** `ControllerBindingResolverLayerTests` (Steuerkreuz unter R1, keine Wirkung bei Wiederholung),
  `ControllerActionDispatcherIslandTests` (Insel bleibt bei Schaltern offen, Wach ohne Freigabe öffnet keinen
  Dialog, Archiv ruft den Befehl), Tests der geteilten Glocken-Logik.

### 2. Limits-Karte (R1 + ▲)

- R1 + ▲ öffnet die Karte im R1-Inhalt (`ControllerQuickDrawSlots.card: ControllerLimitsCard?`). Solange sie
  offen ist: linker Stick und ▲▼ scrollen (`islandScroll`), ✕ = Aktualisieren (`AccountLimitsStore.refresh`,
  derselbe Weg wie ↻), Loslassen von R1 schließt. ✕ wird im Ausführer umgedeutet (offene Karte → Aktualisieren,
  sonst Schnellbefehl); die Belegung bleibt pur und kennt die Karte nicht.
- Inhalt (schlank, freigegeben): Abschnitte Claude und GPT, je Konto 5 Std. und Woche mit Balken, Prozent
  verbraucht, Rücksetzzeit; Problemtext aus dem Popover statt Balken; „dieser Chat“ am Konto des Chats; Kopf
  „Stand vor 1 min“ bzw. „aktualisiere …“. Keine Plan-Kürzel, kein Wochenlimit je Modell, kein Codex-CLI-Konto.
- Höhe: höchstens sechs Konto-Zeilen sichtbar, schmaler Rollbalken. Die Insel misst ihre Höhe schon selbst
  (`ControllerIslandPresenter`, `fittingSize`).
- Die Problemtexte (`ClaudeUsagePopoverView.problemText`) ziehen in eine statische Funktion, die Popover und
  Insel teilen.

### 3. Konto wechseln mit Prozenten

- `ControllerAccountChoice` bekommt `fiveHourUsed`, `weekUsed` (verbraucht) und `isMostFree`. Befüllt im
  Ausführer beim Öffnen des Menüs (`menuSetup`) aus dem `AccountLimitsStore` — kein I/O.
- Pure Regel `ControllerAccountHeadroom.mostFree(in:)` im Kern: je Gruppe (Claude, GPT) das wählbare Konto mit
  dem kleinsten `max(5h, Woche)`; ohne Zahlen keine Markierung; Gleichstand → das obere. Reihenfolge bleibt.
- Startpunkt der Markierung: siehe „Was sich ändert“ (`ControllerListMenu(entries:start:)` erlaubt einen
  ausgegrauten Start; `move` springt danach normal). Tests in `ControllerNavigationModelsTests`.
- Anzeige in `ControllerMenuOverlay`: rechts „42 % · 61 %“ in Ampelfarbe, Kopfzeile „verbraucht: 5 Std. ·
  Woche“, Plakette „am meisten frei“.

### 4. R1-Kopf: Ziel, Konto, 5 Std.

Siehe Punkt 1. Alle Prozentwerte (Kopf, Karte, Konto-Menü) sind verbraucht, Ampel wie das Popover.

### 5. (zurückgestellt) Vibration als Limit-Warnung

Nicht gebaut.

### 6. L1 + Steuerkreuz

- **◀ ▶** → `.chatKey(.wordLeft/.wordRight)`, mit Wiederholung beim Halten (die Ebene liefert
  `.move(…, isRepeat: true)`). Nur Claude und Codex, nicht in einer Rückfrage (`layerWritingAllowed`).
- **▲ ▼** → `.chatKey(.up/.down)` nur, wenn `draftLayout` sicher ist und gilt: `rows >= 2`, für ▲
  `cursorRow > 0`, für ▼ `cursorRow < rows - 1`. Sonst „geht nicht“ (in der Insel ausgegraut mit
  „nur im mehrzeiligen Entwurf“). Codex: dieselbe Regel (vorsichtig, auch wenn Codex selbst nachsichtiger ist).
- **Erster Bauschritt ist ein Gerätetest:** `whisperm8 debug controller state` gibt `openView`, `draftLayout`
  und SwiftTerms Cursor aus. Der Nutzer tippt in einem Claude- und einem Codex-Chat drei Zeilen und bewegt den
  Cursor; stimmt die Zeile nicht, entfällt ▲▼ für dieses Profil (siehe oben). Kein interaktiver Test durch den
  Bau-Chat.
- Pfeile per L1 zählen als Bewegung, nicht als frische Eingabe (anders als das Steuerkreuz ohne Ebene).
- **Insel:** L1 zeigt zwei Spalten wie im Entwurf (Steuerkreuz links, Tasten rechts),
  `ControllerWritingSlots` bekommt `canMoveWord`, `canMoveLine`, `pastePreview`, `canEscape`, `canUndo`.

### 7. L1 + ✕: neuesten Eintrag einfügen

- Neue Schnittstelle `ControllerClipboardSource` (Live: `ClipboardHistoryController`/`ClipboardHistoryStore`)
  mit `newestEntryPreview() -> ControllerClipPreview?` (Art Text/Bild, kurzer Text, Bildgröße) — aus dem
  Index im Speicher, ohne Dateizugriff; gebaut beim Öffnen der L1-Insel.
- Ausführen (`ControllerActionDispatcher+Paste.swift`):
  - **Text:** vollen Text abseits des Main Thread laden (`ClipboardHistoryStore.fullText`), dann
    `terminals.sendText(text, submit: false, to:)` (Bracketed Paste, wie das Diktat). Auch in Shells
    erlaubt; dort ohne Senden und ohne Entwurfs-Merker-Änderung über das Übliche hinaus.
  - **Bild:** `ClipboardRestore.write(payload, to: .general)` (beansprucht intern schon per
    `ClipboardInternalWrites.claim`, landet also nicht doppelt im Verlauf), danach `sendKey(.imagePaste)`.
    Nur Claude und Codex; in Shells „geht nicht“ mit Hinweis.
  - Nicht in einer Rückfrage. Ziel ist der Chat beim Drücken; wechselt er bis zum Einfügen, nichts senden.
  - Danach `store.bump` wie im Verlauf (der Eintrag bleibt oben). Zählt als frische Eingabe (Kreuz darf danach
    senden).
- Leerer Verlauf oder Verlauf aus: ✕ ausgegraut „nichts zum Einfügen“.
- Tests: Dispatcher mit Spy (Text → `sendText`, Bild → Schreiben vor `0x16`, Shell + Bild → abgelehnt,
  Rückfrage → abgelehnt, Chatwechsel → nichts).

### 8. L2 + □: zuletzt geschlossenen Chat wieder öffnen

- `AgentWindowStore` bekommt `peekLastClosedTab(isEligible:) -> ClosedTabRecord?` (ohne zu entfernen), damit die
  Insel den Namen zeigt. Wiederöffnen über `reopenLastClosedTab(isEligible:)` mit derselben Prüfung wie
  `sessionReopen` (Chat existiert, nicht archiviert); dafür eine gemeinsame statische Funktion, die CLI und
  Controller teilen.
- Neuer Befehl `AgentChatsCommand.reopenLastClosed` (Katalog), Belegung `.inLayer(.whereTo, .press(.square))`
  → `.islandReopenClosed`. Schließt die Insel. Wiederholt weiter zurück ergibt sich aus LIFO.
- Nichts geschlossen: □ ausgegraut „nichts geschlossen“, Druck vibriert „geht nicht“, Insel bleibt.
- Ein wiedergeöffneter, beendeter Chat steht gestoppt da; Kreuz startet ihn (bestehende Regel).
- Tests: `AgentWindowStoreTests` (peek ändert nichts, übersprungene Einträge), Dispatcher (Name in der Insel,
  zweimal hintereinander zwei Chats), Belegung.

### R1. R1 + ✕: Weiter oder Jetzt senden

- Pure Entscheidung `ControllerQuickDrawSlots.crossAction(state:)` → `.continueWork`, `.sendNow` oder `nil`:
  - Ruht der Chat (heutige Regel): „Weiter“ (nicht an einen Entwurf hängen).
  - Arbeitet ein Claude-Chat und gilt `queuedOwnPrompt || draftSuspected && recentDraftInput` (frischer
    Entwurf): „Jetzt senden“.
  - Rückfrage, Shell, Codex, unbekannter Status: aus.
- `queuedOwnPrompt`: neue pure Funktion `ClaudeQueueScan.pendingOwnPrompts(inTail:)` (Warteschlange
  nachspielen: `enqueue` hängt an, `dequeue` nimmt das erste, `remove` das erste mit gleichem Inhalt, `popAll`
  alles; zählen, was nicht mit `<` beginnt und nicht leer ist). Aufgerufen in
  `AgentSessionRuntimeWatcher.pollSnapshot` auf demselben 64-KB-Tail (nur Zeilen mit `"queue-operation"`
  werden geparst), gespeichert im `AgentSessionActivityStore` neben der Stand-Zeile, gelesen in
  `state(of:)`. Kein zusätzliches I/O.
- Senden: `sendKey(.sendNow)`; zählt als Absenden (Tracker, `lastEnterAt`, „gerade gesendet“).
- Insel: Beschriftung wechselt („Jetzt senden“), Prüfung beim Auslösen frisch wie heute (`perform`).
- Tests: Queue-Scan mit echten Zeilenformen aus der Stichprobe (Benachrichtigungen, `absorbed_mid_turn`,
  `popAll`, abgeschnittene erste Zeile), Entscheidungstabelle.

### R2. Offene Claude-Ansicht erkennen

- Baustein B. Belegung (`ControllerBindingResolver+Chat.swift`):
  - `.tap(.circle)`: Ist `openView != nil` (nur Claude), Escape auch bei „arbeitet“, „gerade gesendet“ und
    ohne 1-s-Sperre (`escapeAllowed` bekommt den Zweig vorneweg).
  - Kreis halten bleibt Unterbrechen.
- Frische Eingabe durch Pfeile (`recordControllerKey`, seit dem Steuerkreuz-Branch immer): nur noch, wenn eine
  Ansicht offen ist, eine Rückfrage, eine Auswahl des Menüs oder bei Codex. Dafür bekommt `recordControllerKey`
  den Parameter `countsAsChoice: Bool`, berechnet in `AgentTerminalController.sendKey` aus Status, Profil,
  „Auswahl offen“ und der erkannten Ansicht. So schickt ↑ im Hauptfeld + ✕ den alten Prompt bei „arbeitet“
  nicht mehr ab. (Bei ruhendem Chat sendet ✕ ohnehin; das ist der bekannte Preis aus dem Steuerkreuz-Branch.)
- Legende: Kreis heißt bei offener Ansicht „Ansicht schließen“ (neues Label `closeView`).
- Tests: Belegung (Escape bei „arbeitet“ nur mit Ansicht), Marks (Pfeil im Hauptfeld zählt nicht).

### R3. L1 + ○: genau ein Escape

- `.inLayer(.writing, .press(.circle))` → `.chatKey(.escape)` mit eigener Prüfung `layerEscapeAllowed`: lebender
  Claude- oder Codex-Chat, unabhängig vom Status, ohne 1-s-Sperre (ausdrücklich gewollt: ein Escape). In
  Shells gilt die L1-Regel: ausgegraut.
- Insel: Hat der Chat Status „arbeitet“ und ist keine Ansicht erkannt, Hinweis „arbeitet: unterbricht, wenn
  keine Ansicht offen ist“.

### R4. R1 + L3: ausführliches Transkript

`.inLayer(.quickDraw, .press(.l3))` → `.chatKey(.toggleTranscript)`; nur Claude, sonst „geht nicht“. Schließt
die Insel wie ein Befehl. In der R1-Insel als kleine Zeile unter den Rauten („L3 Transkript“).

### R5. Befehle › mit /tasks, /workflows, /rewind

`ControllerSlashCommands.claude` bekommt die drei Befehle (nach `/agents`), alle drei in `claudeChoiceLists`.
Englische Beschreibungen plus deutsche Übersetzung. `/rewind` öffnet nach Enter eine zweite Liste
(Wiederherstellen-Auswahl); der Merker fällt dann wie bei Untermenüs — mit dem Steuerkreuz-Branch erreicht
man sie trotzdem, und R2 erkennt `Rewind` als Ansicht. Test in `ControllerTerminalMarksTests`.

### R6. L1 + L3: Rückgängig

`.inLayer(.writing, .press(.l3))` → `.chatKey(.undo)`; nur Claude, nicht in einer Rückfrage. Codex ausgegraut
„in Codex nicht“.

### R7. Menü „Neu zeichnen“

Neuer Eintrag `ControllerMenuItem.redraw` in der Gruppe „Eingaben“ (schreibt in den Chat, also aus bei
Rückfrage), nur Claude: `sendKey(.redraw)` (0x0C). Im 2.1.322 ist das `forceRedraw`; der Entwurf bleibt. Die
Doku nennt die Version als Beleg.

### R8. Tastatur: Ctrl+Return in Claude-Chats

`TerminalShortcut.bytes` (`AgentTerminalView.swift`) bekommt vor `guard !hasControl` den Fall Ctrl (ohne
Cmd/Option/Shift) + Return bei `.claudeCodeChat` → `[0x18, 0x13]`. `ControllerTerminalMarks.recordKeyboard`
zählt Ctrl+Return schon als Absenden; der Entwurfs-Tracker (`recordKeyDown`) ebenso prüfen und testen.
Tests in den bestehenden `TerminalShortcut`-Tests.

## Legende, Einstellungsseite, Lokalisierung

- Legende (`ControllerLegend.swift`): Die Leiste ändert sich kaum (Ebenen stehen in einem Eintrag). Neu:
  Label `closeView` für Kreis bei offener Ansicht. `allBindings()` bekommt die neuen Kombinationen für die
  Einstellungsseite (`combination(.r1, .dpadUp, .limits)` usw.). Neue Labels: `limits`, `alertLevel`,
  `stayAwake`, `archiveToggle`, `wordJump`, `lineMove`, `pasteNewest`, `escapeOnce`, `undo`, `transcript`,
  `reopenClosed`, `sendNow`, `closeView`.
- Lokalisierung: alle neuen Texte englisch als Schlüssel, deutsch in `Localizable.xcstrings`. Insel:
  „Limits“, „all accounts“, „Notifications“, „Stay awake“, „Archive“, „Word back / forward“, „Line up /
  down“, „Paste“, „Paste image“, „nothing to paste“, „Escape once“, „Undo“, „Transcript“, „Reopen“, „nothing
  closed“, „Send now“, „Refresh“, „updated %@ ago“, „refreshing …“, „this chat“, „most free“, „used: 5 h ·
  week“, „Allow it in the sidebar first“, „working: interrupts if no view is open“, „only in a multi-line
  draft“, „not in Codex“, Bestätigungstexte der Schalter (Glocke und Wach-Knopf nutzen ihre vorhandenen
  Texte). Menü: „Redraw“, Beschreibungen für `/tasks`, `/workflows`, `/rewind`.
  `LocalizationCatalogTests` prüft Vollständigkeit.
- Keine Ternär-Literale in `Text(…)`; Texte für die Insel über `String(localized:)` wie heute.

## Leistung

- Nichts läuft dauerhaft. Bildschirm lesen nur im Ereignis-Pfad (diskrete Gesten, Statuswechsel), nur für
  Claude/Codex, höchstens 12 Zeilen. Kein Lesen pro Abtastwert, kein Timer.
- Limits: Laden nur beim Öffnen der R1-Insel (älter als 60 s) und auf ✕; Ergebnisse kommen asynchron.
- Warteschlange: auf dem Tail, den der Watcher ohnehin liest; nur Zeilen mit dem Marker werden geparst.
- Insel-Signpost `controller.islandShow` (33 ms) bleibt das Budget; der R1-Aufbau liest nur Speicher
  (Limits-Store, Schalterzustände).
- Keine Body-Arbeit: Die Insel zeichnet nur ihr Modell; die Sidebar-Knöpfe ändern sich nicht im Aufbau.

## Snapshots

`make snapshots ONLY=controller-insel` bekommt neue Zustände (hell und dunkel, Notch und Pille):

1. R1 mit zwei Rauten und Kopf „main · 5 h 42 %“ (Notch)
2. R1 als Pille, GPT-Chat
3. R1, Chat arbeitet (Weiter aus, Schalter an)
4. R1 nach Glocken-Schalter mit Bestätigung
5. R1, Wach-Knopf ohne Freigabe („Erst in der Seitenleiste freigeben“)
6. R1, „Jetzt senden“ statt „Weiter“
7. Limits-Karte, Claude-Chat, Stand vor 1 min
8. Limits-Karte als Pille, viele Konten, „aktualisiere …“, Problemzeile
9. L1 mit Steuerkreuz-Spalte und Text-Vorschau
10. L1 mit Bild-Vorschau
11. L1 in der Shell (ausgegraut mit Hinweis)
12. L1, Chat arbeitet (Escape-Hinweis)
13. L2 mit „Wieder öffnen · Name“
14. L2 als Pille, „nichts geschlossen“

`ONLY=controller`: Konto-Menü mit Prozenten (Claude-Chat, GPT-Chat), Befehle-Menü mit den drei neuen
Befehlen, Legende mit „Ansicht schließen“. Nach jeder Ansichtsänderung rendern und ansehen.

## Reihenfolge der Commits (Phase 2)

1. `git merge main` (touchpad, steuerkreuz, l2-zurueck), volle Suite grün.
2. `feat(controller): neue Terminal-Tasten für Wortsprung, Jetzt senden, Transkript, Rückgängig, Bild,
   Neu zeichnen` — Baustein A mit Tests; R8 (Ctrl+Return) im selben Zug.
3. `feat(controller): offene Claude-Ansichten am Bildschirm erkennen` — Baustein B, R2, Debug-Ausgabe für den
   Gerätetest. **Halt: Gerätetest ▲▼ durch den Nutzer**, bevor Schritt 5 ▲▼ einbaut.
4. `feat(controller): L1 mit Escape, Rückgängig und Einfügen` — R3, R6, Punkt 7, Insel L1 neu.
5. `feat(controller): L1 bewegt im Entwurf` — Punkt 6 (◀▶ immer, ▲▼ nach Befund).
6. `refactor(limits): Limits-Stand für Popover und Controller teilen` — Baustein C, Popover umgestellt,
   keine sichtbare Änderung.
7. `feat(controller): R1 mit App-Schaltern, Kontostand im Kopf und Transkript` — Punkte 1, 4, R4.
8. `feat(controller): Limits-Karte in der Insel` — Punkt 2.
9. `feat(controller): Jetzt senden mit R1 und Kreuz` — R1 (Queue-Scan im Watcher).
10. `feat(controller): Konto wechseln mit Verbrauch und „am meisten frei“` — Punkt 3.
11. `feat(controller): zuletzt geschlossenen Chat mit L2 und Viereck wieder öffnen` — Punkt 8.
12. `feat(controller): Befehle /tasks, /workflows, /rewind und Neu zeichnen` — R5, R7.
13. `docs(controller): Runde 5 beschrieben` — `docs/features/controller.md` (Belegung, Ebenen, Schutzregeln,
    Grenzen: Leertaste bei eingeschalteter Claude-Sprachfunktion, Subagent-Ansicht nicht erkennbar,
    Ctrl+L-Beleg an Version 2.1.322), Snapshots.

Nach jedem Schritt `swift build` und `swift test --filter Controller`, vor dem letzten die volle Suite. Kein
`make dev` aus dem Chat; am Ende „bereit für make dev“ mit Branch und Commit. Danach Review durch einen
eigenen Agenten (Opus) über den ganzen Branch.

## Handtest nach make dev (Nutzer)

- R1 halten: zwei Rauten, Kopf mit Konto und 5 Std.; ◀ ▶ ▼ schalten, Insel bleibt; ▲ Karte, Stick scrollt,
  ✕ aktualisiert, Loslassen schließt.
- Konto-Menü: Prozente, „am meisten frei“, Start auf dem aktuellen Konto.
- L1: ◀▶ Wortsprung in Claude und Codex; ▲▼ im dreizeiligen Entwurf, in der ersten Zeile ▲ aus; ✕ Text und
  Bild (Bild kommt als Anhang); ○ ein Escape; L3 Rückgängig in Claude.
- Arbeitender Chat: `/tasks`, Ctrl+O-Transkript, Fußzeilen-Auswahl jeweils mit ○ schließen (kein Abbruch);
  ↑ im Hauptfeld + ✕ schickt nichts.
- R1 + ✕ bei arbeitendem Chat mit getipptem Entwurf: „Jetzt senden“.
- L2 + □ zweimal: zwei geschlossene Chats in umgekehrter Reihenfolge zurück.
- Tastatur Ctrl+Return in Claude bei arbeitendem Chat.
