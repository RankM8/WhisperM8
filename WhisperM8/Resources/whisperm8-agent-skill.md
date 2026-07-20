---
name: codex-subagent
description: GPT-Subagents nutzen — standardmäßig NATIV über den Claude-Code-Agent-Typ `gpt` (WhisperM8 GPT-Backend), nur explizit als headless Codex-Job über das whisperm8-CLI. Nutze diese Skill bei "GPT-Subagent", "starte GPT-Agents", "lass GPT das machen/reviewen", "zweite Meinung", "frag Codex", "Codex-Subagent", "delegiere an Codex/GPT", bei Bild-Generierung via Codex, wenn Subagent-Jobs verwaltet werden sollen (Status, Logs, Nachsteuern, Stoppen, Aufräumen) oder wenn Codex-Jobs als Steps in Claude Dynamic Workflows orchestriert werden.
---

# GPT-Subagents: nativ (Standard) oder Codex-CLI (explizit)

Es gibt ZWEI Wege zu GPT-Subagents. **Standard ist der native Weg** über den
Claude-Code-Agent-Typ `gpt` — schnell, in-session, volles Tool-Set. Das
whisperm8-CLI ist die Spezial-Variante für alles, was nur Codex kann.

## Wegweiser — welcher Weg wann

| Anlass | Weg |
|---|---|
| Standard: "GPT-Subagent", zweite Meinung, Review, parallele Teilaufgabe | **NATIV** (`subagent_type: "gpt"`) |
| Bilder generieren (codex-natives `image_gen`) | **CLI** — immer; nativ gibt es kein image_gen |
| User sagt explizit "CLI", "whisperm8 agent", "Job" — oder `--cli` als Skill-Argument | **CLI** |
| Detachte Langläufer: Sidebar-Sichtbarkeit in der App, überleben App-Neustart | **CLI** |
| Browser-QA (Playwright-storageState), 1Password-Flows | **CLI** |
| Steps in Claude Dynamic Workflows | **NATIV**: `agent(prompt, {agentType: "gpt", schema})` — inkl. Structured Output E2E-validiert (2026-07-18). CLI/codex-runner nur für Codex-Spezifisches (Bilder, detachte Jobs) |

Skill-Argumente: `/codex-subagent <aufgabe>` → nativ. `/codex-subagent --cli
<aufgabe>` → CLI erzwingen. Bild-Aufträge gehen unabhängig vom Argument immer
über die CLI.

## Nativer Weg (Standard): Agent-Typ `gpt`

Das WhisperM8-GPT-Backend verwaltet eine Agent-Definition
(`<config-dir>/agents/gpt.md`, Frontmatter `model: gpt-5.6-sol` — bei
aktivem Fast-Modus, dem Default, `model: gpt-5.6-sol-fast` = Priority-Tier,
2,5× ChatGPT-Credits) für das
Main-Profil UND jedes Account-Profil; alle Requests laufen über den lokalen
Mix-Router. Nutzung: normales Agent-Tool mit `subagent_type: "gpt"` — ein
Spawn pro Teilaufgabe, parallele Fan-outs ausdrücklich erwünscht. Effort ist
per Env immer aktiv (high thinking gemäß Session-Einstellung).

Wenn der Spawn fehlschlägt („Agent type 'gpt' not found"):

- Die Registry lädt beim **Session-Start** — Sessions, die älter sind als die
  Agent-Definition, kennen den Typ nicht (nur PROJEKT-Level-Definitionen unter
  `.claude/agents/` laden mid-session nach). Abhilfe: neue Session, oder
  CLI-Weg als Fallback + Hinweis an den User.
- GPT-Backend deaktiviert? `env | grep ANTHROPIC_BASE_URL` muss auf
  `http://127.0.0.1:<router-port>` zeigen; sonst Settings → „GPT-Backend"
  prüfen und den CLI-Weg nehmen.

Gotchas (QA-verifiziert 2026-07-18):

- **Selbstauskunft ist wertlos**: GPT-Subagents halten sich laut System-Prompt
  für Claude/Opus. Modell-Beweis liefern nur die `"model"`-Felder im
  Session-JSONL (`~/.claude*/projects/<cwd>/…jsonl`).
- **Der `model`-Parameter des Agent-Tools hat eine Alias-Whitelist**
  (sonnet/opus/haiku/fable) und lehnt GPT-Slugs ab — GPT geht NUR über den
  Agent-TYP, nie über den Parameter.
- Instruiere Subagents, ihr Ergebnis IMMER in der finalen Antwort zu melden —
  sonst enden sie teils mit bloßer Idle-Meldung ohne Inhalt.

# CLI-Weg (explizit): Codex-Subagents via `whisperm8 agent`

## Was das System ist

Die OpenAI Codex CLI hat kein Background-Konzept (kein Pendant zu
`claude --bg`/`attach`). WhisperM8 schließt die Lücke: **das whisperm8-CLI ist
der Supervisor.** `whisperm8 agent run` startet einen headless
`codex exec`-Lauf, ein detachter Supervisor-Prozess protokolliert Events und
Zustand in ein Job-Verzeichnis, und die WhisperM8-App zeigt jeden Job live in
der Sidebar (eingerückt unter der Claude-Session, die ihn gespawnt hat).

Wichtige Eigenschaften:

- **Jeder Job ist eine echte Codex-Session** (persistiert in
  `~/.codex/sessions/`). Folge-Turns via `agent send` nutzen
  `codex exec resume` — der Kontext bleibt erhalten.
- **Ein Turn = ein Prozess.** Zwischen Turns läuft nichts; Jobs überleben
  Neustarts. Ein Job durchläuft:
  `spawning → running → done | failed | stopped` (+ `takenOver`, wenn der
  User ihn in der App als interaktiven Chat übernimmt — danach ist `send`
  dauerhaft gesperrt).
- **Approvals gibt es nicht** (headless = `never`); Sicherheit kommt aus der
  Sandbox: `workspace-write` (Default, kein Netzwerk) oder `read-only`.
- Der User sieht alles in der WhisperM8-App und kann eingreifen — erwähne
  bei gespawnten Jobs die Job-ID, damit er sie zuordnen kann.

## Befehle (vollständig)

```bash
whisperm8 agent run  [optionen] "<prompt>"       # Job starten
whisperm8 agent send <id> [--wait] [--json] "<prompt>"   # Folge-Turn (resume)
whisperm8 agent list [--json]                    # alle Jobs, neueste zuerst
whisperm8 agent status <id> [--json]             # Zustand + Report + Metriken
whisperm8 agent wait <id> [--json]               # auf Turn-Ende warten / nach Timeout wieder anhängen
whisperm8 agent logs <id> [--tail N]             # letzte N Event-Zeilen (Default 50, rohe JSONL)
whisperm8 agent stop <id>                        # laufenden Turn abbrechen (SIGTERM)
whisperm8 agent rm <id>                          # Job-Verzeichnis entfernen (Codex-Session bleibt)
whisperm8 agent help                             # Hilfetext
```

### run-Optionen

| Flag | Wirkung |
|------|---------|
| `--wait` | Synchron: blockiert bis Turn-Ende, Ergebnis auf stdout. Ohne `--wait`: detacht, gibt sofort `{"shortId":"…","state":"spawning"}` aus. |
| `--json` | Maschinenlesbares Ergebnis-Objekt auf stdout (immer setzen, wenn du das Ergebnis parst). |
| `--cd <dir>` | Working Directory des Jobs. Default: aktuelles Verzeichnis. |
| `--sandbox <m>` | `read-only` oder `workspace-write` (Default). read-only für reine Analyse/Reviews. |
| `--worktree` | Job arbeitet in einem frischen Git-Worktree (Branch `subagent/<id>`, liegt im Job-Verzeichnis). Pflicht-Empfehlung, wenn du selbst gerade im selben Checkout editierst. |
| `--allow-network` | Netzwerk in der Sandbox (u.a. `git push`, Paketinstallationen). Default aus — vorher den User fragen. |
| `--config <key=value>` | Generischer Codex-Config-Override, wiederholbar — wird 1:1 als `-c` an codex exec durchgereicht und gilt auch für Folge-Turns (`send`). Kommt NACH den eingebauten Configs, übersteuert sie also (z.B. `--config tools.web_search=true`). Werte mit führendem `-` werden abgelehnt (Exit 1) — codex läse sie als Flag. |
| `--playwright-storage-state <path>` | Browser-QA: startet den Playwright-MCP im Codex-Subagent isoliert mit dieser storageState-Datei (`--isolated --storage-state`). Relative Pfade werden relativ zu `--cd`/CWD aufgelöst; fehlt die Datei, bricht `run` sofort mit Exit 1 ab. Browser-Traffic braucht KEIN `--allow-network`. |
| `--model <name>` | Codex-Modell-Override. **IMMER explizit `--model gpt-5.6-sol` setzen** (Frontier-Modell, Stand codex 0.144.0) — NIEMALS `gpt-5.5` oder älter, und nie weglassen (ohne Flag gilt die `~/.codex/config.toml`, deren Effort-Default niedrig ist). Freier String, keine Whitelist — neue Modelle funktionieren sofort. |
| `--effort <level>` | `model_reasoning_effort`-Override: minimal/low/medium/high/xhigh/max/ultra — modellabhängig (bis `ultra` nur gpt-5.6-sol/terra; gpt-5.6-luna bis `max`; ältere Modelle bis `xhigh`). **IMMER explizit setzen, Standard `high`** (ohne Flag greift der config.toml-Default `low`); für die härtesten Verifikationen `xhigh`+. Verfügbare Level pro Modell: `~/.codex/models_cache.json`. |
| `--parent <session-id>` | Claude-Session-ID des spawnenden Chats — nur nötig, wenn du eine echte ID kennst. OHNE das Flag ordnet WhisperM8 den Job automatisch über den Prozessbaum dem Chat zu, in dem du läufst (`$CLAUDE_SESSION_ID` existiert NICHT als Env-Variable — nicht verwenden). |

## Exit-Codes (verbindlich — kein Text-Parsing nötig)

| Code | Bedeutung | Typische Reaktion |
|------|-----------|-------------------|
| 0 | ok / Job done (Report-status success oder partial) | Report auswerten |
| 1 | Usage-Fehler (Flag/Argument falsch) | Aufruf korrigieren |
| 2 | Job failed (turn.failed, Prozessfehler, oder Report meldet `status: failure`) | `status`/`logs` lesen, ggf. `send` mit Korrektur |
| 3 | Zustandskonflikt (Turn läuft schon; Job wurde übernommen; keine Thread-ID) | Warten bzw. Job neu starten |
| 4 | Umgebungsproblem (codex fehlt/zu alt, Job-ID unbekannt, Worktree dirty bei rm) | Meldung auf stderr lesen, User informieren |

## Ausgabe-Formen (`--json`)

`run` ohne `--wait` (detacht):

```json
{"shortId":"a3f81c2e","state":"spawning"}
```

`run --wait`, `send --wait` und `status` liefern das volle Job-Objekt
(Auszug; Felder können `null` sein):

```json
{
  "shortId": "a3f81c2e",
  "state": "done",
  "intent": "…erster Prompt…",
  "cwd": "/pfad/zum/repo",
  "codexThreadID": "019f2f13-…",
  "parentSessionID": "…",
  "turns": 2,
  "sandbox": "workspace-write",
  "worktree": {"path": "…", "branch": "subagent/a3f81c2e"},
  "metrics": {"lastTurnSeconds": 42.1, "diffChangedFiles": 3, "diffAdded": 120, "diffDeleted": 8},
  "failureReason": null,
  "report": {
    "status": "success",
    "summary": "…was getan wurde…",
    "filesChanged": ["…"],
    "commits": [{"sha": "9c2e1af", "message": "feat(...): …"}],
    "testsRun": {"command": "swift test --filter Foo", "passed": true},
    "openQuestions": ["…"]
  }
}
```

- `report` ist schema-erzwungen (`--output-schema`). Ist es trotzdem `null`,
  steht der Rohtext in `rawLastMessage`.
- `metrics` misst der Supervisor selbst (verlässlich); `report` sagt das
  Modell (plausibel, aber verifizierbar — Commits ggf. per git prüfen).
- `list --json` liefert ein Array dieser Job-Objekte (ohne `report`).

## Arbeitsregeln

0. **Modellwahl ist festgelegt, nicht deine Entscheidung:** jeder `run`
   bekommt `--model gpt-5.6-sol --effort high` (das beste verfügbare
   Modell). NIEMALS `gpt-5.5` oder ein anderes älteres Modell wählen und
   die Flags NIE weglassen — ohne sie zieht die `~/.codex/config.toml`
   mit Effort `low`. Härteste Verifikationen/Adjudikationen: `--effort
   xhigh` bis `ultra`. Abweichen nur, wenn der User es ausdrücklich sagt.
1. **Parent-Zuordnung ist automatisch:** Läufst du in einem
   WhisperM8-Chat, erkennt das CLI den spawnenden Chat über den
   Prozessbaum — kein `--parent` nötig. (`$CLAUDE_SESSION_ID` ist als
   Env-Variable LEER — niemals darauf verlassen.)
2. **Kurz (< ~2 Min erwartet):** direkt `run --wait --json`.
3. **Länger:** `run --wait --json` als **Background-Bash-Task** starten
   (run_in_background) — das Harness meldet sich beim Prozessende von
   selbst. Keine Poll-Schleifen bauen.
   **`--wait` ist nur Zuschauer:** der Job läuft immer detacht; stirbt der
   wartende Prozess (Bash-Timeout, Ctrl-C, Abbruch), arbeitet der Turn
   weiter. `agent wait <id>` hängt sich wieder an (die Short-ID steht als
   stderr-Breadcrumb sofort im Output, auch bei `--json`). Turns stoppt
   ausschließlich `agent stop <id>`.
4. **Paralleles Schreiben im selben Repo, in dem du selbst editierst:**
   `--worktree`. Danach: Branch `subagent/<id>` reviewen
   (`git log/diff <branch>`), mergen/cherry-picken oder verwerfen.
5. **Reine Analyse:** `--sandbox read-only` — schneller freigegeben, kein
   Schreibrisiko.
6. **Nachsteuern statt neu spawnen:** `agent send <id> "…"` behält den
   Session-Kontext. Exit 3 heißt: Turn läuft noch (mit `logs` reinschauen)
   oder Job wurde übernommen.
7. **Zwischenstand:** `agent logs <id> --tail 20` (rohe JSONL-Events:
   `agent_message`-, `command_execution`-Items etc.).
8. **Committen ja, Pushen nein.** Das CLI schaltet bei workspace-write das
   gemeinsame Git-Verzeichnis automatisch frei (`git rev-parse
   --git-common-dir`; Codex' Sandbox behandelt es sonst als read-only) —
   Commits funktionieren in-place, aus Repo-Unterverzeichnissen und mit
   `--worktree`. Push nur nach User-Freigabe via `--allow-network`.
   Nebenwirkung: der Override ERSETZT ein etwaiges
   `sandbox_workspace_write.writable_roots` aus der eigenen `config.toml`
   (TOML ersetzt Arrays) — eigene Roots ggf. per `--config` mitgeben.
   Scheitert ein Commit an `.git/index.lock: Operation not permitted`, läuft
   ein whisperm8-Binary von vor dem Fix — App neu bauen/starten.
9. **Aufräumen:** fertige, ausgewertete Jobs mit `agent rm <id>` entfernen —
   aber nicht ungefragt, der User sieht die Jobs auch in der App.
10. Codex liest Projekt-Konventionen aus `AGENTS.md` im Ziel-Repo (nicht
    CLAUDE.md). Fehlt es, gib die 2–3 wichtigsten Konventionen im Prompt mit.
11. Formuliere Aufträge **abschlussorientiert**: was tun, wie verifizieren
    (Test-Befehl!), was committen. Der Abschluss-Report ist erzwungen — gute
    Prompts machen ihn aussagekräftig.

## Browser-/UI-QA mit Playwright-State

Für UI- und Browser-Verifikation ist Playwright-MCP der Standardpfad, nicht der
sichtbare Chrome des Users und nicht Computer Use. Authentifizierung wird über
Playwright `storageState` geteilt, z.B. `.qa/auth/akquise-admin.storageState.json`.

Verbindliche Regeln:

1. **Nie direkt fan-outen.** Starte zuerst genau einen Probe-Subagent mit
   `--playwright-storage-state <path>`, der eine geschützte Route öffnet und
   Auth-Indikatoren prüft.
2. **Fan-out nur nach PASS.** Wenn der Probe-Subagent Playwright-MCP nicht sieht,
   auf Login/Auth umgeleitet wird oder den Auth-Indikator nicht findet, keine
   weiteren Browser-QA-Subagents starten.
3. **State-Dateien sind read-only.** Subagents dürfen `.qa/auth/*` lesen, aber
   nicht überschreiben. Refresh des Auth-State ist ein eigener, serieller Auftrag.
4. **Isolierte Browser-Kontexte.** `--playwright-storage-state` erzwingt einen
   isolierten Playwright-MCP-Kontext, damit parallele Subagents keine Browser-
   Profile teilen.
5. **Eindeutige Artefakte.** Jeder QA-Subagent bekommt eigene Pfade:
   `.qa/reports/<task-id>.md`, `.qa/screenshots/<task-id>/`,
   `.qa/traces/<task-id>/`.
6. **Keine Fallbacks ohne Freigabe.** Wenn Playwright-MCP nicht funktioniert,
   nicht auf sichtbaren Chrome, Codex Chrome Plugin oder Computer Use ausweichen.
7. **State frisch capturen, direkt vor jedem Batch.** storageStates sterben
   serverseitig binnen ~40 Minuten (App-Session-Rotation), unabhängig von der
   Cookie-Expiry im JSON. Erzeugung via 1Password-CLI ohne Secret-Sichtkontakt:
   siehe `references/1password-cli.md`.
8. **Harte Verbotsregeln in JEDEN Prompt.** Codex kennt die Sicherheitsregeln
   des Haupt-Agenten nicht — ein Agent hat sich bei totem State eigenmächtig
   mit Seed-Credentials eingeloggt. Pflichtbausteine: nie einloggen/ausloggen/
   Passwörter, bei Login-Redirect abbrechen mit VERDICT "NICHT PRUEFBAR",
   erlaubte Datenänderungen explizit benennen inkl. Rückdreh-Pflicht.
9. **Mutierende Agents brauchen disjunkte Testobjekte** (pro Agent ein eigenes
   Wegwerf-Objekt, namentlich zugewiesen). Fehlende Testdaten vorher selbst
   headless anlegen, nicht dem Agent überlassen.
10. **Agent-Verdicts sind Evidenz, keine Wahrheit.** Überraschende MÄNGEL/
    NICHT-PRÜFBAR-Urteile selbst nachmessen (headless Playwright mit demselben
    State) — Fehlurteil-Muster in `references/playwright-browser-qa.md`.

Technische Eigenschaften (für korrekte Flags/Prompts):

- Der Playwright-MCP läuft **außerhalb der Codex-Sandbox** — Browser-Traffic
  (auch localhost/Dev-Server) funktioniert ohne `--allow-network`. Das Flag nur
  setzen, wenn der Subagent selbst Netz braucht (z.B. Paketinstallation).
- Der MCP ist gepinnt (`@playwright/mcp`, `--browser chrome
  --ignore-https-errors`): nutzt das installierte Chrome und ignoriert
  TLS-Fehler — gedacht für lokale Test-Umgebungen mit self-signed Zertifikaten.
- **Jeder Subagent startet eine eigene Chrome-Instanz.** Moderat
  parallelisieren (3–5 Jobs) und größere Ticket-Mengen staffeln — der
  Engpass sind RAM/CPU der vielen Chrome-Instanzen, kein hartes Limit.
- **Fehlersignatur `user cancelled MCP tool call`:** Codex hat den Toolcall
  am MCP-Approval-Gate abgebrochen (nicht-read-only Tools wie
  `browser_resize`/`browser_tabs`/`browser_evaluate` brauchen headless eine
  Freigabe). Das CLI setzt diese Freigabe seit 2026-07-05 automatisch
  (`default_tools_approval_mode`) — tritt der Fehler trotzdem auf, ist es
  KEIN Timing-/Parallel-Problem: Logs prüfen und den Job per
  `agent send <id> "…erneut prüfen…"` nachsteuern statt neu spawnen — der
  Session-Kontext (gelesene Tickets etc.) bleibt erhalten.

Probe-Subagent:

```bash
whisperm8 agent run --wait --json --cd /pfad/zum/repo \
  --model gpt-5.6-sol --effort high \
  --playwright-storage-state .qa/auth/akquise-admin.storageState.json \
  "Browser-QA Preflight. Öffne https://akquise.test/admin/kunden mit Playwright-MCP. Prüfe: keine Weiterleitung zu /login oder auth.akquise.test, Titel AkquiseAI, sichtbarer Auth-Indikator Admin AkquiseAI oder admin@akquise.ai. Schreibe .qa/reports/preflight.md. Keine App-Daten ändern."
```

Subagent-Prompt für Browser-QA:

```text
Browser-QA Auftrag.

Base URL: <url>
Auth-State: <storageState>
Report: .qa/reports/<task-id>.md
Screenshots: .qa/screenshots/<task-id>/
Traces bei Fehlern: .qa/traces/<task-id>/

Nutze Playwright-MCP. Nutze nicht den sichtbaren Chrome, nicht Computer Use und
nicht das Codex Chrome Plugin. Überschreibe .qa/auth/* nicht.

HARTE REGELN: NIEMALS einloggen, ausloggen oder Passwörter eingeben — wenn eine
Login-Seite erscheint oder der Auth-State nicht greift, sofort abbrechen und
VERDICT "NICHT PRUEFBAR" dokumentieren. Erlaubte Datenänderungen: <explizit
aufzählen oder "keine">; jede Änderung zurückdrehen und im Report dokumentieren.
Arbeite zügig — der Auth-State altert.

Schreibe VERDICT (BESTANDEN/MAENGEL/NICHT PRUEFBAR), Beobachtung pro
Akzeptanzpunkt (Texte wörtlich zitieren), finale URL, Console-/Network-
Auffälligkeiten und Artefaktpfade — VERDICT zusätzlich in die Abschlussnachricht.
```

## Einsatz in Claude Dynamic Workflows (`/workflows`)

Codex-Jobs funktionieren als Steps in Dynamic Workflows — validiert 2026-07-08
(Fan-out, Resume über Phasen, Exit-Code-Pfade, Parent-Zuordnung alle grün).
Das Workflow-Skript kann nicht selbst shellen; jeder Codex-Aufruf läuft über
einen billigen Claude-Wrapper-Subagenten (`model: 'sonnet'` oder `'haiku'`,
`effort: 'low'` — nie das teure Hauptmodell) mit `run --wait --json`,
`; echo "EXIT:$?"` und `{schema}`-Relay des stdout-JSON. Exit-Codes wertet das
Skript aus, nicht der Wrapper. `status <id>` statt `list` (Kontext-Falle!),
`shortId` durch die Stages reichen für `send`-Nachsteuerung, Playwright-Jobs
auf 3–5 parallel batchen. Prompt-Vorlage, Schema, Muster (Cross-Model-
Verifier-Panel, Fan-out-Implementierung) und bekannte Grenzen:
**`references/claude-workflows.md`**.

## Workflows (Kopiervorlagen)

```bash
# 1) Second-Opinion-Review, synchron
whisperm8 agent run --wait --json --sandbox read-only \
  --model gpt-5.6-sol --effort high \
  "Reviewe den Diff von HEAD~3..HEAD auf Regressionen, Races und API-Brüche. Nur Analyse, keine Edits."

# 2) Parallele Implementierung, isoliert (als Background-Task starten!)
whisperm8 agent run --wait --json --worktree \
  --model gpt-5.6-sol --effort high \
  "Implementiere <X> in <Datei>. Verifiziere mit 'swift test --filter <Y>'. Committe bei grün (Conventional Commit, deutsche Beschreibung)."

# 3) Fire-and-forget mit späterem Abholen
ID=$(whisperm8 agent run --json --cd /pfad/repo --model gpt-5.6-sol --effort high "…" | sed -E 's/.*"shortId":"([a-f0-9]+)".*/\1/')
# … später:
whisperm8 agent status "$ID" --json

# 4) Nachsteuern
whisperm8 agent send a3f81c2e --wait --json \
  "openQuestions[0] beantworten: ja, Legacy-Modes hart ablehnen. Bitte anpassen und nachcommitten."
```

## Troubleshooting

- **Shell-Parse-Error beim Inline-Prompt (`(eval):N: parse error`)**: Lange
  deutsche Prompts mit typografischen Anführungszeichen (`„…"`) brechen die
  zsh-Doppelquote-Umklammerung — das gerade Abschlusszeichen `"` beendet den
  String. Robustes Muster: Prompt mit Write in eine Datei legen und per
  `whisperm8 agent run … "$(cat /pfad/prompt.txt)"` übergeben (gelernt
  2026-07-12, Doku-Nachsteuerungs-Job).
- **Exit 4 „codex nicht gefunden/zu alt"**: Codex.app installieren oder
  `codex` in den PATH; Mindestversion siehe Fehlermeldung.
- **`state: failed` mit `failureReason: "supervisor died …"`**: der
  Supervisor-Prozess wurde gekillt (Neustart o.ä.). Der Job ist per `send`
  fortsetzbar, sofern `codexThreadID` gesetzt ist.
- **`stalled` im failureReason**: 30 Min keine Events — Idle-Watchdog hat
  abgebrochen. Prompt verkleinern oder Aufgabe zerlegen.
- **Exit 3 bei `send`, Job zeigt `takenOver`**: der User hat den Job in
  WhisperM8 als interaktiven Chat übernommen — nicht mehr anfassen, den User
  fragen.
- **Report null trotz done**: `rawLastMessage` nutzen; beim nächsten `send`
  explizit an den Report-Vertrag erinnern.
- **`partial` + openQuestion „Sandbox blockiert .git/index.lock"**: das
  laufende whisperm8-Binary ist älter als der Commit-Fix (writable_roots-
  Override, 2026-07-08) — App neu bauen/starten. Die Dateiarbeit des Jobs
  ist trotzdem erledigt: notfalls selbst committen; nach dem Update
  committet ein `send`-Folge-Turn auch selbst nach.
- **Report meldet Commits, aber `git log` kennt sie nicht als neu**: Codex
  referenziert gern existierende SHAs — Commits IMMER per git verifizieren,
  besonders bei read-only-Jobs (die können gar nicht committen).

## Referenzen

Vertiefendes Betriebswissen (bei Bedarf laden):

- **`references/playwright-browser-qa.md`** — Browser-QA im Detail:
  State-Lebensdauer und Frische-Regeln, Parallelitäts-Empirie und
  Approval-Gate-Historie, Sandbox-Grenzen, Werkzeug-Verfügbarkeits-Fallbacks,
  Prompt-Pflichtbausteine, Testdaten-Kollisionsvermeidung, Verdict-Kalibrierung
  (dokumentierte Fehlurteil-Muster), bewährter Batch-Ablauf.
- **`references/1password-cli.md`** — Auth-States via 1Password-CLI:
  `op run`-Muster ohne Secret-Sichtkontakt, capture-state.mjs, Item-Mapping,
  Setup, Betriebsregeln (Frische, gitignore, read-only für Subagents).
- **`references/claude-workflows.md`** — Codex-Jobs als Steps in Claude
  Dynamic Workflows: Wrapper-Kontrakt (Prompt-Vorlage + Schema),
  Exit-Code-Mapping im Skript, Parallelitäts- und Budget-Regeln, bewährte
  Muster (Cross-Model-Verifier-Panel, Fan-out, Nachsteuer-Kette), bekannte
  Grenzen inkl. Commit-Blockade und verifiziertem Fix (Testprotokoll
  2026-07-08).
