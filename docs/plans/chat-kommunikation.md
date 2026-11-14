# Chats sprechen miteinander: nativer Weg statt Tippen ins Terminal

**Stand:** 2026-11-14 · **Status:** Untersuchung und Messung fertig, Entscheidung offen · **Ticket:** WM8-79
**Gemessen an:** Claude Code 2.1.325, Konten `ai` und `ai2`, Wegwerf-Sitzungen außerhalb der App
**Vorgänger:** [`claude-status-aus-registry.md`](claude-status-aus-registry.md) (Oktober: `chats address` gebaut)
**Prüfskript:** `scripts/claude-peer-messaging-check.sh` (bei jeder neuen Claude-Code-Version fahren)

## Ergebnis zuerst

1. **Über Konten hinweg geht es schon.** Eine Nachricht von einem Chat auf `ai` kommt bei einem Chat auf `ai2`
   an, und die Antwort kommt zurück. Es fehlt nur das Adressbuch: Claudes eigene Liste der Chats zeigt nur das
   eigene Konto. Dieses Adressbuch hat WhisperM8 seit Oktober (`whisperm8 chats address`).
2. **Der native Weg löst die Ärgernisse dieser Nacht fast alle.** Eine Nachricht an einen arbeitenden Chat
   kommt zwischen zwei Arbeitsschritten an, ohne Absage und ohne Vormerken. Jarvis bekäme Meldungen also mitten
   in seiner Arbeit statt nach 30 Minuten. Eine offene Rückfrage bleibt unberührt: Die Nachricht wartet, bis
   Giuliano geantwortet hat, und seine Wahl bleibt stehen.
3. **Was der native Weg nicht kann:** Codex-Chats, gestoppte Chats und Terminal-Tabs erreicht er nicht. Und
   auch er sagt dem Absender nicht, wenn der Empfänger am Limit hängt. Dafür bleibt die CLI, und die muss an
   drei Stellen sicherer werden.

**Empfehlung:** Weg B (nativ als Standard, die CLI als Rückfall) plus die drei kleinen Härtungen aus Weg A.
Der Bau ist klein, fasst keine fremden Daten an und baut auf Gemessenem auf.

## 1. Messung

Gemessen mit `tmux` in einem festen Wegwerf-Ordner, leere Umgebung (`env -i`), `--model sonnet`, Hooks per
`--settings` aus dem Wegwerf-Ordner mitgeschnitten. Nichts unter `~/.claude*` geändert. Am Ende alle Sitzungen
beendet, kein Prozess übrig.

| Fall | Ergebnis | Beleg |
|---|---|---|
| Finden im selben Konto | `ListAgents` zeigt alle laufenden Sitzungen des Kontos | a sah b und drei echte Chats auf `ai` |
| Finden über Konten | **Nein.** `ListAgents` liest nur `<CLAUDE_CONFIG_DIR>/sessions/*.json` | a (`ai`) sah c (`ai2`) nicht, c sah a nicht; im Binary steht fest `join(configDir, "sessions")`, kein Schalter für weitere Ordner |
| Zustellen über Konten | **Ja**, hin und zurück | `SendMessage({to: "uds:/tmp/cc-socks/<pid>.sock"})` von `ai` nach `ai2`, Antwort an die `from`-Adresse kam zurück |
| Empfänger ruht | Nachricht startet sofort einen Turn | b antwortete binnen 3 s |
| Empfänger arbeitet | Nachricht kommt **zwischen zwei Tool-Calls** an, der Turn läuft weiter | b mitten in einem 40-s-Befehl: Vorschauzeile sofort sichtbar, an Claude gegeben direkt nach dem Befehl |
| Offene Rückfrage (AskUserQuestion) | **Dialog bleibt unberührt**, Nachricht kommt nach der Antwort | Antwort „Rot“ blieb, PING „Blau“ kam danach als eigene Nachricht |
| Offene Freigabe (Bash) | ebenso: Dialog bleibt, Nachricht danach | `rm` blieb stehen, bis abgelehnt wurde |
| Bypass ↔ Bypass, über Konten | zugestellt | e (`ai2`, Bypass) → d (`ai`, Bypass) |
| Nicht-Bypass → Bypass (und umgekehrt) | **gehalten**, Dialog „Held message“ mit Vorauswahl **Deny** | gilt in beide Richtungen, auch für Antworten; die Registry meldet dabei `waiting` / `permission prompt` |
| Einfügen + Enter in den Halte-Dialog | **lehnt die Nachricht ab**, der eingefügte Text ist weg | genau das, was `chats send` täte |
| `crossSessionInbound: "accept"` per `--settings` | Halten entfällt für diesen Empfänger | d nahm die Nachricht von a an |
| Empfänger am Limit (simuliert, lokaler Fake-Server mit 429) | Nachricht kommt an, der Turn scheitert; Hook `StopFailure` mit `error: "rate_limit"`; Claude zeigt „Continuing automatically at 7:23am“ | Absender bekam nur „in that session's inbox, not yet read“ |
| Codex-Chat | nicht erreichbar, hat kein Postfach | `chats address` antwortet dort mit „nicht nativ erreichbar“ |

**Hook `UserPromptSubmit` feuert bei jeder nativen Nachricht**, auch mitten im Turn. Der Prompt ist erkennbar
verpackt:

```
<cross-session-message from="uds:/tmp/cc-socks/4923.sock" from-name="a" from-mode="prompting">
PING-1 von a
</cross-session-message>
```

`from` ist die geprüfte Adresse (Claude prüft die PID des Absenders), `from-name` schreibt der Absender selbst
und ist nicht vertrauenswürdig. `from-mode` ist `prompting` oder `bypass`.

**Was der Empfänger sieht:** Claude weiß, dass die Nachricht von einer anderen Sitzung kommt und nicht vom User.
Eine Nachricht ohne klaren Auftrag („PING“) behandelt Claude als Hinweis und tut nichts. Aufträge müssen also
ausdrücklich formuliert sein.
**Was Giuliano sieht:** eine gedimmte Zeile `› Message from @a: PING-1 von a (ctrl+o to expand)` im
Empfänger-Chat. Gehaltene Nachrichten erscheinen als Dialog.
**Was der Absender sieht:** „success … in that session's inbox, not yet read by its Claude“. Wird gehalten
oder abgelehnt, folgt ein `[Cross-session delivery notice]`. Eine Lesebestätigung gibt es nicht.

**Namen:** Ohne Angabe heißen Sitzungen nach dem Ordner (`whisperm8-0a`). `claude --name <name>` setzt den
Namen (`nameSource: "user"`); danach findet `ListAgents` den Chat unter diesem Namen.

**Grenzen laut Doku:** etwa 1 Mio. Zeichen je Nachricht, Bremse gegen Schleifen, höchstens 50 wartende und 100
gehaltene Nachrichten. Seit 2.1.323 dürfen Sitzungen sich etwa 100.000 statt 20 Nachrichten ohne Rückfrage
schicken.

**Nicht gemessen:** das Hauptkonto (ohne `CLAUDE_CONFIG_DIR`; gleicher Socket-Ordner, also gleiches Verhalten
zu erwarten), ein echtes Limit (nur simuliert), `notify_when_idle` (im Oktober über Konten bestätigt).

**Wichtig für die App:** Alle WhisperM8-Chats laufen mit `--dangerously-skip-permissions` (Einstellung
`claudeExtraArguments`), sind also eine Rechte-Klasse. Untereinander wird darum ohne Halten zugestellt. Gehalten
wird nur, wenn ein Chat in einem anderen Modus läuft oder eine Sitzung außerhalb der App schreibt.

## 2. Durchsicht der CLI

Weg heute: `chats send` → Socket der App → Statusprüfung → Marker-Zeile → Text als Einfüge-Block
(`ESC[200~ … ESC[201~`) ins Terminal → 80 ms später Enter. `enqueue` legt den Auftrag in
`agent-prompt-queue.json`; zugestellt wird nur, wenn der Chat ruht oder einen Turn beendet.

### Fehler

| # | Was | Fundstelle | Wirkung |
|---|---|---|---|
| F1 | `send` lässt „wartet auf Antwort“ standardmäßig zu (`ifStatus` = `awaitingInput, idle`) | `AgentControlRequestHandler.swift:162` | Text landet im Feld „Type something“ der Rückfrage, das Enter schickt ihn als Antwort ab. Das ist der Vorfall aus WM8-71 (fünfmal diese Nacht). Bei einem Halte-Dialog lehnt das Enter die Nachricht ab |
| F2 | Einfüge-Klammern immer, auch in Shell-Tabs | `AgentTerminalView.swift:820` | `^[[200~` erscheint als Text, das Enter führt aus (WM8-47). Die Controller-Bedienung prüft das schon (`ControllerActionDispatcher+Round5.swift:36`) |
| F3 | Unbekannter Status lässt alles durch | `AgentControlRequestHandler.swift:215` (`let runtime`), `:1091` | Shell-Tabs und Chats ohne erste Statusmeldung haben keinen Schutz |
| F4 | Warteschlange stellt nur am Turn-Ende zu, ohne Nachversuch | `AgentPromptQueueDelivery.swift:67-75`, Auslöser nur `AgentSessionStatusCoordinator.swift:1028/1068` | Bei einem fast immer arbeitenden Chat (Jarvis) verliert sie jedes Rennen; nach ESC-Abbruch oder weggeklickter Rückfrage hängt sie, bis der nächste Turn endet. Pro Turn-Ende geht nur ein Auftrag raus |
| F5 | Zwei schnelle Sends können sich mischen | `AgentTerminalView.swift:825` (Enter 80 ms nach dem Einfügen, Status bleibt `idle`, bis ein Hook „arbeitet“ meldet) | Zweiter Text hängt am ersten oder landet in Claudes eigenem Puffer |
| F6 | Schutz gegen doppeltes Einfügen wirkt nicht | `ChatsControlClient.swift:33` (neue `requestID` je Aufruf) | Jeder Wiederholungsversuch fügt neu ein; die Doku verspricht anderes (`agent-chats-cli.md:339`) |
| F7 | `queue` meldet einen hängenden Auftrag als „fließt gleich ab“ | `ChatsQueueBlockExplainer.swift:46-49` | Der Stau aus F4 bleibt unsichtbar |

### Fallen

| # | Was | Fundstelle | Wirkung |
|---|---|---|---|
| L1 | `send` an einen arbeitenden Chat sagt ab, statt vorzumerken; die Meldung nennt `enqueue` nicht | `AgentControlRequestHandler.swift:215-216` | Rund ein Dutzend Handgriffe diese Nacht |
| L2 | „✓ delivered“ heißt nur „Schreiben angestoßen“; die Antwort geht raus, bevor das Enter geschrieben ist, und niemand prüft, ob Claude den Prompt angenommen hat | `AgentControlRequestHandler.swift:245`, Warteschlange `AgentPromptQueueDelivery.swift:84` | Am Limit ist die Nachricht verbraucht, ohne dass jemand es merkt (WM8-69/70) |
| L3 | Exit 4 fasst „arbeitet“, Entwurf, Start, tote PTY und „Zustand unklar“ zusammen; Exit 5 heißt auch „Antwort nach 12 s ausgeblieben, vielleicht doch zugestellt“ | `ChatsControlProtocol.swift:129` | Agenten raten aus deutschem Fehlertext; Hilfsfelder `isRetryable`/`alternative` sind ungenutzt (`:136-150`) |
| L4 | `--json` gibt bei Fehlern nichts auf stdout aus | `ChatsLiveCommands.swift:72-77` | Skripte sehen nur stderr |
| L5 | Marker nennt Titel und Uhrzeit, keine Kurz-ID und keine Rückadresse | `AgentControlRequestHandler+Marker.swift:12` | Der Empfänger weiß nicht sicher, wem er antworten soll |
| L6 | Text kommt über die Kommandozeile | `ChatsLiveCommands.swift:142` | Backticks und `$` im Bash-Aufruf des Absenders wertet die Shell aus |

### Fehlt

- Rückmeldung an den Absender, wenn ein vorgemerkter Auftrag zugestellt wurde oder der Empfänger am Limit
  scheiterte. Die App kennt `StopFailure` noch nicht (nicht in `ClaudeHookSettingsBuilder.swift`).
- Ablaufzeit für offene Aufträge in der Warteschlange.
- Text über stdin oder aus einer Datei.
- Vormerken, während die App nicht läuft.

## 3. Drei Wege

### A — CLI härten, die CLI bleibt Standard

- `awaitingInput` aus dem Standard von `send` nehmen (F1); `send` merkt bei „arbeitet“, Rückfrage, Entwurf und
  Start selbst vor und meldet „vorgemerkt als Nr. N“ (L1).
- Shell-Tabs: nur mit Einfüge-Modus und an der Eingabeaufforderung, sonst Absage (F2, F3).
- Warteschlange auch beim Wechsel auf „ruht“ zustellen und alle 15 s nachsehen, mehrere Aufträge bündeln (F4).
- `StopFailure` als Hook aufnehmen; „zugestellt“ erst nach `UserPromptSubmit` melden, sonst „unbestätigt“ (L2).

**Im Alltag besser:** keine Absagen mehr, keine überschriebenen Rückfragen, Limit wird bemerkt.
**Bleibt schlecht:** Meldungen an Jarvis kommen weiter erst am Turn-Ende (WM8-71 bleibt offen), alles läuft
weiter über simulierte Tastatur.
**Aufwand:** 1,5 bis 2 Tage mit Tests. **Risiko:** gering, aber jede Rennbedingung im Terminal bleibt eine
mögliche Fehlerquelle. **Fremde Daten:** keine.

### B — nativ als Standard, die CLI als Rückfall (empfohlen)

- **Skills umstellen** (`whisperm8-chats-skill.md`, `whisperm8-jarvis-skill.md`): Für einen laufenden
  Claude-Chat in jedem Konto ist `chats address` + `SendMessage` der Normalfall, auch für Aufträge. `chats send`
  / `enqueue` nur noch für Codex-Chats, gestoppte Chats, Terminal-Tabs und wenn eine Nachricht gehalten wurde.
  Heute sagt der Skill das Gegenteil („Arbeitsauftrag → `chats send`“, Jarvis: „Ein arbeitender Chat bekommt
  `enqueue`“).
- **Namen:** Die App startet Claude-Chats mit `--name <Kurzname>` (etwa `noa-wm8-79`), damit `ListAgents` im
  eigenen Konto dieselben Namen zeigt wie die App. `chats address` bleibt das Adressbuch über alle Konten.
- **Sichtbarkeit:** Die Hook-Brücke erkennt `<cross-session-message …>` in `UserPromptSubmit` und schreibt
  einen Eintrag ins Audit (Absender, Empfänger, Zeit), damit Giuliano nachvollziehen kann, wer wem was gesagt hat.
- **Limit:** `StopFailure` in die Hook-Settings aufnehmen. Scheitert ein Turn mit `rate_limit` direkt nach
  einer nativen Nachricht, meldet die App das dem Absender (Board, Statuszeile oder `chats send` an ihn).
- **Rechte-Klasse:** Alle App-Chats laufen heute im Bypass und erreichen sich ohne Halten. `crossSessionInbound`
  bleibt auf dem Standard. „accept“ würde auch Nachrichten von Sitzungen ohne Bypass durchlassen; das ist genau
  der Rechte-Umweg, den Claude mit dem Halten verhindert.
- Dazu die drei Sofort-Härtungen aus A, weil der Rückfall bleibt: F1 (keine Texte in offene Rückfragen),
  F2/F3 (Shell-Tabs), L1 (`send` merkt selbst vor).

**Im Alltag besser:** Nachrichten kommen mitten im Turn an, auch bei Jarvis (WM8-71 erledigt sich). Keine
überschriebene Rückfrage, keine Einfüge-Klammern, keine Absage „Ziel ist working“, Antworten mit Rückadresse.
Über Konten geht es mit dem Adressbuch, das es schon gibt.
**Aufwand:** etwa 1 Tag (Skills, `--name`, Hook-Erkennung, `StopFailure`) plus 0,5 Tag für die Härtungen.
**Risiken:** Claude Code kann das Messaging ändern (es wird gerade oft angepasst); dagegen hilft das
Prüfskript. Native Nachrichten laufen an Marker, Selbst-Send-Schutz und Ein-Hop-Regel von `chats send` vorbei;
die Regeln stehen dann nur im Skill. Gemischte Rechte-Modi führen zum Halte-Dialog mit Vorauswahl „Deny“.
**Fremde Daten:** nur lesen, wie heute (`<config>/sessions/*.json` durch `chats address`). `--name` und die
Hook-Settings gehören der App (`claude-hooks/<id>.json` in Application Support).

### C — die mitgelieferte Erweiterung schließt die Lücke

Das Plugin `whisperm8` ist bereits ein Mod (`register.tsx`: Board, Ansagen, Zwischenablage, Wecken per
`$.prompt.submit`). Es könnte bekommen:

- ein Werkzeug `chat_send(ziel, text)`, das das Ziel über `whisperm8 chats address --json` in jedem Konto
  findet und per `$.session.send({to: "uds:…"})` zustellt. Codex und gestoppte Chats leitet es selbst an
  `chats enqueue` weiter. Ein Werkzeug für alles, kein Bash-Aufruf im Chat;
- den Hook `session.receive`, der jede eingehende Nachricht sieht, bevor Claude sie liest (`origin.kind` = `peer`):
  Audit, Board-Zähler, Schutz gegen Weiterreichen.

**Im Alltag besser:** wie B, dazu ein einziges Werkzeug und durchgesetzte Regeln statt Skill-Text.
**Aufwand:** 1,5 bis 2 Tage. **Risiken:** Ob `$.session.send` eine `uds:`-Adresse eines anderen Kontos annimmt,
steht nicht in der Doku und ließ sich ohne Installation eines Mods nicht testen (das war für diese Untersuchung
ausgeschlossen). Die Mod-API ist jung (ab 2.1.287) und läuft ohne Sandbox. `register.tsx` darf nicht in
Teildateien zerfallen, das Plugin wird nur per Symlink-Tausch umgestellt.
**Fremde Daten:** keine; das Plugin kommt aus dem App-Bundle über `CLAUDE_CODE_PLUGIN_DIRS`.

### Empfehlung

**B jetzt, C später nur bei Bedarf.** B nutzt nur, was gemessen ist, und der Rückfall wird durch die drei
Härtungen sicher. C lohnt sich, wenn sich nach einigen Tagen zeigt, dass Chats die Regeln im Skill nicht
zuverlässig befolgen. Dann zuerst `$.session.send` über Konten an einer Test-Instanz prüfen.

## Prüfskript

`scripts/claude-peer-messaging-check.sh [konto-a] [konto-b]` (Standard `ai ai2`) misst die vier Grundlagen:
Sichtbarkeit je Konto, Zustellung über Konten, `UserPromptSubmit` mit Hülle, unberührte Rückfrage. Lauf am
14.11.2026 mit 2.1.325: alle acht Punkte OK. Hilfsfunktionen für Einzelmessungen:
`scripts/claude-peer-messaging-lib.sh`; Fake-Server für den Limit-Fall: `scripts/claude-peer-fake-limit-server.py`.
