---
status: abgeschlossen
updated: 2026-07-18
description: Einstieg in die Umsetzungsphase nach Workflow 3 — verifizierte Feldvergleichs-Muster, Identitätsmodell als Kern-Umbau, Regressionsschutz-Vorgehen und Dokumentindex.
description_long: Synthese des Feldvergleichs von sieben Referenz-Repositories (agent-deck, superset, cmux, nimbalyst, claudecodeui, claude-code-log, claude-agent-sdk-python) nach adversarialer Schluss-Verifikation; leitet daraus den Identitätsmodell-Umbau für Fork/Resume und verlorene Chats sowie das Regressionsschutz-Vorgehen ab.
---

# Umsetzungsphase — Einstieg (Workflow 3)

Workflow 3 hat sieben Referenz-Repositories im Klon analysiert (je ein
Codex-Analyst pro Repo, ohne WhisperM8-Lesezugriff) und die Ergebnisse
anschließend adversarial gegen die Klone **und** gegen den echten
WhisperM8-Code verifiziert
([Schluss-Verifikation](../03-vergleich/code-analysen/verifikation-fable.md)).
Zitat-Fidelität der Analysen: 12 von 12 Stichproben wörtlich bestätigt; kein
Report empfiehlt einen SDK-/Eigen-Chat-UI-Umbau. Dieses Dokument fasst
zusammen, was davon in die Umsetzung geht — und was ausdrücklich nicht.

## 1. Kurzfazit Feldvergleich — übertragbare Muster

Nur Muster, die die Schluss-Verifikation als tragfähig bestätigt hat.
Das stärkste Qualitätssignal ist die Konvergenz: Alle sieben Quellen landen
unabhängig bei derselben Kernstruktur — **Wrapper-ID ≠ Claude-UUID ≠
Prozessinkarnation, plus Account-Scope; Identitätsübergänge geplant →
bestätigt.**

| # | Muster | Beleg | Übernahme |
|---|---|---|---|
| 1 | **Fork als zweiphasiger, verifizierter Identitätsübergang mit Parent-ID-Guard.** `claude --resume <parent> --fork-session` feuert SessionStart mit der **Eltern**-ID; die Fork-ID entsteht erst beim ersten UserPromptSubmit. | [cmux](../03-vergleich/code-analysen/cmux.md) (Guard-Code + CLI-Issue), [agent-deck](../03-vergleich/code-analysen/agent-deck.md) (persistiertes Fork-Datenmodell), [sdk-python](../03-vergleich/code-analysen/claude-agent-sdk-python.md) (Übergangstabelle, `forkedFrom`) | Datenmodell aus agent-deck (prepared → spawned → identityVerified → committed), Flag-Mechanik aus cmux (**ohne** `--session-id`-Vorvergabe) |
| 2 | **Drei getrennte Identitäten plus Account-Scope** (Chat-/Wrapper-ID, Claude-UUID, PTY-/Prozessinkarnation; Lookups nie ohne Config-Root-Filter). | Alle sieben Quellen unabhängig (agent-deck-Schema, superset-`terminalId`, cmux-Surface-Generation, claudecodeui-Zwei-Spalten-Modell, sdk-python-`SessionKey`) | Kern-Umbau, siehe Abschnitt 2 |
| 3 | **Autoritative Fehlerklassifikation statt Heuristik:** „session expired" nur bei eindeutigem CLI-Fehler; JSONL-Miss ist Soft-Signal; nur eindeutige JSONL-Kandidaten binden; Zwei-Pass-Schonfrist vor destruktivem Aufräumen; Katalog gegen read-only-Wahrheit reconciliieren (`missing`/`discovered` statt Löschen). | [nimbalyst](../03-vergleich/code-analysen/nimbalyst.md) (Zustandstabelle, verifizierte Selbstkorrektur), [superset](../03-vergleich/code-analysen/superset.md) (Reaper), cmux/agent-deck, sdk-python | Fehler-Zustandstabelle in den Indexer/Coordinator übernehmen |
| 4 | **Dubletten-Merge zwischen Watcher und Hook-Bindung:** Zwei-Spalten-Identität und transaktionales Merge, wenn der JSONL-Watcher die Session vor der Hook-Bindung anlegt; `subagents/`-Pfade beim Scan ausfiltern, sonst überschreibt Subagent-JSONL den Pfad der Hauptsession. | [claudecodeui](../03-vergleich/code-analysen/claudecodeui.md); Negativreferenz [nimbalyst](../03-vergleich/code-analysen/nimbalyst.md) (Import-Dublette durch App-ID-only-Upsert) | Direkt prüfenswert für `AgentSessionIndexer` + Hook-Bridge |
| 5 | **Adoption statt Doppel-Spawn** nach Host-Neustart; Initialkommando nach Adoption nie erneut senden; persistente Terminal-Identität. | [superset](../03-vergleich/code-analysen/superset.md) (wörtlich verifiziert inkl. E2E-Test) | Als Prinzip für die Terminal-Snapshot-Roadmap; **nicht** als Broker-Neubau (siehe unten) |
| 6 | **Transcript-Robustheit:** `uuid`/`parentUuid`-DAG mit Reparatur (fehlender Parent → Root, Zyklen brechen), `compact_boundary` = Multi-Root **derselben** Session (kein Sessionwechsel!), Tool-Korrelation über `(session_id, tool_use_id)` statt Nachbarschaft. | [claude-code-log](../03-vergleich/code-analysen/claude-code-log.md), branch-bewusstes Lesen aus [sdk-python](../03-vergleich/code-analysen/claude-agent-sdk-python.md) | `ClaudeTranscriptReader`-Härtung |
| 7 | **Quick-Win Flag-Härtung:** `--resume=<uuid>` in equals-Form statt zwei Tokens (Injection-Schutz) plus UUID-Validierung von IDs, die aus Hook-Events gebunden werden. | [sdk-python](../03-vergleich/code-analysen/claude-agent-sdk-python.md) + eigener Verifikationsbefund gegen WhisperM8 | Sofort umsetzbar, klein, unabhängig vom Umbau |

**Nicht übernehmen** (von der Verifikation als fragwürdig markiert):

- **`--session-id`-Vorvergabe** (agent-deck-Fork-Kommando, nimbalyst-Fresh-Start):
  kollidiert frontal mit WhisperM8s Weg-B-Entscheidung
  (`AgentCommandBuilder.swift:353-358` dokumentiert `--session-id` als Wurzel
  der „No conversation found"-Fehler). Nur nach erneuter Verifikation gegen die
  aktuelle CLI-Version — sonst cmux-Variante ohne Pinning.
- **Externer PTY-Broker als P1** (superset): constraint-konform, aber de facto
  ein Terminal-Stack-Neubau in Spannung zur gewählten
  Terminal-Snapshot-Strategie (f448e02/a26d29f). Grundsatzentscheidung /
  Fernziel, kein übertragbares Muster.
- **SDK-Pfad-Mechaniken** (nimbalyst-SDK-Provider, claudecodeui-Runtime,
  sdk-python-Transport): ausschließlich als **Invarianten-Norm** verwenden,
  nie als Mechanik-Vorlage. Nimbalysts echter CLI-Pfad hat selbst **kein**
  Fork-Muster.
- **claude-code-log-Fixture-/Inkremental-Vorschläge**: Analysten-Eigenleistung
  ohne Klon-Beleg — als Idee brauchbar, nicht als „so macht es die Referenz".
- **Offline-Fork des SDK** (UUID-Neuschreibung): schreibende Operation auf
  Transcript-Daten; für WhisperM8 bleibt `~/.claude/` read-only. Nur das
  `forkedFrom`-**Lesen** ist übertragbar.

## 2. Kern-Umbau: das Identitätsmodell

Der konkreteste Befund des gesamten Vergleichs betrifft WhisperM8 direkt:
`bindExternalSessionID` (`AgentSessionStatusCoordinator.swift:345-367`) bindet
beim SessionStart-Hook **jede** gemeldete ID ohne Fork-Guard. Trifft das von
cmux dokumentierte CLI-Verhalten zu, bindet ein Fork die **Eltern-ID** an den
Fork-Chat — jeder spätere Resume öffnet dann den Elternzweig (Workflow-3-Risiko
2). Solange Prozess, Workspace und Claude-Session in einem einzigen
„Chat"-Status vermischt bleiben, sind verlorene Chats und Resume in den
falschen Zweig strukturell möglich.

### Ziel-Datenmodell

Ein langlebiger Binding-Datensatz pro Chat mit mindestens: Provider,
Config-Root (`CLAUDE_CONFIG_DIR` / Account), Session-ID, Eltern-/Root-ID
(Fork-Lineage), autoritativer `transcript_path`, aktuelles cwd, Workspace-ID,
letzte Dateigröße/MTime, Lifecycle-Zustand.

### Grundregeln

1. **Absicht ≠ Identität.** Launch-Argumente (`--resume`, `--fork-session`)
   beschreiben die Absicht. Identität kommt ausschließlich aus einer
   autoritativen Quelle (Hook-Event, validierte JSONL) und wird vor dem Binden
   verifiziert (UUID-Format, Datei existiert, cwd plausibel).
2. **Fork ist zweiphasig.** prepared → spawned → identityVerified → committed.
   SessionStart-Events während eines Fork-Launches **nicht** binden; die
   Child-ID erst über UserPromptSubmit bzw. neue JSONL bestätigen, dann
   Ziel-ID, Transcriptpfad und Lineage **atomar** umhängen. Der Elternzweig
   bleibt auffindbar; die UI zeigt „Fork von …".
3. **Kein `--session-id`-Pinning.** Weg B bleibt: Claude vergibt die ID,
   WhisperM8 bindet nach — jetzt auch beim Fork.
4. **Forks entstehen auch zur Laufzeit** (`/branch`, `/rewind`): nicht nur
   Startflags beobachten, sondern Hook-/Transcript-Identität während der
   Session neu abgleichen.
5. **Ein Writer pro `(configRoot, sessionID)`.** Paralleles Resume derselben
   ID interleaved die Session; zweiter Attach heißt bewusst forken
   (Writer-Lease).
6. **„Chat verloren" ist kein Einzelzustand.** Mindestens sieben Fälle trennen
   (siehe [workflow3-kandidaten.md](../03-vergleich/workflow3-kandidaten.md)
   §3.3): gebunden / verborgen (Picker-Filter) / verwaist (cwd- oder
   Config-Root-Wechsel) / logisch unvollständig (Compact, Parent-Chain) /
   Fork-Bindung veraltet / temporär unlesbar (Tail) / wirklich gelöscht
   (Retention, Purge). Der eigene Index löscht nie still aufgrund eines
   einzelnen negativen Scans; `~/.claude/` bleibt read-only.
7. **Quick-Win vorziehen:** equals-Form `--resume=<uuid>` + UUID-Validierung
   beim Binden — unabhängig vom Umbau, sofort.

### Vorbedingung vor dem Fix

Das cmux-Verhalten („Fork-SessionStart meldet die Parent-ID") ist im Klon nur
über Kommentar, Guard-Implementierung und Issue-Link belegt. Vor der Umsetzung
einmal gegen die installierte CLI-Version reproduzieren: Fork starten,
Hook-Event-File ansehen, Verhalten protokollieren.

## 3. Regressionsschutz-Vorgehen

Befund aus Runde 2
([runde2-tests-qualitaet-codex.md](../02-findings/runde2-tests-qualitaet-codex.md)):
**0 von 16** verifizierten Findings haben einen vollständigen Regressionstest.
Der Identitäts-Umbau berührt genau die Pfade, die heute am schlechtesten
abgesichert sind. Deshalb gilt: **erst Ist-Verhalten festhalten, dann umbauen.**

### Vorgehen

1. **Feature-Inventar** aller Agent-Chats-Verhalten erstellen (Quelle: die
   neun Subsystem-Karten in `01-subsysteme/`), jedes Verhalten einer Kategorie
   zuordnen:
   - **Kategorie 1 — vom Identitäts-Umbau direkt berührt:** Spawn/Resume/
     Bindung (`AgentCommandBuilder`, `bindExternalSessionID`), Hook-Bridge,
     Indexer-Merge und Dubletten-Behandlung, Statusableitung
     (working/awaitingInput/idle), Session-Wiederfinden nach Neustart,
     Fork-/Branch-Verhalten, Account-/Profilwechsel.
   - **Kategorie 2 — angrenzend:** Terminal-Lifecycle und Snapshots,
     Tab-/Fenster-Bindung an Session-IDs, Auto-Naming, Diktat-Routing in
     aktive Chats, Background-Agents.
   - **Kategorie 3 — unabhängig:** Diktat-Pipeline im Übrigen, Output-Modi,
     Settings.
2. **Test-Specs für Kategorie 1 VOR dem Umbau** schreiben und als Tests
   ausführbar machen: Das dokumentierte Ist-Verhalten ist das Oracle; wo ein
   Test das Soll-Verhalten (Fork-Guard) beschreibt, wird er als
   erwartet-fehlschlagend markiert, bis der Umbau ihn grün macht. Kategorie 2
   erhält Specs vor dem Umbau, Tests spätestens mit der jeweiligen Welle;
   Kategorie 3 bleibt bei bestehender Suite + manueller QA.
3. **Infrastruktur:** die W0.1-Oracles der
   [Roadmap](../05-roadmap/refactor-roadmap.md) (Fake-Home, ManualClock/
   Sleeper, ProcessRunner-Spy, kontrollierbare File-Events) sind Voraussetzung —
   Hook-Events, JSONL-Fixtures und Fork-Sequenzen müssen ohne echte CLI
   simulierbar sein. Testkonvention bleibt DI über Closures/Kleinprotokolle.
4. **Gates:** die verbindlichen Leitplanken der Roadmap gelten unverändert
   (Regressions-Gate pro Maßnahme, exklusive Datei-Ownership, Verhaltens-
   Oracles vor Refactor, `~/.claude/`/`~/.codex/` read-only — auch in Tests
   nur über Fixtures im Fake-Home).

## 4. Dokumente (Workflow 3)

| Dokument | Inhalt |
|---|---|
| [workflow3-kandidaten.md](../03-vergleich/workflow3-kandidaten.md) | Kandidaten-Ranking, Claude-Code-Interna, Edge-Case-Landkarte (Fork/Resume/„verloren"), Robustheitsregeln |
| [code-analysen/agent-deck.md](../03-vergleich/code-analysen/agent-deck.md) | First-Class-Fork-Datenmodell, drei Identitäten, `CLAUDE_CONFIG_DIR`-Gruppen, UPSERT-Persistenz |
| [code-analysen/superset.md](../03-vergleich/code-analysen/superset.md) | PTY-Adoption nach Host-Neustart, persistente Terminal-Identität, Zwei-Pass-Reaper, Statusentkopplung |
| [code-analysen/cmux.md](../03-vergleich/code-analysen/cmux.md) | Fork-SessionStart-Guard (Parent-ID-Problem), Surface-ID ≠ Runtime-Generation, Hook-first/OSC-Fallback |
| [code-analysen/nimbalyst.md](../03-vergleich/code-analysen/nimbalyst.md) | Resume-Fehlerklassifikation („session expired" nur autoritativ), Import-Dubletten-Lücke, Fokus-Gating |
| [code-analysen/claudecodeui.md](../03-vergleich/code-analysen/claudecodeui.md) | Zwei-Spalten-Identität, transaktionales Dubletten-Merge, Subagent-Filter beim Scan |
| [code-analysen/claude-code-log.md](../03-vergleich/code-analysen/claude-code-log.md) | `uuid`/`parentUuid`-DAG mit Reparatur, `compact_boundary`-Semantik, Tool-Korrelation |
| [code-analysen/claude-agent-sdk-python.md](../03-vergleich/code-analysen/claude-agent-sdk-python.md) | Normative Übergangstabelle Neu/Resume/Continue/Fork, `forkedFrom`, Flag-Härtung, branch-bewusstes Lesen |
| [code-analysen/verifikation-fable.md](../03-vergleich/code-analysen/verifikation-fable.md) | Adversariale Schluss-Verifikation aller sieben Analysen; tragfähige vs. fragwürdige Muster |
| [claude-session-manager.md](../03-vergleich/claude-session-manager.md) · [claude-cli-oekosystem.md](../03-vergleich/claude-cli-oekosystem.md) | Runde-1-Vorarbeiten, die Workflow 3 vertieft |
| [../05-roadmap/refactor-roadmap.md](../05-roadmap/refactor-roadmap.md) | Umsetzungswellen und Regressions-Gates aus dem Gesamtaudit — der Identitäts-Umbau fügt sich hier ein |
