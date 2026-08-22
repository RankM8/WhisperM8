---
name: codex-subagent
description: Dieser Skill sollte verwendet werden, wenn Nutzer „GPT-Subagent“, „starte GPT-Agents“, „lass GPT reviewen“, „zweite Meinung“, „frag Codex“ oder „delegiere an GPT/Codex“ sagen. Standard ist der native Agent-Typ `gpt`. Der CLI-Spezialpfad gilt nur bei explizitem `--cli`/`whisperm8 agent` oder Codex-only-Anforderungen wie detachten, App-sichtbaren Jobs, Browser-QA mit Playwright-State, `image_gen`, Jobverwaltung oder ausdrücklich gewünschten CLI-Steps in Dynamic Workflows.
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
| Steps in Claude Dynamic Workflows | **NATIV**: `agent(prompt, {agentType: "gpt", schema})` — inkl. Structured Output E2E-validiert (2026-07-18). Der ausgelieferte Workflow `codex-verify` ist native-only und fällt nie auf CLI/`codex-runner` zurück. |

Skill-Argumente: `/codex-subagent <aufgabe>` → nativ. `/codex-subagent --cli
<aufgabe>` → CLI erzwingen. Bild-Aufträge gehen unabhängig vom Argument immer
über die CLI.

**Für jeden CLI-Einsatz zuerst `references/codex-cli.md` laden** — dort stehen
Befehle, run-Optionen, Exit-Codes, Arbeitsregeln (inkl. Modellwahl
`--model gpt-5.6-sol --effort high`), Browser-QA mit Playwright-State,
CLI-Steps in Dynamic Workflows, Kopiervorlagen und Troubleshooting. Diese
Hauptdatei deckt nur den nativen Weg und die gemeinsamen Grundregeln ab.

## Nativer Weg (Standard): Agent-Typ `gpt`

Das WhisperM8-GPT-Backend verwaltet eine Agent-Definition
(`<config-dir>/agents/gpt.md`, Frontmatter `model: gpt-5.6-sol` — bei
aktivem Fast-Modus, dem Default, `model: gpt-5.6-sol-fast`) für das
Main-Profil UND jedes Account-Profil; alle Requests laufen über den lokalen
Mix-Router. Nutzung: normales Agent-Tool mit `subagent_type: "gpt"` — ein
Spawn pro Teilaufgabe, parallele Fan-outs ausdrücklich erwünscht. Effort ist
per Env immer aktiv (high thinking gemäß Session-Einstellung).

Schlägt der Spawn mit „Agent type 'gpt' not found" fehl: Diagnose im
Gotcha-Abschnitt unten — nicht automatisch auf den CLI-Weg wechseln.

## Gemeinsame Gotchas & Grundregeln (kanonische Stelle)

Diese Regeln gelten für ALLE GPT-Delegation. Die Skills `gpt-coworker` und
`gpt-workflow` verweisen per Gotcha-Namen hierher — Änderungen nur hier
vornehmen, nirgends duplizieren.

- **Model-Parameter-Whitelist:** Der `model`-Parameter des Agent-Tools hat
  eine Alias-Whitelist (sonnet/opus/haiku/fable) und lehnt GPT-Slugs ab —
  GPT geht NUR über den Agent-TYP (`subagent_type: "gpt"`, in Workflows
  `agentType: "gpt"`), nie über den Parameter.
- **Ergebnis-Meldepflicht:** Jeden GPT-Agent explizit instruieren, sein
  Resultat IMMER in der finalen Antwort zu melden — sonst enden manche mit
  bloßer Idle-Meldung ohne Inhalt. In Workflows zusätzlich per `schema`
  erzwingen und im Prompt „Antworte NUR über das StructuredOutput-Tool."
- **Kein Commit durch GPT-Agents:** Native GPT-Subagents committen/pushen
  NIE und führen keine zustandsändernden git-Befehle aus; committet wird
  erst nach dem Review durch das Orchestrierungsmodell. (Explizit beauftragte
  CLI-Jobs dürfen committen, aber nie pushen — Regel 8 in
  `references/codex-cli.md`.)
- **Modell-Nachweis:** Selbstauskunft ist wertlos — GPT-Subagents halten
  sich laut System-Prompt für Claude/Opus. Beweis liefern nur die
  `"model"`-Felder im Session-JSONL (`~/.claude*/projects/<cwd>/…jsonl`; bei
  Workflows die `agent-*.jsonl` im Workflow-Transcript-Verzeichnis).
- **Diagnose „Agent type 'gpt' not found":** Die Registry lädt beim
  **Session-Start** — Sessions, die älter sind als die Agent-Definition,
  kennen den Typ nicht (nur PROJEKT-Level-Definitionen unter
  `.claude/agents/` laden mid-session nach). Abhilfe: neue Session starten
  und den User informieren; nicht automatisch auf CLI wechseln. GPT-Backend
  deaktiviert? `env | grep ANTHROPIC_BASE_URL` muss auf
  `http://127.0.0.1:<router-port>` zeigen; sonst Settings → „GPT-Backend"
  prüfen. Der native-only Workflow `codex-verify` bricht in diesem Fall klar
  ab; nur ein ausdrücklich angeforderter CLI-Auftrag darf auf den CLI-Weg
  wechseln.
- **Kontextfenster:** `gpt`-Subagents, die aus einer **Claude**-Main-Session
  gespawnt werden, laufen mit dem 200k-Default (~177k nutzbar). 272k bzw.
  900k (erweitertes Profil, Auto-Compact um ~830k) gibt es nur in
  GPT-gestempelten Main-Sessions (`CLAUDE_CODE_MAX_CONTEXT_TOKENS`;
  verifiziert 2026-08-18 für Sol/Terra/Luna/GPT-5.4). Subagents kompaktieren
  nie — wer sein Fenster füllt, stirbt terminal mit „Prompt is too long".
  Deshalb große Scopes vor der Delegation splitten und Diffs/Dateien
  referenzieren statt einbetten.
- **Kosten:** Delegation schont Claude-Limits und Main-Kontext, ist aber
  nicht gratis: der Fast-Default (`gpt-5.6-sol-fast`) läuft im Priority-Tier
  mit 2,5× ChatGPT-Credits. Bei größeren Fan-outs dem User die
  Agent-Gesamtspanne nennen, damit er den Einsatz einschätzen kann.

### Verbindliche Modell-Deklaration bei jedem Subagent

Jeder Spawn muss das Modell **technisch und explizit** deklarieren, damit Claude
Codes Agents-Ansicht den echten Modell-Chip (`[gpt-5.6-sol]`, die zugehörige
`-fast`-Variante oder Terra) zeigt:

- Standard-Aufruf: immer `subagent_type: "gpt"`; in Workflows ausnahmslos
  `agentType: "gpt"`. Den Agent-Typ niemals weglassen und nie nur im Prompt
  behaupten, dass GPT verwendet werde.
- Ein spezialisierter Custom Agent darf seinen eigenen `subagent_type` bzw.
  `agentType` behalten, **wenn** dessen Definition im Frontmatter explizit
  `model: gpt-5.6-sol` oder `model: gpt-5.6-terra` setzt. Vor dem Spawn prüfen;
  Custom-Prompt und Tool-Grenzen dürfen nicht durch `gpt` ersetzt werden.
- Zulässige Subagent-Modelle sind ausschließlich **GPT-5.6 Sol** (Standard) oder
  **GPT-5.6 Terra**. Niemals Haiku verwenden. Ist keine explizite Terra-
  Definition verfügbar, auf den verwalteten `gpt`-Typ (Sol) zurückfallen —
  nicht auf ein implizit geerbtes Modell.
- Bei Custom-Agent-Definitionen muss `model:` im Frontmatter gesetzt sein; keine
  Definition mit impliziter Vererbung starten. Name/Label beschreibt die
  Aufgabe, nicht das Modell — den Modell-Chip rendert Claude Code aus der
  tatsächlich aufgelösten Definition.
- CLI-Jobs deklarieren das Modell weiterhin zwingend über `--model
  gpt-5.6-sol` oder ein ausdrücklich gewünschtes `--model gpt-5.6-terra`.
- Die sichtbare Deklaration ist ein Kontrollsignal, aber der verbindliche
  Nachweis bleibt das `"model"`-Feld im Agent-Transcript.

## CLI-Weg (explizit): Codex-Subagents via `whisperm8 agent`

Die OpenAI Codex CLI hat kein Background-Konzept; das whisperm8-CLI ist der
Supervisor: `whisperm8 agent run` startet einen headless `codex exec`-Lauf,
ein detachter Supervisor protokolliert in ein Job-Verzeichnis, und die
WhisperM8-App zeigt jeden Job live in der Sidebar. Jeder Job ist eine echte
Codex-Session (Folge-Turns via `agent send` behalten den Kontext), Jobs
überleben Neustarts, Sicherheit kommt aus der Sandbox.

Die vollständige Betriebsanleitung — Befehle, run-Optionen, Exit-Codes,
Arbeitsregeln, Browser-/UI-QA mit Playwright-State, CLI-Steps in Dynamic
Workflows, Kopiervorlagen, Troubleshooting — steht in
**`references/codex-cli.md`** (bei CLI-Bedarf immer zuerst laden). Vertiefungen
von dort: `references/playwright-browser-qa.md`, `references/1password-cli.md`,
`references/claude-workflows.md`.
