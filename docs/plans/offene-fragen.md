---
status: Entwurf zur Abnahme (WM8-89); Bau nicht freigegeben
stand: 2026-11-15
feature: Offene Fragen der Chats an einer Stelle, zusammen mit „Wartet auf mich“
branch: design/WM8-89-offene-fragen
---

# Offene Fragen der Chats an einer Stelle

Ticket `WM8-89`, Wunsch aus dem Betrieb vom 15.11.2026. Freigegeben ist nur ein Klick-Entwurf, kein Bau:
„wie Fragen der Chats an dich (Text und Optionen) an einer Stelle erscheinen, zusammen mit ‚Wartet auf mich‘“.

Klick-Entwurf: [`../design/offene-fragen.html`](../design/offene-fragen.html). Verwandt:
[`ticket-board-alltag.md`](ticket-board-alltag.md) (WM8-113, WM8-115), [`../features/jarvis-board.md`](../features/jarvis-board.md),
[`claude-status-aus-registry.md`](claude-status-aus-registry.md).

## Kurz

1. **Die App kennt die Frage schon, sie zeigt sie nur nicht.** Claude schreibt das Fragetool samt aller Reiter,
   Optionen und Beschreibungen in den Verlauf, bevor der Dialog aufgeht. Die App liest diesen Aufruf bereits, behält
   davon aber nur die erste Zeile der ersten Frage (80 Zeichen) und zeigt sie nur im Tab-Wechsler.
2. **Die drei Arten des Wartens sind unterschiedlich gut belegt.** Entscheidung (Fragetool) und Erlaubnis bei Claude:
   verlässlich aus Verlauf und Registry. Erlaubnis bei Codex: nur vom Bildschirm abgelesen. „Bei dir“ (Schlüssel,
   Login, Handprobe): gar kein Signal, nur Jarvis' Eintrag am Board.
3. **Empfehlung:** Die ganze Frage steht in „Wartet auf mich“, in derselben Liste wie die Tickets (oben eine Gruppe
   „Fragen der Chats“). Board-Band, Kachelkopf und Mitteilung zeigen die erste Zeile mit der Art und führen dorthin.
   Zuerst nur lesen, mit Sprung in den Chat.
4. **Als Erstes, klein und sofort spürbar:** ein CLI-Befehl, der Jarvis alle Reiter mit Optionen liefert. Dann muss
   er nicht mehr nacherzählen, und das Band füllt sich selbst.
5. **Im Board antworten:** nicht jetzt. Später, nach einer Messung, und dann nur für Claude-Fragen mit einem Reiter.
   Erlaubnisse nie.

## Teil 1: Befunde

### 1. Was die App über eine offene Frage weiß

**Wie Status ankommt.** Seit dem Umbau auf Claudes Registry (Plan `claude-status-aus-registry.md`) meldet Claude selbst
`<config-dir>/sessions/<pid>.json` mit `status: "waiting"` und `waitingFor`. Gemessen: `"input needed"` beim
Fragetool, `"permission prompt"` bei Erlaubnis und Plan-Freigabe (Claude Code 2.1.325, siehe WM8-75). Die Hooks
binden in diesem Modus nur noch die Sitzung: registriert sind `SessionStart`, `SessionEnd`, `TaskCreated`,
`TaskCompleted` (`ClaudeHookSettingsBuilder.registryModeEventNames`). `PreToolUse` und `PermissionRequest` kommen
nur noch, wenn der Kill-Switch `claudeRegistryStatusEnabled` aus ist. Dann landet die ganze Hook-Nutzlast samt
`tool_input` in der Ereignisdatei (`(cat; echo) >> …`), die App hebt sie als `rawJSON` auf, wertet aber nur
`tool_name` aus (`ClaudeHookEventStore.swift`).

**Woher Text und Optionen kommen.** Aus dem Verlauf: Der `AgentSessionRuntimeWatcher` liest bei jedem Schreiben den
Schluss der JSONL-Datei (bis 64 KB), der `AgentTranscriptActivityExtractor` sucht rückwärts den jüngsten Aufruf. Für
das Fragetool steht dort die ganze Eingabe, nachgesehen an einem echten Verlauf dieses Projekts:

```
input.questions[]          bis zu 4 Reiter
  .header                  kurzer Reitername („Ort“)
  .question                Fragetext
  .multiSelect             Mehrfachauswahl ja/nein
  .options[] .label        Option
             .description  Beschreibung der Option
```

`claudeToolDetail` macht daraus heute `.question(<erste Zeile der ersten Frage>)`, gekappt auf 80 Zeichen
(`AgentTranscriptActivityExtractor.swift`, `maxLength = 80`). Die Warte-Art setzt
`AgentSessionStatusCoordinator.registryAwaitingKind` aus `waitingFor` und diesem Detail zusammen.

| Art | Was belegt ist | Quelle | Verlässlich |
|---|---|---|---|
| **Entscheidung**, Claude-Fragetool | alle Reiter mit Überschrift, Frage, Optionen, Beschreibungen, Mehrfachauswahl; Kennung des Aufrufs; beantwortet, sobald das Ergebnis zur Kennung im Verlauf steht | Verlauf + Registry `input needed` | **ja** |
| **Erlaubnis**, Claude (Werkzeug) | Werkzeug und erstes Argument, etwa `Bash: rm -rf …`; die Knöpfe (Yes, „don't ask again“, No) stehen nirgends in den Daten, sie zeichnet Claude selbst | Verlauf + Registry `permission prompt` | **ja**, ohne Knöpfe |
| **Erlaubnis**, Claude (Plan) | `ExitPlanMode` mit dem Plan als Text | Verlauf | **ja** |
| **Entscheidung**, MCP-Werkzeug fragt nach | Registry sagt `input needed`, im Verlauf steht aber ein anderes Werkzeug (gesehen am 14.11. bei einem Chrome-Werkzeug) | Registry | nur „wartet“, kein Text |
| **Erlaubnis**, Codex | der Befehl aus dem offenen Aufruf; *dass* Codex wartet, schreibt er nicht ins Rollout. Erkannt nur am festen Wortlaut unten im Terminal (`ControllerScreenReading.isCodexApproval`, Codex 0.169.0) | Bildschirm | **nein**, abgelesen |
| **Entscheidung**, Codex | `request_user_input…` steht im Rollout (`AgentSessionTranscript.codexUserQuestionToolPrefixes`); der Chat gilt heute als „ruht“. Aufbau der Argumente ungemessen | Verlauf | vor dem Bau messen |
| **Bei dir** (Schlüssel, Login, Handprobe) | nichts. Der Chat beendet seinen Zug und schreibt in den Text, was er braucht; das Board meldet „fertig – prüfen“ | nur Jarvis' Feld `needs` am Board, von Hand | **kein Signal** |

**Was nur Ablesen vom Bildschirm wäre:** welcher Reiter im Dialog gerade offen ist, welche Option vorausgewählt ist,
die festen Einträge „Type something“ und „Chat about this“, die Knöpfe einer Erlaubnis, jede Codex-Freigabe.
`ControllerScreenReading.isQuestionDialog` unterscheidet Frage-Dialog und Erlaubnis an Hinweiszeile und festen
Optionen. Das ist gut genug als *zweite* Prüfung vor dem Schreiben (so nutzt es `ClaudeQuestionTextGate`), aber
keine Quelle für den Inhalt.

**Was Jarvis heute bekommt:** `chats snapshot`, `show` und `board --json` nennen den Status `awaitingInput`, aber keine
Frage. Jarvis liest deshalb den Bildschirm des Chats und sieht von einem Dialog mit mehreren Reitern nur den ersten.

### 2. Wo Giuliano heute sieht, dass ein Chat wartet

| Stelle | Was steht da | Trägt Text? |
|---|---|---|
| Status-Punkt in Seitenleiste, Tab, Kachelkopf (`AgentStatusIndicator`) | Raute in Bernstein, Hilfe „Waiting for you“; für alle drei Arten gleich | nein |
| Tab-Wechsler ⌃Tab (`TabSwitcherTileModel.activityLine`) | „Question: <erste Zeile>“ oder „Freigabe: Bash …“, höchstens 80 Zeichen | **ja, eine Zeile**, nur solange der Wechsler offen ist |
| Board-Band über Jarvis' Eingabefeld (Mod `register.tsx`) | je wartendem Chat eine Zeile: Rufname, Ticket, Feld `needs` | ja, aber **Jarvis' eigene Worte**, 30 bis 50 Zeichen, von Hand gepflegt |
| Notiz-Karte am Kachelkopf (Raster, nur Board-Chats) | Feld „Eingriff“ (`needs`) | ja, ebenfalls von Hand |
| Mitteilung von macOS (`AgentSessionNotifier`) | „Agent has a question.“ / „is waiting for permission.“ / „is waiting for plan approval.“, lautlos | nur die Art |
| Ansage (Voice-Callouts) | „Jon wartet auf dich.“ | nein |
| Insel (Controller) und Notch | „waiting“ und Punkt | nein |
| Ticket-Board Stufe 1 | Chat-Zeile der Karte mit Status | nein |
| Toast | gibt es für Warten nicht | – |

Keine Stelle trägt die Frage selbst, keine trennt die drei Arten außer der Mitteilung, und Codex-Freigaben zeigt
keine als „wartet“.

### 3. Was schon entschieden ist

- **„Wartet auf mich“ über alle Teams** (WM8-115, entschieden 15.11.): eine Liste nach Grund (Prüfung ohne Prüfer,
  Produktentscheidung, Abnahme, Staging-Test, Handtest), „Durchgehen“ öffnet die Triage.
- **Board-Chat** (WM8-113): Jarvis des Projekts neben dem Board; das Board schreibt nicht selbst nach Linear,
  Triage-Knöpfe sammeln und gehen per Enter an den Board-Chat.
- **E4:** Jarvis öffnet das Board nur, wenn Giuliano gerade mit ihm spricht.
- **WM8-89 selbst (14.11.):** Notiz wird eine Zeile im Kachelkopf, Karte nur auf Klick; das Board muss auch ohne
  Ticket-System funktionieren.
- **Vorgabe für diesen Entwurf:** Offene Fragen gehören in dieselbe Liste wie die Tickets, die auf Giuliano warten,
  nicht an eine zweite Stelle.

## Teil 2: Entwurf

### Die drei Arten

Immer mit Zeichen *und* Wort, nie nur Farbe:

- **? Entscheidung** – Fragetool, Claude oder Codex. Zeigt alle Reiter, je Option Text und Beschreibung, die
  Empfehlung des Chats, falls er eine Option so nennt.
- **! Erlaubnis** – ein Befehl will laufen (Claude-Werkzeug, Plan-Freigabe, Codex-Freigabe). Zeigt Werkzeug und
  Befehl; die Knöpfe nur als feste Einträge, weil sie nicht in den Daten stehen.
- **↗ Bei dir** – etwas außerhalb. Zeigt, was Jarvis als Eingriff eingetragen hat.

An jeder Frage steht, woher sie kommt: *aus dem Verlauf*, *vom Bildschirm abgelesen* (in Bernstein) oder *von Jarvis
eingetragen*. Eine Frage verschwindet, sobald ihr Ergebnis im Verlauf steht oder der Dialog mit Esc zugeht
(Registry wechselt auf `idle`).

### Varianten für den Ort

| | **A · „Wartet auf mich“** ★ | **B · Board-Band bei Jarvis** | **C · Zeile am Kachelkopf** | **D · Insel** |
|---|---|---|---|---|
| Was steht da | ganze Frage, alle Reiter, Beschreibungen | je Chat eine Zeile: Art, Ticket, erste Zeile der Frage | Art und erste Zeile; Klick klappt die Frage auf | Frage, Reiter, Optionen ohne Beschreibung |
| Mehrere Fragen eines Dialogs | Reiter wie im Dialog | „Frage 1/3“; Jarvis legt alle wörtlich vor | Reiter in der aufgeklappten Karte | Reiter als Knöpfe |
| Mehrere wartende Chats | Liste, ↑↓ zum Durchgehen | eine Zeile je Chat | nur die Chats auf dem Schirm | Leiste unten zum Wechseln |
| Für | eine Liste für Tickets und Fragen, wie entschieden; Platz; geht ohne Ticket-System | genau da, wo er mit Jarvis spricht; kein Klick | am Chat selbst, baut auf WM8-89 auf | auch wenn WhisperM8 hinten liegt; Controller |
| Wider | ein Klick weg; der Ticket-Bereich wird heute selten geöffnet | wenige Zeilen, nichts anklickbar, nur im Jarvis-Chat | keine Sammlung, nur im Raster | eng; eine weitere Stelle; kann stören |

**Empfehlung: A als die eine Liste, B und C als Wegweiser dorthin.** Das hält die Vorgabe „eine Liste“ ein und
holt Giuliano trotzdem dort ab, wo er hinsieht:

- „Wartet auf mich“ bekommt einen eigenen Knopf in der Titelzeile mit Zahl, erreichbar aus jeder Ansicht. Oben in
  der Liste steht die Gruppe „Fragen der Chats“, darunter die Ticket-Gruppen aus WM8-115. Ohne Ticket-System zeigt
  sie nur die Fragen. Ein Ticket, an dessen Chat eine Frage hängt, trägt deren Zeichen und steht nicht doppelt da.
- Das Band füllt seine Zeile selbst mit Art und erster Zeile der Frage; `needs` bleibt für „Bei dir“ und als
  Vorrang, wenn Jarvis etwas Besseres einträgt.
- Die Zeile am Kachelkopf aus WM8-89 zeigt dasselbe; der Klick klappt die Frage auf, „In ‚Wartet auf mich‘“ führt in
  die Liste.
- Die Mitteilung nennt die erste Zeile der Frage statt „Agent has a question.“ (Inhalte von Chats auf dem
  Sperrbildschirm: siehe Risiken).
- D (Insel) nicht jetzt. Sie lohnt sich erst, wenn der Controller im Alltag läuft, und wäre dann eine Ansicht
  derselben Liste.

### Stufe 2: im Board antworten

Im Board zu antworten heißt, in einen fremden Dialog zu tippen. Genau dort lagen WM8-67 (Diktat in eine
Codex-Freigabe), WM8-75 (Enter trifft eine gerade aufgehende Freigabe) und WM8-107 (Sperre blind, wenn
hochgescrollt), dazu WM8-71 (Text landete fünfmal in einer offenen Rückfrage). Heute gibt es zwei Wege hinein:
`chats send --answer` (Text ins Feld „Type something“, dann Enter) und das Diktat in eine offene Frage
(`ClaudeQuestionTextGate`: nur Einfüge-Block, nie Enter).

**Sicher wäre es nur, wenn alle Bedingungen zugleich gelten:**

1. **Nur Claudes Fragetool.** Nie eine Erlaubnis, nie Codex. Eine einzeln getippte „1“ gibt eine Erlaubnis frei;
   Codex meldet Freigaben nicht.
2. **Genau diese Frage.** Die Liste merkt sich die Kennung des Aufrufs aus dem Verlauf. Direkt vor dem Schreiben:
   Registry `input needed`, jüngster offener Aufruf hat dieselbe Kennung, unten steht der Frage-Dialog
   (`isQuestionDialog`, auch hochgescrollt).
3. **Nur ein Einfüge-Block, nie einzelne Tasten.** Eine Option geht als ihr Text in das Feld „Type something“, nicht
   als Ziffer oder Pfeiltaste. Das Enter folgt erst nach erneuter Prüfung (Muster aus WM8-75).
4. **Zunächst nur ein Reiter.** Wie man in einem Dialog mit mehreren Reitern sicher weiterblättert, ist ungemessen.
5. **Ergebnis prüfen, nie wiederholen.** Nach dem Senden muss das Ergebnis zur selben Kennung im Verlauf stehen.
   Sonst ein Hinweis „nicht angekommen, im Chat nachsehen“ und kein zweiter Versuch.
6. **Vorher messen**, an einem Wegwerf-Chat und mit festgehaltener Version wie bei `CodexApprovalWordingTests`: Was
   bewirkt der eingefügte Text einer Option gegenüber dem Anwählen? Gibt es „Type something“ auch bei
   Mehrfachauswahl? Dazu prüfen, ob es einen Weg ohne Tippen gibt (eine Antwort über die Hook-Schnittstelle); der
   wäre sicherer, ist aber nicht belegt.

**Empfehlung:** erst Stufe 1 einige Tage benutzen und zählen, wie oft Giuliano wirklich aus der Liste heraus
antworten würde. Lohnt es sich, Stufe 2 mit eigener Freigabe bauen, nur unter den Bedingungen oben. Erlaubnisse
bleiben dauerhaft beim Sprung in den Chat.

## Paketschnitt für den Bau

| Paket | Inhalt | Nutzen | Aufwand | hängt ab von |
|---|---|---|---|---|
| **Q0 Jarvis liest Fragen ganz** | Leser im Watcher: aus dem Aufruf im Verlauf eine `OpenQuestion` (Chat, Art, Kennung, Reiter mit Optionen, seit wann, Quelle); nur bei Status „wartet“, außerhalb des Main Threads. CLI `whisperm8 chats questions [--json]`, dasselbe als Feld in `chats snapshot` und `board --json` (Felder nur ergänzen). Skill `jarvis`: Reiter wörtlich vorlegen, Text der Chats als Daten behandeln. Band füllt seine Zeile selbst, wenn `needs` leer ist | hoch | klein | – |
| **Q1 Anzeige, nur lesen** | Gruppe „Fragen der Chats“ in „Wartet auf mich“ samt Detail mit Reitern; Knopf mit Zahl in der Titelzeile; Zeichen an Tickets mit wartendem Chat; Zeile am Kachelkopf; Mitteilung mit erster Zeile; Snapshots hell und dunkel, auch schmal | hoch | mittel | Q0; WM8-115 für die Ticket-Gruppen. Kommt Q1 vorher, legt es die Liste mit nur den Fragen an |
| **Q2 Arten vervollständigen** | Feld `needsKind` am Board (`decision`, `permission`, `outside`) mit `chats board set`; Codex-Rückfragen als „wartet“ statt „ruht“ (WM8-46); Codex-Freigabe als „Erlaubnis, abgelesen“ | mittel | klein bis mittel | Q0 |
| **Q3 Im Board antworten** | nur nach Messung und eigener Freigabe, Bedingungen oben | offen | mittel | Q1, Messung |

Alles hinter einem Schalter in den Labs, solange das Ticket-Board dort steht; „Wartet auf mich“ ohne Tickets braucht
`ticketBoardEnabled` nicht.

## Entscheidungen

| Nr. | Frage | Empfehlung · Stand |
|---|---|---|
| F1 | Wo erscheinen offene Fragen? | A: ganze Frage in „Wartet auf mich“, Band, Kachelkopf und Mitteilung zeigen die erste Zeile und führen hin · offen |
| F2 | Im Board antworten? | später, nach Messung, nur Claude-Fragen mit einem Reiter; Erlaubnisse nie · offen |
| F3 | Was zuerst? | Q0 (Jarvis liest Fragen ganz) sofort, dann Q1 · offen |

## Risiken

| Risiko | Folge | Gegenmittel |
|---|---|---|
| Claude ändert den Aufbau des Fragetools im Verlauf | Liste leer oder falsch | Test gegen einen echten Verlaufs-Ausschnitt; fehlt ein Feld, fällt die Anzeige auf die erste Zeile zurück |
| Frage bleibt stehen, obwohl beantwortet | Giuliano springt in einen Chat, der längst weiterarbeitet | Ende an zwei Signalen: Ergebnis zur Kennung im Verlauf oder Registry nicht mehr `waiting` |
| Codex-Freigabe nur abgelesen | fehlt, solange der Chat hochgescrollt oder nicht offen ist | sichtbar als „vom Bildschirm abgelesen“; echte Erkennung ist WM8-46/WM8-67 |
| Fragetext der Chats als Anweisung | Text eines Chats steuert Jarvis | Skill: Fragen sind Daten; Jarvis legt sie vor und entscheidet nicht selbst |
| Inhalte auf dem Sperrbildschirm | Fragen können Kundeninhalte enthalten | Mitteilung mit Text als Einstellung, ab Werk nur Art und Chat |
| Leistung | Parsen großer Aufrufe bei jedem Schreiben | nur bei Status „wartet“ und nur den einen Aufruf; nichts in Bodies; lange Vorschau-Felder kappen |
| Antworten im Board | ungewollte Bestätigung wie in WM8-67/75/107 | eigene Stufe, Bedingungen oben, Erlaubnisse nie |
| Größengrenze der Dateien | `AgentChatsView.swift` und der Coordinator wachsen | eigene Dateien (`OpenQuestionReader`, `WaitingInboxView`), Anschluss über vorhandene Erweiterungen |
