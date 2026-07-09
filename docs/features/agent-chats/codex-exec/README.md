---
status: aktiv
updated: 2026-07-09
---

# Codex-Exec — Integrationsschicht

Codex-Exec ist die WhisperM8-Schicht für nicht-interaktive Codex-Läufe. Sie
fasst die wiederkehrenden Entscheidungen rund um `codex exec` zusammen:
Binary-Auflösung, Sandbox-Argumente, JSONL-Streaming, Resume-Kontext,
Report-Vertrag und Status-Proben. Die Schicht ist bewusst näher an der
Prozessintegration als an der UI; Persistenz, Sidebar und Job-Lifecycle liegen
bei den jeweiligen Consumern.

## Consumer

| Consumer | Nutzung |
|----------|---------|
| [`../sub-agents/`](../sub-agents/) | Startet headless Subagent-Turns über `CodexTurnExecutor` und `CodexExecRunner`, persistiert Events, Thread-ID, Report und Status im Job-Verzeichnis. |
| [`../../dictation/ai-output/`](../../dictation/ai-output/) | Nutzt dieselben Codex-Status-, Modell-, Reasoning- und Service-Tier-Modelle für Transkript-Postprocessing; der aktuelle Postprocessing-Pfad baut seinen eigenen read-only `codex exec`-Aufruf über `CodexInvocation`. |

Diese Abgrenzung ist wichtig: Sub-Agents verwenden die JSON-Streaming-Schicht
direkt. Dictation/AI-Output teilt die Codex-Verfügbarkeit, Einstellungen und
Argumentkonventionen, aber in den gelesenen Quellen nicht `CodexExecRunner`.

## Was die Schicht kann

**Headless `exec --json` Streaming:** `CodexExecRunner` startet genau einen
`codex -a never exec --json`-Prozess, schreibt den Prompt über stdin und liest
stdout fortlaufend als JSONL. Dadurch muss WhisperM8 nicht auf das
Prozessende warten, bevor Events verarbeitet werden.

**Resume mit Kontext:** Der erste `thread.started`-Event liefert die
Codex-Thread-ID. Sub-Agents persistieren sie sofort im Job-State und geben sie
bei Folge-Turns als `codex exec resume <thread-id>` weiter.

**Sandbox-Modi:** Der Runner kennt `read-only` und `workspace-write`. Neue
Turns bekommen Sandbox und CWD als normale CLI-Flags; Resume-Turns setzen die
Sandbox als Config-Override und verwenden das Prozess-CWD, weil das externe
CLI-Verhalten von `codex exec resume` laut Codekommentar empirisch ohne
`--sandbox`- und `--cd`-Flag-Unterstützung validiert wurde.

**Report-Schema:** `CodexReportSchema` übergibt der externen Codex-CLI per
`--output-schema` den gewünschten letzten Agent-Output als JSON-Report mit
`status`, `summary`, `filesChanged`, `commits`, `testsRun` und
`openQuestions`. Ob Codex das Schema zur Laufzeit strikt durchsetzt, ist
externes Verhalten; WhisperM8 parst deshalb tolerant. Nicht parsebarer Output
macht den Turn nicht automatisch technisch fehlgeschlagen, sondern lässt den
Report als `nil` und den Rohtext verfügbar.

**Preflight und Status-Probe:** `CodexAgentPreflight` prüft vor Subagent-Spawns
das Codex-Binary und die Version. `CodexStatusProbe` und
`CodexConnectionModel` liefern der Settings-Seite Installation, Login-Status
und Version; Dictation nutzt im Hotpath den gecachten Login-/Installationsstatus
und löst später für den Lauf nur den Codex-Pfad auf.

**Isolierter Browser-MCP:** Wenn ein Subagent-Turn einen
`playwrightStorageStatePath` erhält, überschreibt der Runner die
Playwright-MCP-Konfiguration für genau diesen Lauf mit gepinnter MCP-Version,
isoliertem Chrome und Storage-State-Datei.

## Was sie bewusst nicht macht

Codex-Exec implementiert keine interaktive Approval-Schicht. Der Runner
startet Codex mit `-a never`; Sicherheit entsteht aus Sandbox-Modus,
writable-roots, Prozess-CWD und den expliziten Config-Overrides. Für den
Playwright-MCP setzt WhisperM8 im isolierten Lauf
`default_tools_approval_mode="approve"`; die tatsächliche Approval-Semantik ist
externes Codex-/MCP-Laufzeitverhalten.

Die Schicht besitzt auch keine eigene Job-Wahrheit. Sie kennt weder
`state.json` noch Sidebar-Sessions noch Dictation-Archive. Diese Zustände
gehören zu Sub-Agents beziehungsweise AI-Output.

## Laufzeitvertrag

Ein Codex-Exec-Turn ist ein Prozess und ein Prompt. Das Ergebnis besteht aus
Exit-Code, optionaler Thread-ID, optionalem letzten Modell-Output,
stderr-Tail, optionalem `turn.failed`-Text und einem Stall-Flag. Der
Executor mappt daraus `done` oder `failed`; Sub-Agents übersetzen dieses
Outcome anschließend in Job-Zustände und CLI-Exit-Codes.

Externe CLI-Details sind als Laufzeitverhalten markiert, weil sie nicht von
WhisperM8 kontrolliert werden: Dazu gehören das konkrete JSONL-Eventformat,
die `codex exec resume`-Flag-Unterstützung, `codex login status`-Ausgaben und
die Sandbox-Behandlung von Git-Verzeichnissen.

## Schlüsseldateien

- `WhisperM8/Services/AgentChats/CodexExecRunner.swift` baut die `codex exec`-Argumente, startet den Prozess, streamt stdout, sammelt stderr-Tail, setzt den Idle-Watchdog und löst Git-writable-roots auf.
- `WhisperM8/Services/AgentChats/CodexExecEvent.swift` definiert die typisierte Sicht auf bekannte `codex exec --json`-Events und Token-Nutzung.
- `WhisperM8/Services/AgentChats/CodexExecEventParser.swift` parst JSONL-Zeilen defensiv und erhält unbekannte Event-Typen als `.unknown`.
- `WhisperM8/Services/AgentChats/CodexTurnExecutor.swift` verbindet Runner und Sink, misst Turn-Dauer und mappt Prozessresultate auf `CodexTurnOutcome`.
- `WhisperM8/Services/AgentChats/CodexReportSchema.swift` enthält das eingebettete JSON-Schema und das tolerante Parsing von `AgentReport`.
- `WhisperM8/Services/AgentChats/CodexAgentPreflight.swift` prüft Binary-Auflösung und Mindestversion für Subagent-Spawns.
- `WhisperM8/Models/CodexReasoningEffort.swift` modelliert die Reasoning-Stufen `low`, `medium`, `high` und `xhigh`.
- `WhisperM8/Models/CodexServiceTier.swift` modelliert `fast` und `standard` und liefert die dazugehörigen Codex-Config-Argumente.
- `WhisperM8/Views/Settings/Models/CodexConnectionModel.swift` hält den Settings-Snapshot aus Codex-Status und Version.

## Keywords

Codex-Exec, Codex Integrationsschicht, headless Codex, codex exec,
codex exec --json, Codex JSONL, Codex Streaming, Codex Resume, Thread-ID,
Subagent-Turn, Folge-Turn, Report-Schema, Agent-Report, strukturierter Report,
Sandbox, read-only Sandbox, workspace-write Sandbox, writable roots,
Git-Verzeichnis beschreibbar, Playwright MCP, Storage State, Status-Probe,
Preflight, Codex Login Status, AI Output, Diktat Nachbearbeitung,
Transkript-Postprocessing, `CodexExecRunner`, `CodexTurnRequest`,
`CodexTurnResult`, `CodexExecEvent`, `CodexExecEventParser`,
`CodexTurnExecutor`, `CodexTurnOutcome`, `AgentTurnSink`,
`CodexReportSchema`, `AgentReport`, `CodexAgentPreflight`,
`CodexGitWritableRoot`, `CodexStatusProbe`, `CodexConnectionModel`,
`CodexReasoningEffort`, `CodexServiceTier`, `CodexInvocation`,
`CodexPostProcessor`, `playwrightStorageStatePath`, `resumeThreadID`,
`gitWritableRootPath`, `configOverrides`, `idleTimeout`,
`--output-schema`, `--output-last-message`, `--skip-git-repo-check`,
`sandbox_workspace_write.writable_roots`.
