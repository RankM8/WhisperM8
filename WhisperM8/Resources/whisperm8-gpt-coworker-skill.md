---
name: gpt-coworker
description: Session-weiter Delegations-Modus — NUR bei explizitem Aufruf laden (/gpt-coworker oder "GPT-Coworker-Modus an"). Danach gibt das Orchestrierungsmodell klar definierte Tasks aktiv an GPT-Subagents ab (implementieren, planen, reviewen, Zweitmeinungen — parallel), um Kontext und Claude-Limits zu sparen. Beim Aktivieren PFLICHT: den Skill codex-subagent mitladen (enthält die Spawn-Mechanik — die beiden gehören zusammen). NICHT laden für einzelne GPT-Subagent-Aufrufe oder Codex-Jobs — das ist codex-subagent allein.
---

# GPT-Coworker: aktiv abgeben statt alles selbst machen

**PFLICHT beim Aktivieren: lade SOFORT zusätzlich den Skill
`codex-subagent` (Skill-Tool), bevor du den ersten GPT-Agent spawnst.**
Die beiden gehören zusammen: gpt-coworker regelt WANN und WIE VIEL
delegiert wird, codex-subagent das WIE (nativ vs. CLI, Spawn-Details,
Gotchas, Fallback-Diagnose). Ohne geladenen codex-subagent fehlt dir
die Mechanik — Verweise unten wie „siehe codex-subagent" setzen voraus,
dass er im Kontext ist.

Dieser Modus gilt ab Aufruf **session-weit**, bis der User ihn beendet
(„Stopp", „normal weiter" o. ä.).

## Arbeitsannahme (vom User so festgelegt)

- **GPT hat deutlich höhere Limits als Claude.** Lieber ein GPT-Agent zu
  viel als zu wenig: Zweitmeinungen, parallele Reviews und
  Planungs-Perspektiven schonen Claude-Limits und Main-Kontext. Gratis
  sind sie nicht (Gotcha „Kosten" in codex-subagent): bei größeren
  Fan-outs die Agent-Spanne nennen, sinnlose Doppel-Spawns vermeiden.
- **Rollen nach Vergleichsläufen:** Als Gegenprüfer war ein Claude-Modell
  (Sonnet, effort high) schneller und gründlicher als GPT: Es rechnete
  Behauptungen am Repo nach, statt sie zu übernehmen, und stufte
  Schweregrade realistischer ein. GPT ergänzte andere Gesichtspunkte, und
  seine Verwerfungen waren verlässlich. GPT, das GPT prüft, übersieht
  systematisch.

## Folgerung: wer was macht

- **Sonnet (effort high) macht die Hauptarbeit** (Reviews, Fixes).
- **GPT ist die unabhängige Zweitmeinung** (Gegenprüfung, parallele
  Perspektiven).
- **Opus** für Kernpfade, Schiedsrichter und Abnahme.
- **Nie prüft das bauende Modell.** Zweitprüfung immer durch ein anderes
  Modell.
- **Workflow-Betrieb:** Nachrichten der Hauptsitzung können in laufende
  Workflow-Agenten gelangen (bei jedem Modell) und dort sogar eine zweite
  Instanz starten. Ergebnis deshalb immer auf Vollständigkeit prüfen (je ID
  ein Urteil) und bei Lücken mit einem Claude-Modell nachprüfen.

Neue Vergleichswerte gehören in das Gedächtnis des Users, nicht in diesen
Skill; die Folgerung oben ändert sich nur, wenn er sie ändert.

## GPT spawnen

Wo nach der Folgerung GPT drankommt, gilt `subagent_type: "gpt"`.
Claude-Subagents (Fable/Opus/Sonnet) nimmst du für die Hauptarbeit und für
jedes Zweiturteil gegen einen GPT-Befund. GPT geht nur über den Agent-TYP,
nie über den `model`-Parameter (Gotcha „Model-Parameter-Whitelist" in
codex-subagent).

## Delegations-Reflex

Prüfe bei **jedem Arbeitspaket** zuerst: „Kann das ein Subagent
selbst-contained erledigen?" Das Modell wählst du nach der Folgerung oben.
Gut abgebbar:

- **Implementierung** klar spezifizierter Tasks — Subagents haben volles
  Schreibrecht im Working Tree, inkl. Tests laufen lassen.
- **Reviews** (Code, Pläne, Diffs) — default 2 unabhängige Reviewer aus
  verschiedenen Modellen.
- **Planung** — 2–3 parallele GPT-Perspektiven statt einer eigenen.
- **Zweitmeinungen** — parallel zur eigenen Arbeit starten, nicht danach.
- **Recherche/Exploration** in Code oder Doku, deren Ergebnis sich in
  wenigen Absätzen zurückmelden lässt (spart Main-Kontext am meisten).

**Briefing-Pflicht:** Delegation lohnt nur mit selbst-containedem
Auftrag — betroffene Dateien/Pfade, Akzeptanzkriterien, Testbefehl,
relevante Konventionen (z. B. CLAUDE.md-Regeln des Repos) gehören ins
Briefing. Wenn das Briefing länger würde als die Arbeit selbst: nicht
delegieren, sondern selbst machen. Kein Delegations-Theater.

**Ergebnis-Meldepflicht** (Gotcha in codex-subagent): das Resultat
immer in der finalen Antwort einfordern.

**Kontextbudget** (Gotcha „Kontextfenster" in codex-subagent, dort stehen
die Fenstergrößen): Subagents kompaktieren nie. Große Scopes vor der
Delegation splitten; Diffs und Dateien im Briefing referenzieren
statt einbetten — ein volles Fenster tötet den Agent samt Ergebnis.

## Parallelität: Lesen breit, Schreiben seriell

- **Lese-Arbeit** (Review, Planung, Zweitmeinung, Recherche): beliebig
  parallel, immer in EINEM Block spawnen.
- **Schreib-Arbeit:** 1 Implementierer pro Working Tree. Mehrere
  Umsetzungs-Agents parallel nur bei nachweislich disjunkten Dateimengen
  oder mit `isolation: "worktree"`.

## Review-Gate (das Orchestrierungsmodell bleibt verantwortlich)

**Baseline — immer:** vollständiges `git diff` lesen + Tests/Build grün
verifizieren, bevor etwas als erledigt gilt. Nie ungelesen übernehmen.

**Deep-Review** (Umfeld-Code mitlesen, Architektur-Fit, Edge Cases,
Testqualität), sobald mindestens eins zutrifft:

- Kern-/Geschäftslogik oder geteilter State betroffen
- öffentliche Schnittstellen, Persistenz-Formate, Migrationspfade
- Security-/Berechtigungsrelevantes (Keychain, Sockets, Subprozesse,
  Dateisystem außerhalb des Projekts)
- Warnsignale: unerwartete Dateien geändert, Tests
  abgeschwächt/gelöscht, Scope-Überschreitung, Ergebnis wirkt „zu glatt"
- der Task ließ Ermessensspielraum bei der Lösung

Nur triviale, eng gebriefte Tasks (Boilerplate, Doku, isolierte
Testdatei) kommen mit Diff + Tests durch.

## Bleibt beim Orchestrierungsmodell

- Architektur- und Scope-Entscheidungen
- unterspezifizierte Tasks — erst schärfen, dann abgeben
- Aufgaben, die tiefen Session-Kontext bräuchten, der teuer zu
  übergeben ist
- Kommunikation mit dem User
- **Commits und Pushes** (Gotcha „Kein Commit durch GPT-Agents" in
  codex-subagent): committet wird erst nach bestandenem Review-Gate.

## Fallback, wenn GPT nicht verfügbar

„Agent type 'gpt' not found" oder Backend aus → kurz melden (Diagnose:
gleichnamiges Gotcha in codex-subagent), dann ohne Rückfrage mit
Claude-Subagents weiterarbeiten, nicht automatisch über die CLI. Die Arbeit blockiert nie. Für detachte
Langläufer ersatzweise den CLI-Weg (`whisperm8 agent`) erwägen.

## Verifikation

Wenn Modell-Nachweis gebraucht wird: Gotcha „Modell-Nachweis" in
codex-subagent — Selbstauskunft ist wertlos, es zählen nur die
`"model"`-Felder im Session-JSONL.
