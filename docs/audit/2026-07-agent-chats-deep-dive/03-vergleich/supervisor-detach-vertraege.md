---
status: aktiv
updated: 2026-07-18
description: Quellcodevergleich zu Detach-, Exit- und Stop-Verträgen für den whisperm8-agent-Supervisor
---

# Supervisor-Detach-Verträge: tmux, Zellij, containerd-shim und runc

## Auftrag und Kurzurteil

Gegenstand sind ausschließlich die bestätigten Supervisor-Findings **N07**
(Detach hängt am Waiter-Baum), **N08** (unvollständiger Codex-Turn wird als
Erfolg gespeichert) und **N14** (frühes Stop-Signal geht verloren). Das Ziel
ist kein Austausch der echten Codex-/Claude-Code-CLI, sondern ein belastbarer
Vertrag zwischen dem kurzlebigen `whisperm8 agent run`-Client, dem detachten
Supervisor und dessen `codex exec`-Kind.

Das zentrale Ergebnis lautet:

1. **Detach ist ein bestätigtes Handoff, kein erfolgreicher `Process.run()`.**
   `run --json` ohne `--wait` darf erst antworten, nachdem der endgültige
   Supervisor seine Unabhängigkeit und Stop-Fähigkeit bestätigt hat. Der
   ausgegebene Status bedeutet dann nur **angenommen/läuft**, niemals
   Turn-Erfolg.
2. **Turn-Erfolg ist eine Konjunktion aus Prozess- und Protokollwahrheit.**
   Exit-Code 0 allein genügt nicht. Erforderlich sind normaler Exit,
   `turn.completed`, vollständiger Stream-Drain, ein nichtleeres finales
   Ergebnis und ein erfolgreich persistierter Endzustand.
3. **Stop ist level-triggered und dauerhaft.** Ein Stop-Wunsch wird vor jedem
   Signal unter dem Job-Lock persistiert. Die spätere Prozessregistrierung muss
   denselben Wunsch atomar konsumieren; so kann kein Stop zwischen
   `process.run()` und `self.process = process` verschwinden.
4. **Waiter sind wiederanheftbare Clients, keine Prozess-Owner.** Das Beenden
   eines `wait`-Clients darf weder Supervisor noch Turn beeinflussen; der
   Supervisor besitzt Lifecycle und Exit-Wahrheit.

## Quellenkonvention

Lokale Fremdprojekte wurden auf den folgenden, unveränderten Revisionen gelesen:

- `<tmux>` =
  `/private/tmp/claude-501/-Users-giulianocosta-repos-whisperm8/8b93468c-4cf1-41c0-a5fc-b852563d2a8d/scratchpad/vergleich/tmux`
  (`cad1c81c711ac185ebc13a5ba7a12e1325face1f`)
- `<zellij>` =
  `/private/tmp/claude-501/-Users-giulianocosta-repos-whisperm8/8b93468c-4cf1-41c0-a5fc-b852563d2a8d/scratchpad/vergleich/zellij`
  (`68362d4cf0b20682d16647570cc324a770b687bc`)
- Pfade ohne Präfix sind relativ zum WhisperM8-Repository.
- containerd und runc wurden ergänzend aus den unten verlinkten, commit-gepinnten
  Upstream-Quellen gelesen: containerd
  `29edc6e8b7fe4a66d4f4fde6666893941910d954` (18. Juli 2026), runc
  `fc89fbd9ebec617475d7e7a7a38f4e4bf277cf54` (10. Juli 2026).

## 1. Der aktuelle WhisperM8-Vertrag und seine drei Brüche

### 1.1 N07: Der Parent meldet Erfolg vor dem Detach

`AgentSupervisorLauncher` startet das eigene Binary als direktes
`Foundation.Process`-Kind, schließt den Log-Handle und gibt unmittelbar nach
`process.run()` dessen PID zurück. Es existiert weder Ready-Pipe noch
Detach-ACK. (`WhisperM8/Services/AgentChats/AgentSupervisorLauncher.swift:30-60`)

Das eigentliche `setsid()`, das Ignorieren von SIGHUP und die Installation des
SIGTERM-Handlers geschehen erst im später laufenden Kind. Der Signal-Source wird
sogar erst nach der Erzeugung von `AgentJobSupervisor` aktiviert.
(`WhisperM8/CLI/AgentSuperviseCommand.swift:8-33`)

Trotz dieser offenen Strecke persistiert der Parent die zuerst erhaltene PID
bereits als `supervisorPid`; der nicht wartende JSON-Pfad emittiert danach
`{"state":"spawning"}` und liefert Exit-Code 0.
(`WhisperM8/CLI/AgentCLICommand.swift:513-561`) Genau diese Lücke ist als N07
bestätigt: Der erfolgreiche Spawn des noch nicht detachten Zwischenzustands ist
kein Beleg dafür, dass der Supervisor den Waiter überlebt.
(`docs/audit/2026-07-agent-chats-deep-dive/04-verifikation/verdicts-runde2.md:52-54`)

### 1.2 N08: Prozessende wird mit Turn-Vollständigkeit verwechselt

Der Runner besitzt bereits eine gute Drain-Barriere: Das Ergebnis wird erst
freigegeben, nachdem stdout-EOF, stderr-EOF **und** Process-Termination in einer
`DispatchGroup` eingetroffen sind. Er übernimmt aus dem Process jedoch nur
`terminationStatus`, nicht `terminationReason`.
(`WhisperM8/Services/AgentChats/CodexExecRunner.swift:240-310`)

`CodexTurnResult` enthält weder `turnCompleted` noch Termination-Reason. Der
Stream-State merkt nur die erste Thread-ID und `turn.failed`; ein vom Parser
empfangenes `turn.completed` wird nicht in die Ergebniswahrheit übernommen.
(`WhisperM8/Services/AgentChats/CodexExecRunner.swift:39-50,493-500`)
`mapOutcome` erklärt deshalb jeden nicht gestallten Turn ohne `turn.failed` und
mit Exit-Code 0 zu `.done`; `lastMessage` darf dabei `nil` sein.
(`WhisperM8/Services/AgentChats/CodexTurnExecutor.swift:83-120`) Das ist der
bestätigte N08-Fall.
(`docs/audit/2026-07-agent-chats-deep-dive/04-verifikation/verdicts-runde2.md:56-58`)

### 1.3 N14: Stop-Wunsch und Prozessregistrierung sind nicht atomar

`requestStop()` setzt zwar unter Lock `stopRequested`, ruft danach aber
`runner.terminate()` auf. `terminate()` ist ein No-op, wenn der Runner sein
`process` noch nicht veröffentlicht hat.
(`WhisperM8/Services/AgentChats/AgentJobSupervisor.swift:44-57`,
`WhisperM8/Services/AgentChats/CodexExecRunner.swift:327-335`)
Genau dieses Fenster existiert: `process.run()` erfolgt vor der späteren,
separat gelockten Zuweisung `self.process = process`.
(`WhisperM8/Services/AgentChats/CodexExecRunner.swift:267-286`)

Der Job ist zu diesem Zeitpunkt bereits als `.running` mit Supervisor-PID
persistiert, bevor der Executor den Runner startet.
(`WhisperM8/Services/AgentChats/AgentJobSupervisor.swift:77-87,124-128`)
Der CLI-Stop ignoriert zusätzlich den Rückgabewert von `kill(2)` und meldet nach
spätestens zwei Sekunden Exit-Code 0, auch wenn nur „Signal gesendet“ angenommen
wird. (`WhisperM8/CLI/AgentCLICommand.swift:355-392`) Damit ist N14 nicht bloß
ein In-Memory-Race, sondern auch im Control-Plane-Vertrag nicht zuverlässig
beobachtbar.
(`docs/audit/2026-07-agent-chats-deep-dive/04-verifikation/verdicts-runde2.md:80-82`)

## 2. Übertragbare Muster aus echten Supervisoren

### 2.1 tmux: Client-Detach verändert nicht die Server-Wahrheit

Der tmux-Server behandelt Detach als Client-Operation: Er setzt am betroffenen
Client `CLIENT_EXIT`, merkt Detach-Typ und Session-Namen, zerstört dabei aber
keine Session und keinen Pane-Prozess.
(`<tmux>/server-client.c:600-614`) Der Server entscheidet seine eigene
Lebensdauer separat anhand von Optionen, vorhandenen Sessions, angehefteten
Clients und laufenden Jobs; vor dem Exit werden wartende Clients geflusht.
(`<tmux>/server.c:270-307`) Auch ein unerwartet verlorener Client wird aus der
Client-Liste entfernt und dessen TTY/Peer freigegeben, ohne in diesem Pfad die
Session zu zerstören. (`<tmux>/server-client.c:480-555`)

Detach ist außerdem ein Protokoll und kein lokales `exit(0)`:

1. Der Server wartet vor der Exit-Nachricht auf Control-/Dateipuffer und sendet
   dann `MSG_DETACH`. (`<tmux>/server-client.c:2279-2326`)
2. Der Client merkt den Detach-Grund und bestätigt mit `MSG_EXITING`.
   (`<tmux>/client.c:728-750`)
3. Erst darauf löst der Server die Client-Session, schließt das TTY und sendet
   `MSG_EXITED`. (`<tmux>/server-client.c:2604-2611`)
4. Erst `MSG_EXITED` beendet den Client-Prozess.
   (`<tmux>/client.c:767-772`)

**Übertragbares Muster für N07:** Das kurzlebige Frontend darf nicht aus seinem
eigenen Spawn-Erfolg auf den Serverzustand schließen. Es braucht eine Antwort
aus der bereits zuständigen Server-/Supervisor-Instanz und darf erst nach
diesem Handoff beenden.

### 2.2 tmux: Exit-Status stammt aus `waitpid`, nicht aus dem letzten Output

tmux übernimmt den echten Wait-Status im SIGCHLD-Pfad in den Pane-Zustand und
markiert ihn als bereit. (`<tmux>/server.c:475-507`) Ein wartender Command wird
erst fortgesetzt, wenn dieser Status bereit ist; normaler Exit wird mit
`WEXITSTATUS`, Signalende mit `128 + WTERMSIG` abgebildet.
(`<tmux>/window.c:481-502,1350-1371`) Der Server packt seinen `retval` in
`MSG_EXIT`, der Client übernimmt genau diesen Wert und gibt ihn schließlich aus
`client_main` zurück. (`<tmux>/server-client.c:2304-2317`,
`<tmux>/client.c:594-617,433-438`)

**Übertragbares Muster für N08:** Prozessstatus, Termination-Art und
Protokollabschluss müssen getrennt erfasst und erst in einer finalen
Entscheidung zusammengeführt werden. Ein vorhandener letzter Text ist kein
Ersatz für Reaping; ein Exit-Code 0 ist kein Ersatz für `turn.completed`.

### 2.3 Zellij: Server- und Client-Lifecycle sind explizite IPC-Rollen

Zellij daemonisiert den Unix-Server in `start_server()`; der aufrufende Client
startet das Server-Binary synchron, prüft den Exit des daemonisierenden
Zwischenprozesses und verbindet sich danach über den Session-Socket.
(`<zellij>/zellij-server/src/lib.rs:802-833`,
`<zellij>/zellij-client/src/lib.rs:433-455,1014-1039`) Der Verbindungsaufbau
pollt, bis der Socket tatsächlich Verbindungen annimmt.
(`<zellij>/zellij-client/src/os_input_output.rs:284-300`)

Attach ist eine eigene Nachricht mit Terminal-/Konfigurationsdaten und
optionalem Fokusziel. (`<zellij>/zellij-utils/src/ipc.rs:103-154`,
`<zellij>/zellij-client/src/lib.rs:873-923`) Der Server registriert den Client
in Session-State, Screen und Plugin-Thread; er rekonstruiert damit die
Darstellung aus serverseitigem Zustand statt einen neuen Prozess zu starten.
(`<zellij>/zellij-server/src/lib.rs:1126-1214`) Für einen reinen
Liveness-Check existiert sogar `ConnStatus → Connected`, statt bloß die Existenz
der Socket-Datei als Wahrheit zu behandeln.
(`<zellij>/zellij-utils/src/sessions.rs:141-165`,
`<zellij>/zellij-server/src/lib.rs:1556-1559`)

Detach und Quit sind serverseitig verschiedene Aktionen. `Action::Quit` wird
zu `ClientExit`, `Action::Detach` dagegen zu `DetachSession`.
(`<zellij>/zellij-server/src/route.rs:1137-1153`) Beim Detach sendet der Server
die Exit-Nachricht, entfernt die Clients und signalisiert über den
`completion_tx` ausdrücklich erst danach, dass die Clients bereits getrennt
sind; der Server-Loop wird in diesem Zweig nicht beendet.
(`<zellij>/zellij-server/src/lib.rs:1462-1493`) `KillSession` entfernt dagegen
alle Clients und bricht den Server-Loop ab.
(`<zellij>/zellij-server/src/lib.rs:1430-1442`)

**Übertragbares Muster für N07 und den Waiter-Vertrag:** `run`, `wait` und
`status` sind Clients eines langlebigen Owners. Attach/Detach sind
Control-Plane-Nachrichten. Socket- oder PID-Existenz allein genügt nicht; ein
Request/Response-Probe bestätigt den lebenden Owner.

### 2.4 containerd-shim: Bootstrap-Erfolg erst nach Adresse, Verbindung und Persistenz

containerd Runtime v2 trennt kurzlebigen Shim-Start und langlebigen Listener:
Das `start`-Unterkommando muss ein versioniertes `BootstrapResult` mit
Listener-Adresse und Protokoll liefern; erst über diese Adresse erfolgen die
späteren Lifecycle-RPCs. ([containerd Runtime v2:191-258])

Der konkrete containerd-Code wartet auf `CombinedOutput()` des Start-Helfers,
parst dessen Bootstrap-Antwort, baut die Verbindung zum Shim auf und schreibt
`bootstrap.json` für einen späteren Restore. Erst danach liefert `binary.Start`
den verwendbaren Shim zurück. ([containerd binary.go:66-152]) Der
`ShimManager` nimmt die Instanz erst nach erfolgreichem `startShim` in seine
Registry auf; bei Folgefehlern läuft Cleanup. ([containerd
shim_manager.go:292-306,309-347])

**Übertragbares Muster für N07:** Der Supervisor muss selbst einen
versionierten Ready-Datensatz liefern. Der Parent darf weder die pre-detach PID
noch die bloße Existenz einer Datei als Startbeleg verwenden.

### 2.5 runc: Detach-Erfolg folgt dem Prozess- und PID-Handoff

runc kehrt im detached Pfad erst mit 0 zurück, nachdem `Start`/`Run` erfolgreich
war, die Console bereit ist, der PID-File-Write erfolgreich war und ein
optionaler Notify-Socket weitergereicht wurde. ([runc
utils_linux.go:288-326]) Der PID-File wird nicht stückweise überschrieben,
sondern über exklusive temporäre Datei plus Rename atomar publiziert.
([runc utils_linux.go:161-182]) Der Integrationstest verlangt nach Exit-Code 0
einen laufenden Container und prüft, dass der PID-File-Wert mit dem
Runtime-State übereinstimmt. ([runc start_detached.bats:34-55])

**Übertragbares Muster für N07:** Exit 0 eines detachenden Launchers bezeichnet
ein vollzogenes Handoff an einen nachprüfbar laufenden Owner, nicht „der Fork
hat funktioniert“. Ein PID-Artefakt wird erst nach erfolgreichem Start atomar
sichtbar.

### 2.6 containerd-shim: Exit-Wahrheit und frühe Events werden gelatcht

Der Shim-`Wait` blockiert auf einem eigenen Exit-Kanal; erst danach liefert er
Exit-Status und Exit-Zeit. ([containerd process/init.go:216-249,277-290],
[containerd task/service.go:575-594]) Die Runtime-v2-Spezifikation verlangt
außerdem eine feste Eventordnung `Create → Start → Exit → Delete`, gerade um
das Race „TaskExit vor Rückkehr von Start“ beherrschbar zu machen.
([containerd Runtime v2:384-408])

Für das konkrete Frühereignis-Race registriert der runc-v2-Shim **vor** dem
Prozessstart einen Exit-Subscriber. `handleStarted` prüft später unter demselben
Lifecycle-Lock, ob der Exit schon eingetroffen ist; wenn ja, wird er sofort
verarbeitet, andernfalls wird der Prozess erst jetzt in `running` registriert.
([containerd task/service.go:149-219]) Der Startpfad installiert diesen
Subscriber vor `container.Start`, publiziert anschließend das Start-Event und
ruft erst danach `handleStarted` zur Reconciliation auf.
([containerd task/service.go:295-350])

**Übertragbares Muster für N14:** Ereignisse, die vor der Registrierung des
Zielobjekts eintreffen können, brauchen einen unter demselben Lock geführten
Latch. „Jetzt noch kein Prozess“ darf nie „Stop erledigt“ bedeuten.

## 3. Verbindliche Regeln für den WhisperM8-Supervisor

### V1 — Detach-Acceptance-Gate: Wann `run --json` ohne `--wait` antworten darf

Exit-Code 0 und ein finales JSON sind erst erlaubt, wenn der **endgültige**
Supervisor über einen geerbten, nur für den Bootstrap verwendeten IPC-Kanal
mindestens Folgendes bestätigt hat:

1. Session-/Terminal-Detach ist vollzogen; SIGHUP- und SIGTERM-Verhalten sind
   installiert.
2. `supervisor.log` und der Job-Store sind geöffnet; der Supervisor kann ohne
   Handles des Waiters weiterarbeiten.
3. Der Supervisor hat seine **eigene** PID plus eine gegen PID-Reuse geeignete
   Prozessidentität publiziert; die Parent-PID vor dem Handoff ist keine
   Registry-Wahrheit.
4. Der Zustand `spawning → running` und die Supervisor-Identität sind atomar
   persistiert.
5. Entweder ist das Codex-Kind bereits unter dem Stop-Lock registriert, oder der
   langlebige Stop-Latch ist installiert und wird bei jeder späteren
   Registrierung atomar geprüft.

Erst dann darf JSON etwa `{"shortId":"…","state":"running","accepted":true}`
ausgeben. Dieses 0 bedeutet ausschließlich **dauerhaft angenommen**. Timeout,
EOF vor Ready, ungültige Protokollversion, fehlende Persistenz oder Tod des
Bootstrap-Kinds führen zu einem Nicht-null-Exit und einem persistierten
`failed`; es darf kein positives `spawning`-Resultat geben.

**Vorbildbelege:** tmux beendet den Client erst nach dem vollständigen
Detach-Handshake (`<tmux>/server-client.c:2279-2326,2604-2611`;
`<tmux>/client.c:728-772`); containerd liefert den Shim erst nach
Bootstrap-Antwort, Verbindung und persistierbarer Wiederanheftung
([containerd binary.go:66-152]); runc publiziert detached Erfolg und PID erst
nach erfolgreichem Prozess-/Console-Handoff ([runc
utils_linux.go:288-326,161-182]).

### V2 — Waiter-Vertrag: beobachten und wiederanheften, nie besitzen

`agent wait <id>`/`run --wait` dürfen nur über Job-State und den
Supervisor-Control-Kanal beobachten. Ihr Tod, Ctrl-C oder Timeout bedeutet
**Client-Detach** und darf kein Signal an Supervisor oder Codex senden. Ein
neuer Waiter muss anhand der stabilen Short-ID wieder anheften können und über
einen Probe-Request eine Antwort des Owners erhalten; PID-/Dateiexistenz ist
nur ein Hinweis. Der Supervisor räumt seine Ressourcen selbst auf und
persistiert den Endzustand unabhängig von der Zahl der Waiter.

Das entspricht bereits der beabsichtigten WhisperM8-Semantik in
`detachThenFollowAndEmit`: Ctrl-C stoppt nur das Zuschauen, `agent stop` den
Turn. (`WhisperM8/CLI/AgentCLICommand.swift:445-459`) N07 zeigt jedoch, dass
diese Semantik ohne V1 zwischen Spawn und Ready noch nicht garantiert ist.

**Vorbildbelege:** tmux entfernt einen verlorenen Client, ohne im selben Pfad
die Session zu zerstören (`<tmux>/server-client.c:480-555`), und Zellij
verbindet Attach-Clients per Session-Socket und eigener `AttachClient`-Nachricht
(`<zellij>/zellij-client/src/lib.rs:873-923`;
`<zellij>/zellij-server/src/lib.rs:1126-1214`).

### V3 — Finalitäts-Gate: Wann `run --json --wait` Erfolg melden darf

Die finale Entscheidung wird erst nach der vorhandenen Drei-Wege-Drain-Barriere
(stdout-EOF, stderr-EOF, Process-Termination) gefällt. Für einen erfolgreichen
Turn müssen **alle** Bedingungen wahr sein:

1. `terminationReason == .exit` und `terminationStatus == 0`;
2. genau ein gültiges `turn.completed` wurde im Turn-State gelatcht;
3. kein `turn.failed` und kein Watchdog-Stall liegt vor;
4. `--output-last-message` ist vorhanden und nicht leer;
5. der Abschluss-Report ist gemäß `AgentReport` parsebar;
6. der finale State samt Exit-Fakten wurde erfolgreich und atomar persistiert.

Fehlt eine Bedingung, wird der Job nicht `.done`: Signalende wird mit
Termination-Reason und Signalnummer als `failed` erfasst; ein bestätigter
Stop-Wunsch wird `.stopped`; fehlendes `turn.completed` oder finales Ergebnis
wird `failed` mit präzisem Protokollgrund. Ein absichtlich gelieferter
`report.status == partial` muss im JSON als `partial` sichtbar bleiben und darf
nicht als `success` etikettiert werden. Der Exit-Code des Waiters muss aus dem
persistierten Endzustand entstehen; `.stopped`, `.partial` und `.failed`
brauchen voneinander unterscheidbare Nicht-Erfolgswerte statt des heutigen
pauschalen 0 für `.stopped`.

**Vorbildbelege:** tmux wartet auf den echten Child-Status und überträgt normal
vs. Signal als exakten Rückgabewert (`<tmux>/server.c:475-507`;
`<tmux>/window.c:1350-1371`; `<tmux>/server-client.c:2304-2317`); der
containerd-Shim blockiert `Wait` bis zum Exit und liefert Status plus Zeit
([containerd task/service.go:575-594]). Die geforderte Eventordnung verhindert,
dass ein früher Exit einen erfolgreichen Start überholt ([containerd Runtime
v2:384-408]).

### V4 — Stop-vor-Registrierung: persistieren, latchen, atomar konsumieren

`agent stop` muss zuerst unter dem Job-Lock einen dauerhaften Stop-Wunsch
(`stopping` oder äquivalente monotone Stop-Generation) schreiben und erst danach
signalisieren. Der Signal-Handler setzt denselben In-Memory-Latch. Der Runner
benötigt eine einzige gelockte Operation nach dem Muster
`registerProcessAndApplyPendingStop(process)`: Prozess veröffentlichen und,
falls der Latch bereits gesetzt ist, noch unter demselben Lifecycle-Vertrag
die Termination auslösen. Ein getrenntes `terminate()` vor einer späteren
Zuweisung ist verboten.

Konkrete Resultatregeln:

- Stop vor Supervisor-Ready bleibt im Store stehen und wird beim Bootstrap
  konsumiert; V1 verhindert zusätzlich, dass eine noch nicht signalbereite PID
  als erfolgreich gestartet gemeldet wird.
- Stop zwischen Supervisor-Ready und Codex-Registrierung wird gelatcht; das Kind
  darf nach Registrierung nicht weiterlaufen.
- Stop nach Registrierung signalisiert genau das registrierte Kind.
- `kill(2)`-Fehler werden ausgewertet: Ein gescheitertes Signal ist kein
  bestätigter Stop. „gestoppt“ darf erst nach persistiertem Terminalzustand
  erscheinen; bis dahin lautet die Wahrheit `stopping`/„Stop angenommen“.
- Der Stop-Wunsch wird erst beim terminalen Übergang gelöscht, nicht beim
  bloßen Signalversand.

**Vorbildbeleg:** containerd registriert den Exit-Subscriber vor Start und
reconciliert ein bereits eingetroffenes Ereignis unter demselben
`lifecycleMu`, bevor der Prozess als laufend gilt ([containerd task/service.go:149-219,295-350]).

## 4. Zustands- und Ausgabe-Matrix

| Beobachtung | Persistierter Zustand | JSON-Aussage | Waiter-Exit |
|---|---|---|---|
| Bootstrap läuft, kein Ready | `spawning` | noch keine finale stdout-Ausgabe | Client wartet |
| Detach + Ready + Stop-Fähigkeit bestätigt | `running` | `accepted: true`, **kein** Turn-Erfolg | 0 nur im nicht wartenden Acceptance-Modus |
| Stop dauerhaft angenommen, Abschluss offen | `stopping` oder monotones Stop-Feld | `stopAccepted: true`, nicht `stopped` | Stop-Command darf Acceptance melden; Waiter bleibt offen |
| Normaler Exit 0 + `turn.completed` + valider Report `success` | `done` | `completion: complete`, `report.status: success` | 0 |
| Valider Abschluss mit Report `partial` | eigener semantischer Partial-Ausgang oder `done` + explizites Partial | `report.status: partial`, nie `success` | dedizierter Nicht-Erfolgswert |
| `turn.failed`, Stall, Signal ohne Stop-Wunsch, fehlendes Complete/Resultat | `failed` | präziser Prozess-/Protokollgrund | Nicht-null |
| Exit nach bestätigtem Stop-Wunsch | `stopped` | Stop-Grund und Exit-Fakten | dedizierter Nicht-Erfolgswert |

Damit bleiben zwei Wahrheiten getrennt: **Acceptance** beantwortet, ob der
Supervisor den Job unabhängig übernommen hat; **Completion** beantwortet, wie
der Turn tatsächlich endete. runc macht dieselbe Trennung zwischen detached
Start-Erfolg und späterer Exit-Wahrheit, die containerd-shim über `Wait`
bereitstellt. ([runc utils_linux.go:288-326], [containerd task/service.go:575-594])

## 5. Erforderliche Verifikationsfälle für die spätere Umsetzung

1. **N07 deterministisch:** Waiter direkt an jedem Bootstrap-Gate beenden
   (vor `setsid`, vor Signal-Source, vor State-Persistenz, vor Ready). Nur nach
   Ready darf der Job weiterlaufen; davor muss der Aufrufer einen Fehler sehen
   oder die bereits übernommene Supervisor-Instanz per Probe wiederfinden.
2. **N08 deterministisch:** Matrix aus Exit 0 ohne `turn.completed`, Exit 0 mit
   leerer/missing Last-Message, `turn.completed` plus Signalende, `turn.failed`
   plus Exit 0 und vollständigem Erfolg. Nur die vollständige Konjunktion darf
   0/`success` ergeben.
3. **N14 deterministisch:** Stop vor Supervisor-Ready, nach Ready aber vor
   `process.run`, zwischen `process.run` und Registrierung sowie nach
   Registrierung injizieren. In keinem Fall darf ein Codex-Kind nach dem
   konsumierten Stop-Latch weiterlaufen.
4. **Exit-Wahrheit:** normaler Exit, SIGTERM, SIGKILL, Watchdog und absichtlicher
   Stop müssen in State, finalem JSON und Waiter-Exit unterscheidbar sein.
5. **Reattach:** Ersten Waiter töten, zweiten per Short-ID anheften und dasselbe
   finale Ergebnis einschließlich Exit-Fakten erhalten.

## Webquellen

- [containerd Runtime v2:191-258] —
  <https://github.com/containerd/containerd/blob/29edc6e8b7fe4a66d4f4fde6666893941910d954/docs/runtime-v2.md#L191-L258>
- [containerd Runtime v2:384-408] —
  <https://github.com/containerd/containerd/blob/29edc6e8b7fe4a66d4f4fde6666893941910d954/docs/runtime-v2.md#L384-L408>
- [containerd binary.go:66-152] —
  <https://github.com/containerd/containerd/blob/29edc6e8b7fe4a66d4f4fde6666893941910d954/core/runtime/v2/binary.go#L66-L152>
- [containerd shim_manager.go:292-306,309-347] —
  <https://github.com/containerd/containerd/blob/29edc6e8b7fe4a66d4f4fde6666893941910d954/core/runtime/v2/shim_manager.go#L292-L347>
- [containerd process/init.go:216-249,277-290] —
  <https://github.com/containerd/containerd/blob/29edc6e8b7fe4a66d4f4fde6666893941910d954/cmd/containerd-shim-runc-v2/process/init.go#L216-L290>
- [containerd task/service.go:149-219] —
  <https://github.com/containerd/containerd/blob/29edc6e8b7fe4a66d4f4fde6666893941910d954/cmd/containerd-shim-runc-v2/task/service.go#L149-L219>
- [containerd task/service.go:295-350] —
  <https://github.com/containerd/containerd/blob/29edc6e8b7fe4a66d4f4fde6666893941910d954/cmd/containerd-shim-runc-v2/task/service.go#L295-L350>
- [containerd task/service.go:575-594] —
  <https://github.com/containerd/containerd/blob/29edc6e8b7fe4a66d4f4fde6666893941910d954/cmd/containerd-shim-runc-v2/task/service.go#L575-L594>
- [runc utils_linux.go:161-182] —
  <https://github.com/opencontainers/runc/blob/fc89fbd9ebec617475d7e7a7a38f4e4bf277cf54/utils_linux.go#L161-L182>
- [runc utils_linux.go:288-326] —
  <https://github.com/opencontainers/runc/blob/fc89fbd9ebec617475d7e7a7a38f4e4bf277cf54/utils_linux.go#L288-L326>
- [runc start_detached.bats:34-55] —
  <https://github.com/opencontainers/runc/blob/fc89fbd9ebec617475d7e7a7a38f4e4bf277cf54/tests/integration/start_detached.bats#L34-L55>

[containerd Runtime v2:191-258]: https://github.com/containerd/containerd/blob/29edc6e8b7fe4a66d4f4fde6666893941910d954/docs/runtime-v2.md#L191-L258
[containerd Runtime v2:384-408]: https://github.com/containerd/containerd/blob/29edc6e8b7fe4a66d4f4fde6666893941910d954/docs/runtime-v2.md#L384-L408
[containerd binary.go:66-152]: https://github.com/containerd/containerd/blob/29edc6e8b7fe4a66d4f4fde6666893941910d954/core/runtime/v2/binary.go#L66-L152
[containerd shim_manager.go:292-306,309-347]: https://github.com/containerd/containerd/blob/29edc6e8b7fe4a66d4f4fde6666893941910d954/core/runtime/v2/shim_manager.go#L292-L347
[containerd process/init.go:216-249,277-290]: https://github.com/containerd/containerd/blob/29edc6e8b7fe4a66d4f4fde6666893941910d954/cmd/containerd-shim-runc-v2/process/init.go#L216-L290
[containerd task/service.go:149-219]: https://github.com/containerd/containerd/blob/29edc6e8b7fe4a66d4f4fde6666893941910d954/cmd/containerd-shim-runc-v2/task/service.go#L149-L219
[containerd task/service.go:295-350]: https://github.com/containerd/containerd/blob/29edc6e8b7fe4a66d4f4fde6666893941910d954/cmd/containerd-shim-runc-v2/task/service.go#L295-L350
[containerd task/service.go:149-219,295-350]: https://github.com/containerd/containerd/blob/29edc6e8b7fe4a66d4f4fde6666893941910d954/cmd/containerd-shim-runc-v2/task/service.go#L149-L350
[containerd task/service.go:575-594]: https://github.com/containerd/containerd/blob/29edc6e8b7fe4a66d4f4fde6666893941910d954/cmd/containerd-shim-runc-v2/task/service.go#L575-L594
[runc utils_linux.go:161-182]: https://github.com/opencontainers/runc/blob/fc89fbd9ebec617475d7e7a7a38f4e4bf277cf54/utils_linux.go#L161-L182
[runc utils_linux.go:288-326]: https://github.com/opencontainers/runc/blob/fc89fbd9ebec617475d7e7a7a38f4e4bf277cf54/utils_linux.go#L288-L326
[runc start_detached.bats:34-55]: https://github.com/opencontainers/runc/blob/fc89fbd9ebec617475d7e7a7a38f4e4bf277cf54/tests/integration/start_detached.bats#L34-L55
