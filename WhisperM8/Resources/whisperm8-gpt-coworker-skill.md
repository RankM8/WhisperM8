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

- **GPT 5.6 (gpt-5.6-sol) ist bei klar definierten Tasks ≈ Fable-Niveau
  und über Opus.** Wo du sonst einen Opus/Sonnet-Subagent nehmen würdest,
  ist GPT die bessere Wahl.
- **GPT hat deutlich höhere Limits als Claude.** Lieber ein GPT-Agent zu
  viel als zu wenig: Zweitmeinungen, parallele Reviews und
  Planungs-Perspektiven kosten praktisch nichts, schonen aber
  Claude-Limits und Main-Kontext.

## Harte Default-Regel: Subagent = GPT

Für jeden Subagent-Spawn mit klar definiertem Auftrag gilt
`subagent_type: "gpt"` als Standard. Claude-Subagents (Fable/Opus/Sonnet)
nur mit explizitem Grund — z. B. wenn bewusst ein *Claude*-Zweiturteil
gegen einen GPT-Befund gewünscht ist oder es um Claude-spezifisches
Verhalten geht. Der `model`-Parameter des Agent-Tools kann KEIN GPT
(Whitelist) — GPT geht nur über den Agent-TYP.

## Delegations-Reflex

Prüfe bei **jedem Arbeitspaket** zuerst: „Kann das ein GPT-Agent
selbst-contained erledigen?" Gut abgebbar:

- **Implementierung** klar spezifizierter Tasks — GPT hat volles
  Schreibrecht im Working Tree, inkl. Tests laufen lassen.
- **Reviews** (Code, Pläne, Diffs) — default 2 unabhängige Reviewer.
- **Planung** — 2–3 parallele GPT-Perspektiven statt einer eigenen.
- **Zweitmeinungen** — parallel zur eigenen Arbeit starten, nicht danach.
- **Recherche/Exploration** in Code oder Doku, deren Ergebnis sich in
  wenigen Absätzen zurückmelden lässt (spart Main-Kontext am meisten).

**Briefing-Pflicht:** Delegation lohnt nur mit selbst-containedem
Auftrag — betroffene Dateien/Pfade, Akzeptanzkriterien, Testbefehl,
relevante Konventionen (z. B. CLAUDE.md-Regeln des Repos) gehören ins
Briefing. Wenn das Briefing länger würde als die Arbeit selbst: nicht
delegieren, sondern selbst machen. Kein Delegations-Theater.

**Ergebnis-Meldepflicht:** Jeden GPT-Agent explizit instruieren, sein
Resultat in der finalen Antwort zu liefern — sonst enden manche mit
bloßer Idle-Meldung (bekanntes Gotcha, siehe codex-subagent).

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
- **Commits und Pushes — GPT-Agents committen/pushen NIE.** Committet
  wird erst nach bestandenem Review-Gate.

## Fallback, wenn GPT nicht verfügbar

„Agent type 'gpt' not found" oder Backend aus → kurz melden (mit
Ursache: Registry lädt nur beim Session-Start; `ANTHROPIC_BASE_URL`
muss auf den lokalen Router zeigen — Details in codex-subagent), dann
ohne Rückfrage mit Claude-Subagents weiterarbeiten. Die Arbeit blockiert
nie. Für detachte Langläufer ersatzweise den CLI-Weg (`whisperm8 agent`)
erwägen.

## Verifikation

Selbstauskunft der Agents ist wertlos (sie halten sich für
Claude/Opus). Wenn Modell-Nachweis gebraucht wird: `"model"`-Felder im
Session-JSONL prüfen (Details in codex-subagent).
