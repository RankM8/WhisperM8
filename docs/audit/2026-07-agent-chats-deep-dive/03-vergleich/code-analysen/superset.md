# superset

## Scope und Beleggrenze

Diese Analyse basiert ausschließlich auf dem lokalen Superset-Klon. WhisperM8-Code wurde nicht gelesen. Der Vergleich verwendet den vorgegebenen Ist-Rahmen: WhisperM8 ist eine native macOS-App, hostet die echte Claude-Code-CLI interaktiv in SwiftTerm-PTYs und startet zusätzlich `claude -p` beziehungsweise `claude --bg`.

Ein wichtiger Vorbehalt: Superset besitzt neben echten CLI-Terminals einen eigenen ACP-Chat-Pfad. Die persistierten `acpSessions` mit `sessionId`, `acpSessionId`, Harness und CWD in `packages/host-service/src/db/schema.ts:212-233` gehören zu diesem eingebauten Chat und sind kein Beleg für die Session-Steuerung einer im Terminal laufenden Claude-Code-CLI. Entsprechend werden nur Terminal-, Prozess-, Workspace- und Hook-Muster übertragen. Ein Umbau WhisperM8s zu ACP, Agent SDK oder einer eigenen Chat-Runtime wird nicht empfohlen.

## Kurzfazit

Supersets stärkste Idee ist die Trennung dreier Lebensdauern: Ein persistenter `terminalId` bezeichnet die Terminal-Ressource, ein separater Daemon besitzt die PTY, und die UI kann beliebig an- und abgekoppelt werden. Dadurch überleben laufende Shells Renderer- und Host-Service-Neustarts.

Die Schwäche für WhisperM8s Anwendungsfall liegt eine Ebene darüber: Superset beobachtet die Claude-Conversation-ID lediglich über Hooks. Der untersuchte Terminalpfad injiziert weder `--session-id`, `--resume` noch `--fork-session`, liest keine Claude-JSONL-Historie und modelliert Fork und Resume nicht als unterschiedliche Zustandsübergänge.

Drei übertragbare Kernmuster:

1. **Persistente Terminal-Ressource mit externem PTY-Owner:** stabile `terminalId`, SQLite-Zeile, detached Broker, Adoption statt Doppel-Spawn und Socket-Reconnect mit begrenztem Replay.
2. **Explizite Identitätsschichten und bestätigte Übergänge:** WhisperM8 muss UI-Surface, PTY/Prozess, Claude-Session, Fork-Elternschaft, Workspace/Worktree und CLI-Account getrennt persistieren; Hooks und JSONL bestätigen die geplante `--session-id`-, `--resume`- oder `--fork-session`-Transition.
3. **Status und Recovery als Reconciliation:** PTY-Liveness, Claude-Turnstatus, Conversation-Auffindbarkeit und UI-Unread sind verschiedene Wahrheiten. Beim Neustart werden Registry, Broker und account-spezifische Claude-JSONL-Dateien abgeglichen; vor destruktiver Bereinigung gilt eine Schonfrist.

## Projektüberblick und Stack

Superset ist ein TypeScript-Monorepo für parallele CLI-Agenten in isolierten Git-Worktrees. Das Projekt beschreibt Worktree-Isolation und parallele Agenten in `README.md:27-36`, einen Workspace mit eigenem Branch, Terminal und Environment in `README.md:46-50` sowie persistente Terminals über Neustarts in `README.md:74-78`.

| Schicht | Technik | Relevante Dateien |
|---|---|---|
| Desktop-UI | Electron/React, xterm.js, TanStack DB, Zustand, `@superset/panes` | `apps/desktop/src/renderer/lib/terminal/terminal-runtime-registry.ts:37-350`; `apps/desktop/src/renderer/lib/terminal/terminal-ws-transport.ts:15-637`; `apps/desktop/src/renderer/routes/_authenticated/_dashboard/v2-workspace/$workspaceId/hooks/useV2WorkspacePaneLayout/useV2WorkspacePaneLayout.ts:19-108` |
| Host-Service | Bun/Node, Hono/tRPC, Drizzle/SQLite | `packages/host-service/src/terminal/terminal.ts:213-1545`; `packages/host-service/src/db/schema.ts:16-56`; `packages/host-service/src/daemon/DaemonSupervisor.ts:183-1202` |
| PTY-Broker | eigener Node-Prozess, `node-pty`, Unix Domain Socket | `packages/pty-daemon/src/Server/Server.ts:78-617`; `packages/pty-daemon/src/SessionStore/SessionStore.ts:4-103`; `packages/pty-daemon/src/Pty/Pty.ts:28-575` |
| Agent-/Workspace-Integration | Shell-Wrapper, Claude-/Codex-Hooks, Git-Worktrees | `apps/desktop/src/main/lib/agent-setup/agent-wrappers-claude-codex-opencode.ts:48-284`; `packages/host-service/src/terminal-agents/store.ts:20-195`; `packages/host-service/src/trpc/router/workspaces/workspaces.ts:569-832` |

Die Architektur ist terminalzentriert. Der Host-Service bezeichnet sich selbst als dünnen Adapter zum Daemon; der Daemon besitzt die PTYs (`packages/host-service/src/terminal/terminal.ts:44-53`). Das ist für WhisperM8 die relevante Referenz.

## 1. Session-Identität und aktive Session

### Supersets Identitätsmodell

Superset verwendet im Terminalpfad mehrere getrennte IDs:

| Identität | Lebensdauer und Eigentümer | Code-Beleg |
|---|---|---|
| Workspace | persistente DB-Entität mit Projekt, Worktree-Pfad und Branch | `packages/host-service/src/db/schema.ts:167-210` |
| Terminal | persistente `terminalSessions.id`; trägt Ursprungs-Workspace und Lifecycle-Zeitpunkte | `packages/host-service/src/db/schema.ts:16-37` |
| PTY-Prozess | vom Daemon unter derselben Terminal-ID gehalten; PID ist Metadatum, nicht UI-Identität | `packages/pty-daemon/src/protocol/messages.ts:9-24` |
| Pane/Ansicht | Pane-Daten enthalten nur `terminalId` | `apps/desktop/src/renderer/routes/_authenticated/_dashboard/v2-workspace/$workspaceId/types.ts:9-11` |
| Agent-Lauf | optionale Hook-Bindung aus `agentId` und `agentSessionId` an eine Terminal-ID | `packages/host-service/src/db/schema.ts:39-56`; `packages/shared/src/agent-identity.ts:3-17` |

Der aktuelle UI-Tab ist damit weder Prozess noch Agent-Conversation. Das persistierte Pane-Layout enthält den `terminalId` und die aktive Tab-ID. Es wird pro Workspace aus einer lokalen Collection geladen und wieder zurückgeschrieben (`useV2WorkspacePaneLayout.ts:19-22,42-62,81-106`). Diese Skopierung ist bewusst: Bei schnellen Workspacewechseln dürfen noch geladene Pane-Daten nicht unter einem anderen Worktree gerendert oder persistiert werden (`useV2WorkspacePaneLayout.ts:23-35`).

Beim Wechsel einer Terminal-Session prüft das Dropdown zuerst, ob die Ziel-ID bereits in einem anderen Pane gerendert wird. Dann aktiviert es nur dieses Pane. Andernfalls wird das aktuelle Terminal in den Hintergrund gelegt und das Pane auf die andere `terminalId` umgebogen (`TerminalSessionDropdown.tsx:64-83,94-108,174-210`). Der Wechsel der aktiven UI-Auswahl beendet weder PTY noch CLI-Prozess.

Auch der Renderer-Lifecycle ist getrennt. `TerminalPane` mountet zuerst xterm und verbindet danach den WebSocket. Der Socket transportiert nur Daten und keine Create-Absicht; die Session muss vorher existieren (`TerminalPane.tsx:132-165`). Beim Unmount wird nur detached. Ein explizites `dispose` im Runtime-Registry-Code ist destruktiv, während `release` lediglich Renderer-Ressourcen freigibt (`terminal-runtime-registry.ts:326-350`).

### Bedeutung der Claude-Session-ID

Die optionale `agentSessionId` ist nicht der Primärschlüssel des Terminals und wird nicht zum Starten oder Wiederaufnehmen von Claude verwendet. Der Claude-Wrapper ist ein pass-through und endet in `exec "$REAL_BIN" "$@"` (`agent-wrappers-claude-codex-opencode.ts:274-284`). Die eingebaute Claude-Definition startet interaktiv nur `claude --dangerously-skip-permissions` und headless `claude -p` (`packages/shared/src/builtin-terminal-agents.ts:59-68`). Im untersuchten Terminalpfad fanden sich keine Aufrufe mit `--session-id`, `--resume`, `--fork-session` oder `--continue`.

Die Claude-Session-ID gelangt nachträglich über Hooks in Superset. Das Hook-Template extrahiert `session_id` aus dem Claude-Payload und sendet es mit Terminal- und Agent-ID an den Host (`apps/desktop/src/main/lib/agent-setup/templates/notify-hook.template.sh:7-19,76-93`). Der Host validiert die Terminal-ID, leitet den Workspace serverseitig daraus ab und persistiert die Bindung (`packages/host-service/src/trpc/router/notifications/notifications.ts:54-95`). Das ist gute Beobachtung, aber keine kontrollierte Conversation-Identität.

### Vergleich zu WhisperM8

**Superset besser:** UI-Auswahl, Renderer-Objekt, WebSocket, PTY und Prozess sind nicht dieselbe Entität. Ein Tabwechsel kann eine laufende CLI deshalb nicht versehentlich beenden. Die Workspace-ID wird außerdem bei mutierenden Terminaloperationen geprüft; Schreiben und Attach verweigern eine fremde Workspace-Zuordnung (`packages/host-service/src/terminal/terminal.ts:450-471,1367-1467`).

**WhisperM8 potenziell besser:** Als gezielter Host der echten Claude-Code-CLI kann WhisperM8 die Conversation-ID beim Start kontrollieren und offizielle CLI-Übergänge verwenden. Superset beobachtet `agentSessionId` nur und kann nach Verlust der PTY nicht aus eigener persistenter Wahrheit sagen, welche Conversation in welchem Zweig aufzunehmen ist.

WhisperM8 sollte mindestens diese Identitäten getrennt führen:

- `surfaceId`: dauerhafte Chat-/Tab-Auswahl der App,
- `terminalId`: logische PTY-Ressource,
- `processGeneration`: konkreter Spawn beziehungsweise Reconnect,
- `claudeSessionId`: echte Claude-Code-Conversation,
- `workspaceId` und kanonischer `worktreePath`,
- `accountId` beziehungsweise `cliProfileId`.

Die aktive UI-Auswahl referenziert eine `surfaceId`. Diese zeigt auf die bestätigte Claude-Session und optional auf eine lebende Terminal-Generation. So kann dieselbe Conversation nach App-Neustart in einem neuen Prozess fortgesetzt werden, ohne ihre Identität zu wechseln.

## 2. Fork versus Resume

### Im Klon auffindbar

Für terminalgehostete Claude-Code-Sessions besitzt Superset kein explizites Fork-/Resume-Modell. Weder der Agent-Wrapper noch die Built-in-Definition setzen die betreffenden Claude-Flags (`agent-wrappers-claude-codex-opencode.ts:274-284`; `builtin-terminal-agents.ts:59-68`). Die Terminaldatenbank kennt `terminalId` und eine optionale zuletzt beobachtete `agentSessionId`, aber keine Eltern-Session, Transition-Art oder erwartete Ziel-ID (`packages/host-service/src/db/schema.ts:16-56`). Im untersuchten Terminalpfad wurde auch kein JSONL-Reader für Claude-Sessions gefunden.

Ein begrenzter Sicherheitsmechanismus existiert in der Statusbindung: Ändert sich `agentId`, übernimmt der Store nicht blind Session-ID oder Agent-Definition des alten Agenten. Bei einer geänderten `agentSessionId` setzt er außerdem `startedAt` neu (`packages/host-service/src/terminal-agents/store.ts:64-114`). Das verhindert veraltete Statusvererbung, aber nicht das Wiederaufnehmen des falschen Claude-Zweigs.

Supersets ACP-Chat-Sessionlogik ist hierfür nicht übertragbar. Sie steuert nicht die echte Claude-Code-CLI im PTY und würde den harten WhisperM8-Constraint verletzen.

### Erforderliches WhisperM8-Modell

Fork und Resume müssen zwei getrennte Identitätsübergänge sein:

| Operation | Identitätsregel | Persistenter Übergang |
|---|---|---|
| Neu | neue `claudeSessionId`, kein Parent | `planned(new) -> spawning -> confirmed` |
| Resume | dieselbe `claudeSessionId`; Prozess und PTY dürfen neu sein | `planned(resume, expectedSessionId) -> spawning -> confirmed` |
| Fork | neue Child-ID mit unveränderlicher Parent-ID | `planned(fork, parentSessionId, expectedChildId) -> spawning -> confirmed` |

Die genaue Kombination und Reihenfolge von `--session-id`, `--resume` und `--fork-session` muss gegen die von WhisperM8 unterstützte Claude-Code-Version verifiziert werden. Architektonisch sollte WhisperM8 aber bereits vor dem Spawn einen Launch-Intent atomar persistieren. Erst wenn Hook und/oder JSONL die erwartete Ziel-ID im erwarteten Account und Worktree bestätigen, wird `surfaceId.activeClaudeSessionId` umgehängt.

Bei einer abweichenden Hook-ID darf WhisperM8 nicht still auf den beobachteten Zweig wechseln. Der Prozess sollte als `identityMismatch` quarantänisiert werden, während die alte Surface-Zuordnung erhalten bleibt. Diese Soll-Ist-Prüfung fehlt Superset.

## 3. Verlorene oder nicht wiedergefundene Sessions

### Supersets Terminal-Recovery

Superset verhindert verlorene Terminalressourcen durch ein dreistufiges Register:

1. SQLite enthält aktive Terminalzeilen (`packages/host-service/src/db/schema.ts:16-37`).
2. Der Host-Service hält verbundene `TerminalSession`-Objekte in einer Map nach `terminalId` (`packages/host-service/src/terminal/terminal.ts:213-275`).
3. Der Daemon hält die tatsächlichen PTYs in einem `SessionStore`, ebenfalls nach ID (`packages/pty-daemon/src/SessionStore/SessionStore.ts:22-76`).

Beim Erzeugen prüft der Host zuerst In-Memory- und SQLite-Zustand und verwirft eine Workspace-Kollision (`terminal.ts:963-1013`). Danach fragt er den Daemon. Ist die ID dort bereits live, adoptiert er sie. Meldet ein normaler Open-Versuch eine bereits vorhandene Session, listet der Host erneut und adoptiert statt einen zweiten Prozess zu erzeugen (`terminal.ts:1058-1106`). Für eine adoptierte Session wird das Initialkommando ausdrücklich nicht erneut gesendet (`terminal.ts:1179-1181`). Das ist eine starke Exactly-once-Näherung für Spawn-Absichten.

Beim WebSocket-Attach wird die DB-Zeile validiert und erneut eine Daemon-Adoption versucht. Ist nach einem Maschinenneustart keine PTY mehr vorhanden, kann Superset unter derselben Terminal-ID eine Shell neu erzeugen und einen Restore-Hinweis anzeigen (`terminal.ts:1367-1467`). Dieser Fallback stellt eine Terminal-Surface wieder her, aber nicht notwendigerweise die zuvor laufende Claude-Conversation.

Der Reaper gleicht aktive DB-Zeilen mit Daemon-Sessions ab. Eine Daemon-Session ohne Datenbankzeile wird nicht beim ersten Durchlauf getötet, sondern erhält eine Zwei-Pass-Schonfrist, damit Create- und Recovery-Races keine frische Session vernichten (`packages/host-service/src/terminal/reaper/reaper.ts:38-92,168-225`). Der Supervisor unterscheidet bei der Daemon-Abfrage zudem zwischen unbekannt beziehungsweise nicht erreichbar (`null`) und erreichbar, aber leer (`[]`) (`packages/host-service/src/daemon/DaemonSupervisor.ts:470-509`). Diese Semantik verhindert falsche Negativbefunde.

### Fehlende Claude-Conversation-Recovery

Im untersuchten Terminalpfad fehlt ein persistenter, autoritativer Claude-Session-Katalog. `agentSessionId` ist ein Status-Binding. Es gibt keinen belegten Scan oder Index der Claude-JSONL-Dateien, keine Zuordnung von JSONL-Dateipfad, Inode oder mtime zu Workspace und Account und keine Recovery-Entscheidung anhand von Parent-/Child-Informationen.

Superset löst deshalb Terminal wiederfinden deutlich besser als Claude-Conversation zweifelsfrei wiederfinden.

### Übertragung auf WhisperM8

WhisperM8 sollte Supersets dreifachen Abgleich auf die CLI-Conversation erweitern:

```text
persistente WhisperM8-Registry
        |            \
        |             +--> PTY-Broker: terminalId, pid, alive, generation
        +----------------> Claude-Store: account, JSONL, sessionId, cwd, parent
```

Beim Start wird nicht aus einem einzelnen fehlenden Signal auf Verlust geschlossen. Der Reconciler prüft:

- Existiert die Surface-/Session-Zeile?
- Besitzt der Broker die Terminal-ID noch?
- Existiert die erwartete Claude-Session im richtigen Account-Store?
- Passen kanonischer Worktree-Pfad und gegebenenfalls JSONL-CWD?
- Gab es einen noch nicht bestätigten Fork-/Resume-Intent?
- Ist der letzte Hook zeitlich neuer als die bekannte Prozessgeneration?

Ein Zustand `brokerUnknown` ist nicht `processExited`; `jsonlScanPending` ist nicht `sessionMissing`. Wie Supersets Zwei-Pass-Reaper sollte WhisperM8 vor destruktiver Bereinigung einen bestätigten zweiten Abgleich nach einer Schonfrist verlangen.

Headless-Jobs über `claude -p` oder `claude --bg` gehören in dieselbe Registry, erhalten aber einen eigenen Ausführungstyp. Ein fehlendes UI-Pane darf einen Headless-Job nicht als verwaist klassifizieren.

## 4. PTY-Robustheit und Persistenz über Neustarts

### PTY-Ownership und Prozess-Reconnect

Der PTY-Daemon ist Supersets stärkster Referenzpunkt. Der Produktions-Host startet ihn detached und beendet ihn beim normalen Host-Service-Shutdown nicht; nur der Development-Pfad fährt ihn mit herunter (`packages/host-service/src/serve.ts:65-91`). Pro Organisation liegt ein Manifest unter `$SUPERSET_HOME_DIR/host/{organizationId}` mit PID, Socket, Protokollversion und Startzeit (`packages/host-service/src/daemon/manifest.ts:1-55`).

Beim Neustart versucht der Supervisor zuerst Manifest-Adoption und danach Socket-Adoption. Ein lebender PID wird bei einer fehlgeschlagenen Probe nicht vorschnell getötet. Die Socket-Antwort liefert außerdem die tatsächliche Daemon-PID und schützt gegen PID-Reuse (`packages/host-service/src/daemon/DaemonSupervisor.ts:889-1004`).

Der Unix-Socket wird wegen Darwins Pfadlängenlimit aus einer kurzen organisationsgebundenen Hash-ID gebildet und mit Modus `0600` geschützt (`DaemonSupervisor.ts:126-154`; `packages/pty-daemon/src/Server/Server.ts:78-96`). Der Supervisor besitzt getrennte Prüfungen für PID-Liveness und Socket-Erreichbarkeit. Ein lebender, aber vorübergehend nicht antwortender Daemon wird nicht automatisch mitsamt Sessions zerstört (`DaemonSupervisor.ts:581-630`).

Beim Host-Service-Verbindungsabbruch verwirft der Host alle In-Memory-Adapter und schließt Renderer-Sockets. Die PTYs bleiben im Daemon unangetastet, sodass Renderer-Reconnect eine frische Adoption erzwingt (`packages/host-service/src/terminal/terminal.ts:277-316`). Nicht die Electron-App und nicht der Host-Service besitzen die PTY.

### Daemon-Upgrade ohne PTY-Verlust

Superset übergibt laufende PTY-Master-FDs an einen Daemon-Nachfolger. Der Server sammelt Session-ID, FD, PID, Metadaten und Replay-Puffer (`packages/pty-daemon/src/Server/Server.ts:148-197`), startet einen Successor mit geerbten FDs und wartet auf ein IPC-Acknowledge (`Server.ts:199-279`). Erst nach erfolgreicher Bestätigung schließt der Vorgänger, ohne die Sessions zu töten (`Server.ts:282-321`). Bei einem Fehlschlag bleibt der Vorgänger Eigentümer.

`AdoptedPty` bedient den geerbten Master-FD direkt, pollt den Root-PID und implementiert Read, Write, Resize und Kill weiter (`packages/pty-daemon/src/Pty/Pty.ts:396-538`). Das ist ein anspruchsvolles P2-Muster. Für WhisperM8 ist zunächst ein langlebiger Broker wichtiger als ein Zero-Downtime-Broker-Upgrade.

### Binärpfad, Replay und Backpressure

Der Transport ist binär. Das Protokoll hält den PTY-Byte-Tail ausdrücklich als Bytes und nicht als Base64 (`packages/pty-daemon/src/protocol/messages.ts:1-5`). Der WebSocket leitet PTY-Ausgabe als Binärdaten weiter (`packages/host-service/src/terminal/terminal.ts:147-177`), und der Renderer schreibt rohe Bytes in xterm (`apps/desktop/src/renderer/lib/terminal/terminal-ws-transport.ts:15-35`). So bleiben UTF-8-Grenzen und Terminal-Escape-Sequenzen intakt.

Der Daemon speichert nur einen 64-KiB-Ringpuffer; der Renderer besitzt den längeren Scrollback (`packages/pty-daemon/src/SessionStore/SessionStore.ts:4-37`). Beim Subscribe kommt der Snapshot vor Live-Daten (`packages/pty-daemon/src/handlers/handlers.ts:132-164`). Der Host sendet beim Replay zunächst eine Modus-Präambel und danach Daten in FIFO-Reihenfolge (`packages/host-service/src/terminal/terminal.ts:576-611`).

Langsame Renderer-Verbindungen werden ab 8 MiB `bufferedAmount` geschlossen, damit sie die PTY nicht blockieren; anschließend können sie reconnecten und replayen (`terminal.ts:544-574`). Auf Daemon-Ebene wird bei Socket-Stau die PTY per Kernel-Flow-Control pausiert und später fortgesetzt (`packages/pty-daemon/src/Server/Server.ts:476-555`).

Der Renderer reconnectet mit exponentiellem Backoff von 500 ms bis 10 s grundsätzlich unbegrenzt. Erst nach zehn Versuchen wird eine Diagnose prominent. Ein explizites PTY-Exit oder ein fataler Protokollfehler beendet den Reconnect (`terminal-ws-transport.ts:59-119,459-630`). Zugriffstokens werden pro Dial neu signiert (`terminal-ws-transport.ts:459-505`).

Der xterm-Runtime-Registry parkt unsichtbare DOM-Runtimes, statt sie bei Workspacewechseln sofort zu zerstören. Ein LRU-Limit kann den Renderer-Puffer freigeben, ohne die PTY anzufassen (`terminal-runtime-registry.ts:155-165,261-295`). So überlebt Scrollback kurze UI-Wechsel unabhängig von Prozesspersistenz.

### Prozessbaum und Beenden

Superset beendet nicht nur den Shell-Root-PID. `TreeKiller` merkt sich Prozessketten, aktualisiert die Prozessliste mehrfach und eskaliert bei Bedarf bis `SIGKILL` (`packages/pty-daemon/src/Pty/Pty.ts:28-68,91-186`). TTY und Prozessgruppe werden als langlebige Koordinaten gehalten, damit auch später geforkte Nachfahren auffindbar bleiben (`Pty.ts:63-68`). Für die normale Close-Operation wird standardmäßig `SIGHUP` verwendet, weil zsh `SIGTERM` abfangen kann (`packages/pty-daemon/src/handlers/handlers.ts:80-130`).

### Grenze des Restore-Fallbacks

Supersets Respawn unter derselben `terminalId` nach einem Rechnerneustart stellt nur eine neue Shell hinter der alten Surface her. Für WhisperM8 wäre ein blindes erneutes Starten von `claude` gefährlich: Die CLI könnte eine neue Conversation eröffnen oder implizit den falschen Zweig wählen.

Nach Verlust des Brokers muss WhisperM8 aus der persistierten `claudeSessionId` einen expliziten Resume-Launch bauen und ihn vor Aktivierung bestätigen. `terminalId` darf die Conversation-ID niemals ersetzen.

### Priorisierte PTY-Übertragung

- **P0:** Stabile Terminal-ID, persistente Registry, idempotentes Create/Adopt, Workspace-Ownership-Gate, binäre PTY-Bytes, begrenzter Replay-Puffer, Backpressure und Reconnect bis zu einem autoritativen Exit.
- **P1:** Separater detached macOS-Broker besitzt die PTY außerhalb des SwiftUI-App-Prozesses. App-, Fenster- und View-Lifecycle detach-en nur; `dispose` ist ausdrücklich destruktiv.
- **P2:** FD-Handoff für Broker-Upgrades. Erst sinnvoll, wenn Crash-Adoption, Session-Reconciliation und Prozessbaum-Kill stabil getestet sind.

## 5. Multi-Account-Isolation

### Supersets tatsächliche Isolation

Superset isoliert seine eigenen Organisationen gut. Der Desktop-Koordinator hält Host-Prozesse nach `organizationId`, setzt je Organisation `HOST_DB_PATH`, Secret und Auth-Token und verwendet `$SUPERSET_HOME_DIR/host/{organizationId}/host.db` (`apps/desktop/src/main/lib/host-service-coordinator.ts:353-497`). PTY-Daemon, Manifest, Socket und Health-State sind ebenfalls organisationsgebunden (`packages/host-service/src/daemon/manifest.ts:1-55`; `packages/host-service/src/daemon/DaemonSupervisor.ts:183-218`). Terminal- und Workspace-Daten liegen damit nicht in einer gemeinsamen Superset-Datenbank.

Das ist jedoch keine belegte Isolation mehrerer Claude-Code-Accounts auf demselben macOS-Benutzer. Die Claude-Hook-Konfiguration wird global in `~/.claude/settings.json` verwaltet (`agent-wrappers-claude-codex-opencode.ts:143-164,245-262`). Terminalprozesse erhalten eine bereinigte, aber grundsätzlich gemeinsame Login-Shell-Umgebung (`packages/host-service/src/terminal/env.ts:121-170,193-209`). Der Denylist-Filter entfernt Superset-Host-Secrets, richtet aber kein Claude-spezifisches Account-Home ein (`packages/host-service/src/terminal/env-strip.ts:1-72`). Im untersuchten Pfad fanden sich weder `CLAUDE_CONFIG_DIR` noch eine account-spezifische Claude-JSONL-Suche.

### Vergleich zu WhisperM8

**Superset besser:** Organisation, Host-Prozess, DB, Daemon-Socket und Authentisierung besitzen einen konsistenten Namespace.

**Superset unzureichend als Multi-Claude-Account-Referenz:** Zwei Superset-Organisationen unter demselben OS-Benutzer können weiterhin dieselbe globale Claude-Konfiguration und dieselben Credentials sehen.

WhisperM8 sollte `accountId` zu einem Pflichtbestandteil jeder relevanten Schlüsselbeziehung machen:

```text
(accountId, workspaceId, surfaceId)
    -> terminalId
    -> claudeSessionId
    -> jsonlLocation
    -> hookBinding
```

Der Spawn muss ein ausdrücklich gewähltes account-spezifisches CLI-Profil oder Konfigurations-Home erhalten, sofern die unterstützte Claude-Code-Version dafür einen stabilen Mechanismus bereitstellt. Diese konkrete CLI-Konfiguration ist außerhalb des Superset-Klons zu verifizieren und darf nicht aus Supersets globalem `~/.claude`-Setup abgeleitet werden.

Hook-Ereignisse müssen zusätzlich `accountId` oder einen nicht fälschbaren lokalen Profil-Schlüssel tragen. Eine alleinige `sessionId` ist über Profile hinweg kein hinreichender Lookup-Key.

## Workspace- und Worktree-Lifecycle

Superset koppelt Terminal-Ownership konsequent an persistente Workspaces. Ein Terminal kann nur erstellt werden, wenn Workspace und Worktree-Pfad noch existieren (`packages/host-service/src/terminal/terminal.ts:1002-1013`). Sichtbare Sessions werden nach Workspace gefiltert (`terminal.ts:387-418`), und Input, Attach sowie Dispose prüfen die Zuordnung erneut (`terminal.ts:450-471,947-961`).

Die Worktree-Erzeugung ist unter einem Lock idempotent. Vor dem Erzeugen werden stale Git-Registrierungen gepruned; vorhandene Branches und Worktrees werden geprüft und gegebenenfalls adoptiert (`packages/host-service/src/trpc/router/workspaces/workspaces.ts:569-680`). Zeigt ein vorhandener Branch auf einen anderen Commit als erwartet, wird abgebrochen statt in den falschen Zweig zu wechseln (`workspaces.ts:653-660`). Bei der Adoption liest Superset den tatsächlichen Branch aus Git und vertraut nicht einem möglicherweise veralteten Request (`workspaces.ts:799-832`). Fehlgeschlagene Teilschritte rollen Worktree und Branch zurück (`workspaces.ts:681-784`).

Auch das Löschen ist geordnet: Eine Single-flight-Sperre und ein Dirty-Preflight stehen vor dem Teardown (`packages/host-service/src/trpc/router/workspace-cleanup/workspace-cleanup.ts:178-257`). Danach werden PTYs beendet (`workspace-cleanup.ts:259-272`). Erst dann wird ein kanonisch validierter Worktree entfernt und die Git-Registry kontrolliert. Bei unbekanntem Zustand bleibt der Datensatz erhalten, statt eine nicht wiederauffindbare Disk-Leiche zu erzeugen (`workspace-cleanup.ts:274-340`). Die lokale Löschung ist autoritativ, Cloud-Tombstones werden wiederholt (`workspace-cleanup.ts:343-360`).

Für WhisperM8 sollte dieselbe Reihenfolge um Claude-Conversation-Metadaten erweitert werden:

1. Workspace-Löschung single-flight markieren.
2. Dirty- und Prozess-Preflight durchführen.
3. Headless- und interaktive PTYs explizit beenden oder detach-en.
4. Registry-Einträge nicht sofort löschen, sondern mit kanonischem Worktree, Account und letzter Claude-Session tombstonen, solange ein späteres Resume gewünscht sein kann.
5. Worktree kanonisch und gegen Git verifiziert entfernen.
6. JSONL-Metadaten aktualisieren; externe Dateien unter `~/.claude` bleiben read-only.

Der übertragbare Kern ist nicht ein Worktree pro Chat, sondern: Jeder CLI-Launch besitzt eine überprüfbare Workspace-Bindung, und ein Fork der Claude-Conversation ist nicht automatisch ein Git-Branch-Fork. Beide Elternschaften müssen getrennt modelliert werden.

## Statusentkopplung

Superset behandelt Hook-Status als eigene Datenquelle, statt Terminalausgabe zu parsen. Das Hook-Template normalisiert Claude-Ereignisse und verwirft Parsefehler, statt sie fälschlich als `Stop` zu melden (`apps/desktop/src/main/lib/agent-setup/templates/notify-hook.template.sh:7-40`).

Der zentrale Mapper trennt Turn-Ereignisse `Start`, `Stop`, `PermissionRequest` und `Failed` von Session-Lifetime `Attached` und `Detached`. Insbesondere ist `SessionStart` kein arbeitet gerade (`packages/host-service/src/events/map-event-type.ts:1-21,23-93`).

Der Host persistiert die aktuell lebende Agentbindung nur für aktive Terminalzeilen und kann defunkte Bindings bereinigen (`packages/host-service/src/terminal-agents/persistence.ts:46-99,151-219`). Der Renderer persistiert dagegen nur Benutzerfakten wie bis wann gesehen. Eine Migration verwirft bewusst alten persistierten Arbeitsstatus, damit nach Neustarts keine stale Statuspunkte erscheinen (`apps/desktop/src/renderer/stores/v2-notifications/store.ts:18-35,61-88,99-132`). PTY-Lifecycle und Agent-Lifecycle sind auch im Eventmodell getrennt (`packages/host-service/src/events/types.ts:26-45`).

Für WhisperM8 sollte die Trennung so aussehen:

| Statusdimension | Autoritative Quelle | Neustartregel |
|---|---|---|
| PTY/Prozess | Broker und Exit-Event | vom Broker neu ableiten |
| Claude-Turn | Claude Hooks | `working` und `permission` nicht blind aus UI-Cache übernehmen |
| Conversation | Registry, JSONL und bestätigte CLI-ID | persistent und reconcile-bar |
| Headless-Job | Prozess, Exitcode und strukturierte Ausgabe | getrennt vom interaktiven Turnstatus |
| Unread/Attention | letzter Hook-Zeitpunkt gegenüber `seenAt` | nur Benutzerfakt persistieren |

Der Hook-Endpunkt sollte wie bei Superset den Workspace nicht aus untrusted Hook-Daten übernehmen, sondern über `terminalId` und `accountId` serverseitig herleiten. Zusätzlich muss WhisperM8 den Hook gegen den aktuellen Launch-Intent prüfen: Ein `SessionStart` mit unerwarteter Claude-ID bestätigt keinen Resume oder Fork.

## Direkte Bewertung gegenüber WhisperM8

Da kein WhisperM8-Code gelesen wurde, ist die Bewertung auf den vorgegebenen Architekturrahmen begrenzt.

| Bereich | Superset | Bewertung für WhisperM8 |
|---|---|---|
| Echte CLI im Terminal | echte CLI, pass-through Wrapper | kompatibel mit dem harten Constraint |
| PTY-Ownership | detached Broker statt App-/Host-Prozess | deutlich stärkeres Referenzmuster für Neustartpersistenz |
| UI-/Prozess-Trennung | Pane, xterm, Socket, Terminal und PID getrennt | direkt übernehmen |
| Claude-Session-Identität | nur optional per Hook beobachtet | schwächer; WhisperM8 braucht steuernde Registry und Flags |
| Fork/Resume | nicht modelliert | unzureichend; getrennte Transitions sind Pflicht |
| JSONL-Recovery | im Terminalpfad nicht auffindbar | unzureichend; WhisperM8 sollte read-only indexieren |
| Worktree-Sicherheit | Locking, OID-/Branchprüfung, Adoption, geordnetes Löschen | starkes Muster |
| Status | Hook-Quelle, Lifecycle getrennt, UI persistiert nur Seen-Fakten | starkes Muster, um Conversation-Dimension ergänzen |
| Multi-Tenant | Superset-Org trennt DB, Daemon und Socket | stark für App-Tenants, aber kein Beleg für Claude-Account-Isolation |

## Priorisierte übertragbare Muster

### P0 — Identitätsledger

Eine persistente, transaktional aktualisierte Tabelle sollte mindestens enthalten:

```text
surfaceId, accountId, workspaceId, canonicalWorktreePath,
terminalId, processGeneration,
claudeSessionId, parentClaudeSessionId,
transitionKind(new|resume|fork),
transitionState(planned|spawning|confirmed|failed),
jsonlPath, lastJsonlMtime, lastHookEvent, lastHookAt,
ptyState, conversationState, createdAt, updatedAt
```

Ein Resume ändert niemals `claudeSessionId`; ein Fork ändert sie immer und schreibt den Parent unveränderlich. Die Surface-Umschaltung erfolgt erst nach Bestätigung. Dies schließt Supersets größte Lücke für WhisperM8.

### P0 — Reconciliation statt implizitem Fallback

Beim App-Start und nach jedem Broker-Reconnect werden Registry, Broker-Liste, Hooks und account-spezifische JSONL-Dateien verglichen. Fehlende Daten erhalten Zustände wie `unknown`, `scanPending` oder `brokerUnavailable`, nicht sofort `lost`. Ein zweiter bestätigender Durchlauf muss destruktivem Reaping vorausgehen. Supersets Zwei-Pass-Reaper und `null`-gegen-`[]`-Semantik sind die direkten Vorbilder (`packages/host-service/src/terminal/reaper/reaper.ts:168-225`; `packages/host-service/src/daemon/DaemonSupervisor.ts:470-509`).

### P0 — Idempotenter CLI-Launch mit Soll-ID

Vor dem Spawn wird der Launch-Intent persistiert. Create prüft, ob dieselbe Terminal-ID bereits im Broker lebt, und adoptiert sie. Nur ohne lebende Ressource wird gestartet. Das Initialkommando darf nach Adoption nie erneut in die PTY geschrieben werden, analog zu `packages/host-service/src/terminal/terminal.ts:1058-1106,1179-1181`. Hook und JSONL müssen anschließend die erwartete Claude-ID bestätigen.

### P1 — Langlebiger PTY-Broker

Ein separater lokaler Prozess besitzt PTY-Master und Prozessbaum. Die SwiftUI-App besitzt nur Client-Verbindungen und persistente IDs. Der Broker benötigt:

- ein versioniertes Unix-Socket-Protokoll und restriktive Dateirechte,
- `open`, `list`, `subscribe`, `input`, `resize` und `close` nach Terminal-ID,
- binäre Ausgabe, kleinen Ringpuffer und Replay-vor-live,
- Backpressure und Schutz vor langsamen Clients,
- getrennte PID- und Socket-Healthchecks ohne vorschnelles Töten,
- pro Account oder Profil einen Namespace beziehungsweise gleichwertige Zugriffskontrolle.

### P1 — Vier getrennte Statusautomaten

Prozessstatus, Claude-Turnstatus, Conversation-Recovery und UI-Attention dürfen einander nicht überschreiben. Hooks sind Turnquelle, Broker ist Prozessquelle, JSONL und Registry sind Conversationquelle, `seenAt` ist Benutzerquelle. Stale `working`-Zustände werden nach Neustart nicht als Wahrheit rehydriert.

### P1 — Worktree- und Account-Gates

`input`, `resize`, `attach`, `resume`, `fork`, `kill` und JSONL-Lookup müssen die Tupelbindung aus Account, Workspace und Terminal prüfen. Pfade werden kanonisiert; ein bereits vorhandener Branch wird gegen den erwarteten OID geprüft. Eine identische Claude-Session-ID in einem anderen Profil darf nie als Treffer gelten.

### P2 — Broker-Handoff und Surface-Parking

FD-Handoff ermöglicht Broker-Upgrades ohne Prozessverlust. Geparkte SwiftTerm-Surfaces könnten kurzfristig Scrollback und Terminalmodi über View-Wechsel behalten. Beides ist wertvoll, aber nachrangig gegenüber sicherem Conversation-Resume: Ein überlebender PTY-Prozess im falschen Claude-Zweig wäre kein Erfolg.

## Nicht auffindbar oder nicht belegbar

- Keine terminalseitige Verwendung von Claude `--session-id`, `--resume`, `--fork-session` oder `--continue`.
- Kein explizites Parent-/Child-Modell für Claude-Forks im Terminalpfad.
- Kein belegter Claude-JSONL-Reader oder JSONL-basierter Sessionindex im Terminalpfad.
- Keine belegte Isolation mehrerer Claude-Code-Accounts; nachgewiesen ist nur Superset-Organisationsisolation.
- Keine Garantie, dass der Respawn unter derselben `terminalId` nach einem Maschinenneustart dieselbe Claude-Conversation wiederherstellt; der Code stellt lediglich eine Shell-/PTY-Surface wieder her.
- Supersets ACP-Chat-Persistenz ist vorhanden, wurde wegen WhisperM8s echtem-CLI-Constraint aber nicht als Lösung gewertet.

## Schlussfolgerung

Superset ist eine starke Terminalreferenz und nur eine begrenzte Claude-Sessionreferenz. WhisperM8 sollte Supersets `terminalId`-, Broker-, Adoption- und Reconnect-Modell übernehmen, aber dessen beobachtete `agentSessionId` nicht mit kontrollierter CLI-Identität verwechseln.

Die robuste Zielarchitektur verbindet Supersets langlebige PTY-Ressource mit einem eigenen account- und worktree-gebundenen Claude-Identitätsledger. Erst die Kombination aus geplantem CLI-Flag-Übergang, Hook-Bestätigung und read-only JSONL-Reconciliation verhindert nach Restart, Fork oder Resume zuverlässig den Wechsel in den falschen Zweig.
