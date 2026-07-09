---
status: aktiv
updated: 2026-07-09
---

# Codex-Exec — Architektur

Die Architektur trennt Prozessausführung, Event-Parsing, Outcome-Mapping und
Codex-Verfügbarkeit. Der Runner bleibt prozessnah, der Executor übersetzt in
einen WhisperM8-Turn, und die Consumer entscheiden selbst, wie sie das Ergebnis
persistieren oder anzeigen.

## Komponenten

- `WhisperM8/Services/AgentChats/CodexExecRunner.swift` ist der Prozess-Runner für einen einzelnen `codex exec`-Turn inklusive Argumentbau, stdin-Prompt, Stream-Drain und Idle-Watchdog.
- `WhisperM8/Services/AgentChats/CodexExecEvent.swift` beschreibt die bekannten Event- und Item-Formen des externen `codex exec --json`-Streams.
- `WhisperM8/Services/AgentChats/CodexExecEventParser.swift` wandelt rohe JSONL-Zeilen in `CodexExecEvent` und wirft bei unbekannten oder kaputten Zeilen nicht.
- `WhisperM8/Services/AgentChats/CodexTurnExecutor.swift` koordiniert Runner und `AgentTurnSink`, persistiert selbst nichts und bildet `CodexTurnResult` auf `CodexTurnOutcome` ab.
- `WhisperM8/Services/AgentChats/CodexReportSchema.swift` definiert den erzwungenen Abschlussreport und das Swift-Modell `AgentReport`.
- `WhisperM8/Services/AgentChats/CodexAgentPreflight.swift` ist die Subagent-Preflight-Prüfung für Codex-Pfad und Version.
- `WhisperM8/Models/CodexReasoningEffort.swift` liefert die auswählbaren Reasoning-Efforts und den Default `medium`.
- `WhisperM8/Models/CodexServiceTier.swift` liefert die Service-Tiers samt Codex-Config-Argumenten für Fast und Standard.
- `WhisperM8/Views/Settings/Models/CodexConnectionModel.swift` kapselt den beobachtbaren Settings-Zustand für Status, Version, Refresh und Warnlogik.

## CodexExecRunner

`CodexExecRunner.buildArguments(for:)` ist pure Logik und separat testbar. Ein
neuer Turn wird als `codex -a never exec --json` gebaut, erhält
`--skip-git-repo-check`, `--output-schema`, `--output-last-message`, Sandbox,
CWD, optional Modell, Reasoning, Netzwerk, Playwright-MCP und generische
Config-Overrides. Der Prompt wird nicht als Argument übergeben, sondern über
stdin; das letzte Argument ist deshalb `-`.

Bei Resume-Turns baut der Runner `exec resume`. Das externe CLI-Verhalten ist
im Code als empirisch verifiziertes Laufzeitdetail dokumentiert: `resume`
akzeptierte in der validierten Codex-CLI keine `--sandbox`- und `--cd`-Flags.
Deshalb setzt WhisperM8 die Sandbox dort per `-c sandbox_mode="..."` und das
Arbeitsverzeichnis über `Process.currentDirectoryURL`.

Für `workspace-write` kann `gitWritableRootPath` gesetzt werden. Der Runner
fügt dann `sandbox_workspace_write.writable_roots=[...]` hinzu. Die gewünschte
Wirkung ist, das gemeinsame Git-Verzeichnis für Commits beschreibbar zu machen;
diese Sandbox-Wirkung ist externes Codex-Laufzeitverhalten. Der Pfad selbst
kommt aus `CodexGitWritableRoot.resolve`, das
`git rev-parse --path-format=absolute --git-common-dir` im effektiven CWD
abfragt und nur absolute Pfade übernimmt; dadurch werden auch
Unterverzeichnisse, Linked Worktrees und bare-Repos korrekt aufgelöst.

Wenn `playwrightStorageStatePath` gesetzt ist, baut der Runner eine isolierte
Playwright-MCP-Konfiguration: `npx`, gepinnte Version
`@playwright/mcp@0.0.77`, Chrome, `--isolated`, Storage-State, erhöhte
Start- und Tool-Timeouts sowie automatische MCP-Tool-Approval für den
headless Lauf. Diese Overrides hängen am einzelnen Codex-Prozess und hängen
nicht von einer vorhandenen User-Config ab; die Semantik der Approval-Option
bleibt externes Codex-/MCP-Laufzeitverhalten.

Die Ausführung nutzt `Process`, `LoginShellEnvironment.shared.processEnvironment()`,
`NO_COLOR=1` und `CLICOLOR=0`. stdout und stderr werden per
`readabilityHandler` fortlaufend gelesen, damit lange Codex-Sessions nicht am
Pipe-Puffer blockieren. stderr wird nur als Tail behalten. stdout wird
zeilenweise gepuffert; Restdaten ohne abschließenden Newline werden beim EOF
noch verarbeitet.

Der Idle-Watchdog ist kein Gesamt-Timeout. Er wird bei beliebiger
stdout-Aktivität neu geplant, auch wenn diese Bytes noch keine parsebare
JSONL-Event-Zeile ergeben. Er terminiert den Prozess erst, wenn für
`idleTimeout` keine stdout-Daten mehr kamen. Nach stdout-EOF, stderr-EOF und
Prozessende wird der Run als fertig markiert, damit ein spät feuernder Timer
keinen erfolgreichen Turn nachträglich als stalled klassifiziert.

`terminate()` sendet SIGTERM an den laufenden Codex-Prozess. Das ist der
definierte Abbruchweg für `agent stop` und den Supervisor-Signal-Handler; wenn
kein Prozess läuft, ist der Aufruf ein No-op.

Der Runner ignoriert einmalig SIGPIPE und schluckt EPIPE beim Schreiben des
stdin-Prompts. So kann ein früh beendeter Codex-Prozess nicht die App oder den
Supervisor-Prozess beenden; der Fehler wird anschließend über Exit-Code,
stderr-Tail oder `turn.failed` sichtbar.

## CodexExecEvent und Parser

`CodexExecEvent` modelliert `thread.started`, `turn.started`, Item-Events,
`turn.completed`, `turn.failed`, `error` und `.unknown`. Die Item-Struktur ist
absichtlich flach und optional, weil Codex heterogene Item-Typen wie
`agent_message`, `command_execution` und `error` liefert.

`CodexExecEventParser` nutzt `JSONSerialization` und optionale Casts. Leere
Zeilen, Nicht-JSON und Nicht-Objekte ergeben `nil`; bekannte Typen werden
gemappt; unbekannte Typen bleiben als `.unknown(type:)` erhalten. Dieses
defensive Verhalten schützt Subagent-Supervisor und UI vor kleinen Änderungen
im externen Codex-Eventformat.

## CodexTurnExecutor

`CodexTurnExecutor.execute` ruft zuerst `sink.turnWillStart`, startet den
Runner, leitet jedes Event an den Sink weiter und ruft bei jedem
`.threadStarted`-Event zusätzlich `sink.threadStarted`. Die Erstmalig-Guards
liegen nicht im Executor: Der Runner hält für sein Result die erste Thread-ID,
und `JobDirectorySink` schreibt nur, wenn im Job-State noch keine ID steht. Der
Executor kennt kein Job-Verzeichnis; Sub-Agents hängen einen `JobDirectorySink`
an, einfache Aufrufer können den `InMemoryTurnSink` verwenden.

`AgentTurnSink`-Callbacks laufen auf einer Hintergrund-Queue. Die Reihenfolge
pro Turn ist garantiert, der konkrete Thread nicht; neue Sink-Implementierungen
müssen daher selbst synchronisieren, wenn sie geteilten Zustand halten.

Das Outcome-Mapping ist pure Logik:

| Prozessresultat | Outcome |
|-----------------|---------|
| `stalled == true` | `failed` mit Idle-Watchdog-Grund. |
| `turn.failed` mit Meldung | `failed` mit `turn.failed: ...`. |
| Exit-Code ungleich `0` | `failed` mit Exit-Code und stderr-Tail. |
| Exit-Code `0` | `done`, Report wird tolerant aus `lastMessage` geparst. |

Bei erfolgreichem Prozessende, aber unparsebarem Report, ist
`done(report: nil, rawLastMessage: ...)` das erwartete Ergebnis. Der Turn war
technisch erfolgreich; nur der Modellvertrag wurde verletzt. Sub-Agents können
den Rohtext deshalb weiterhin anzeigen.

## Report-Schema

`CodexReportSchema.json` ist als String eingebettet und wird vor einem Turn in
eine Datei geschrieben. Das vermeidet Bundle-Ressourcen für die SwiftPM- und
CLI-Pfade. Das Schema erlaubt keine zusätzlichen Properties und verlangt
`status`, `summary`, `filesChanged`, `commits`, `testsRun` und
`openQuestions`; WhisperM8 übergibt es per `--output-schema` an die externe
Codex-CLI, parst das Ergebnis aber weiterhin tolerant.

`AgentReport.parse` entfernt optional umschließende Markdown-Code-Fences und
decodiert dann per `JSONDecoder`. Fehlerhafte JSON-Reports, unbekannte Status
oder Prosatext ergeben `nil`; der Rohtext bleibt beim Outcome erhalten.

## Preflight und Status

`CodexAgentPreflight` löst `codex` über `CodexStatusProbe.resolveCommandPath`
auf. Dadurch wird zuerst ein gebündeltes
`/Applications/Codex.app/Contents/Resources/codex` akzeptiert, danach der
normale `AgentCommandBuilder.commandPath`-Pfad. Danach läuft `codex --version`
in der Login-Shell-Umgebung.

Die Mindestversion ist `0.100.0`; zu alte Versionen werden abgelehnt. Eine
nicht parsebare Version blockiert nicht, sondern liefert ein eigenes
Warn-Outcome. Neuere Major-Versionen laufen weiter, aber mit Warnung, weil das
JSONL-Eventformat externes Codex-Verhalten ist.

`CodexStatusProbe` kann `codex login status` und `codex --version` abfragen.
Die Settings-Seite nutzt über `CodexConnectionModel` beides in einem Snapshot.
Dictation fragt im Hotpath über `CodexStatusCache` nur den Login-/
Installationsstatus ab; Versionen werden dort nicht geprüft. Bekannte
Login-Ausgaben werden zu `signedIn`, `notSignedIn` oder `installed`
verdichtet; `notInstalled` entsteht bereits davor, wenn gar kein
Codex-Binary aufgelöst werden kann. `CodexConnectionModel` speichert den letzten
Snapshot, verhindert veraltete parallele Refreshes und mappt den Status auf
Settings-Töne.

## Reasoning und Service-Tier

`CodexReasoningEffort` enthält `low`, `medium`, `high` und `xhigh`; unbekannte
Rohwerte fallen nur dort auf `medium` zurück, wo `CodexReasoningEffort.resolve`
aufgerufen wird. Sub-Agents reichen den gespeicherten Wert als
`model_reasoning_effort=...` an den Runner weiter. AI-Output nutzt
`OutputMode.resolvedCodexReasoningEffortRaw()` und gibt den resultierenden
Rohwert direkt an `CodexInvocation.arguments` weiter.

`CodexServiceTier` enthält `fast` und `standard`; unbekannte Rohwerte fallen
auf `fast` zurück. `fast` setzt `features.fast_mode=true` und
`service_tier=fast`, `standard` setzt `service_tier=default`. Diese Argumente
werden aktuell im Dictation-Postprocessing über `CodexInvocation` verwendet;
Subagent-Runs bekommen zusätzliche Config-Overrides über `CodexTurnRequest`.

## Consumer-Flows

Sub-Agents schreiben vor einem Turn das Report-Schema in das Job-Verzeichnis,
berechnen das effektive CWD aus Worktree oder Job-CWD, lösen bei
`workspace-write` das gemeinsame Git-Verzeichnis auf und bauen daraus einen
`CodexTurnRequest`. `AgentJobSupervisor` hängt einen `JobDirectorySink` an,
der rohe Events nach `events.jsonl` schreibt und die erste Thread-ID sofort im
State persistiert.

Dictation/AI-Output prüft vor Postprocessing den gecachten Codex-Status. Der
eigentliche Lauf wird in `CodexPostProcessor` mit `CodexInvocation.arguments`
gebaut: read-only Sandbox, optionales Projekt-CWD, optionale Bilder,
`--output-last-message`, optional `--ephemeral` und Prompt über stdin. Dieser
Pfad nutzt keine `CodexExecEvent`-Streams und kein `AgentReport`-Schema,
sondern erwartet den finalen nachbearbeiteten Text.

## Invarianten und Gotchas

- Ein Runner-Turn ist ein Prozess; Wiederaufnahme passiert über eine extern persistierte Thread-ID.
- `resumeThreadID == nil` bedeutet erster Turn; ein gesetzter Wert bedeutet `codex exec resume`.
- Generische `configOverrides` werden nach den eingebauten `-c`-Werten angehängt und können diese übersteuern.
- `read-only` bekommt keinen Git-writable-root-Override.
- Netzwerkzugriff ist ein Opt-in für `workspace-write` über `sandbox_workspace_write.network_access=true`.
- `CodexExecEventParser` wirft nie und ist nicht die Instanz, die Turns fehlschlagen lässt.
- stderr wird begrenzt gespeichert; vollständige stderr-Logs sind kein Vertrag dieser Schicht.
- `CodexConnectionModel.shouldWarnAboutGPT55` warnt bei GPT-5.5-Auswahl und Codex-Versionen mit `0.120.`.
- Externe Tool-Ausgaben wie `codex login status` und `codex exec --json` bleiben Laufzeitverhalten und werden defensiv behandelt.

## Test-Cluster

- `Tests/WhisperM8Tests/CodexExecRunnerTests.swift` deckt Argumentbau, Resume-Besonderheiten, Playwright-MCP, Git-writable-roots, Config-Override-Reihenfolge, Streaming, stderr-Tail, Launch-Fehler und Idle-Watchdog ab.
- `Tests/WhisperM8Tests/CodexExecEventParserTests.swift` deckt bekannte Eventtypen, unbekannte Events, Fehlerformen und echte Fixture-Reihenfolge ab.
- `Tests/WhisperM8Tests/AgentReportTests.swift` deckt Report-Parsing, Code-Fences und JSON-Schema-Gültigkeit ab.
- `Tests/WhisperM8Tests/CodexAgentPreflightTests.swift` deckt Version-Parsing, fehlendes Binary, zu alte Versionen, neuere Major-Versionen und nicht parsebare Versionen ab.
- `Tests/WhisperM8Tests/CodexStatusProbeTests.swift` deckt Status- und Versionserkennung ohne echtes Codex-Binary ab.
- `Tests/WhisperM8Tests/OutputDashboardTests.swift` und `Tests/WhisperM8Tests/AIOutputModelsTests.swift` decken Dictation/AI-Output-Argumente, Service-Tier, Reasoning-/Service-Overrides und `CodexConnectionModel` ab.
- `Tests/WhisperM8Tests/AgentJobSupervisorTests.swift` und `Tests/WhisperM8Tests/AgentCLICommandTests.swift` decken die Subagent-seitige Verwendung von `CodexTurnRequest`, Report-Schema und CLI-Outcome-Vertrag ab.
