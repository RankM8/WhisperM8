---
status: aktiv
updated: 2026-07-20
---

# GPT-Subagents in Claude Dynamic Workflows

Claude Dynamic Workflows starten GPT-Subagents standardmäßig direkt über den
nativen Agent-Typ `gpt` des WhisperM8-GPT-Backends:

```js
agent(prompt, {
  agentType: 'gpt',
  schema: RESULT,
  effort: 'high',
})
```

Der Mix-Router leitet diese Requests an das konfigurierte GPT-Modell weiter.
Das Workflow-Skript erhält das schema-validierte Ergebnis unmittelbar; ein
Shell-Prozess, `whisperm8 agent`, `codex-runner` und ein JSON-Relay sind dafür
nicht erforderlich.

## `codex-verify`

`.claude/workflows/codex-verify.js` ist der ausgelieferte native
Review-Workflow. Er startet mehrere GPT-Finder parallel und prüft jedes Finding
anschließend mit zwei adversarischen GPT-Refutern:

1. Finder untersuchen den Scope aus unterschiedlichen Perspektiven.
2. Pro Finding prüfen die Linsen `reality` und `repro` Faktenlage und
   Reproduzierbarkeit.
3. Nur zwei bestätigende Refuter ergeben `confirmed`.
4. Gemischte Urteile, `unverified` oder ausgefallene Refuter ergeben
   `plausible`.
5. Nur zwei erfolgreiche Widerlegungen ergeben `dropped`.

Der Workflow akzeptiert optional `scope`, `effort`, `repo` und `dimensions`.
Alte Parameter wie `runner` oder `agentType` werden ausdrücklich abgelehnt,
damit kein stiller Wechsel auf einen anderen Ausführungsweg möglich ist.

## Fehlerverhalten

Ein fehlgeschlagener Agent darf nicht als fachliches Urteil interpretiert
werden:

- Schlagen alle Finder fehl, bricht der Workflow mit einem klaren Hinweis auf
  GPT-Backend und Agent-Registry ab.
- Teilweise Finder-Ausfälle setzen `complete` auf `false` und werden unter
  `failedFinders` zurückgegeben.
- Fehlende Refuter-Urteile widerlegen ein Finding nicht. Das Finding bleibt
  `plausible`, der Lauf wird unvollständig und die Ausfälle erscheinen unter
  `failedRefuters`.
- „Keine überlebenden Findings“ wird nur bei einem technisch vollständigen Lauf
  gemeldet.

Eine ältere Chat-Session kann eine vor der GPT-Integration geladene
Agent-Registry oder einen eingefrorenen Workflow-Snapshot besitzen. In diesem
Fall einen neuen Chat und einen neuen Workflow-Lauf starten, keinen alten Lauf
fortsetzen.

## Explizite Codex-CLI-Spezialfälle

Das headless WhisperM8-/Codex-CLI bleibt für Eigenschaften vorgesehen, die der
native Agent nicht bietet, beispielsweise detachte und in der App sichtbare
Jobs, Browser-QA mit Playwright-Storage-State oder `image_gen`. Es ist kein
Fallback von `codex-verify`.

Auswahlregeln, Befehle, Sicherheitsvorgaben und das Wrapper-Muster für solche
Spezialfälle sind zentral im Skill `.claude/skills/codex-subagent/SKILL.md`
dokumentiert. Aufruf:

```text
/codex-subagent --cli <Aufgabe>
```

Die vertiefende Referenz
`.claude/skills/codex-subagent/references/claude-workflows.md` beschreibt nur
diesen expliziten CLI-Spezialpfad. Dadurch bleibt die native Review-Architektur
frei von CLI-Boilerplate, während das Codex-spezifische Betriebswissen an einer
Stelle gepflegt wird.

## Modellnachweis

Die Selbstauskunft eines Subagents beweist nicht, welches Modell tatsächlich
gelaufen ist. Maßgeblich ist ausschließlich das `model`-Feld im betreffenden
Session-JSONL unter `~/.claude*/projects/<cwd>/`.
