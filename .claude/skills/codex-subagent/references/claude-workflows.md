# Codex-Subagents in Claude Dynamic Workflows (`/workflows`)

Empirisch validiert am 2026-07-08: ein Test-Workflow mit 10 Agenten (8 Codex-Jobs:
Smoke, 3er-Fan-out, Resume, 2 Schreib-Jobs, 2 Fehlerpfade) lief in 75 s fehlerfrei
durch. Kontext-Erhalt über `send`, Exit-Code-Vertrag, Schema-Relay und
Parent-Zuordnung funktionieren aus Workflows heraus. Die damals gefundene
Commit-Blockade der Codex-Sandbox ist behoben (siehe „Bekannte Grenzen").

## Grundprinzip

Dynamic Workflows sind JavaScript-Skripte, die der Claude-Code-Harness **lokal**
ausführt (nicht in Claude Code on the Web — dort existiert `whisperm8` nicht).
Das Skript selbst hat KEINEN Filesystem-/Prozess-Zugriff — es kann `whisperm8`
nicht direkt aufrufen. Der Weg führt immer über einen Claude-Subagenten als
dünnen Wrapper:

```
Workflow-Skript (JS)
  └─ agent(wrapperPrompt, {model:'sonnet', effort:'low', schema:RESULT})
       └─ Bash: whisperm8 agent run --wait --json … ; echo "EXIT:$?"
            └─ codex exec (ein Turn)
       ←─ stdout-JSON als validiertes StructuredOutput
  ←─ Report-Objekt im Skript verfügbar
```

## Der bequeme Weg: `agentType: 'codex-runner'`

Liegt im Projekt ein `.claude/agents/codex-runner.md` (in WhisperM8 selbst
vorhanden), ist der Wrapper-Kontrakt dort fest verdrahtet — Sonnet, nur Bash,
mechanisches Relay. Dann genügt im Workflow:

```js
agent(`Führe genau diesen Befehl aus:\n\n${cmd}\n\n${relayHinweis}`,
      { agentType: 'codex-runner', schema: RESULT })
```

Kein Boilerplate, kein `model`/`effort` setzen (kommt aus der Agent-Definition).
Ein benannter Beispiel-Workflow liegt in `.claude/workflows/codex-verify.js`
(Finder × adversarische Refuter). Ohne diese Datei gilt der Kontrakt unten.

## Der Wrapper-Kontrakt (manuell)

Wrapper sind mechanische Arbeit — **immer ein günstiges Modell**
(`model: 'sonnet'` oder `'haiku'`, `effort: 'low'`), nie das teure
Hauptmodell. Bewährte Prompt-Vorlage:

```text
Du bist ein mechanischer CLI-Wrapper. Führe via Bash exakt diesen Befehl aus
(nichts anderes, kein Retry, kein rm, Bash-timeout-Parameter 300000):

<befehl> ; echo "EXIT:$?"

Der Befehl blockiert bis zu mehreren Minuten — warte auf das Ende. Gib danach
als StructuredOutput exakt die Werte aus dem stdout-JSON zurück: exitCode
(Zahl aus der EXIT-Zeile), shortId, state, turns, reportStatus (= report.status,
sonst leerer String), summary (= report.summary, sonst Anfang von
rawLastMessage), seconds (= metrics.lastTurnSeconds), notes (Auffälligkeiten:
Permission-Nachfragen, stderr-Meldungen, fehlender Report; sonst "ok").
Erfinde nichts, gib exakt wieder, was das CLI ausgegeben hat.
```

Passendes `schema` für `agent()`:

```json
{
  "type": "object", "additionalProperties": false,
  "properties": {
    "exitCode": {"type": "integer"},
    "shortId": {"type": "string"},
    "state": {"type": "string"},
    "turns": {"type": "integer"},
    "reportStatus": {"type": "string"},
    "summary": {"type": "string"},
    "seconds": {"type": "number"},
    "notes": {"type": "string"}
  },
  "required": ["exitCode", "shortId", "state", "notes"]
}
```

Exit-Code-Mapping gehört ins **Skript**, nicht in den Wrapper:
`0` weiterverarbeiten, `2` = Job/Report failed (Folge-`send` mit Korrektur oder
Item droppen), `3` = Zustandskonflikt (nicht retryen — meist `takenOver`: der
User hat übernommen, Step überspringen), `4` = Umgebung (abbrechen, loggen).

## Regeln für Workflow-Autoren

1. **Immer `run --wait --json`.** Kein Detach-plus-Polling — der Wrapper wartet,
   das Harness ist geduldig. Gemessene Turn-Zeiten bei kleinen Aufträgen: 5–30 s.
2. **`status <id> --json` statt `list --json`.** `list` liefert ALLE Jobs mit
   vollen Intents (bei ~160 Jobs ≈ 385 KB) — sprengt jeden Kontext.
3. **`shortId` durch die Pipeline reichen.** Spätere Phasen steuern denselben
   Job per `agent send <id> --wait --json` nach — der Codex-Kontext bleibt
   erhalten (empirisch bestätigt, auch über Workflow-Phasen hinweg).
4. **Worktree ist Werkzeug, kein Muss.** Codex-Jobs sind normale Subagents;
   `--worktree` nur, wenn parallel zum eigenen Editieren im selben Checkout
   geschrieben wird oder Varianten isoliert verglichen werden sollen.
5. **Parallelität selbst steuern.** Das CLI hat keine Kapazitätsschicht.
   Read-only-Jobs vertragen breiten Fan-out; Playwright-QA-Jobs max. 3–5
   gleichzeitig (eine Chrome-Instanz pro Job) — im Skript batchen.
6. **Browser-QA nur mit Preflight-Gate:** Phase 1 = ein Probe-Job, im Skript
   auf PASS prüfen (`if (!preflight.pass) return`), erst dann Fan-out.
7. **Codex-Tokens zählen nicht ins Workflow-Budget** (`budget.spent()` sieht
   nur Claude-Tokens). Kostensteuerung für Codex = Anzahl Jobs im Skript.
8. **Permission-Allowlist:** `Bash(whisperm8 agent *)` in die Projekt-Settings,
   sonst können Wrapper in restriktiven Sessions an Permission-Prompts hängen.
   In WhisperM8 stehen `run`/`send`/`list`/`status`/`logs` in `.claude/settings.json`
   — `rm` und `stop` bewusst nicht: löschen und töten bleibt Handarbeit.
9. **Urteile nie mit `--effort low` einholen.** Gemessen am 2026-07-08: Codex
   erfand auf dieser Stufe Guards und Fehlertypen, die es im geprüften Code
   nicht gibt, und „widerlegte" damit zwei echte Defekte. Für Refuter/Reviewer
   `--effort high`; `low` taugt nur zum Smoke-Test der Mechanik. Oberhalb von
   `high` existieren seit codex 0.144.0 `xhigh`, `max` und `ultra`
   (modellabhängig — gpt-5.6-sol/terra bis `ultra`, gpt-5.6-luna bis `max`);
   für die härtesten Verifikationen `--model gpt-5.6-sol --effort xhigh`
   aufwärts erwägen. Verfügbare Level pro Modell: `~/.codex/models_cache.json`.

## Bewährte Muster

- **Cross-Model-Verifier-Panel** (stärkster Fit): Claude-Finder finden,
  read-only-Codex-Jobs verifizieren/widerlegen — echte Modell-Diversität statt
  N identischer Prüfer.
- **Fan-out-Implementierung:** `pipeline()` über eine Task-Liste, pro Item ein
  Codex-Job (workspace-write), Synthese-Step reviewt die Ergebnisse.
- **Nachsteuer-Kette:** Phase N wertet `openQuestions` aus, Phase N+1 schickt
  gezielte `send`-Folge-Turns an dieselben Jobs.

Minimalbeispiel (Verifier-Panel):

```js
phase('Verify')
const verdicts = await parallel(findings.map(f => () =>
  agent(wrapperPrompt(
    'whisperm8 agent run --wait --json --sandbox read-only --effort low --cd ' + REPO +
    ' "Widerlege oder bestätige: ' + f.claim + '. Nur Analyse, Urteil ins summary."'),
    { model: 'sonnet', effort: 'low', schema: RESULT, phase: 'Verify' })))
```

## Bekannte Grenzen (Stand 2026-07-08, codex 0.142.5)

- **Commits: behoben (Fix vom 2026-07-08).** Codex' Sandbox behandelt `.git`
  jeder writable root als read-only; das CLI ermittelt das gemeinsame
  Git-Verzeichnis (`git rev-parse --git-common-dir`) und schaltet es bei
  workspace-write automatisch frei (`sandbox_workspace_write.writable_roots`,
  auch für Resume-Turns, Repo-Unterverzeichnisse und Worktrees). Tritt
  `index.lock: Operation not permitted` doch auf, läuft ein Binary von vor dem
  Fix — App neu bauen/starten. Der Override ersetzt ein etwaiges eigenes
  `writable_roots` aus der `config.toml`; eigene Roots per `--config`
  mitgeben. Report-`commits` weiterhin per git verifizieren — read-only-Jobs
  haben nachweislich schon existierende SHAs als „eigene" Commits gemeldet.
- **Codex-Fähigkeiten freischalten:** `--config key=value` (wiederholbar)
  reicht beliebige Codex-Configs durch (z.B. weitere MCP-Server oder
  `tools.web_search=true`) und gilt für alle Turns des Jobs — die Overrides
  gewinnen gegen eingebaute Werte. Werte mit führendem `-` lehnt das CLI ab.
- **PID-Reuse** (dokumentierte Limitation): stirbt ein Supervisor und vergibt
  macOS seine PID neu, kann ein toter Job als aktiv gelten. Selten; `agent
  status` und ein Blick in die App klären es.
- **`rg` fehlt im Codex-PATH** — Jobs weichen selbstständig auf grep/awk aus
  (nur Noise in openQuestions, kein Fehler).
- **Wrapper-Overhead:** ~35 k Sonnet-Tokens pro Wrapper mit Inline-Kontrakt,
  ~15 k mit `agentType: 'codex-runner'` (Kontrakt steckt im Agent, nicht im Prompt).
  Bei großen Fan-outs einkalkulieren; der Wrapper belegt außerdem einen
  Workflow-Concurrency-Slot für die gesamte Turn-Dauer.
