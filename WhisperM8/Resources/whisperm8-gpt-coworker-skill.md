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

- **Das neueste Codex-Modell (`auto`, derzeit GPT-6 Astra) ist bei klar
  definierten Tasks ≈ Fable-Niveau und über Opus.** Wo du sonst einen Opus/Sonnet-Subagent nehmen würdest,
  ist GPT die bessere Wahl.
- **GPT hat deutlich höhere Limits als Claude.** Lieber ein GPT-Agent zu
  viel als zu wenig: Zweitmeinungen, parallele Reviews und
  Planungs-Perspektiven schonen Claude-Limits und Main-Kontext. Gratis
  sind sie nicht — der Fast-Default läuft im Priority-Tier mit 2,5×
  ChatGPT-Credits (Gotcha „Kosten" in codex-subagent): bei größeren
  Fan-outs die Agent-Spanne nennen, sinnlose Doppel-Spawns vermeiden.

## Beobachtungen aus der Praxis (laufend nachführen)

**Stand 29.09.2026, ListM8-Merge-Reife (hunderte Review-/Fix-Agenten):**

- **GPT ist deutlich langsamer** als Sonnet 5.5 — bei gleichem Prüfauftrag
  merklich längere Laufzeit.
- **Sonnet 5.5 (effort high) war als Gegenprüfer klar stärker:** Im direkten
  Vergleich auf denselben Plan fand Sonnet 5 Faktenfehler (GPT 1) und 8 fehlende
  Punkte (GPT 6), rechnete Behauptungen am Repo nach statt sie zu übernehmen und
  entdeckte als Einziger den relevantesten Punkt (develop mit neuem
  Akquise-Mandanten weiter). GPT ergänzte andere Prozess-Aspekte — kombiniert
  am besten. Datenbasis noch klein (1 Direktvergleich + 1 Gegenprüfwelle).
- **GPT prüft GPT übersieht systematisch:** Eine Opus-Abnahme fand nach
  GPT-Umsetzung + GPT-Zweitprüfung noch 10 Punkte in einer Welle. Zweitprüfung
  daher immer durch ein anderes Modell (Sonnet/Opus).
- **Tempo gemessen (29.09.):** Gegenprüfung von 57 Paketen (366 Befunde) mit
  Sonnet 5.5 high: 9 Minuten, 0 Fehler. Vergleichbare GPT-Gegenprüf-Läufe
  (W2/W3) brauchten 50–100 Minuten. Verwerfungsquote ähnlich (Sonnet 8 %,
  GPT 7–8 %), Sonnet stufte aber deutlich mehr Schweregrade realistisch herab
  (105 von 366 auf niedrig).
- **Zweite Meinung zu GPT-Gegenprüfungen (29.09.):** Sonnet 5.5 high prüfte 327
  von GPT bereits bestätigte Befunde erneut: 22 widerlegt (7 %), 63 in der
  Schwere herabgestuft (GPT stuft tendenziell zu hoch ein: 37 von 114 „hoch“
  sind nach Sonnet mittel/niedrig). Umgekehrt waren GPTs Verwerfungen
  verlässlich: 77 von 78 hielt Sonnet ebenfalls für unbegründet.
- **Verbrauch:** Sonnet 5.5 belastete die Claude-Limits in diesen Läufen
  spürbar weniger als erwartet.
- **Gotchas im Workflow-Betrieb:** Nachrichten an laufende Workflow-Agenten
  starteten eine zweite Instanz; zweimal beantworteten GPT-Agenten eine
  Chatnachricht des Users statt ihres Auftrags — trotz Schutzsatz. Nachrichten der Hauptsitzung gelangen in
  laufende Workflow-Agenten — am 29.09. auch in einen Opus-Umsetzer belegt, also
  modellunabhängig. Deshalb Ergebnis immer auf Vollständigkeit prüfen
  (je ID ein Urteil) und bei Lücken mit einem Claude-Modell nachprüfen.

Folgerung (vom User am 29.09. bestätigt): **Sonnet 5.5 high macht die Hauptarbeit**
(Reviews, Fixes), **GPT ist die unabhängige Zweitmeinung** (Gegenprüfung),
Opus für Kernpfade, Schiedsrichter und Abnahme. Nie prüft das bauende Modell.
Weitere Vergleiche hier nachtragen; die Arbeitsannahme oben ggf. anpassen.

## Harte Default-Regel: Subagent = GPT

Für jeden Subagent-Spawn mit klar definiertem Auftrag gilt
`subagent_type: "gpt"` als Standard. Claude-Subagents (Fable/Opus/Sonnet)
nur mit explizitem Grund — z. B. wenn bewusst ein *Claude*-Zweiturteil
gegen einen GPT-Befund gewünscht ist oder es um Claude-spezifisches
Verhalten geht. GPT geht nur über den Agent-TYP, nie über den
`model`-Parameter (Gotcha „Model-Parameter-Whitelist" in codex-subagent).

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

**Ergebnis-Meldepflicht** (Gotcha in codex-subagent): das Resultat
immer in der finalen Antwort einfordern.

**Kontextbudget:** GPT-Subagents aus einer Claude-Main-Session haben nur
das 200k-Fenster, ~177k nutzbar (272k/900k gibt es nur in GPT-gestempelten
Main-Sessions — Gotcha „Kontextfenster" in codex-subagent). Große Scopes
vor der Delegation splitten; Diffs und Dateien im Briefing referenzieren
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
Claude-Subagents weiterarbeiten. Die Arbeit blockiert nie. Für detachte
Langläufer ersatzweise den CLI-Weg (`whisperm8 agent`) erwägen.

## Verifikation

Wenn Modell-Nachweis gebraucht wird: Gotcha „Modell-Nachweis" in
codex-subagent — Selbstauskunft ist wertlos, es zählen nur die
`"model"`-Felder im Session-JSONL.
