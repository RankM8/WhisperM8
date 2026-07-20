---
name: gpt-workflow
description: Dieser Skill ist zu nutzen, wenn der User verlangt, einen PR, Branch, Diff oder Code „mit GPT (zu) reviewen", ein „GPT-Review", einen „GPT-Workflow", „Code-Review mit GPT-Agents", „Doku-Review", „Dokumentation verifizieren/auf den neuesten Stand bringen" oder einen Multi-Agent-Review-Workflow anfordert — insbesondere mit Formulierungen wie „nur GPT nutzen", „GPT-Sol", „Chip für Chip reviewen" oder Agent-Mengenangaben („20 bis 60 Agents"). Orchestriert Code- und Doku-Reviews ausschließlich mit nativen GPT-Subagents über das Workflow-Tool.
version: 1.0.1
---

# GPT Workflow: Code- & Doku-Review ausschließlich mit GPT-Agents

Multi-Agent-Review-Workflows (Code-Review eines PR/Diffs, Doku-Verifikation gegen den Code), bei denen JEDER Subagent ein GPT-Modell ist. Die Orchestrierung läuft deterministisch über das Workflow-Tool; der Hauptagent orchestriert, dedupliziert im Skript und committet am Ende.

## Eiserne Regeln

1. **Bestätigungs-Gate — IMMER, ohne Ausnahme:** Vor dem Start jedes Workflows dem User eine KURZE Übersicht vorlegen und auf explizites Go warten. Format: pro Workflow die Stufen, die Agent-Anzahl je Stufe und welche Agents genau (Paket-/Angle-Namen als Kurzliste oder Tabelle). Keine Prosa-Abhandlung — die Übersicht muss auf einen Blick erfassbar sein. Erst nach dem Go starten. Ein Go für etwas anderes (z. B. „mach ein PR") ist KEIN Go für die Workflows.
2. **GPT-only:** Jeder einzelne `agent()`-Aufruf im Workflow-Skript trägt `agentType: 'gpt'` — Finder, Verifier, Doku-Prüfer, Doku-Fixer, ausnahmslos. Der native GPT-Weg aus dem Skill `codex-subagent` ist Pflicht (Agent-TYP `gpt`, nie der `model`-Parameter — der hat eine Alias-Whitelist und lehnt GPT-Slugs ab). CLI-Jobs (`whisperm8 agent`) nur, wenn der User es explizit verlangt.
3. **GPT-Agents committen NIE** und führen keine zustandsändernden git-Befehle aus. Schreibende Agents (Doku-Fixer) arbeiten ausschließlich auf disjunkten Dateimengen. Commits, Diff-Review und Push übernimmt der Hauptagent.
4. **GPT-only belegen, nicht behaupten:** Selbstauskunft der Agents ist wertlos. Beweis liefern die `"model"`-Felder in den `agent-*.jsonl` des Workflow-Transcript-Verzeichnisses (`grep -oh '"model":"[^"]*"' <dir>/agent-*.jsonl | sort | uniq -c`). Auf Nachfrage des Users diesen Nachweis führen.
5. **Fixes dokumentieren:** Nach Abschluss (a) Commits pro Themenblock, (b) PR-Body um einen Review-Abschnitt (Findings + Fixes) ergänzen, (c) Doku nachziehen, wenn ein Fix dokumentiertes Verhalten ändert.

## Ablauf

### Schritt 0 — Scope vermessen

Vor jeder Planung Fakten erheben, keine Schätzungen: `git diff --stat <base>...HEAD` (Dateien, Zeilen, Verteilung nach Bereich via `--name-only | awk -F/ …`), für Doku-Reviews `find docs -name '*.md' | …` nach Verzeichnissen gruppiert. Ausschlüsse identifizieren (Lockfiles, Vendor-Material, `docs/archive`, Verzeichnisse anderer laufender Sessions).

### Schritt 1 — Pakete schneiden und Kurzübersicht vorlegen

Den Diff entlang von Feature-Grenzen in Chunks à ~10–20 Dateien schneiden (nicht mechanisch alphabetisch, außer bei homogenen Beständen). Doku in disjunkte Verzeichnis-Pakete à ~8–15 Dateien. Prototypen-/Mockup-Bestände bekommen einen abgeschwächten Auftrag („nur schwere Fehler"). Dann die Kurzübersicht nach Regel 1 vorlegen und auf Go warten.

### Schritt 2 — Workflows starten

Skripte nach den Vorlagen in `examples/` bauen und als Background-Workflows starten. Vor jedem Einsatz **alle projektspezifischen Bereiche** anpassen: `CHUNKS`/`PACKS`, `COMMON`/`CHECK_COMMON`, `ANGLES` sowie ggf. Merge-Commits und Ausschlüsse. Die Vorlagen beziehen `REPO`, Diff-`RANGE` und das Doku-Datum aus Workflow-`args`; diese Werte beim Start zwingend übergeben, z. B. `{repo: "/pfad/zum/repo", range: "origin/main...HEAD", updatedAt: "2026-07-20"}`. Code- und Doku-Workflow dürfen parallel laufen (Doku-Fixer schreiben nur in docs/, Code-Review liest nur).

**Workflow „Code-Review"** (Vorlage `examples/wf-code-review.js`):
- *Find:* N Chunk-Reviewer (Diff Zeile für Zeile + umgebende Dateien lesen, bis 8 Kandidaten mit konkretem Failure-Szenario, Recall-orientiert) **plus** Querschnitts-Angles: Removed-Behavior-Audit (gelöschte Zeilen → wo lebt die Invariante weiter?), Merge-Audit (Konfliktauflösungen gegen beide Elternseiten), Cross-File-Tracer (Call-Sites geänderter Signaturen), Query-/State-Cache-Konsistenz, Security/Auth, Konventions-Check (CLAUDE.md/Rules mit Regel-Zitatpflicht).
- *Dedup:* im Skript (plain JS, `file:line`-Key, höchste Severity gewinnt) — kein Agent.
- *Verify:* pro Kandidat ein adversarialer GPT-Verifier mit Widerlegungsauftrag. CONFIRMED nur nachvollzogen am Code; REFUTED nur mit Beweis (Zitat der Zeile/des Guards); alles andere PLAUSIBLE — „spekulativ" ist kein Widerlegungsgrund. Verify-Cap setzen (~45) und Überhang als `unverified` ausweisen, nie still verwerfen.

**Workflow „Doku-Review"** (Vorlage `examples/wf-docs-review.js`):
- *Prüfen:* pro Paket ein Auditor, der jede prüfbare Behauptung gegen den Code verifiziert (Pfade, Routen, Enums, Befehle, Architekturaussagen, interne Links). Nur belegbare Abweichungen melden (falsch/veraltet/unvollständig) mit Code-Beleg.
- *Fixen:* nur Pakete mit Befunden. Fixer verifiziert jede Meldung selbst erneut, fixt minimal-invasiv per Edit, behält Stil/Struktur, setzt Frontmatter-`updated`, meldet `fixedFiles` und `skipped` mit Grund. Harte Schranken im Prompt: nur Markdown im eigenen Paket, nie Code, nie fremde Pakete, nie git.

Beide Workflows als `pipeline()` wo möglich; Barrier (`parallel()`) nur für den Dedup-Schritt vor Verify.

### Schritt 3 — Ergebnisse verarbeiten

Verifizierte Findings dem User als lesbaren Bericht liefern (CONFIRMED zuerst, dann PLAUSIBLE; Datei:Zeile klickbar). Klare bestätigte Bugs direkt fixen (sofern der User Fix-Autonomie gegeben hat), Grenzfälle als Entscheidungsliste vorlegen. Doku-Änderungen per `git diff` reviewen, dann committen. Abschluss nach Regel 5 dokumentieren.

## Technische Gotchas (aus dem Praxiseinsatz)

- **Agent-Ausfälle nie verschweigen:** Die Vorlagen führen fehlgeschlagene Finder/Pakete und Verifier explizit als `failedFinders`, `failedPacks` bzw. `unverified` und setzen `incomplete`. Diese Felder im Abschlussbericht immer auswerten.
- **Schema-Zwang nutzen:** Jeder Agent bekommt ein `schema` — GPT-Agents enden sonst teils mit bloßer Idle-Meldung ohne Inhalt. Zusätzlich im Prompt: „Antworte NUR über das StructuredOutput-Tool."
- **`Date.now()`/`Math.random()`/argloses `new Date()` sind in Workflow-Skripten verboten** (brechen Resume) — Datumsstempel (z. B. Frontmatter-`updated`) als Literal in den Prompt schreiben.
- **Resume statt Neustart:** Gestoppte/edierte Workflows mit `{scriptPath, resumeFromRunId}` fortsetzen — fertige Agents kommen aus dem Cache. Vor Diagnose „leeres Ergebnis" das `journal.jsonl` im Transcript-Verzeichnis lesen.
- **Concurrency:** Cap liegt bei min(16, Kerne−2) pro Workflow; zwei parallele Workflows verdoppeln die Last auf dem lokalen GPT-Router — mehr als zwei nicht parallel starten.
- **Kostenrahmen nennen:** gpt-5.6-sol-fast läuft im Priority-Tier (2,5× ChatGPT-Credits). Bei der Bestätigungs-Übersicht die Agent-Gesamtspanne angeben, damit der User den Einsatz einschätzen kann.
- **Severity-Skala Code:** critical/major/minor; Doku: falsch/veraltet/unvollstaendig (Schema-Enum ohne Umlaut, Fließtexte mit korrekten Umlauten).

## Ressourcen

- **`examples/wf-code-review.js`** — vollständiges Code-Review-Skript (Chunks + Angles + adversariale Verify-Stufe, Schemas, Dedup, Severity-Ranking und explizite Ausfallbilanz). Alle projektspezifischen Prompts und Arrays pro Einsatz zuschneiden.
- **`examples/wf-docs-review.js`** — vollständiges Doku-Review-Skript (Prüfen→Fixen-Pipeline, Fix-Schranken und explizite Ausfallbilanz). PACKS und Projektkontext pro Einsatz neu zuschneiden.
- **Skill `codex-subagent`** — Grundlagen der GPT-Subagents (nativer Weg vs. CLI, Gotchas, Modell-Nachweis). Der native Weg (`agentType: 'gpt'`) ist für diesen Skill der Standard; CLI nur auf explizite User-Anforderung.
