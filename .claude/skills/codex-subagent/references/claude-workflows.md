# Explizite Codex-CLI-Subagents in Claude Dynamic Workflows (`/workflows`)

> **Spezialpfad, nicht Standard:** Normale GPT-Schritte laufen nativ über
> `agent(prompt, {agentType: "gpt", schema})`. Der ausgelieferte Workflow
> `.claude/workflows/codex-verify.js` ist native-only und verwendet weder
> `whisperm8 agent` noch `codex-runner`. Diese Referenz gilt ausschließlich für
> Workflows, die ausdrücklich Codex-CLI-Eigenschaften wie detachte Jobs,
> Browser-QA oder `image_gen` benötigen.

Empirisch validiert am 2026-07-08: ein Test-Workflow mit 10 Agenten (8 Codex-Jobs:
Smoke, 3er-Fan-out, Resume, 2 Schreib-Jobs, 2 Fehlerpfade) lief in 75 s fehlerfrei
durch. Kontext-Erhalt über `send`, Exit-Code-Vertrag, Schema-Relay und
Parent-Zuordnung funktionieren aus Workflows heraus. Die damals gefundene
Commit-Blockade der Codex-Sandbox ist behoben (siehe „Bekannte Grenzen").

## Grundprinzip

Dynamic Workflows sind JavaScript-Skripte, die der Claude-Code-Harness **lokal**
ausführt (nicht in Claude Code on the Web — dort existiert `whisperm8` nicht).
Das Skript selbst hat KEINEN Filesystem-/Prozess-Zugriff — es kann `whisperm8`
nicht direkt aufrufen. Der Weg führt immer über den explizit als GPT-5.6 Sol
deklarierten Custom-Agent `codex-runner` als dünnen Wrapper:

```
Workflow-Skript (JS)
  └─ agent(wrapperPrompt, {agentType:'codex-runner', schema:RESULT})
       └─ codex-runner [gpt-5.6-sol, nur Bash]
            └─ Bash: whisperm8 agent run --wait --json … ; echo "EXIT:$?"
                 └─ codex exec (ein Turn)
       ←─ stdout-JSON als validiertes StructuredOutput
  ←─ Report-Objekt im Skript verfügbar
```

## Der bequeme Weg: `agentType: 'codex-runner'`

Liegt im Projekt ein `.claude/agents/codex-runner.md` (in WhisperM8 selbst
vorhanden), ist der Wrapper-Kontrakt dort fest verdrahtet — explizit
`model: gpt-5.6-sol`, nur Bash, mechanisches Relay. Dann genügt im Workflow:

```js
agent(`Führe genau diesen Befehl aus:\n\n${cmd}\n\n${relayHinweis}`,
      { agentType: 'codex-runner', schema: RESULT })
```

Kein Boilerplate, kein `model`/`effort` setzen (kommt aus der Agent-Definition).
Dieses Muster gehört ausschließlich in explizite CLI-Spezialworkflows;
`codex-verify.js` verwendet bewusst den nativen `gpt`-Agent-Typ und ist kein
Beispiel für diesen Wrapper.

## Der Wrapper-Kontrakt (manuell)

Wrapper bleiben mechanische Arbeit, werden aber gemäß Modellrichtlinie ebenfalls
explizit mit **GPT-5.6 Sol** ausgeführt. Haiku, Sonnet und implizite Vererbung
sind verboten. Bewährte Prompt-Vorlage:

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
   **Timeout-fest seit dem `agent wait`-Umbau:** `--wait` ist nur Zuschauer,
   der Job läuft detacht. Killt das Bash-Timeout des Wrappers (hart max.
   10 Min) den Waiter, arbeitet der Turn weiter — die Short-ID steht als
   stderr-Breadcrumb im Teil-Output, `whisperm8 agent wait <id> --json`
   hängt sich wieder an (der `codex-runner` macht das automatisch, max.
   5 Wiederanhänge). Vorher starben Turns > 10 Min GARANTIERT mitten in
   der Arbeit („supervisor died") — forensisch belegt am 2026-07-10.
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
7. **Codex-Tokens zählen nicht ins Workflow-Budget**, der native GPT-Wrapper
   dagegen schon. Kostensteuerung = Anzahl CLI-Jobs plus Wrapper-Overhead im
   Skript begrenzen.
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

## Bewährte CLI-Spezialmuster

- **Browser-QA-Fan-out:** Ein CLI-Preflight mit
  `--playwright-storage-state` prüft Authentifizierung und Testumgebung; nur
  bei PASS startet der Workflow 3–5 isolierte Browser-Jobs. Sicherheitsregeln
  und Prompt-Vorlagen stehen in `playwright-browser-qa.md`.
- **App-sichtbarer Langläufer:** Ein detachter Job übernimmt Arbeit, die einen
  Workflow- oder App-Neustart überleben soll; spätere Phasen holen den Status
  über die `shortId` ab.
- **Nachsteuer-Kette:** Phase N wertet `openQuestions` aus, Phase N+1 schickt
  gezielte `send`-Folge-Turns an denselben Job.
- **Isolierte Implementierung:** Schreibende Codex-Jobs verwenden `--worktree`,
  wenn App-Sichtbarkeit, persistente Folge-Turns oder andere CLI-Eigenschaften
  ausdrücklich benötigt werden. Normale Workflow-Implementierungen bleiben
  nativ.

Minimalbeispiel für einen expliziten Browser-QA-Preflight:

```js
phase('Preflight')
const preflight = await agent(wrapperPrompt(
  'whisperm8 agent run --wait --json --sandbox read-only --model gpt-5.6-sol --effort high ' +
  '--playwright-storage-state ' + STATE + ' --cd ' + REPO +
  ' "Prüfe ausschließlich, ob die geschützte Route authentifiziert erreichbar ist. ' +
  'Bei Login-Redirect NICHT PRUEFBAR melden; nicht einloggen und keine Daten ändern."'),
  { agentType: 'codex-runner', schema: RESULT, phase: 'Preflight' })
```

## Bekannte Grenzen (fortgeschrieben bis 2026-07-20, Codex 0.144.0)

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
- **Wrapper-Overhead:** `codex-runner` läuft explizit auf GPT-5.6 Sol und
  belegt für die gesamte Turn-Dauer einen Workflow-Concurrency-Slot. Bei großen
  Fan-outs Agent-Zahl und GPT-Budget entsprechend begrenzen.
