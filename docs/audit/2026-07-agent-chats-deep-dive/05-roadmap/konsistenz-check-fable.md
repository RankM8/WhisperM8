---
status: aktiv
updated: 2026-07-18
description: Konsistenz-Check der Roadmap gegen Verdicts (Runde 1+2) und Plan-Review — priorisierte Mängelliste plus Bestätigung des Stimmigen.
description_long: Prüft die vier Prüffragen (verworfene Findings, eingearbeitete NACHBESSERN-Hinweise, Dokument-Widersprüche, Wellen-Ownership) über refactor-roadmap.md, verdicts.md, verdicts-runde2.md und plan-review.md.
---

# Konsistenz-Check der Refactor-Roadmap (Fable)

Geprüfte Dokumente: [`refactor-roadmap.md`](refactor-roadmap.md),
[`verdicts.md`](../04-verifikation/verdicts.md),
[`verdicts-runde2.md`](../04-verifikation/verdicts-runde2.md),
[`plan-review.md`](plan-review.md); Stichproben in `02-findings/` und `README.md`.

**Gesamturteil:** Die Roadmap selbst ist sauber gegen beide Verdict-Runden
konsolidiert — alle C01–C16 und N01–N16 sind lückenlos Maßnahmen zugeordnet,
alle VERWERFEN-/veraltet-Urteile sind in der Roadmap gestrichen. Die Mängel
liegen fast ausschließlich **zwischen** den Dokumenten: das Plan-Review führt
das verworfene P0.8 weiter, zwei von ihm geforderte Postprocessing-Blocker sind
nie verifiziert oder verplant worden, und drei Dokumente beschreiben drei
verschiedene Wellen-Zuordnungen, ohne dass eines als maßgeblich markiert ist.

## Priorisierte Mängelliste

### M1 (hoch) — Plan-Review führt das verworfene P0.8 als offene Maßnahme weiter

`verdicts-runde2.md` (Teil B) urteilt für P0.8 **VERWERFEN**; die Roadmap hat es
korrekt gestrichen („Gestrichene Maßnahme“). Das Plan-Review enthält P0.8 aber
weiterhin an vier Stellen als lebende Maßnahme:

- Abschnitt 1, Tabelle: „P0.8 Save-Deadline — **auf P1 absenken**“ (statt streichen);
- Quick Win 2: „erst danach P0.8 `maxInterval` ergänzen“;
- Risikotabelle Abschnitt 5: eigene P0.8-Zeile mit Gate;
- Welle 4 (Abschnitt 6): „C11 monotone Workspace-Publikation **und P0.8
  Save-Deadline mit Retry-Vertrag**“.

Wer der empfohlenen Umsetzungsreihenfolge des Plan-Reviews folgt, würde die
verworfene Maßnahme wieder einführen. Das Plan-Review entstand vor dem
Runde-2-Verdict, trägt aber weder Nachtrag noch Historisch-Vermerk.
**Fix:** Plan-Review mit einem P0.8-Nachtrag versehen oder die betroffenen
Stellen als „durch Runde 2 überholt, siehe Roadmap“ markieren.

### M2 (hoch) — Zwei vom Plan-Review geforderte Release-Blocker sind weder verifiziert noch verplant

Das Plan-Review verlangt (Abschnitt 1, „Fehlende P0-Kandidaten“) einen
Refuter-Durchgang u. a. für den **Postprocessing-Kernvertrag**
(`runde2-postprocessing-codex.md` F1/F3/F7) mit anschließendem expliziten
Status je Cluster. Davon wurde nur F7 verifiziert (→ N03, Maßnahme R2.2):

- **F1 — Codex-Postprocessing ohne Deadline/Kill-Pfad** (Diktatpfad:
  `CodexSupport.swift`, `CodexPostProcessor.swift`): kein N-Verdict, keine
  Roadmap-Maßnahme. R2.4/P1.1 decken nur Subagent-Supervisor bzw.
  Environment ab, nicht den Diktat-Postprocessing-Lauf.
- **F3 — Task-Modus verspricht Ausführung, läuft aber read-only**: kein
  N-Verdict, keine Roadmap-Maßnahme.

Gleichzeitig behauptet die Roadmap (Z. 10): „Grundlage sind **alle Findings**
aus `02-findings/`“ — exakt der Vollständigkeitsanspruch, den das Plan-Review
bereits als Hauptproblem kritisiert hat. Die dort geforderte
**Finding→Verdict→Maßnahme-Matrix** existiert nicht (kein Dokument im Audit
enthält sie); ebenso fehlen in der Roadmap zwei weitere Plan-Review-Quick-Wins:
die drei hohen Lifecycle-Leaks aus `memory-lifecycle-codex.md` (Quick Win 8)
und die OSC-8-Härtung (Quick Win 6; OSC taucht in der Roadmap nur als
„Später“-Tech-Entscheidung für 133/99/9/777 auf).
**Fix:** F1/F3 nachverifizieren und einplanen oder mit Grund zurückstellen;
Matrix als Scope-Quelle nachliefern; „alle Findings“ in der Roadmap-Einleitung
präzisieren.

### M3 (mittel–hoch) — Drei verschiedene Wellen-Zuordnungen ohne maßgebliche Quelle

Die drei Dokumente widersprechen sich in der Einsortierung mehrerer Maßnahmen:

| Maßnahme | verdicts-runde2 (Teil B) | plan-review (Abschn. 6) | refactor-roadmap |
|---|---|---|---|
| P0.5 | Welle 1 | Welle 2 (Session-Owner) | Welle 2 |
| P1.6+P1.7+P1.9 | Welle 1 | Welle 3 („können parallel laufen“) | Welle 1 |
| P0.7 vs. P2.1 | — | **P2.1 vor P0.7**, beide Welle 2 | P0.7 Welle 2, **P2.1 erst Welle 4** |
| P1.4-Aktivierung | Welle 2–3 | eigene Stufe in Welle 3 | im Welle-2-Bündel („erst danach aktivieren“) |
| P1.11 | Welle 4 | Welle 4 | Welle 3 |
| P0.8 | Welle 1 (verworfen) | Welle 4 | gestrichen |

Teil B benutzt zudem noch die alten Wellen-Namen („Crash & Quick Wins“,
„Datenintegrität & Claude-Erlebnis“ …), die es in der konsolidierten Roadmap
nicht mehr gibt. Inhaltlich am schwersten wiegt **P2.1 vs. P0.7**: Das
Plan-Review empfiehlt den mechanischen Terminal-Split *vor* dem
Teardown-Umbau, die Roadmap macht es umgekehrt — das ist eine echte
Reihenfolge-Entscheidung, kein Dokumentationsdetail.
**Fix:** Roadmap explizit als maßgebliche Reihenfolge deklarieren (in
verdicts-runde2 Teil B und plan-review je einen Verweis „Wellen-Angaben
historisch, gültig ist refactor-roadmap.md“) und die P2.1/P0.7-Reihenfolge
bewusst entscheiden und begründen.

### M4 (mittel) — Datei-Überlappungen innerhalb derselben Welle ohne festgelegte Serialisierung

Die Leitplanke „ein Owner je Cluster und Welle, überlappende Maßnahmen seriell“
existiert, aber die Roadmap legt bei folgenden Same-Wave-Überlappungen keine
Reihenfolge fest:

- **Welle 2:** R2.5 (Identitätsprüfung vor `terminate()`) und P0.7+P1.12
  (Teardown-Zustandsautomat) ändern beide den `terminate()`-Pfad in
  `Views/AgentTerminalView.swift`. Sinnvoll wäre, R2.5 als Zustand *im*
  P0.7-Automaten zu spezifizieren statt als getrennten Eingriff.
- **Welle 3:** P1.10(3) (geteilter Scroll-Monitor) und T1 (Terminal-Recording)
  treffen beide `AgentTerminalView.swift`; P1.10(1) (ISO8601-Formatter) und
  P1.11 treffen beide `CodexTranscriptReader.swift`.
- **Welle 4:** P2.1 („AgentCommandBuilder als Consumer berücksichtigt“) und
  P2.5+P2.6 (AgentCommandBuilder von `CodexStatusProbe` lösen) treffen
  dieselbe Datei; P2.2 (View-Extension-Extraktion) und P2.7 (~570-LOC-Reduktion)
  treffen beide die `AgentChatsView`-Familie.
- **Welle 1:** R2.4, P1.1 und P0.4a liegen alle beim Prozess-Owner; P0.4a setzt
  faktisch die P1.1-Environment-Fabrik voraus, ohne dass die Roadmap diese
  Intra-Wellen-Reihenfolge nennt (bei P1.5+P1.8 → P1.10(4) tut sie es vorbildlich).

**Fix:** Pro Welle die serielle Reihenfolge der überlappenden Maßnahmen
benennen (ein Satz je Cluster genügt).

### M5 (niedrig–mittel) — P1.11-FEHLER-Verdict nur teilweise aufgelöst

`verdicts-runde2.md` verlangt für P1.11 ausdrücklich einen **eigenen
Nachverifikations-Lauf** (leere Begründung/jobId). Die Roadmap begrenzt den
Umfang stattdessen auf die bestätigten N15/N16 — nimmt aber weiterhin
unverifizierte Alt-Bestandteile mit (Golden-Korpus für `/cd`,
Resume-ID-Rotation, Interleaving). Das ist vertretbar, aber die geforderte
Nachverifikation ist nirgends als erledigt oder bewusst ersetzt dokumentiert.
**Fix:** Entweder Kurz-Nachverifikation der Restpunkte oder ein expliziter
Vermerk „Restumfang bewusst ohne Einzel-Verdict, gedeckt durch N15/N16-Gates“.

### M6 (niedrig) — Quit-Pfad wird in zwei Wellen nacheinander umgebaut

R2.1 (Welle 1) definiert die `.terminateLater`-Koordination von Recorder **und
Terminal** in `WhisperM8App.swift`; P0.7 (Welle 2) ordnet den
Terminal-Teardown inklusive App-Quit danach neu. Die Welle-1-Koordination baut
damit auf dem Teardown auf, der eine Welle später ersetzt wird — das
Plan-Review wollte Quit-Recovery „nur nach abgestimmtem
App-Termination-Contract“. Kein Widerspruch, aber ein absehbarer
Doppelumbau; ein gemeinsamer Termination-Contract-Absatz (wer wartet auf wen)
würde das entschärfen.

## Bestätigung des Stimmigen

1. **Kein verworfenes Finding als offene Maßnahme in der Roadmap:** P0.8 ist
   gestrichen und korrekt als Testbarkeitsdetail deklariert; der
   „Dateisystem-als-Registry“-Punkt (P2.8b), der pauschale `/`-Prune (P0.4)
   und der veraltete zweite Load→Index→Save-Pfad (P1.10 b) sind ebenfalls
   entfernt — deckungsgleich mit den Runde-2-Urteilen.
2. **Vollständige Verdict-Abdeckung:** Alle 16 C-Findings (C01→P0.1/P0.2,
   C03→P0.3, C04→P0.5, C05→P0.4a/b, C06→P1.1, C07→P0.6, C08→P1.2, C09→P1.3,
   C10→P0.7, C11→P1.10(4), C12→P1.5, C13→P1.6, C14→P1.7, C15→P1.8, C16→P1.9)
   und alle 16 N-Findings (N01→R2.5, N02→R2.1, N03/N04→R2.2, N05/N06→R2.3,
   N07/N08/N14→R2.4, N09/N10→P1.1, N11→R2.6, N12/N13→R2.7, N15/N16→P1.11)
   haben genau eine Maßnahme; Schweregrade und Fundorte stimmen zwischen
   Verdicts und Roadmap überein.
3. **NACHBESSERN-Hinweise der Plan-Verifikation sind eingearbeitet** (16 von
   16 Paketen nachvollziehbar): u. a. enger Fehlervertrag statt `throws`-Brücke
   (P0.1/P0.2), kein pauschales `@MainActor` + indirekter Preference-Read
   (P0.3), Prävention/Migration-Split (P0.4a/b), `createdAt` ≠ Launch-Zeitpunkt
   und Doppel-Row-Repair (Welle-2-Bündel), `SupervisorJobReader`-Profil-Root
   (P1.1), Diktat-Hotpath + Revisionsschutz vor Off-Main-Merge (P1.5+P1.8),
   Formatter-Paar mit/ohne Fractional Seconds (P1.10), `AgentCommandBuilder`
   als P2.1-Consumer, atomares Apply (P2.3), „28 statt 29“ (P2.5/P2.6),
   570-LOC-Vorreduktion vor CI-Gate (P2.7) und die Aufspaltung von P2.8a/b.
4. **Einschränkungen aus Runde 1 korrekt übernommen:** C03 als Härtung statt
   Crash-Fix, C16 als „unbounded nur im Miss-Fall“ — beides so in P0.3 bzw.
   P1.9 formuliert.
5. **Tech-Entscheidungen konsistent** über README, Roadmap und Plan-Review
   (Swift-6.3-Baseline vor Isolation, `agents --json` nach
   Environment-Propagation, Recording vor Broker, OSC nachrangig,
   `swift-subprocess` später).
6. **Traceability-Teilfix:** Der im Plan-Review bemängelte README-Stand
   (01-subsysteme „leer“) ist behoben; README verlinkt den vollständigen
   Bestand und beschreibt beide Runden korrekt (32/32 bestätigt).
