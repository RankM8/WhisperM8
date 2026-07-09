---
status: aktiv
updated: 2026-07-09
---

# Sub-Agents in Claude Dynamic Workflows

Claude Dynamic Workflows können Codex-Subagents benutzen, obwohl die
Workflow-Skripte selbst keine beliebigen Shell-Befehle ausführen. Das Muster
im Repo ist ein Wrapper: Ein Claude-Subagent vom Typ `codex-runner` erhält
genau einen fertigen `whisperm8 agent …`-Befehl, führt ihn per Bash aus,
wartet auf das Ergebnis und relayed das JSON zurück an das Workflow-Skript.

## Wrapper-Muster

`.claude/agents/codex-runner.md` beschreibt einen mechanischen Agenten mit
`tools: Bash`. Seine Aufgabe ist nicht Analyse, sondern Ausführung: Er nimmt
einen einzigen `whisperm8 agent`-Befehl, hängt `; echo "EXIT:$?"` an, nutzt
einen langen Bash-Timeout und gibt das stdout-JSON unverfälscht weiter.

Das Workflow-Skript wertet dieses JSON aus. Es interpretiert Exit-Codes,
Short-ID, State, Report und Metriken, entscheidet über Folge-Jobs und baut
gegebenenfalls weitere `agent run`- oder `agent send`-Aufrufe. Damit bleibt
die Shell-Fähigkeit im Claude-Agent mit Bash-Tool, während die Workflow-Logik
strukturierte Daten statt Terminaltext verarbeitet.

Falls der Agent-Typ noch nicht registriert ist, nutzt
`.claude/workflows/codex-verify.js` denselben Vertrag inline im Prompt und
startet einen Sonnet-Agenten mit Bash-Fähigkeit. Der eigentliche Codex-Job
läuft trotzdem über `whisperm8 agent run --wait --json`.

## Exit-Code-Vertrag

| Code | Bedeutung im Workflow |
|------|-----------------------|
| `0` | Job ist verwendbar abgeschlossen; Report `success` oder `partial`. |
| `1` | Usage-Fehler im erzeugten CLI-Aufruf; Workflow-Builder hat falsch parametrisiert. |
| `2` | Job ist fehlgeschlagen oder der Report meldet `failure`; Workflow kann das als negatives Ergebnis behandeln. |
| `3` | Zustandskonflikt; typischer Fall ist ein aktiver oder bereits übernommener Job. |
| `4` | Umgebungsproblem; etwa fehlendes Codex-Binary, unbekannte Job-ID oder nicht entfernbarer Worktree. |

Der `codex-runner` interpretiert diese Codes nicht fachlich. Er meldet sie
zusammen mit dem JSON zurück; die Workflow-Datei entscheidet, ob daraus ein
Retry, ein Abbruch oder ein bewusstes negatives Urteil folgt.

## `shortId` weiterreichen

Detached Jobs geben sofort eine `shortId` zurück. Synchrone Workflow-Schritte
verwenden im Repo meist `--wait --json`, damit der Wrapper erst nach dem Turn
zurückkehrt und direkt ein vollständiges Statusobjekt auswertbar ist.

Die Short-ID bleibt trotzdem wichtig: Sie ist der stabile Handle für
Nachsteuerung per `whisperm8 agent send <shortId> --wait --json "<prompt>"`,
für `status`, `logs`, `stop` und für manuelles Debugging in der App. Ein
Workflow, der einen Job später fortsetzen will, muss die `shortId` aus dem
ersten JSON-Ergebnis explizit im eigenen Zwischenzustand weiterreichen.

`send` ist nur auf ruhenden Jobs erlaubt. Der CLI-Claim reserviert den Job
unter `.claim.lock`; parallele Nachsteuerungen auf dieselbe Short-ID enden
deshalb mit Exit `3` statt verschränkte Codex-Historien zu erzeugen.

## Parallelität

Parallelität entsteht auf Workflow-Ebene, nicht innerhalb eines Jobs. Ein Job
führt immer genau einen Supervisor-Turn aus. Mehrere unabhängige Jobs können
parallel per mehreren `agent(...)`-Aufrufen gestartet werden, solange sie nicht
dieselbe Short-ID nachsteuern.

Für reine Analyse nutzt das Beispiel `--sandbox read-only`, damit parallele
Finder und Refuter keine Dateien verändern. Schreibende Jobs im selben
Working Tree bleiben ein bewusstes Konfliktrisiko; der CLI bietet dafür
`--worktree`, das einen separaten Worktree im Job-Verzeichnis anlegt. Wenn ein
Workflow mehrere schreibende Codex-Jobs parallel startet, muss er die
Arbeitsbereiche trennen oder Konflikte fachlich einplanen.

## Reale Beispiele im Repo

- `.claude/agents/codex-runner.md` ist der registrierbare Claude-Subagent für das Bash-Relay eines einzelnen `whisperm8 agent`-Befehls.
- `.claude/workflows/codex-verify.js` ist ein Dynamic Workflow, der mehrere Codex-Finder parallel startet und jedes Finding durch zwei adversarische Codex-Refuter prüfen lässt.

`codex-verify.js` baut Befehle der Form
`whisperm8 agent run --wait --json --sandbox read-only --effort <level> ...`.
Die Finder schreiben Findings in ein vorgegebenes Report-Format. Für jedes
Finding erzeugt der Workflow zwei weitere Wrapper-Jobs mit unterschiedlichen
Prüflinsen. Am Ende gruppiert das Skript bestätigte, strittige und widerlegte
Findings anhand der strukturierten Wrapper-Ergebnisse.

## Grenzen

Der Wrapper ist absichtlich mechanisch. Er startet keinen zweiten Befehl,
führt keine Cleanup-Aktionen aus, stoppt keine hängenden Jobs und repariert
keine Reports. Timeout, fehlendes JSON oder Exit `3` werden als Ergebnis an
das Workflow-Skript gemeldet. Dadurch bleibt der Workflow deterministisch:
Die Kontrolllogik liegt im Skript, die Shell-Ausführung im `codex-runner`, und
der eigentliche Modelllauf im WhisperM8-Subagent-Job.
