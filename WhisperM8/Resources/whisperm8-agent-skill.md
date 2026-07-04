---
name: codex-subagent
description: Codex-Subagents über das whisperm8-CLI spawnen, steuern und verwalten — delegiere Implementierungen, Reviews, Second Opinions oder parallele Teilaufgaben an einen headless Codex-Agenten. Nutze diese Skill bei "frag Codex", "lass Codex das machen/reviewen", "Codex-Subagent", "zweite Meinung", "delegiere an Codex" oder wenn Subagent-Jobs verwaltet werden sollen (Status, Logs, Nachsteuern, Stoppen, Aufräumen).
---

# Codex-Subagents via `whisperm8 agent`

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
| `--model <name>` | Codex-Modell-Override. |
| `--effort <level>` | `model_reasoning_effort`-Override (z.B. low/medium/high). |
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

1. **Parent-Zuordnung ist automatisch:** Läufst du in einem
   WhisperM8-Chat, erkennt das CLI den spawnenden Chat über den
   Prozessbaum — kein `--parent` nötig. (`$CLAUDE_SESSION_ID` ist als
   Env-Variable LEER — niemals darauf verlassen.)
2. **Kurz (< ~2 Min erwartet):** direkt `run --wait --json`.
3. **Länger:** `run --wait --json` als **Background-Bash-Task** starten
   (run_in_background) — das Harness meldet sich beim Prozessende von
   selbst. Keine Poll-Schleifen bauen.
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
8. **Committen ja, Pushen nein** (Sandbox blockt Netzwerk). Push nur nach
   User-Freigabe via `--allow-network`.
9. **Aufräumen:** fertige, ausgewertete Jobs mit `agent rm <id>` entfernen —
   aber nicht ungefragt, der User sieht die Jobs auch in der App.
10. Codex liest Projekt-Konventionen aus `AGENTS.md` im Ziel-Repo (nicht
    CLAUDE.md). Fehlt es, gib die 2–3 wichtigsten Konventionen im Prompt mit.
11. Formuliere Aufträge **abschlussorientiert**: was tun, wie verifizieren
    (Test-Befehl!), was committen. Der Abschluss-Report ist erzwungen — gute
    Prompts machen ihn aussagekräftig.

## Workflows (Kopiervorlagen)

```bash
# 1) Second-Opinion-Review, synchron
whisperm8 agent run --wait --json --sandbox read-only \
  "Reviewe den Diff von HEAD~3..HEAD auf Regressionen, Races und API-Brüche. Nur Analyse, keine Edits."

# 2) Parallele Implementierung, isoliert (als Background-Task starten!)
whisperm8 agent run --wait --json --worktree \
  "Implementiere <X> in <Datei>. Verifiziere mit 'swift test --filter <Y>'. Committe bei grün (Conventional Commit, deutsche Beschreibung)."

# 3) Fire-and-forget mit späterem Abholen
ID=$(whisperm8 agent run --json --cd /pfad/repo "…" | sed -E 's/.*"shortId":"([a-f0-9]+)".*/\1/')
# … später:
whisperm8 agent status "$ID" --json

# 4) Nachsteuern
whisperm8 agent send a3f81c2e --wait --json \
  "openQuestions[0] beantworten: ja, Legacy-Modes hart ablehnen. Bitte anpassen und nachcommitten."
```

## Troubleshooting

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
