---
status: aktiv
stand: 2026-11-13
feature: whisperm8 chats (Agent-Chats-CLI / Jarvis)
---

# Agent-Chats-CLI (`whisperm8 chats`)

Jeder Claude-Code-Chat kann über die `whisperm8 chats`-CLI alle anderen
WhisperM8-Agent-Sessions sehen und verwalten — das „Jarvis"-Supervisor-Feature,
umgesetzt als CLI + Skill statt als UI. Plan-Dokumentation (Konzept, Mockups):
`docs/plans/whisperm8-chats-cli/`.

## Zwei Pfade

- **Lese-Pfad, app-unabhängig:** Die CLI ist das App-Binary (argv0-Multiplex in
  `CLIEntryPoint`). Sie liest `AgentSessions.json` read-only
  (`ChatsWorkspaceReader` → `AgentWorkspaceRepository.load`, kein Store, keine
  Schreib-Nebenwirkung) und leitet den Runtime-Status one-shot aus den
  Transcripts ab (`ChatsStatusProbe` mit denselben puren Bausteinen wie der
  `AgentSessionRuntimeWatcher`: `AgentTranscriptLocator` → stat → Tail →
  `AgentTranscriptParser` → `AgentTranscriptStatusDecider`). Funktioniert auch
  bei geschlossener App (`live: false`, Status geschätzt).
- **Schreib-/Live-Pfad, nur mit App:** Mutationen und Live-Status laufen über
  einen BSD-Unix-Domain-Socket (`AgentControlServer`, gestartet in
  `applicationDidFinishLaunching`). Die App bleibt Single Writer für den
  Workspace — die CLI schreibt nie selbst an `AgentSessions.json`.

## Befehle

| Befehl | Klasse | Pfad |
|---|---|---|
| `list`, `overview`, `show`, `tail`, `wait`, `audit`, `archived`, `duplicates`, `address` | Lesen | Disk (+ optionaler Live-Merge; `address`: Claudes Registry) |
| `send`, `interrupt`, `open`, `close`, `reopen`, `pin`/`unpin`, `order`, `move`, `move-account`, `window list`, `resume`, `new`, `rename`, `group`, `archive`, `unarchive`, `workspace …` | Handeln | Socket → App |

### Claude-Account-Profil neuer Chats

`new` legt einen Claude-Chat immer in **einem** Account an — und zwar in dem,
der in den WhisperM8-Einstellungen (Agent Chats → Claude Accounts) aktiv ist.
Das gilt für jeden Erstellungsweg gleichermaßen: GUI, CLI und Jarvis.

```bash
whisperm8 chats new --project whisperm8 --title "Analyse"            # aktives Profil
whisperm8 chats new --project whisperm8 --title "Analyse" --account main      # ausdrücklich Haupt-Account
whisperm8 chats new --project whisperm8 --title "Analyse" --account PowerUser # ausdrücklich Zusatzkonto
```

**Terminal-Tab:** `whisperm8 chats new --project <ordner> --provider terminal [--title T] [--command "…"]`
legt einen Terminal-Tab an wie das Menü. `--command` ist für Tests gedacht und braucht den Debug-Steuerkanal
(`debugControlEnabled`): Wer `whisperm8 chats` pauschal erlaubt, gäbe sonst jedem Agenten eine Shell an den
Rechte-Abfragen von Claude Code vorbei. Ohne Schalter bricht der Befehl mit Exit 1 und einer Meldung ab und legt
nichts an; ein Terminal-Tab ohne Befehl geht immer. Ein Befehls-Tab, der in einem früheren App-Lauf angelegt und nie
angezeigt wurde, startet nicht mehr von selbst: Er zeigt „Befehl noch nicht gestartet“ samt Befehl und den Knopf
„Befehl ausführen“. `chats resume` auf einen vorhandenen Befehls-Tab führt dessen Befehl erneut aus, auch ohne den
Schalter; das betrifft nur Tabs, die einmal mit Schalter angelegt wurden. Mit `--command` läuft statt der Login-Shell `/bin/sh -c "<befehl>"`
im Projektordner (Umgebung wie in Terminal-Tabs, PATH aus der Login-Shell, aber ohne `.zshrc`, Aliase und
Shell-Funktionen). Endet der Befehl, endet sein Prozess; der Tab bleibt mit „Befehl beendet“ stehen, und sein Knopf
„Befehl erneut ausführen“ startet ihn noch einmal, von selbst läuft er nie erneut. Läuft der Befehl, fragt das
Schließen des Tabs immer nach. `--prompt` und `--account` gelten hier nicht. Der Befehl steht im Klartext in der
Workspace-Datei (`AgentSessions.json`), also keine Geheimnisse hineinschreiben.
Gestartet wird wie bei jedem Chat, sobald der Tab angezeigt wird. Die CLI wartet kurz und sagt auf stderr, ob der
Tab läuft (`Terminal-Tab läuft (PID …)`), schon fertig ist (kurze Befehle) oder noch auf seine Anzeige wartet
(`whisperm8 chats open <ref>`); das
JSON auf stdout hat dieselbe Form wie bei Claude und Codex (`result.session.id`, dazu `kind: terminal`). Der Befehl
steht nicht im Audit. `chats show --json` nennt für jeden laufenden Tab (Terminal, Codex, Claude) die PID des
obersten Prozesses im PTY unter `runtime.pid`. `chats send` erreicht einen laufenden Terminal-Tab ohne Marker-Zeile.

Die Erfolgsmeldung nennt das Konto und woher es kommt
(`Konto: RankM8 (aktiv in den Einstellungen)` bzw. `(--account)`), im
`--json`-Modus stehen `session.account` (immer der Name, auch `main`) und
`session.accountSource` (`active` · `explicit` · `killSwitch`). Codex-Chats
haben kein Claude-Konto: dort ist `session.account` `null` (bis 13.11.2026
stand dort fälschlich `main`), und `--account` zusammen mit
`--provider codex` ist ein Bedienfehler (Exit 1).

Der Befehl **scheitert mit Exit 3**, statt still auf den Haupt-Account
auszuweichen, wenn das gewählte Konto nicht taugt — egal ob es per `--account`
genannt oder in den Einstellungen aktiv ist:

- das Profil existiert nicht (auch: `.active` nennt ein gelöschtes Profil),
- `.active` ist vorhanden, aber nicht lesbar (Rechte, Ordner statt Datei, kein
  UTF-8) — nur eine fehlende oder leere `.active` heißt `main`,
- es hat keine Kontodaten (`oauthAccount` fehlt in seiner `.claude.json`) oder
  keinen Login im Keychain (gilt nur für Zusatzprofile),
- sein Login ist nachweislich abgelaufen (30-Tage-Frist, siehe
  [Claude-Konten](agent-chats/claude-konten.md#login-frist-und-erneuerung)).

`main` sperrt nur ein nachweislich abgelaufener Login: dort läuft Claude auch
mit API-Key, `apiKeyHelper` oder über einen Proxy, ganz ohne OAuth-Login.
Die Liste „Angemeldet: …“ in der Meldung nennt nur Konten, die die Prüfung
bestehen — abgelaufene fehlen.

**Offen** (aus dem Review vom 13.11.2026, bewusst später):
- Timeout für das Lesen des Keychains (`security` kann bei gesperrtem
  Schlüsselbund hängen).
- Exit-Codes trennen: Konto-Fehler und Projekt-Fehler von `new` sind beide 3.
- `chats address` meldet das Konto aus Claudes Registry, `list`/`show` aus dem
  Transcript-Ort — vereinheitlichen.
- `move-account` sollte `AccountSwitchPlanner.decide` direkt nutzen statt die
  Regeln über `AccountMoveStopResumePlanner` nachzubauen.
- main mit nachweislich abgelaufenem OAuth-Login wird gesperrt, auch wenn
  Claude dort per API-Key oder Proxy liefe.
- `move-account` liest die `.claude.json` eines Zusatzprofils (Kontodaten) im
  MainActor-Block.

Die Meldung nennt die angemeldeten Konten und den Ausweg (`--account <profil>`
oder ein anderes Konto aktiv setzen bzw. den Login erneuern). Grund: eine im
falschen Konto entstandene Session lässt sich nur noch per Transcript-Umzug
korrigieren. Die Prüfung läuft im Control-Server vor dem Anlegen und abseits
des Main Threads (`ClaudeAccountProfiles.resolveNewChatAccount`, ein
`security`-Aufruf); ist der Keychain gerade nicht lesbar, blockiert sie nicht.
Profilnamen sind unabhängig von Groß-/Kleinschreibung (`--account rankm8`
→ `RankM8`). Der Stempel bekommt immer den echten Ordnernamen: Claude bildet
den Keychain-Namen aus dem unveränderten `CLAUDE_CONFIG_DIR`, ein klein
geschriebener Pfad stünde auf APFS zwar im richtigen Ordner, aber ohne Login da.

Der Stempel wird beim Anlegen eingefroren: ein späterer Wechsel des aktiven
Kontos hängt bestehende Chats nicht um, weil deren `--resume` sonst im falschen
`projects/`-Root suchen würde. Zum nachträglichen Umziehen dient „Zu Account
verschieben" in der App bzw. `chats move-account` (unten).

Kill-Switch (stellt das alte Verhalten her — alles Neue startet im
Haupt-Account): `defaults write com.whisperm8.app chatsNewProfileDefaultEnabled -bool NO`.

**Ausnahme Background-Agenten** (`claude --bg`): laufen weiterhin immer im
Haupt-Account. Supervisor-Daemon, `~/.claude/jobs/` und die Lifecycle-Aufrufe
(`claude logs/stop`) sind fest darauf verdrahtet. Die CLI legt keine
Background-Agenten an; `list`/`show` zeigen für sie `account: "main"`.

**Fork und Resume** folgen nie dem aktiven Konto, sondern dem Chat: ein Fork
(Kontextmenü) erbt das Konto der Quelle, `chats resume` startet im Konto des
Chats — genauer dort, wo sein Transcript liegt, denn nur dort findet
`claude --resume` den Verlauf.

### Konto eines Chats ablesen

`list --json` und `show --json` führen je Chat das Feld `account`: den Namen des
Claude-Kontos, `"main"` für das Hauptkonto, `null` für Codex-, Terminal- und
Agent-View-Tabs. Maßgeblich ist der Ort, an dem das Transcript liegt — dorthin
folgt auch der nächste Start (Resume-Selbstheilung im `AgentCommandBuilder`).
Weicht der gespeicherte Stempel davon ab, steht er zusätzlich unter
`accountStamp`. Vor der ersten Antwort (noch kein Transcript) gilt der Stempel.
`show` zeigt dasselbe als Zeile `Konto`. Das rohe Stempelfeld bleibt unter
`detail.claudeProfileName` (`null` = main).

### Arbeitsordner eines Chats ablesen

`list --json` und `show --json` führen je Chat das Feld `workingCopy`: wo der
Chat zuletzt gearbeitet hat, mit `kind` (`main` = Hauptordner des Projekts,
`worktree` = Arbeitskopie, `other` = Ordner außerhalb des Projekts), `name`
(Name der Arbeitskopie bzw. des Ordners, im Hauptordner `null`), `path`,
`branch`, `defaultBranch` (aus `origin/HEAD`) und `isDefaultBranch`. Ohne
bisherige Beobachtung ist das ganze Feld `null`. `chats list` zeigt es knapp
in der Spalte `ORT`: `main` (Hauptordner auf dem Standard-Branch),
`main@<branch>` (Hauptordner auf einem anderen Branch), `wt:<name>@<branch>`,
`other:<name>`; nennt der Name den Branch schon, steht er nur einmal da.
`show` zeigt eine Zeile `Ort`. Die App leitet den Wert aus dem Verlaufsende
ab, nicht aus dem Startordner; ruhende Chats behalten den letzten Stand.

### Bestehende Chats umziehen

In der App über das Kontextmenü eines Chats bzw. einer Auswahl: **„Zu Account
verschieben"**. Der Umzug bewegt das Transcript in den `projects/`-Root des
Zielkontos — nur dort sucht `claude --resume`, der Ablageort entscheidet also,
unter welchem Konto der Chat weiterläuft. Die CLI-Entsprechung ist
`whisperm8 chats move-account` (siehe unten).

Vor der Ausführung zeigt eine Vorschau, was verschoben und was übersprungen
wird — mit Grund je Chat: laufend, Hintergrund-Agent, kein Claude-Chat, schon
im Zielkonto, Namenskollision im Ziel, Zielkonto nicht eingeloggt. Laufende
Chats werden nie stillschweigend gestoppt; der Prozess hält seine Registry im
alten Config-Dir und schriebe weiter in die alte Datei.

Was mitwandert: der vollständige Gesprächsverlauf samt Subagent-Transcripts.
Was zurückbleibt: Checkpoints und Datei-Historie (`file-history/<session-id>/`,
`session-env/<session-id>/`) — sie liegen außerhalb von `projects/`. Ab dem
nächsten Start zahlt das Kontingent des Zielkontos.

Während des Umzugs pausiert der Indexer-Scan; danach läuft genau einer. Ein
Abbruch wirkt nach dem aktuellen Chat, nie mitten in einer Bewegung. Bereits
verschobene Chats bleiben verschoben — ein Bulk ist nicht atomar, und ein
automatischer Rollback nach halber Strecke könnte selbst scheitern. Stattdessen
protokolliert `account-moves.jsonl` jeden Batch, und **„Letzten Kontowechsel
rückgängig machen"** fährt ihn zurück (dieselbe Bewegung mit vertauschten
Argumenten). Chats, die in dem Moment laufen, nimmt „Rückgängig" nicht zurück: ihr
Prozess schreibt weiter in die jetzige Datei, ein Rückzug darunter teilte den
Verlauf auf zwei Dateien auf. Sie werden gemeldet und bleiben im Journal —
nach dem Anhalten holt ein erneutes „Rückgängig" genau sie nach.

Kill-Switch für den Mehrfach-Umzug (der Einzel-Umzug bleibt):
`defaults write com.whisperm8.app accountBulkMoveEnabled -bool NO`.
Er wirkt nur auf das Kontextmenü; die CLI nimmt immer genau die genannten Refs.

#### Per CLI: `move-account`

```bash
whisperm8 chats move-account <ref> [<ref>…] --to <profil> --dry-run   # Vorschau, ändert nichts
whisperm8 chats move-account <ref> [<ref>…] --to <profil>             # umziehen
whisperm8 chats move-account <ref> [<ref>…] --to <profil> --stop-and-resume [--force]
```

Dieselbe Kette wie das Kontextmenü (`AccountMoveFacts` → `AccountMovePlanner`
→ `AccountMoveService`, Control-Methode `session.moveAccount`): identische
Skip-Regeln, dasselbe Journal — „Letzten Kontowechsel rückgängig machen" in
der App nimmt einen CLI-Umzug genauso zurück. `--to main` zieht zurück in den
Haupt-Account; ein unbekanntes Profil scheitert mit Exit 3 und nennt die
vorhandenen, die Schreibweise ist egal (`--to rankm8` → `RankM8`). Ein Ziel
ohne Login **oder mit abgelaufenem Login** sperrt den Umzug
(`skipped`/`targetNotLoggedIn`, `result.targetLoginProblem` = `notLoggedIn`
bzw. `loginEnded`) — der Chat stünde sonst im Zielkonto vor dem Login.
**Ausnahme main:** Das Hauptkonto sperrt nur ein nachweislich abgelaufener
Login. Fehlen Kontodaten (`oauthAccount`) oder der Keychain-Eintrag, darf der
Umzug nach main trotzdem laufen, denn dort arbeitet Claude auch mit API-Key,
`apiKeyHelper` oder über einen Proxy (in Planung und Ausführung gleich,
`executionTargetIsLoggedIn`). **Abweichung von der App:** Die CLI sperrt ein
Zusatzkonto mit abgelaufenem Login; das Kontextmenü „Zu Account verschieben“
prüft nur, ob Kontodaten da sind, und lässt den Umzug zu.
Hat das Zielkonto den Projektordner nie im Trust-Dialog freigegeben, trägt
das Ergebnis `targetTrustMissing: true` und die Textzeile einen Hinweis:
Claude fragt dann beim nächsten Start nach der Freigabe. Bei Chats, die
nicht laufen, ist das unkritisch — sie starten erst, wenn jemand den Tab
öffnet und den Dialog sieht. Laufende Chats hält `--stop-and-resume` ohne
`--force` in diesem Fall nicht an (siehe unten). Refs werden vorab alle aufgelöst (alles oder nichts), ohne
Nachfrage — die Bestätigung holt der aufrufende Agent vorher ein.

Ergebnis je Chat (`--json`: `result.results[]`): `outcome` = `wouldMove`
(Vorschau) · `moved` · `scheduled` (vorgemerkt, wechselt nach dem Turn;
`reason` = `turnRunning`/`awaitingInput`/`unsentInput`/`backgroundTasks`) ·
`wouldSchedule` (Vorschau: der echte Lauf würde vormerken, seit 13.11.2026;
vorher zeigte `--dry-run` diese Chats als übersprungen) · `skipped`
(+ `reason` = Skip-Grund des Planers) · `failed` · `notFound`. Exit: Vorschau 0; sonst 0 nur, wenn danach **jeder**
genannte Chat im Zielkonto ist (umgezogen oder schon dort), andernfalls 4 —
ein Supervisor erkennt „nicht alles erledigt" am Exit-Code.

**Laufende Chats** werden ohne Flag übersprungen; die Vorschau markiert, welche
`--stop-and-resume` mitnehmen würde (`stopAndResumePossible`). Mit dem Flag
passiert für diese Chats:

1. Anhalten wie `close --stop` (2× Ctrl+C, letzter Flush, SIGTERM); der Tab
   bleibt offen.
2. Warten, bis der Prozess **nachweislich beendet** ist (`ProcessExitWaiter`,
   max. 5 s; ein Zombie zählt als beendet). Erst dann schreibt er garantiert
   nicht mehr in die alte Datei — ein Umzug davor könnte eine späte Zeile an
   den alten Ort schreiben lassen, der Verlauf läge dann in zwei Dateien.
   Endet der Prozess nicht, wird weder umgezogen noch neu gestartet
   (`failed`/`stopTimeout`).
3. Frisch planen und umziehen (Kollisionen werden erneut geprüft).
4. Neustart vormerken (`shouldLaunchOnOpen`, wie `resume` und die
   Absturz-Wiederaufnahme): startet, sobald der Tab angezeigt wird — ein
   gerade sichtbarer Tab sofort. Auch ein gescheiterter Umzug wird wieder
   vorgemerkt, dann im bisherigen Konto.

Geschützt bleiben: **arbeitende** Chats (ein Turn würde abgebrochen) und Chats,
in deren Eingabefeld **vermutlich ungesendeter Text** steht (das Beenden der
TUI verwirft ihn). Seit 11.10.2026 werden sie **vorgemerkt** (`scheduled`)
statt blockiert: der `AccountSwitchCoordinator` der App prüft alle 2 s und
wechselt sie, sobald ihr Turn fertig und kein Entwurf mehr zu vermuten ist
(Rückfrage offen → wartet weiter). Nicht vorgemerkt wird, wenn das Zielkonto
den Ordner nie im Trust-Dialog freigegeben hat — der unbeobachtete Neustart
landete sonst in Claudes Dialog mit Vorauswahl „No, exit"; diese Chats bleiben
blockiert (`stopBlocked: "trustMissing"`, auch schon in der Vorschau).

**Fehlende Freigabe hält auch ruhende Chats auf** (seit 13.11.2026): Ohne
`--force` hält `--stop-and-resume` keinen laufenden Chat an, dessen Ordner das
Zielkonto nie freigegeben hat — auch keinen ruhenden. Die CLI wird meist
unbeobachtet aufgerufen, der Neustart bliebe im Trust-Dialog hängen. Ergebnis:
`skipped` mit `stopBlocked: "trustMissing"` und einem Text mit dem Ausweg:
einmal einen Chat in diesem Ordner im Zielkonto öffnen und die Freigabe
bestätigen (etwa `whisperm8 chats new --project <ordner> --account <ziel>`
und im Tab „Yes“ wählen), dann erneut umziehen — oder `--force`, das wie
bisher anhält. Das Kontextmenü der App bleibt dabei: dort wechselt ein
ruhender Chat sofort, weil der User gerade hinschaut.
Als beschäftigt gilt dieselbe Regel wie in der App
(`AccountMoveStopResumePlanner.isBusy` → `AccountSwitchPlanner.waitReason`):
arbeitet, wartet auf eine Antwort (Permission-Dialog), unbekannter Status oder
offene Hintergrund-Tasks. Bis 13.11.2026 zählte die CLI nur „arbeitet" und
hielt einen Chat mitten in einer Rückfrage sofort an. Vormerkungen sind flüchtig (App-Neustart verwirft sie), aufheben
geht im Kontextmenü („Kontowechsel zu … aufheben"). `--force` hält auch
arbeitende Chats sofort an. Das Vormerken gibt es nur, solange
`accountSwitchAfterTurnEnabled` an ist (Standard). Kill-Switch:
`defaults write com.whisperm8.app accountSwitchAfterTurnEnabled -bool NO`
(dann wieder blockiert wie vorher; die Meldung behauptet dann auch keinen
ausgefallenen „Wechsel nach dem Turn“). Die Entwurfs-Schätzung
(`TerminalComposerDraftTracker`) ist konservativ: getippte Zeichen, Einfügen,
Datei-Drop und `send --no-submit` markieren, Return (ohne Shift/Option),
Ctrl+C und ein zugestellter `send` heben die Markierung auf (Details und
Abbruch-Regeln unter „Zurückgelegter Prompt"). Die
**aufrufende Session** wird nie angehalten, auch nicht mit `--force`.
Hintergrund-Agenten, Codex- und Terminal-Chats fasst das Flag nicht an.

### GPT-Konto: bisher nur lesbar

Das **ChatGPT-Konto des GPT-Backends** ist ein zweiter, vom Claude-Account
unabhängiger Stempel (`gptProfileName`, `null` = Hauptkonto). Die CLI zeigt ihn
in `whisperm8 chats show --json` unter `detail.gptProfileName`; ein Flag zum
Setzen (`new --gpt-account`) und eine Konto-Spalte in `list`/`overview` gibt es
noch nicht. Neue Chats aus der CLI erben wie in der GUI das in den
Einstellungen aktive GPT-Konto; umstellen lässt sich ein bestehender Chat nur
im Kontextmenü der App. Details:
[GPT-Konten](agent-chats/gpt-konten.md).

`overview` = `list --sort attention --format board`. Alle Befehle mit `--json`
(schemaVersion 1). Referenzen: `projekt/titel`, UUID-Präfix ≥ 8, `@self`.
Exit-Codes: 0 ok, 1 usage, 3 nicht gefunden/mehrdeutig, 4 Guard-Konflikt, 5 App
unerreichbar, 124 wait-Timeout, 130 unterbrochen.

## Control-Socket

- **Sicherheit:** Ordner `control/` 0700, Socket 0600, `getpeereid`-Prüfung
  (Peer-EUID == App-EUID), `flock` gegen Doppelstart, sichere Stale-Socket-
  Reklamation (nur eigener toter Socket), `sun_path`-104-Byte-Prüfung mit
  Fallback nach `/private/tmp/whisperm8-<uid>/`. Discovery-Datei
  `control/socket-path`.
- **Protokoll:** NDJSON, ein Request/eine Response pro Verbindung, 1-MiB-Limit,
  `protocolVersion`-Handshake. Typen in `ChatsControlProtocol` (geteilt CLI ↔
  App), Codec `ChatsControlCodec`.
- **Identität:** Die App injiziert beim PTY-Spawn (`AgentTerminalController.start`)
  `WHISPERM8_SESSION_ID` + ein Zufalls-`WHISPERM8_SESSION_TOKEN`
  (`AgentSessionTokenRegistry`). Das Token beweist dem Server, dass der Aufruf
  aus dieser PTY stammt (Selbst-Send-Schutz, „(du)"-Markierung, Audit). Ehrlich:
  Rechenschaft + Versehens-Schutz, keine Boundary gegen einen absichtlich
  bösartigen Prozess desselben Users.
- **Hintergrund-Agents (seit 11.11.2026):** Claudes Daemon und alle Worker,
  die er startet, erben die Umgebung des Chats, der den Daemon zuerst gestartet
  hat — samt `WHISPERM8_SESSION_ID`/`_TOKEN`. Die Umgebung ist bei ihnen deshalb
  kein Beleg. `AgentCallerIdentityCheck` sucht den nächsten Claude-Prozess in
  der Prozesskette in Claudes Registry. Ist er ein Hintergrund-Agent
  (`kind: "bg"`), gehört der Aufruf dem Chat, dessen `externalSessionID` seine
  `sessionId` ist, sonst keinem.
  - Der Server lässt eine behauptete Identität samt Token nur gelten, wenn die
    PTY dieses Chats in der Prozesskette des Aufrufers steht: Prozess-ID des
    Socket-Partners (`LOCAL_PEERPID`), Eltern per `sysctl`, PTY-PID aus
    `AgentSessionTokenRegistry`. Daemon und Worker sind keine Nachfahren der
    PTY, deshalb fällt geerbte Identität heraus, auch ohne Registry-Eintrag.
    Der Aufrufer gilt dann als extern. Log: `control_caller_identity_dropped`.
    Nebenwirkung: Aus einer PTY abgekoppelte Prozesse (`nohup … &`, die bei
    launchd landen) gelten ebenfalls als extern.
  - Die CLI korrigiert `@self` und „(du)“ auf dieselbe Weise
    (`ChatsCallerIdentity.checked`). Die Sitzungsliste lädt sie nur, wenn ein
    Hintergrund-Agent dahintersteht.
  - Die Board-Mod in `register.tsx` übernimmt den Besitzer, den
    `chats board --json` liefert. Meldet die CLI keinen Besitzer, zeigt die Mod
    kein Board, auch nicht das des geerbten Chats.
  - Grenze: Die CLI prüft lokal nur über Claudes Registry. Ein Hintergrund-
    Prozess ohne Registry-Eintrag sieht lokal weiter die geerbte Identität,
    bei der App kommt er damit aber nicht durch.
- **Kill-Switch:** `defaults write com.whisperm8.app agentControlServerEnabled -bool NO`.

## Send-Pipeline (TOCTOU-frei)

`session.send` prüft alle Guards und pastet in EINEM synchronen
`MainActor.run`-Block (kein `await` zwischen Status-Check und Paste):
① existiert + nicht archiviert → ② Ziel ≠ Actor (Selbst-Send, nie überstimmbar)
→ ③ laufende PTY → ④ Status ∈ `--if-status` (Default `awaitingInput,idle`;
`--force` überstimmt) → ⑤ Prompt nicht leer → ⑥ kein vermuteter Entwurf im
Eingabefeld (`--force` überstimmt; ein alter Rückleger wird stattdessen geleert,
siehe unten). Danach Bracketed Paste
(`ESC[200~ … ESC[201~`, Pflicht gegen Newline-Auto-Submit) + CR nach 80 ms.
Idempotenz-Cache (requestID, 60 s) verhindert Doppel-Paste bei Retry. Jeder Send
an einen Claude- oder Codex-Chat bekommt die Marker-Zeile `[via whisperm8 chats ·
von <actor> · HH:MM]` vorangestellt (Ein-Hop-Regel im Skill). An Shell-Tabs geht
der Text ohne Marker: Dessen Zeilenumbruch schickte sonst `[via …` als Befehl
ab, und die Herkunft steht ohnehin im Audit-Log (gilt auch für die
Warteschlange). Bekannte Grenze: Läuft `claude` oder `codex` selbst in einem
Shell-Tab, bekommt dieser Agent `whisperm8 chats send` ebenfalls ohne Marker;
erkannt wird nur die Art des Tabs, nicht das Programm darin.

### Zurückgelegter Prompt nach Abbruch (Send-Schutz)

Nach dem Abbruch eines Turns legt die Claude-CLI den Prompt des abgebrochenen
Turns selbst in den Composer zurück (Interrupt-Restore); die Rewind-Auswahl
(Doppel-ESC, dann Return) legt eine alte Nachricht dorthin. Ein
programmatischer Versand, der seinen Text daran anhängt, ließe den
zurückgezogenen Auftrag mit dem neuen zusammen erneut laufen.

**Vor jeder Zustellung** (`send` und Queue) prüft die App deshalb, was im
Eingabefeld stehen könnte (`TerminalComposerDraftTracker`, pur getestet):

- **Eigener Entwurf des Users vermutet** (getippt, eingefügt, Datei-Drop,
  `send --no-submit`, auch ein bearbeiteter Rückleger): nie anhängen. `send`
  scheitert mit `conflict`/Exit 4 und nennt die Auswege (`enqueue`,
  `--force`); die Queue lässt den Auftrag stehen („Entwurf im Eingabefeld")
  und stellt ihn beim nächsten Turn-Ende zu. Eingereihte Aufträge werden nie
  verworfen.
- **Nur ein alter Rückleger vermutet:** Das Feld wird vorher per Ctrl+C
  geleert (nur Claude-Chats im Status `idle`; in einer offenen Rückfrage
  bräche Ctrl+C den Dialog ab), auch bei `send --no-submit`. Die Antwort von
  `send` trägt dann `clearedInput: true`, die Queue loggt es
  (`queue_delivered … clearedInput=true`).
- **Freigabe offen: `approvalPending` (WM8-75, Verhaltensänderung 14.11.2026):**
  `send` bestätigt nie eine Freigabe. Wartet das Ziel auf eine Freigabe oder
  Plan-Freigabe, ist die Art unklar, oder steht bei Claude unten statt des
  Eingabefelds ein Dialog, lehnt `send` VOR dem Einfügen mit `approvalPending`
  (Exit 4, `isRetryable`, Ausweg `enqueue`) ab — auch mit `--force`. Vorher
  wurde der Text dort ignoriert und das Enter wählte die Vorauswahl „Yes“, auch
  wenn „nein“ geschickt wurde. Eine offene Frage (AskUserQuestion) beantwortet
  `send` wie bisher. Geht die Freigabe erst zwischen Einfügen und Enter (80 ms)
  auf, hält `DelayedEnterGuard` das Enter zurück; `send` wartet darauf kurz
  (bis 330 ms) und antwortet dann ebenfalls `approvalPending` statt
  `delivered` (Audit `withheld`, `detail.textInField: true`,
  `detail.resend: false`): Der Text steht im Eingabefeld — nicht neu senden,
  auch nicht per `enqueue`. Die Idempotenz wird erst danach abgeschlossen; ein
  Wiederholen mit derselben requestID bekommt nie „duplicate“ als Erfolg. Die
  Warteschlange verbucht einen Auftrag erst nach dem Enter als zugestellt;
  zurückgehalten bleibt er vorgemerkt (`queue_withheld`), und eine offene
  Freigabe stellt sie gar nicht erst zu. **Bekannte Wirkung:** Jedes `send` mit
  Enter antwortet 180 ms (nach einem Leeren 330 ms) später als bisher; eine
  Freigabe lässt sich per `send` nicht mehr bestätigen; eine Rückfrage, deren
  Art nicht sicher erkennbar ist, lehnt `send` ab. Einen
  gewollten Weg, eine Freigabe per CLI zu bestätigen (Tasten an einen Chat),
  gibt es noch nicht (WM8-64). Details: [controller.md](controller.md),
  Schutzregeln.

Als Abbruch zählt (Claude-Chats, nicht in Dialogen): ESC oder Ctrl+C,
während der Chat `working` ist, **und** innerhalb von 5 s nach einem
programmatischen Absenden unabhängig vom Status — der Registry-Status kommt
kurz nach dem Return, ein schnelles ESC lief vorher als „nur ESC" durch.
Ebenso `chats interrupt`. Ein danach eintreffender Turn-Start vergisst den
Rückleger nicht. Zweimal ESC und dann Return (Rewind-Auswahl) gilt als
Rückleger, nicht als Absenden. ESC und Ctrl+C im Terminal eines arbeitenden
Chats melden zugleich dem Status-Koordinator den Abbruch-Verdacht
(`observeTerminalInterruptKey`): Endet der Turn kurz danach, gibt es kein
„fertig“ und keine Queue-Zustellung — der nächste Auftrag wartet aufs
nächste echte Turn-Ende. Leert ein Ctrl+C nur ein volles Eingabefeld und
endet der Turn zufällig binnen 10 s, wartet die Queue ebenfalls (sichere
Richtung).

Warum eine Schätzung und kein Lesen des Eingabefelds: Die Claude-TUI zeichnet
das Feld mit Ink, versteckt den echten Cursor, zeigt im leeren Feld einen
Platzhaltertext, und Rahmen, Prompt-Zeichen und Lage wechseln mit Version,
Theme, Mods und Fensterbreite (Codex zeichnet ganz anders). Ein Parser des
SwiftTerm-Puffers wäre ein stiller Fehlerpfad. Tastendrücke und eigene
Zustellungen sieht die App dagegen vollständig; die Schätzung irrt in die
sichere Richtung (Fehlalarm = Wartezeit oder ein Ctrl+C in ein leeres Feld).

**Grenze:** Drückt der User selbst Enter auf einen zurückgelegten Prompt,
läuft dieser erneut — das ist eine bewusste Eingabe im Terminal, die App
hält sie nicht auf. Wer einen Auftrag zurückzieht, nimmt deshalb
`chats interrupt <ref> --clear-input` (opt-in): Es schickt 400 ms nach dem
ESC ein Ctrl+C hinterher und leert den Composer — löscht auch einen etwaigen
User-Entwurf, deshalb nie Default. Hat in diesen 400 ms schon ein `send`,
die Queue, ein Einfügen oder ein anderes Leeren ins Feld geschrieben, fällt
das Ctrl+C aus (Log `composer_clear_skipped`): Es träfe sonst den neuen
Auftrag oder wäre der zweite Ctrl+C-Druck in ein leeres Feld, und Claude
beendete sich. `interrupt --clear-input` und ein sofort folgendes `send`
vertragen sich damit.

Der frühere Send-Guard (zweiter `UserPromptSubmit`-Hook `chats _prompt-guard`
mit Zustell-Tokens, seit 2026-08-17) ist seit 05.11.2026 ausgebaut: Er blockte
auch legitime Zustellungen, etwa per `enqueue` eingereihte Prompts. Das
Subcommand antwortet nur noch mit Exit 0 (und liest das Hook-JSON auf stdin
leer, damit die CLI bei großen Prompts kein EPIPE bekommt), damit vor dem
Update gestartete Sessions mit alten Settings bis zu ihrem Neustart ohne
Fehlermeldung laufen. Den alten Token-Ordner `send-tokens/` und den Schalter
`chatsPromptGuardEnabled` räumt `LegacyDataCleanup` einmalig weg.

## close (Tab-Management)

`chats close <ref> [<ref>…]` schließt AUSSCHLIESSLICH offene UI-Tabs — die
bewusst schwache Schwester von `archive`. Contract:

- **Nur UI:** `AgentWindowStore.closeTabInHostingWindow` entfernt den Tab aus
  dem Fenster, das ihn hält (eine Session lebt in genau einem Fenster, daher
  keine `--window`-Optionen). Session-Status, PTY-Prozess, Pin und
  Transcript bleiben unangetastet; erneutes Öffnen attached an denselben
  Terminal-Controller inkl. Scrollback. Wie in der App verlässt der Chat
  dabei jeden Workspace, der gerade in einem Fenster offen ist (Raster rückt
  nach; Workspaces ohne Fenster behalten ihn) — Details in
  [`agent-chats/ui/grid.md`](agent-chats/ui/grid.md).
- **Ohne `--stop` kein Guard:** auch working/awaitingInput-Ziele dürfen
  geschlossen werden — es geht nur die Ansicht zu. Die Response meldet
  `ptyRunning`/`runtimeStatus`/`isPinned` zur Information.
- **`--stop`: Tab zu + Agent beenden.** Die einzige Stufe zwischen „nur
  Ansicht" und `archive`. Der Server terminiert das PTY über
  `AgentTerminalRegistry.terminate` (graceful: 2× Ctrl+C → Snapshot → Kill,
  damit der letzte JSONL-Flush und der `--resume`-Hinweis erhalten bleiben)
  und stuft den Session-Status von `.running` auf `.closed` herunter. NICHT
  archiviert, nichts gelöscht, Pin bleibt — `resume` fährt die Session wieder
  hoch. Response: `stopped` pro Ziel plus `stoppedCount`. Ein Ziel ohne
  offenen Tab meldet `alreadyClosed` und trotzdem `stopped: true`, wenn dort
  ein Prozess lief.
- **Schutz arbeitender Agenten (`--stop` ohne `--force`):** ist auch nur EIN
  Ziel `working`, scheitert der GESAMTE Request mit `conflict`/Exit 4, bevor
  ein Tab schließt oder ein Prozess stirbt — kein Teilzustand. Die Entscheidung
  liegt im puren, unit-getesteten `ChatsCloseStopGuard`; die Meldung nennt die
  blockierenden Ziele und die drei Auswege (warten, `interrupt`,
  `--stop --force`). `--force` ohne `--stop` lehnt schon der Parser ab: ohne
  Stop gibt es nichts zu erzwingen.
- **Batch, alles-oder-nichts bei der Auflösung:** die CLI löst ALLE Refs vor
  dem Request auf (mehrdeutig/unbekannt → Exit 3, nichts wird geschlossen).
  Der Server verarbeitet alle Ziele in EINEM synchronen MainActor-Block
  (`session.close`, `targetSessionIDs`-Array) — ein konsistenter Snapshot,
  keine Cross-Window-Races. Pro Ziel ein Outcome: `closed`, `alreadyClosed`
  (idempotent, kein Fehler) oder `notFound` (Server-autoritativ, z. B.
  Debounce-Race). Exit 0, sofern kein `notFound`.
- **Auswahl-Fallback:** war der geschlossene Tab selektiert, rückt die
  Selektion auf den vorherigen Tab (sonst den neuen ersten); die Session
  verlässt zudem die ephemere Multi-Auswahl des Fensters. Wird ein
  Sekundärfenster leer, schließt es sich über den bestehenden reaktiven
  Pfad (`onChange(of: openTabIDs)` → `closeWindowIfEmptyAndSecondary`).
- **Kein pauschales `--all`:** die Kandidatenauswahl für „schließe alle, die
  ich nicht brauche" trifft der Aufrufer (Jarvis) über `list --open --json`
  (liefert `isOpen`/`isPinned`/`isSelf`/Status) + Batch-Bestätigung — die
  CLI schließt nur explizit benannte Refs.
- **Relative Modi:** `close --others <ref>` schließt alle anderen Tabs im
  Fenster des Ankers, `close --right <ref>` die Tabs rechts davon (genau
  eine Anker-Ref; Opferliste wird im selben MainActor-Block bestimmt wie
  geschlossen — der Anker kann zwischendurch nicht das Fenster wechseln).
  Anker ohne offenen Tab → Exit 4.

## Weitere Tab-/Fenster-Befehle

- **`reopen`** stellt den zuletzt geschlossenen Tab wieder her (LIFO, Cap 20),
  an seiner alten Stelle in der Tab-Leiste und, falls er dabei einen offenen
  Workspace verlassen hat, auch an seiner alten Kachel.
  Die History lebt ephemer im `AgentWindowStore` (bewusst nicht persistiert —
  App-Neustart leert sie) und wird von `closeTab` UND der
  `setOpenTabIDs`-View-Bridge gefüttert (X-Button/⌘W/Bulk); Fenster-Close mit
  Tabs und die Workspace-GC zeichnen nicht auf. Inzwischen archivierte/
  gelöschte oder wieder geöffnete Sessions werden übersprungen; existiert das
  Ursprungsfenster nicht mehr, landet der Tab im Primärfenster.
- **`pin <ref> [<ref>…]` / `unpin …`** setzen den Sidebar-Pin idempotent
  (Batch wie close; Outcomes `pinned`/`unpinned`/`unchanged`/`notFound`).
- **`order <ref> [<ref>…] [--last <ref>]… [--dry-run] [--json]`** setzt die
  Reihenfolge der Chats eines Projekts in der Seitenleiste (Methode
  `session.order`, seit 13.11.2026). Genannte Chats kommen in dieser Folge nach
  vorn, `--last` ans Ende, alle übrigen behalten ihre relative Folge dazwischen.
  Alle Chats müssen im selben Projekt liegen und in dessen Gruppe der
  Seitenleiste stehen (nicht gepinnt, kein Subagent-Kind), sonst Exit 1;
  unbekannte oder archivierte Chats Exit 3. Geschrieben wird über
  `AgentSessionStore.reorderSessions` (`lastActivityAt` bleibt stehen).
  Die Projekt-Ansicht (Raster) hält ihre Plätze sonst absichtlich stabil, auch
  beim Umsortieren mit der Maus; `order` setzt die belegten Plätze bewusst mit
  um, leere Plätze bleiben (`WorkspaceSlotOps.reorderedSlots`). `--dry-run`
  zeigt die Folge vorher und nachher ohne Änderung; `--json` liefert `before`,
  `after` (je `position`, `id`, `title`) und `projectViews` (Plätze vorher und
  nachher). Beispiel, Chats nach Nummer und Jarvis ans Ende:
  `whisperm8 chats order fin ole dex gus vic jon doc --last jarvis --dry-run`.
  Der Befehl antwortet erst, wenn der Workspace auf der Platte steht, damit ein
  `chats list` direkt danach die neue Folge liest (Befund 13.11.2026: vorher
  bis zu 20 s alte Folge).
  **`--tabs`** (Methode `tab.order`) ordnet stattdessen die Tabs eines
  Fensters: Alle genannten Chats müssen im selben Fenster als Tab offen sein
  und zur selben Tab-Gruppe gehören, wie die Tab-Leiste sie bildet
  (`AgentTabGrouping.key`: ein Raster-Workspace geht vor dem Projekt). Die Tabs
  dieser Gruppe werden wie oben geordnet und rücken als Block an die Stelle des
  ersten; andere Tabs behalten ihre Folge davor und dahinter. Die Auswahl im
  Fenster bleibt. Scheitert das sofortige Schreiben, steht im Ergebnis
  `persisted: false` (Folge in der App gesetzt, auf der Platte noch nicht).
- **`move <ref> --window <primary|id>`** verschiebt einen Tab in ein anderes
  BESTEHENDES Fenster (`AgentUIState.moveTab`-Semantik: nicht-offene Tabs
  werden im Ziel geöffnet). Fenster-Refs: `primary` oder ID/-Präfix ≥ 8 aus
  `window list`. Neue Fenster kann nur die App-UI öffnen (SwiftUI-Scene) —
  CLI-detach bleibt Backlog.
- **`workspace add <ws> <ref> [--slot N]` / `workspace remove <ws> <ref>
  [--keep-slot]`** ändern NUR die Grid-Slot-Mitgliedschaft
  (`WorkspaceSlotOps`-Semantik). `--slot` ist 1-basiert. Tab und Prozess
  bleiben — identisch zur Sidebar-Aktion. Seit 2026-08-17 (Jarvis-Befunde):
  - `--slot N` jenseits der aktuellen Stufe **erweitert das Grid** auf die
    kleinste tragende Stufe (bis 3×3; Outcome-Feld `grewTo`). Nur `--slot` > 9
    ist ein Fehler (Exit 1). Volle Endstufe ohne `--slot` → Exit 4.
  - Ein vorhandenes Mitglied wird mit `--slot N` **verschoben/getauscht**
    (Outcome `moved` mit `fromSlot`) — kein remove+add mehr nötig.
  - Die Outcomes sind unterscheidbar: `added`/`moved`/`replaced`
    (`displacedSessionID`)/`alreadyMember`, jeweils mit `slot` (1-basiert).
  - `remove` **kompaktiert per Default** (übrige rücken nach vorn, Stufe
    fällt — global abschaltbar via `gridAutoCompactEnabled`); `--keep-slot`
    erzwingt für diesen Aufruf stabile Positionen (Slot wird nur leer).
    Das Outcome-Feld `keptSlot: true` steht immer dann, wenn der Slot leer
    geblieben ist — mit `--keep-slot` und ebenso, wenn „Close gaps…“ in den
    Einstellungen aus ist.
  - Ablehnungen sind benannt statt gesammelt: Session nicht gefunden →
    Exit 3, Session archiviert → Exit 4 (+ `unarchive`-Hinweis), Slot
    außerhalb → Exit 1.
- **`workspace create "<name>" [--color #RRGGBB] [<ref> …]`** legt einen
  Grid-Workspace an (`gridWorkspace.create`); weitere Refs füllen die Slots in
  Reihenfolge, die Kapazität ist die kleinste passende Stufe (1 bis 9; ohne
  Refs zwei leere Plätze). Mitglieder werden
  hart validiert (unbekannt → Exit 3, archiviert → Exit 4) — kein stilles
  Loch. Antwort enthält `workspace.id` für Folgebefehle.
- **`workspace delete <name|id> [--force]`** löscht die kuratierte Gruppe
  (`gridWorkspace.delete`) — Slots sind Referenzen, Chats/Tabs/Prozesse
  bleiben. Belegte Workspaces verlangen `--force` (Tippfehler-Schutz,
  Exit 4); Fenster-Referenzen räumt der Store in einer Mutation.

## Archiv: Suche + gezieltes Reaktivieren

Strikte Aktions-Trennung (Produktsemantik, nie stillschweigend vermischt):

| Aktion | Wirkung | Wirkung NICHT |
|---|---|---|
| `close` | UI-Tab zu | archiviert/löscht/stoppt nichts |
| `archive` | Markierung `.archived` + `archivedAt`; laufendes Terminal wird terminiert (mit Guard/`--force`) | löscht keine Daten |
| `unarchive` | NUR Markierung weg (`restoreSession`: Status `.closed`, `archivedAt` = nil) | öffnet keinen Tab, startet nichts |
| `resume` | startet/verbindet eine NICHT archivierte Session | reaktiviert nie aus dem Archiv (Exit 4 + Hinweis) |

- **`archived [query] [--project] [--group] [--provider] [--since D] [--until D]
  [--content "text"] [--limit N] [--json]`** — Archiv-Browser, app-unabhängig
  von Disk. `query` sucht normalisiert (Diakritika-/Trenner-tolerant) über
  Projekt/Titel/Gruppe; Zeitraum gegen `archivedAt` (Alt-Daten ohne Feld:
  `lastActivityAt`), `D` = `yyyy-MM-dd` oder relativ (`14d`, `8w`). Sortiert
  neueste zuerst. Jeder Treffer zeigt die Transcript-Verfügbarkeit
  (stat-billig, `ChatsStatusProbe`) — `⚠︎ kein Transcript` heißt: extern
  verschoben/bereinigt, ein Resume startet eine frische CLI-Session ohne
  Verlauf.
- **`--content`** durchsucht das rohe Transcript-JSONL case-/diakritika-
  insensitiv — erst NACH den Metadaten-Filtern (nur Kandidaten werden
  gelesen). Dateien über dem 64-MB-Cap werden nur im Tail-Fenster durchsucht;
  Treffer/Nicht-Treffer sind dann als `hitTruncated`/`missTruncated` markiert
  (kein Beweis für Abwesenheit).
- **`unarchive <ref> [--resume|--open]`** — Ref-Auflösung inkl. Archiv
  (`includeArchived`), mehrdeutig → Exit 3 mit Kandidaten (nie raten). Der
  Compound ist explizit: `--resume` = danach Auto-Launch + Fokus
  (`session.resume`-Semantik), `--open` = danach nur Tab fokussieren.
  Alles-oder-nichts: ist die Session-Art nicht resumebar (Terminal/agentView),
  passiert bei `--resume` GAR NICHTS (auch kein Unarchive). Nicht archivierte
  Ziele sind idempotenter Erfolg (`alreadyActive`); ein angefordertes
  `--resume`/`--open` läuft dann trotzdem. Kein Pfad löscht Daten.
- **`duplicates [--json]`** (seit 11.11.2026, nur lesend) listet Chats, die
  dieselbe externe Sitzung tragen. Behalten wird der von Hand angelegte Chat
  (sonst der älteste), für die übrigen steht ein `chats archive <ref>`-Vorschlag
  da. Archiviert oder gelöscht wird nichts automatisch. Der Index-Merge
  aktualisiert ohnehin nur noch den behaltenen Chat.

### Backlog Tab-/Session-Management (Gap-Analyse 2026-07-19)

Runde 2 (gleicher Tag) hat die Prioritäten 1–4 umgesetzt: `pin`/`unpin`,
`close --others/--right`, `reopen`, `move` + `window list`,
`workspace add/remove`. Verbleibend:

| Kandidat | Status |
|---|---|
| CLI-detach in ein NEUES Fenster | offen — braucht einen Scene-Open-Request (`openWindow` gehört SwiftUI); Workaround: in der App per Drag |
| Dry-Run/`--plan` für Batch-Aktionen | nicht nötig — `list --open --json` IST der Plan-Schritt |
| Pauschales `close --all` | bewusst nie (gefährlicher Pfad; Kandidaten immer explizit) |

## Agentenvertrag (`snapshot` / `since` / `watch`)

Die CLI ist primär für Agenten. `--json` ist der Vertrag; die Textausgabe der
Agentenbefehle ist ausdrücklich nur Diagnosehilfe **ohne** Stabilitätszusage
und darf nicht geparst werden. Kein Terminal-Dashboard.

**Warum ein eigener Befehl statt einer Option an `overview`:** `overview` und
`list` haben einen etablierten Vertrag, auf den Skill und Skripte bauen.
`snapshot` erlaubt das saubere Schema `wm8.overview/1`, ohne bestehende
Aufrufer zu brechen.

- **`chats snapshot`** (`wm8.overview/1`) — kompaktes Lagebild über ALLE
  Sessions. Gemessener Anlass: `overview --json` lieferte 868.379 Zeichen für
  920 Sessions, von denen fünf relevant waren; `snapshot` liefert dieselbe
  Lage in ~2.200 Zeichen. `counts` deckt **immer** den vollen Bestand ab, auch
  wenn `sessions` gekürzt ist (`coverage.countsComplete`). Gekürzt wird in
  dieser Reihenfolge: erst Auszüge bei nicht handlungsbedürftigen Zeilen, dann
  Sessions vom Ende — und jede Auslassung erscheint in `coverage.omitted`.
  Idle-Sessions nur mit `--include idle`.
- **`chats since --cursor <c>`** (`wm8.changes/1`) — Änderungen seit einem
  Cursor. Kosten proportional zur Änderung statt zum Bestand. **`gap: true`**
  heißt: Der Cursor stammt aus einer älteren Journal-Generation, es fehlen
  Ereignisse — der Aufrufer MUSS einen frischen `snapshot` ziehen. Ein stilles
  Fortfahren „ab jetzt" wäre der gefährlichste Fehler, weil eine Lücke sonst
  wie „nichts passiert" aussieht.
- **`chats watch`** — NDJSON-Strom derselben Ereignisse, eine Zeile pro
  Ereignis mit Cursor. Für Sidecars und Skripte; ein LLM nutzt besser `since`.
  Ausdrücklich **kein zweiter Ereignisweg**: Bricht der Strom ab, holt der
  Cursor die Ereignisse nach.

### Zustandsachsen

Vier unabhängige Achsen statt eines gemischten Status (`ChatsSessionAxes`):

| Achse | Werte | Bedeutung |
|---|---|---|
| `catalog` | `active \| inactive \| archived` | Aufbewahrung, **keine** Prozessaussage |
| `execution.worker` | `alive \| exited \| missing \| unknown` | der echte Agent |
| `execution.attachment` | `attached \| detached \| none` | nur die Anzeige |
| `conversation.state` | `launching \| ready \| working \| needsInput \| turnDone \| stopped \| errored` | |
| `conversation.reason` | `permission \| question \| planApproval` | nur bei `needsInput` |
| `evidence.quality` | `observed \| inferred` | Hook/App belegt vs. Transcript geschätzt |

`launching` ist ein **eigener** Wert und wird nicht auf `idle` abgebildet — das
war die Wurzel des Start-Race. Bei Hintergrund-Agenten ist `attachment` kein
Beleg für `worker`: Das PTY ist dort nur ein `claude attach`.

### Sichere Send-Semantik

`send` an eine Session in `launching` scheitert mit `notReady` (Exit 4) statt
still Erfolg zu melden. Belegt am 2026-07-26: `resume` + sofortiges `send`
meldete „delivered", während die Transcript-Revision 30 Sekunden unverändert
blieb — der Paste landete in einer noch nicht bereiten TUI und ging je nach
Timing verloren oder kam beim Retry doppelt an. `sendPrompt` schreibt blind in
die PTY; ein Erfolg belegt nur den Schreibvorgang, nicht die Verarbeitung.
Wer Zustellung braucht, nutzt `enqueue` (höchstens einmal, bei bestätigtem
Turn-Ende). `snapshot` bietet in `launching` konsequent kein `send` als Aktion an.

### Vormerken und Start bestätigen (WM8-70)

`send --queue-if-busy` legt einen Auftrag an einen beschäftigten Chat (Status
`working`, Entwurf im Eingabefeld, Start läuft noch) in die Warteschlange,
statt mit Exit 4 zu enden; ist der Chat inzwischen frei, wird direkt
zugestellt. `send --wait-started` (Standard 20 s, `--wait-started=N` für eine
andere Frist, höchstens 600) fragt nach dem Zustellen alle 0,5 s den Status der
App ab und achtet nach „arbeitet“ noch 3 s auf eine Limit-Zeile (trifft die
Nachricht auf ein unbekanntes Limit, steht der Chat kurz auf „arbeitet“). Es
meldet eines von drei Ergebnissen: `started` (der Chat arbeitet, Exit 0), `queued` (vorgemerkt,
Exit 0) oder `notStarted` mit Grund: `usageLimit` (Konto am Nutzungslimit, mit
Uhrzeit), `awaitingInput` (wartet weiter auf eine Antwort), `stopped`,
`errored` (Exit 4) oder `timeout` (Exit 124). Maßgeblich ist der Status, nicht
ein wachsender Verlauf: Codex schreibt beim Antworten minutenlang nichts.
`--json` trägt dieselben Felder (`outcome`, `reason`, `waitedSeconds`,
`position`, `usageLimitResetsAt`; `ok` folgt dem Ergebnis). `--force` bleibt,
wie es ist; ein gesetztes `--if-status` wird nicht über die Warteschlange
umgangen. Mit den Regeln aus WM8-75: Bei offener Freigabe meldet
`send --wait-started` „nicht angekommen“ mit Grund `approvalPending`,
`--queue-if-busy` merkt vor. Ein zurückgehaltenes Enter (`enterWithheld`, der
Text steht im Eingabefeld) ist nie „gestartet“ und wird nie vorgemerkt, sonst
käme der Text doppelt. Slash-Befehle (`/login`, `/model`, `/rate-limit-options`) gehen auch
am Limit durch: sie sind der Ausweg.

### Chat am Nutzungslimit (WM8-69)

Claude schreibt die Limit-Antwort als eigene Zeile in den Verlauf
(`isApiErrorMessage`, `error: rate_limit`, `apiError` `usage_limit_reached` oder
`model_requires_usage_credits`, Ende als Unix-Zeit in `quotaLimits.resetsAt`
bzw. `apiErrorParams.rate_limit_info.resetsAt`). Solange sie die letzte Antwort
ist, trägt der Chat `usageLimit` (Art und Ende). Dann gilt:

- `list` zeigt im Status „limit bis 04:20“, `show` eine Zeile `Limit`, `--json`
  unter `runtime.usageLimit` (`kind`, `resetsAt`); `board` führt den Chat unter
  „BRAUCHT DICH“.
- `send` lehnt mit `notReady` ab (Exit 4): der Prompt würde sonst verbraucht,
  ohne dass der Chat arbeitet. Kein `--force`-Bypass. Das gilt auch für einen
  Chat ohne eigene Limit-Zeile, wenn ein anderer Chat desselben Kontos am
  5-Stunden- oder Wochenlimit (`five_hour`, `seven_day`) mit bekanntem Ende
  steht (das Konto ist gesperrt; Vorfall 14.11.: ein ruhender Chat verbrauchte
  die erste Nachricht). Jede andere Art – Guthaben-Limit
  (`model_requires_usage_credits`, gilt nur für ein Modell), unbekannte Arten
  oder ein Limit ohne Ende – sperrt nur den eigenen Chat; bei den anderen
  Chats des Kontos gibt `send` nur eine Warnung aus (stderr, JSON
  `result.warning`). Durch geht nur ein
  Slash-Befehl am Anfang (`/login`, `/model …`, `/rate-limit-options`), kein
  Pfad wie `/Users/…`. `enqueue` merkt vor; die
  Warteschlange stellt erst nach dem Ende zu, auch wenn Claude danach nicht
  von selbst weitermacht. Endet das Limit über den Verlauf (Claude antwortet
  wieder), bekommen auch die anderen Chats des Kontos ihr Vorgemerktes.
- `new` warnt auf stderr, wenn ein anderer Chat desselben Kontos gerade am
  Limit steht.
- Weitermachen zum Ende (belegt in den Verläufen vom 11.–14.11.2026): Claude
  bietet nach der Limit-Zeile „continuing automatically at …“ an und schreibt
  zum Ende selbst „Your claude.ai usage limit has reset. Continue the task …“
  (belegt rund 1 und 10 min nach dem Ende). Eine neue Nachricht an den Chat
  erzeugt eine weitere Limit-Zeile und bricht das meist ab („Automatic continue
  cancelled“); manchmal bietet Claude es danach erneut an („Usage limit
  reached again · continuing automatically at …“), es zählt die jüngste
  Aussage. `usageLimit.autoContinues` sagt, was zuletzt galt; Anzeige und
  Meldungen lauten dann „läuft um … weiter“. Die Warteschlange stellt in dem
  Fall erst nach dem fortgesetzten Turn zu (spätestens 20 min nach dem Ende),
  sonst 5 s nach dem Ende.
- Der Zustand endet von selbst: mit der Endzeit oder sobald Claude wieder
  antwortet. Zeilen vom Typ `user` (Teammate-Nachrichten, Task-Meldungen) beenden
  ihn nicht, Claude antwortet darauf sofort mit der nächsten Limit-Zeile.
- Das Limit gilt für das Konto, an dem es entstand: nach `move-account` sperrt
  es den Chat nicht mehr.
- Fertig-Ton, Fertig-Meldung und Zustellung beim Turn-Ende warten auf einen
  frischen Blick in den Verlauf; steht dort das Limit, entfallen sie (die
  Registry meldet am Limit ein gewöhnliches Turn-Ende).
- Ein Diktat in einen Chat am Limit landet in der Zwischenablage, mit eigener
  Meldung. Der Controller schreibt bewusst weiter: Seine Eingaben sind
  gezielte Tasten im sichtbaren Chat, etwa im Menü `/rate-limit-options`.
- Bekannte Grenzen: Der ganze Weg ist an einem echten Limit in der App noch
  nicht gesehen. Der frische Poll vor Ton und Zustellung wartet höchstens 2 s;
  kommt Claudes Limit-Zeile später, gibt es doch Ton und Zustellung. Der
  Fertig-Ton kann dadurch bis zu 2 s später kommen.
- Codex- und GPT-Chats: noch nicht erkannt (kein belegter Limit-Fall im
  Bestand; Codex führt `rate_limits` in `token_count`, ohne echten Treffer).
- Der Kontowechsel behandelt einen Chat am Limit noch wie bisher (Folgepaket:
  sofort umziehen, Hilfsdienste nicht als laufende Arbeit zählen).

### Anomalien und Kompatibilität

Anomalien (`wm8.anomaly/1`) werden **nie** in einen Gesamtstatus eingerechnet;
sie stehen mit `severity`, `evidence` und `recommendedAction` daneben. Ein
Hintergrund-Agent ohne Tab und ohne PTY ist ausdrücklich **keine** Anomalie —
das ist der Normalfall von `claude --bg`.

Kompatibilität: Additive Felder ändern das Schema nicht; Agenten MÜSSEN
unbekannte Felder ignorieren. Entfernen, Umbenennen oder Umdeuten eines Feldes
erzwingt `/2`. Cursor sind opak und nur innerhalb derselben Generation gültig.

## Jarvis-Board (`chats board`, seit 08.10.2026)

Ein Board je Jarvis-Session (`owner` = deren WhisperM8-Session-ID): die Chats,
die Jarvis aktiv betreut, mit Ampel (`needsYou | running | done | parked`),
`mission` (Ziel), `work` (Arbeitspaket), `needs` (Eingriff), `blocker` und
`milestones` (seit 17.10.2026). Die Anzeige über dem Prompt übernimmt die Mod
des Plugins `whisperm8`, die Notiz-Karte am Kachelkopf im Grid die App, siehe
`docs/features/jarvis-board.md`.

```bash
whisperm8 chats board [--owner @self|<ref>] [--all] [--json]   # lesen, App optional
whisperm8 chats board set <ref> [--light L] [--mission M] [--work W] [--needs N] [--blocker B] [--json]
whisperm8 chats board milestone <ref> "<Ergebnis>" [--json]
whisperm8 chats board remove <ref> | clear | activate | deactivate [--json]
whisperm8 chats show <ref> --recap [--json]   # Claudes Rückblicke als Lesehilfe
```

- **Lesen** direkt von der Platte (`jarvis-board.json`, `wm8.board/1`): je
  Eintrag zusätzlich `ref`, `title`, `project`, Live-`status` und
  `statusSince` (aus dem Journal) sowie `otherOwners`, dazu der aktuelle
  `cursor` für `watch`. Kein Board → `isActive: false`, `entries: []`, Exit 0.
  `--all --json` liefert `{schema, cursor, boards: […]}`.
- **Handeln** nur über den Socket an die laufende App (einziger Schreiber)
  und nur auf dem **eigenen** Board; die App verlangt ein gültiges
  Session-Token (die nackte Session-ID reicht nicht). Texte werden einzeilig,
  getrimmt und auf 160 Zeichen gekürzt. Ein neuer Eintrag ohne `--light` ist
  `running`; ein `set` ohne Änderung liefert `changed: false` und kein
  Ereignis.
- **`work` statt `next`:** `work` löst `next` ab, ohne den Vertrag zu brechen:
  Die App schreibt beide Felder gleich, liest alte Dateien mit nur `next` als
  `work`, und `--next` bzw. der Socket-Parameter `next` bleiben Alias.
- **Meilensteine:** `milestone` hängt vorn an (`{at, text}`, neueste zuerst,
  die 20 neuesten bleiben). Die Zeit setzt die App; derselbe Text wie der
  jüngste ist `changed: false`. Steht der Chat nicht auf dem Board, antwortet
  die App `notFound` (Exit 3) statt still anzulegen. `set` ändert
  Meilensteine nie.
- **Rückblick (`show --recap`):** die drei neuesten `away_summary`-Einträge,
  die Claude Code selbst ins Transcript schreibt, solange der User woanders
  ist („Ziel ist … Zuletzt … Als Nächstes …"). Rückwärtssuche nach dem
  Merkmal, höchstens 64 MB vom Dateiende, Zeilen über 64 KB werden
  übersprungen; nicht dokumentiertes Format, deshalb fail-soft (leere Liste
  plus `note`). Codex-Chats: immer leer.
- **Exit-Codes:** 3 unbekannter Ref, 4 eigener Chat auf eigenem Board
  (`selfSend`), 5 App nicht erreichbar, 1 Kill-Switch/ungültige Eingabe.
  `remove` auf einen nicht eingetragenen oder archivierten Chat ist ok.
- **Ereignisse:** Jede echte Änderung ist ein Journal-Eintrag, den `since` und
  `watch` mit demselben Cursor wie die Konversationsereignisse liefern:
  `{"kind":"board","op":"set|remove|clear|activate|deactivate|milestone","owner","ownerRef","ref","sessionID","light",…}`
  (bei `clear`/`activate`/`deactivate` ohne `ref`, `sessionID`, `light`).
  Konversationsereignisse sind unverändert; die Statushistorie von `show`
  blendet Board-Ereignisse aus.
- **Kill-Switch:** `defaults write com.whisperm8.app jarvisBoardEnabled -bool NO`
  — Handeln antwortet `unsupported`, Lesen liefert ein leeres Board.

## Sichtbarkeit von Workspaces und Grid (nur lesend)

`workspace list --json` und `window list --json` liefern zusätzlich, was ein
Agent braucht, um vor einer Aussage zu **prüfen** statt zu **vermuten**:

```jsonc
// workspace list
{"id":"…","name":"Recherche","capacity":4,          // unverändert
 "hostWindowID":"3D41A097-…",   // null = keinem Fenster zugeordnet
 "gridVisible":true,            // zeigt das Host-Fenster gerade das Grid?
 "slots":[{"index":1,"sessionID":"…","ref":"c595df2e",
           "title":"whisperm8/CLI","hostWindowID":"…","rendered":true},
          {"index":2}]}         // leerer Slot: nur der Index

// window list
{"id":"…","isPrimary":true,"tabCount":11,"tabTitles":[…],  // unverändert
 "tabs":[{"position":1,"id":"…","title":"…"}],   // seit 13.11.2026: Tabs mit ID
 "selectedTitle":"…",
 "showsGrid":false,             // Grid oder Einzelansicht
 "activeWorkspaceID":"…","activeWorkspaceName":"Recherche"}
```

`chats list --json` und `chats show --json` nennen je Chat seine Position
(seit 13.11.2026, nur ergänzt):

```jsonc
"order": {"sidebarPosition": 3,   // Folge im Projekt (1-basiert), archiviert: null
          "sortIndex": 2,         // roher Wert, null = nie sortiert
          "tabs": [{"windowID": "…", "position": 5}]}   // je Fenster, 1-basiert
```

`sidebarPosition` ist die Position in der Projektgruppe der Seitenleiste, mit
demselben Filter wie die App (`AgentSidebarModelBuilder.sessionsByProject`):
`null` für archivierte, gepinnte (eigene Sektion), Subagent-Kinder und nicht von
Hand angelegte Chats. `chats order` ordnet genau diese Gruppe und lehnt
Chats außerhalb davon mit Exit 1 ab.

**Bewusst kein Feld `isVisible`.** `activeWorkspaceID` ist doppelt belegt: Es
bezeichnet das aktive Grid **oder** nur das Rücksprungziel der Einzelansicht —
`showSingleSession` lässt die Referenz stehen und setzt lediglich
`showsGrid = false`. Ein einzelnes Sichtbarkeits-Flag würde diesen Zustand
platt machen. „Logisch sichtbar" ist die UND-Verknüpfung
`hostWindowID != nil && gridVisible`.

**`rendered` ist nicht dasselbe wie „belegt".** Gehört der Slot-Chat als Tab
einem anderen Fenster, wird er nicht materialisiert; das Grid zeigt dort den
Übernahme-Platzhalter. Ohne dieses Feld behauptet ein Agent „A und B liegen
nebeneinander", während der Nutzer „Läuft als Tab in einem anderen Fenster"
sieht.

**Grenzen, die kein Feld abbildet.** Der Store ist UI-Zustand, kein
Fenster-Inventar:

- Ein geschlossenes **Primärfenster** bleibt im Zustand erhalten (`removeWindow`
  verweigert es dort) — `gridVisible` kann `true` melden, obwohl nichts auf dem
  Bildschirm steht.
- **Minimiert, verdeckt oder auf einem anderen Space** ist gar nicht abbildbar.
- **Vordergrund/Fokus** wäre AppKit-Ebene; `keyAgentChatWindowID` wird bereits
  beim App-Wechsel `nil` und taugt nicht als Beleg. Deshalb kein solches Feld.
- Slot-Einträge werden erst bei Load/`flush` bereinigt; eine Slot-UUID ohne
  lebende Session gilt daher **nicht** als belegt.

Formulierungsregel für Agenten: „im Grid angeordnet", niemals „du siehst".

## wait

`ChatsWaitEngine`: pro Transcript ein `DispatchSourceFileSystemObject`
(`O_EVTONLY`, `.write/.extend/.delete/.rename`), 300-ms-Debounce, 10-s-Fallback-
Poll (Missed-Event-Netz), Re-Locate bei delete/rename (Kompaktierung), Timeout
124 / SIGINT 130. `--since REV` (Transcript-Bytes als Revision) schließt die
Lücke zwischen zwei wait-Aufrufen.

## Audit

`ChatsAuditLog` (`chats-audit.jsonl`, Rotation 5 MB): jede Socket-Mutation mit
Actor, Methode, Ziel, Ergebnis, Prompt-Länge + 80-Zeichen-Kopf (kein Volltext —
Privacy-Default). Nur die App schreibt; `chats audit` liest.

## Skill

`whisperm8-chats` (`WhisperM8/Resources/whisperm8-chats-skill.md`): macht aus Befehlen
Verhalten. Autonomie-Stufen (Beobachten/Zuarbeiten/Supervisor), Send-Gate über
AskUserQuestion, Ein-Hop-Regel, Batch-Aufräumen, Supervisor-Loop
(`overview → wait → tail → berichten`). Interrupt nur nach expliziter
User-Freigabe.

**Verhältnis zum nativen Cross-Session-Messaging** (Claude Code
`ListAgents`/`SendMessage`, geprüft 10.10. und 17.10.2026): Es ersetzt
`chats send` nicht, ergänzt es aber über alle Konten. Die native **Erkennung**
liest nur `<CLAUDE_CONFIG_DIR>/sessions/<pid>.json` des eigenen Profils (von
7 laufenden Chats in drei Konten waren nur die 2 im selben Konto sichtbar,
unter abgeleiteten Namen wie `listm8-00`). Die **Zustellung** dagegen geht über
alle Konten: Die Postfächer liegen gemeinsam in `/tmp/cc-socks/<pid>.sock`,
`SendMessage` nimmt `to: "uds:<pfad>"`, und auf macOS verlangt der Empfänger
kein Token (live geprüft 17.10.: PowerUser → ai2 und → PowerUser2 zugestellt,
Antworten und `notify_when_idle` kamen zurück).

`whisperm8 chats address <ref> [--json]` ist das fehlende Adressbuch
(`ChatsAddressCommand` + `ClaudeSessionRegistry`, liest nur Claudes Registry
aller Konten, app-unabhängig): stdout = `uds:`-Adresse, `--json` zusätzlich
nativer Name, Konto, Status, PID. Exit 4 mit Grund (`notClaude`, `notBound`,
`notRunning`, `noInbox`), wenn der Chat nicht nativ erreichbar ist. Die
Zuordnung läuft über `externalSessionID` ↔ `sessionId`; ein Eintrag zählt nur,
wenn die PID lebt und ihre Startzeit zu `procStart` passt (Claude schreibt sie
in UTC). Der Skill nimmt `SendMessage` für Rückfragen an laufende Claude-Chats
(Antwortkanal, `notify_when_idle`), `chats send`/`enqueue` für Codex,
geschlossene Chats, Arbeitsaufträge und „erst nach dem Turn“. Grenzen:
Rechte-Modus-Parität (Bypass vs. Rest → Nachricht wird im Ziel zur Freigabe
gehalten), Adresse wechselt mit jedem Neustart, und erzwingt Anthropic das
Socket-Token auch auf macOS, bricht der Weg über Konten — `chats send` bleibt
deshalb vollwertig. Plan: `docs/plans/claude-status-aus-registry.md`.

## Zentrale Dateien

- CLI: `WhisperM8/CLI/AgentChatsCLICommand.swift`, `ChatsWorkspaceReader.swift`,
  `SessionRefResolver.swift`, `ChatsStatusProbe.swift`, `ChatsAttentionModel.swift`,
  `ChatsTailFormatter.swift`, `ChatsOutput.swift`, `ChatsControlProtocol.swift`,
  `ChatsControlClient.swift`, `ChatsLiveCommands.swift`, `ChatsLiveMerge.swift`,
  `ChatsWaitEngine.swift`.
- App: `Services/AgentChats/AgentControlServer.swift`,
  `AgentControlRequestHandler.swift`, `AgentSessionTokenRegistry.swift`,
  `ChatsAuditLog.swift`; Änderungen in `AgentTerminalView.swift` (Env-Injektion,
  `sendPrompt`/`sendInterrupt`), `AgentChatLaunchService.swift`
  (`openChatViaControl`), `WhisperM8App.swift` (Server-Start).
- Tests: `Tests/WhisperM8Tests/ChatsCLITests.swift`, `ChatsControlTests.swift`,
  `ChatsWaitEngineTests.swift`, `TestControlSocket.swift`.

## Betriebswissen aus CLAUDE.md

*Am 19.10.2026 wörtlich aus der Projekt-CLAUDE.md übernommen (LR-DOK-008); dort stehen nur noch die Arbeitsregeln. Beim nächsten Überarbeiten dieser Seite in den Fließtext einarbeiten.*

- **Agent-Chats-CLI (`whisperm8 chats`, „Jarvis")**: Jeder Chat kann alle Sessions sehen/verwalten. Lese-Befehle (`list`/`overview`/`show`/`tail`/`wait`/`audit`) laufen app-unabhängig direkt von Disk (`ChatsWorkspaceReader` + `ChatsStatusProbe` mit denselben puren Bausteinen wie der Runtime-Watcher). Handeln-Befehle (`send`/`interrupt`/`open`/`new`/`rename`/`group`/`archive`/`move-account`) gehen über einen BSD-Unix-Domain-Socket (`AgentControlServer`, Start in `applicationDidFinishLaunching`) an die laufende App — Workspace-Single-Writer bleibt die App. Identität via `WHISPERM8_SESSION_ID`+Token (beim PTY-Spawn injiziert). `send` ist TOCTOU-frei (Guards + Bracketed Paste in einem MainActor-Block). Skill `whisperm8-chats` steuert das Verhalten (Send-Gate, Ein-Hop-Regel). `move-account --to <profil>` zieht bestehende Claude-Chats über dieselbe Kette wie das Kontextmenü um (`AccountMoveFacts` → Planer → Service → Journal, also per App rückgängig machbar); `--stop-and-resume` hält laufende Chats an, zieht erst nach nachweislichem Prozessende um und merkt den Neustart vor — working und vermuteter Composer-Entwurf (`TerminalComposerDraftTracker`) werden seit 11.10.2026 nach dem Turn gewechselt (`scheduled`, s. „Kontowechsel ohne Stoppen"), sofort nur mit `--force`, die eigene Session nie. Doku: `docs/features/agent-chats-cli.md`, Plan: `docs/plans/whisperm8-chats-cli/`. Lock, Listen-Socket und angenommene Verbindungen des Servers (ebenso `FileEventSource`, Hook-Bridge, Job-Store-Lock) sind **close-on-exec** — vorher erbte jeder Chat-Prozess (SwiftTerm `forkpty`+`execve` schließt nichts) den Lock und hielt ihn nach einem Neustart bis zu ~19 s, ein langlebiger Prozess aus einer Chat-Shell hätte ihn unbegrenzt gehalten (Analyse 11.10.2026). Kill-Switch: `defaults write com.whisperm8.app agentControlServerEnabled -bool NO`.
