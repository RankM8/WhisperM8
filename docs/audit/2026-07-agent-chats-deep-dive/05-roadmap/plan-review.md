---
status: aktiv
updated: 2026-07-18
description: Review der Refactor-Roadmap mit korrigierter Priorisierung, Abhängigkeiten, Regressionsrisiken und agententauglichen Umsetzungswellen.
description_long: Bewertet den Plan als Ganzes gegen Verdicts, Findings und Technologievergleiche und schlägt eine konkrete, konfliktarme Reihenfolge für die Umsetzung vor.
---

# Plan-Review der Refactor-/Fix-Roadmap

## Gesamturteil

Die [Roadmap](refactor-roadmap.md) hat für die 16 adversarial verifizierten Claims eine
gute fachliche Basis, ist als **Gesamtplan des Audits** aber noch nicht ausführungsreif.
Ihr stärkster Teil ist die Zuordnung der bestätigten C01–C16 zu konkreten Maßnahmen. Ihr
größtes Problem ist die falsche Vollständigkeitserwartung: Die Einleitung spricht von
„allen Findings“, tatsächlich plant sie überwiegend die 16 ausgewählten Verdicts und
einige Architekturpunkte. Mehrere später dokumentierte kritische oder hohe Risiken aus
`02-findings/` fehlen vollständig.

Die fünf angegebenen Wellen sind außerdem zu breit für parallele Agents. Sie legen
mehrfach Maßnahmen mit denselben Kern-Dateien in verschiedene Wellen oder gleichzeitig
in eine Welle, ohne einen exklusiven Owner für diese Dateien vorzusehen. Das erzeugt
nicht nur Merge-Konflikte, sondern birgt das größere Risiko, dass zwei einzeln korrekte
Änderungen dieselbe Lifecycle- oder Zustandsinvariante unterschiedlich modellieren.

**Empfehlung:** Roadmap nicht verwerfen, sondern vor Umsetzung in drei Punkten
korrigieren:

1. P0 auf reale Release-Blocker begrenzen und zugleich die bisher ausgelassenen
   Datenverlust-, Supervisor-, Security- und Quit-Kandidaten in einem kurzen
   Verifikations-Gate nachziehen.
2. Maßnahmen nach Risiko-Clustern mit exklusiver Datei-Ownership statt nur nach
   Prioritätsnummern schneiden; Sammelmaßnahmen P1.10, P2.7 und P2.8 auflösen.
3. Die Tech-Empfehlungen als Architektur-Gates einbauen: Swift-6-Diagnostik vor
   Concurrency-Umbauten, offizielle Claude-Schnittstellen vor weiteren Disk-Heuristiken
   und Recording/Transport-Naht vor einem PTY-Broker.

### Traceability-Befund

Die Planungsgrundlage ist derzeit nicht konsistent versioniert: Der
[Audit-README](../README.md) bezeichnet `01-subsysteme/` noch als leer, obwohl dort neun
Kartierungen vorliegen, und die Roadmap nennt „alle Findings“, obwohl mehrere
Runde-2-Dateien nicht abgebildet sind. Vor Umsetzung sollte eine maschinenlesbare oder
tabellarische Finding→Verdict→Maßnahme-Matrix zur eigentlichen Scope-Quelle werden; die
Anzahl „16/16 bestätigt“ beschreibt nur die verifizierte Stichprobe, nicht die
Vollständigkeit des Audits.

## 1. Ist P0 wirklich P0?

P0 sollte hier bedeuten: **vor normaler Feature-Arbeit zu beheben**, weil ein
reproduzierbarer App-Abbruch, irreversibler Daten-/Credential-Verlust, falsche
Prozessidentität oder ein gebrochener Kernvertrag droht. „Bestätigt“, „hoch“ und „P0“
sind nicht dasselbe.

| Maßnahme | Review | Begründung / Korrektur |
|---|---|---|
| P0.1 Exception-Trampolin + Re-Check | **P0 behalten** | C01 ist kritisch und der gemeldete Vollabsturz ist plausibel erklärt. Mit P0.2 gemeinsam spezifizieren und testen. |
| P0.2 Re-Validierung nach `await` | **P0 behalten** | Erreichbarer Zombie-/Stale-State-Pfad; dieselbe Recorder-Generation wie P0.1 verwenden. |
| P0.3 Recorder-Isolation | **auf P1-Härtung absenken** | C03 ist ausdrücklich eingeschränkt; ein Actor-/MainActor-Umbau hat mehr Feature-Regressionsfläche als der akute Fix. Swift-6-Diagnostik vorher erfassen. |
| P0.4 Headless-Junk | **splitten** | **P0:** weitere Persistenz sofort stoppen (`--no-session-persistence`, explizites cwd/profilbewusstes Environment). **P1:** Bestand nur nach Backup, Dry-Run und referenziellem Check bereinigen; 495 Einträge pauschal zu löschen ist selbst ein Datenrisiko. |
| P0.5 Claude-CWD-Encoding | **P0 behalten, Lösung ersetzen** | Datenzugriff/Resume ist betroffen. Das Claude-Encoding nachzubauen bleibt jedoch versionsfragil. `SessionStart.transcript_path` und Launch-Intent müssen autoritativ werden; Encoder/Glob dienen nur Legacy-Discovery. Ein Account-Umzug darf erst nach Copy+Verify die Quelle entfernen. |
| P0.6 Bindung/Dedup | **P0 behalten** | Zwei Tabs dürfen nie dieselbe externe ID besitzen. Zeitfenster+Deduplizierung sind Defensive; atomarer Launch-Intent und ID-Lease gehören in dieselbe Invariante. |
| P0.7 PTY-Teardown | **auf P1-hoch absenken** | C10 ist real, aber der verpasste End-Snapshot ist nicht gleichbedeutend mit Verlust des Claude-Verlaufs. Mit dem fehlenden Quit-/Diktat-Recovery-Pfad und inkrementellem Recording bündeln. |
| P0.8 Save-Deadline | **auf P1 absenken** | Plausibel, aber nicht adversarial verifiziert; ein `maxInterval` erhöht Schreibfrequenz und Lock-/I/O-Druck. Zuerst Save-Fehler, Retry und Future-Schema-Schutz lösen. |

### Fehlende P0-/Release-Blocker-Kandidaten

Vor der ersten Implementierungswelle braucht es einen fokussierten Refuter-Durchgang für
die folgenden Befunde. Sie sind mindestens so gravierend wie mehrere heutige P0-Items:

- **Supervisor-Vertrag:** `runde2-cli-supervisor-codex.md` F1/F2 sind als kritisch
  eingestuft: vermeintliches Detach bleibt im Prozessbaum und Transportende/Exit 0 kann
  fälschlich Erfolg bedeuten. F3/F7/F8 ergänzen PID-Reuse, verlorenes Stop und fehlende
  Prozessgruppen-Eskalation. Das muss vor Ausbau von Background-Agenten geklärt werden.
- **Destruktive Persistenz/Migration:** `robustheit-codex.md` F1–F4 und
  `runde2-settings-migration-codex.md` F1–F4 beschreiben Future-Schema-Downgrade,
  Gesamt-Rebuild, UI-State-/Template-Überschreiben und Keychain-Verlust. P0.8 optimiert
  den Save-Takt, bevor die Semantik des Saves sicher ist.
- **App-Quit während Diktat:** `runde2-onboarding-permissions-codex.md` F1/F3 kann eine
  laufende Aufnahme nur im Temp-Verzeichnis zurücklassen und Recorder/UI
  desynchronisieren. Das ist näher an „Datenverlust“ als P0.7.
- **Security-Grenzen:** `runde2-security-codex.md` F1/F2 beschreibt Secret-Vererbung an
  untrusted Agent-/MCP-Code und OAuth-Secrets in Prozessargumenten. Diese Punkte sind
  Release-Blocker, auch wenn sie nicht in die Kategorie „Stabilität“ passen.
- **Postprocessing-Kernvertrag:** `runde2-postprocessing-codex.md` F1/F3/F7 betrifft
  unendliche Codex-Prozesse, einen Task-Modus, der entgegen seinem Versprechen read-only
  läuft, und einen Start-Crash durch doppelte Mode-IDs.

Nicht jeder dieser Befunde muss nach der Gegenprüfung P0 bleiben. Der Plan darf sie aber
nicht stillschweigend auslassen und gleichzeitig Vollständigkeit behaupten. Für jeden
Finding-Cluster braucht die Roadmap den Status `verifiziert`, `zurückgestellt mit Grund`,
`Duplikat` oder `Maßnahme`.

## 2. Abhängigkeiten und sinnvolle Bündel

### Harte Reihenfolge-Abhängigkeiten

1. **Verhaltens-Oracles vor Refactor:** Die in
   `runde2-tests-qualitaet-codex.md` benannten Lücken für Recorder, Terminal und die
   Pipeline Event→Scan→Bind→Watch→Status sind Schutzgates für P0.1/P0.2, P0.6/P1.2 und
   P0.7. Ohne diese Tests ist „volle Suite grün“ kein ausreichendes Signal.
2. **Swift-6-Diagnostik vor Isolation:** Zuerst stabile Swift-6.3-Toolchain im
   Swift-5-Sprachmodus und Complete Concurrency Checking als Baseline erfassen. Danach
   P0.3 bzw. andere Isolationen korrigieren. Keine Warnung durch pauschales
   `@unchecked Sendable` oder `nonisolated(unsafe)` wegdefinieren.
3. **Daten schützen, dann bereinigen:** Future-Schema-Gates, Quarantäne/Backups und
   Save-Fehler/Retry kommen vor P0.4-Bestandsbereinigung und vor schnellerer
   Save-Frequenz aus P0.8.
4. **Headless-Neuzuwachs stoppen, dann messen:** P0.4a vor Junk-Migration, P1.5- und
   P1.8-Benchmarks. Sonst optimiert man gegen einen sich weiter verändernden Bestand.
5. **Profil-Environment vor Background-SSoT:** P1.1 bzw. eine gemeinsame
   profilbewusste Environment-Fabrik muss vor `claude agents --json` stehen, weil der
   Supervisor pro `CLAUDE_CONFIG_DIR` getrennt ist.
6. **Autoritative Bindung vor selbstvergebener ID:** Launch-Intent,
   `SessionStart.session_id` + `transcript_path`, globale ID-Lease und sichtbarer
   Recovery-Zustand (P0.5/P0.6/P1.3) müssen stabil sein, bevor P1.4
   `--session-id` capability-gegatet aktiviert. Der bestehende Fallback bleibt nur für
   alte CLI-Versionen/Hook-Ausfall.
7. **Store-Invarianten vor Merge-Tempo:** Erst Eindeutigkeit, Future-Schema-Schutz und
   ein reiner Merge-Planner, dann P1.5 O(m+n). Ein schneller falscher Merge ist keine
   Verbesserung.
8. **Diff-Gate vor View-Mikrooptimierung:** P1.7 reduziert die Ursache unnötiger
   Invalidierungen und gehört vor P1.8. Danach mit Signposts neu messen, welche
   Body-Optimierungen noch nötig sind.
9. **Terminal-Contract vor Broker:** P0.7/P2.1 müssen eine Transport-Naht
   `receive/send/resize/detach/close` hinterlassen. Inkrementelles output-only Recording
   ist der sichere Default; der launchd-PTY-Broker bleibt zunächst Feature-Flag-Spike.
10. **Security vor OSC-Ausbau:** Zuerst OSC-8-Scheme-/Pfad-Policy und Notification-
    Deduplizierung. Danach OSC 133 sowie OSC 99/9/777 als nachrangige Metadatenquellen;
    niemals als Ersatz für Claude-Hooks oder `agents --json`.
11. **Modulgrenzen vor Swift-6-Sprachmodus pro Target:** Complete Checking liefert
    früh Wert; die eigentliche Target-für-Target-Migration folgt P2.1/P2.6 und dem ersten
    kleinen SwiftPM-Schnitt. Das Root-App/UI-Target kommt zuletzt.

### Datei-Cluster mit exklusivem Owner

| Cluster | Maßnahmen / fehlende Ergänzungen | Konfliktregel |
|---|---|---|
| Audio & App-Quit | P0.1, P0.2, P0.3, Quit-Recovery, Recorder/UI-Sync | Ein Agent für `AudioRecorder.swift` und Recorder-Lifecycle; AppDelegate-Änderungen mit Terminal-Owner seriell integrieren. |
| Session-Store & Index | P0.4b, P0.6, P1.4, P1.5, Teile P1.10, P2.3, P2.4, P2.6, Future-Schema-Schutz | Ein Store-Owner. Test-Fixtures dürfen parallel entstehen, Produktdateien nicht. |
| Claude Background & Prozesse | P0.4a, P1.1, P1.2, P2.2, Supervisor-Fixes, Hook-Matrix, ProcessRunner/Environment | Ein Owner für den Spawn-/Lifecycle-Contract; keine parallelen „kleinen“ Environment-Patches. |
| Terminal | P0.7, P1.12, P2.1, Recording, Transport-Naht, Broker-Spike, OSC | Ein Owner, in kleinen seriellen Commits: Tests → mechanischer Split → Lifecycle → Recording → optionale Protokolle. |
| Workspace/UI-Performance | P0.8, P1.7, P1.8, C11, Grid-/Tab-Findings | P1.7/C11 zuerst; UI-Agent erst nach stabiler Workspace-Publikation. |
| Package/Toolchain | P0.1-C-Target, P1.12-SwiftTerm-Pin, P2.5, Swift-6-Settings | `Package.swift` hat pro Welle genau einen Owner; diese Änderungen nie parallel mergen. |

P1.10 ist in der heutigen Form **kein risikoarmes Sammelpaket**. Die sechs Unterpunkte
berühren Parser, Scan-Orchestrierung, Event-Priorität, Terminal-Input, Cold-Load und
Workspace-Ordnung. Sie sind nach den obigen Clustern aufzuteilen. Dasselbe gilt für
P2.7 (CI-Policy, Doku und Launcher-Fix) und P2.8 (sieben eigenständige Produktideen).

## 3. Fehlende Quick Wins

Diese Punkte liefern vor großen Refactors sofort Schutz oder Sichtbarkeit:

1. Future-Schema-Dateien read-only lassen; korrupte Primärdateien quarantänisieren,
   bevor irgendein Repair-Save erfolgt.
2. Save-Fehler sichtbar machen und mit begrenztem Backoff erneut versuchen; erst danach
   P0.8 `maxInterval` ergänzen.
3. Headless-Calls sofort mit `--no-session-persistence`, explizitem Scratch-cwd,
   profilbewusstem Minimal-Environment und strukturierter JSON-Ausgabe starten; Cleanup
   getrennt ausrollen.
4. P1.3 vorziehen: Ein Tab ohne gebundene ID darf nie still einen leeren Fresh-Start
   bauen. Das ist ein kleiner Guard mit hohem Vertrauensgewinn.
5. P1.6, P1.7 und P1.9 als unabhängige kleine Changes ausrollen, jeweils mit
   Stale-Result-, Side-Effect- bzw. Cache-Invalidierungs-Test.
6. OSC-8 vor neuen OSC-Protokollen auf sichere Schemes, Längenlimits und bewusste lokale
   Dateiöffnung begrenzen.
7. `AgentTestSupport` um Fake-Home, ManualClock/Sleeper, vollständigen ProcessRunner-Spy
   und kontrollierbare File-Events erweitern; keine Tests mehr in echtem `~/.claude`.
8. Natürlich beendete Terminal-Controller und Hook-Watcher freigeben; die drei hohen
   Lifecycle-Leaks aus `memory-lifecycle-codex.md` müssen zumindest messbar und begrenzt
   werden, bevor ein Broker zusätzliche langlebige Objekte einführt.

## 4. Tech-Empfehlungen: verstärken, ersetzen oder zurückstellen

### Swift 6 Concurrency

Die Tech-Empfehlung verstärkt P0.2/P0.3, C11, Process-Lifecycle und Test-Spies, ersetzt
aber keinen Fix. Empfohlen ist ein eigener, verhaltensneutraler Toolchain-Change:

- Swift 6.3, zunächst Swift-5-Sprachmodus;
- Complete Concurrency Checking und Warnungsinventar als Artefakt/Baseline;
- Hotspots zuerst, keine globale Unsafe-Ausnahme;
- nach den ersten Modulgrenzen einzelne Leaf-Targets auf Swift 6;
- UI/App zuletzt, optional dort `defaultIsolation(MainActor.self)`, nicht in Audio-
  oder Prozessmodulen pauschal.

`swift-subprocess` ist kein Teil der akuten Wellen: Es kann nach stabilem 1.0 hinter dem
eigenen `ProcessRunner` für kurze headless Commands pilotiert werden. Es ersetzt weder
SwiftTerm/PTY noch einen dauerhaften Supervisor oder die Environment-Policy.

### Claude CLI: offizielle Verträge statt Disk-Heuristik

Die Roadmap sollte P1.2 präzisieren: **`claude agents --json` ist pro Profil die primäre
Background-Reconciliation**, `state.json` nur ein kompatibler Fallback. CLI-Version und
Capability werden geprüft; Fehler degradieren sichtbar, nicht zu „working für immer“.

P0.5/P0.6/P1.4 werden zu einem Zustandsautomaten:

1. Launch-Intent mit lokaler ID, Profil, cwd und start/fork/resume persistieren.
2. Erste passende Hook-ID und `transcript_path` atomar binden; belegte IDs ablehnen.
3. Mehrdeutigkeit ergibt `recoveryRequired`, nicht „neueste Datei“.
4. Erst danach `--session-id`/`--fork-session` capability-gegatet nutzen.
5. JSONL bleibt tolerant gelesene History, nicht Identitäts-SSoT.

Zusätzlich fehlt eine Maßnahme zur vervollständigten Hook-Matrix
(`StopFailure`, `SubagentStart/Stop`, `CwdChanged`, `Pre/PostCompact` und gefilterte
Notifications). Sie sollte mit P1.2 umgesetzt werden, nicht als Teil des allgemeinen
JSONL-Parsers P1.11.

### PTY-Broker, Recording und OSC

Der PTY-Broker ersetzt P0.7 **nicht kurzfristig**. Er ändert Ownership, Quit-Semantik,
Reaping, Upgrade und Security so grundlegend, dass er ein eigener RFC/Spike mit Gates
bleiben muss. Die richtige Reihenfolge ist:

1. async Teardown und Quit-Koordination korrekt machen;
2. output-only, append-only ANSI/asciicast-Recording mit `0600`, Retention und Replay;
3. Renderer von lokalem Prozessbesitz entkoppeln;
4. Broker hinter Feature Flag mit `detach != close != stop`, Sequenznummern,
   Backpressure, Lease, Reaper, TTL/Cap und TERM→KILL testen;
5. erst nach Crash/Reconnect-/Leak-/Upgrade-Stresstests als Default erwägen.

OSC 133 markiert nur Shell-Prompt/Kommando-Grenzen; innerhalb einer laufenden Claude-TUI
ist es kein Turn-Signal. OSC 99/9/777 sind untrusted Notifications und bleiben hinter
Hooks sowie der deduplizierten Notification-Pipeline. Diese Protokolle sind ein späterer
P1/P2-UX-Track, keine Stabilitätsvoraussetzung.

## 5. Feature-Regressionsrisiko je bestehender Maßnahme

Bewertet wird das Risiko **der Änderung**, nicht die Schwere des Problems. Das Risiko ist
bewusst strenger als in der Roadmap, weil mehrere Maßnahmen Kernverträge oder breite
gemeinsame Dateien ändern.

| ID | Risiko nach Review | Gefährdete Features / notwendiges Gate |
|---|---:|---|
| P0.1 | **mittel** | Aufnahme-Start, Bluetooth-/Gerätewechsel, SwiftPM-Linking; Engine-Adapter-Test plus manuelle Built-in/Bluetooth-QA. |
| P0.2 | **mittel** | Reconfiguration kann zu früh abbrechen oder Mikrofon hängen lassen; Generation-/Cancel-Test. |
| P0.3 | **hoch** | Audio-Callbacks, MainActor-Latenz, Observable-Publikation; Swift-6-Baseline und TSan/manuelle Diktat-QA. |
| P0.4 | **niedrig / hoch** | Prävention niedrig; Migration/Cleanup hoch wegen möglicher echter `/`-Sessions. Backup, Dry-Run, referenzielle Prüfung und Wiederherstellung. |
| P0.5 | **hoch** | Discovery, Account-Umzug, Resume, Unicode/Langpfad; Golden-Fixtures gegen reale CLI plus Copy+Verify. |
| P0.6 | **hoch** | Import, Bindung, Dedup, Archiv/Branch-Zuordnung; Zwei-Tab-Pipeline-Test und globale ID-Invariante. |
| P0.7 | **hoch** | Ctrl+C, Exit-Drain, Snapshot, Tab-Close, App-Quit; Fake-PTY-Barrieren und Mehrtab-QA. |
| P0.8 | **mittel** | Save-Frequenz, Lock-Haltezeit, Crash-Recovery; ManualClock und Save-/Retry-Spy. |
| P1.1 | **hoch** | Alle Spawn-/Attach-/Stop-/Health-/Headless-Pfade und Multi-Account; Environment-Contract-Matrix pro Profil. |
| P1.2 | **mittel–hoch** | `working/blocked/done`, App-Restart, alte Claude-Versionen; capability-gegatete CLI-Fixtures und Fallback-Matrix. |
| P1.3 | **niedrig** | Resume kann sichtbarer blockieren statt still weiterlaufen; expliziter Repair-/Retry-Weg erforderlich. |
| P1.4 | **hoch** | Start/Resume/Fork und Alt-CLI-Kompatibilität; Launch-Probe, Hook-Bestätigung, Rollback-Flag. |
| P1.5 | **hoch** | Merge-Semantik und MainActor-Publikation; Planner-Golden-Tests plus Komplexitätsbudget. |
| P1.6 | **mittel** | Stale Git-Ergebnis kann falsches Projekt überschreiben; Generation/Cancel und coalesced refresh. |
| P1.7 | **niedrig–mittel** | Falsch definiertes Equatable kann nötige Persistenz unterdrücken; Nebenwirkungszähler und Cold-Load-Roundtrip. |
| P1.8 | **hoch** | Selektion, Tabs, Multi-Window-Invalidierung, Sidebar-Reihenfolge; Signposts plus manuelle Multi-Window-QA. |
| P1.9 | **niedrig–mittel** | Falscher/staler Transcript-Pfad im Diktatkontext; Miss/Hit/Move-/Invalidierungs-Tests. |
| P1.10 | **hoch** | Sechs unabhängige Verträge; nicht als Paket ausrollen, pro Cluster einzeln bewerten. |
| P1.11 | **mittel** | History kann Events verschlucken, doppeln oder falsch verketten; versionsübergreifende Golden-JSONL und Degradationsmatrix. |
| P1.12 | **hoch** | Scroll, Selection, Memory, Teardown und Dependency-Pin; gespeicherte Stream-Fixtures und manuelle TUI-QA. |
| P2.1 | **mittel** | Compile-/Lifecycle-Verdrahtung trotz semantisch mechanischem Move; eigener Move-Commit vor Verhalten. |
| P2.2 | **hoch** | Stub→Spawn→Persist→Attach und Rollback; End-to-End-Harness vor View-Ablösung. |
| P2.3 | **hoch** | Store-Fassade, UI-State und Repair/Merge; strangler-artig, keine gleichzeitige Semantikänderung im Move-Commit. |
| P2.4 | **mittel** | Provider-spezifische Scanner- und Datumssemantik; gemeinsame Fixtures müssen Claude- und Codex-Abweichungen erhalten. |
| P2.5 | **hoch** | Build, Ressourcen, Sichtbarkeit, Tests und signiertes Executable; pro Target shipbarer Schritt, Buildzeit vorher/nachher messen. |
| P2.6 | **mittel** | Preferences-/Statusdefaults können anders aufgelöst werden; Closure-Seams mit Default-Kompatibilität. |
| P2.7 | **mittel** | LOC-Gate kann legitime Arbeit blockieren; Doku/Launcher niedrig, CI-Policy separat kalibrieren. |
| P2.8 | **gemischt, überwiegend hoch** | Kein einzelnes Paket: Worktree/AUHAL/lokale Transkription hoch, Diff/Clipboard mittel–hoch, Push mittel, Registry-Grundsatz niedrig. Je Idee eigener RFC und Erfolgsmetrik. |

## 6. Empfohlene Umsetzungsreihenfolge mit Agents

Grundregel: maximal drei Implementierungs-Lanes gleichzeitig, aber **nur eine Lane pro
Datei-Cluster**. Jeder Agent liefert kleine, reviewbare Commits; ein Integrator merged
nach Abhängigkeit und führt nach jedem Cluster die volle Suite aus. Manuelle QA ist ein
Wave-Gate, kein Ersatz für Tests.

### Welle 0 — Scope, Oracles und Toolchain-Baseline

**Ziel:** Release-Blocker festlegen, bevor Produktcode parallel verändert wird.

- Lane A: kritische/hohe ausgelassene Befunde zu Supervisor, Persistenz/Migration,
  Security, Quit und Postprocessing adversarial verifizieren und in eine
  Finding→Maßnahme-Matrix überführen.
- Lane B: Testinfrastruktur (Fake-Home, ManualClock/Sleeper, ProcessRunner-Spy,
  kontrollierbare File-Events) und die fehlenden C01/C02/C07/C10-Oracles.
- Lane C, seriell zu `Package.swift`: Swift-6.3-/Complete-Checking-Baseline im
  Swift-5-Modus; nur Diagnosen erfassen, noch keine breite Isolation.

**Gate:** `swift test` grün; priorisierte Findings haben einen expliziten Status; keine
Produktsemantik geändert.

### Welle 1 — Aktiven Schaden stoppen

- **Audio-Owner:** P0.1 + P0.2 als ein Recorder-Invariantenpaket; Quit-Recovery für
  laufende Aufnahme nur nach abgestimmtem App-Termination-Contract.
- **Persistenz-Owner:** Future-Schema-Gate, Quarantäne/Backups, Save-Fehler/Retry und
  Keychain-Migration; noch kein Cleanup.
- **Process-Safety-Owner:** minimales/klassifiziertes Environment, Secret-Filter,
  Headless-Hygiene P0.4a und Deadlines/TERM→KILL für kurze Codex-/Claude-Prozesse.

**Gate:** volle Suite; manuelle Aufnahme-QA mit Built-in/Bluetooth, Cancel während
Reconfiguration und Quit während Aufnahme; Persistenz-Recovery-Fixtures.

### Welle 2 — Session- und Background-Korrektheit

- **Session-Owner:** P1.3 zuerst, dann autoritativer Launch-Intent,
  `transcript_path`, ID-Lease und P0.5/P0.6. P1.4 bleibt hinter Capability-Flag aus.
- **Background-Owner:** P1.1 Environment-Propagation vollständig, danach P1.2 mit
  `claude agents --json` als primärer profilbezogener SSoT, State-File-Fallback und
  vervollständigter Hook-Matrix. Verifizierte Supervisor-Fixes gehören demselben Owner.
- **Terminal-Owner:** P2.1 als mechanischer Split, anschließend P0.7 async
  Exit-Drain/Quit-Semantik. Noch kein Broker.

**Gate:** Zwei parallele Tabs können nie dieselbe ID claimen; Restart/Daemon-Tod und
Multi-Account-Contract getestet; Terminal-Exit-Bytes sind im Snapshot.

### Welle 3 — Sichere Bereinigung und deterministische Starts

- P0.4b als versionierte, wiederholbare Migration mit Dry-Run/Backup; danach neue
  Performance-Baseline.
- P1.4 `--session-id`/Fork capability-gegatet aktivieren; Hook-Bestätigung und
  Rollback-Telemetrie beobachten.
- Terminal-Recording Stufe A (output-only, append-only, `0600`, Limits, Replay) als
  Default-Fallback ergänzen.
- Die kleinen unabhängigen Quick Wins P1.6, P1.7 und P1.9 können parallel laufen, wenn
  ihre Produktdateien keinem aktiven Cluster-Owner gehören.

**Gate:** Migration ist rückrollbar; Legacy-/Alt-CLI-Fallback funktioniert; Recording
enthält keine Eingaben/Secrets und bleibt begrenzt.

### Welle 4 — Performance auf stabilen Invarianten

- P2.3 Merge-Planner strangler-artig extrahieren, danach P1.5 linear machen.
- C11 monotone Workspace-Publikation und P0.8 Save-Deadline mit Retry-Vertrag.
- P1.7-Wirkung neu messen, dann nur die belegten Teile von P1.8 umsetzen.
- P1.10 nach Clustern auflösen; Parser/Date-Formatter kann mit P2.4 laufen,
  Scan-Orchestrierung beim Store-Owner, Scroll-Monitor beim Terminal-Owner.
- P1.11 mit Golden-Korpus; aktuelle Codex-Eventtypen und Transcript-Rendering-Findings
  aus Runde 2 müssen Teil des Contracts sein.

**Gate:** festgelegte Merge-/Body-/Cold-Load-Budgets; keine Auswahl-, Reihenfolge- oder
History-Regression in Multi-Window-/Large-Workspace-QA.

### Welle 5 — Architektur und optionale Technologie-Spikes

- P2.2/P2.6 und erster kleiner P2.5-Foundation-/Process-Target; danach einzelne Leaf-
  Targets auf Swift 6, Root-App zuletzt.
- P1.12 SwiftTerm-Feinschliff und Rest-Patches upstreamen; kein Ghostty-Produktwechsel.
- Broker nur als Feature-Flag-Spike nach definierten Reaper-/Reconnect-/Upgrade-Gates.
- OSC 133/99/9/777 erst nach Security-/Dedupe-Policy; Hooks bleiben Status-SSoT.
- P2.7 getrennt ausrollen. P2.8 bleibt priorisierter Produkt-Backlog mit eigenem RFC pro
  Eintrag, nicht Teil der Stabilitäts-Roadmap.

## 7. Ship- und Review-Gates pro Welle

Jede Welle ist nur dann „einzeln shipbar“, wenn zusätzlich zu `swift test` gilt:

- alle geänderten Kerninvarianten haben ein unabhängiges Verhaltens-Oracle;
- Migrations-/Cleanup-Changes besitzen Backup, Dry-Run oder dokumentierten Rollback;
- CLI-/Dateiformate sind capability- bzw. versionsgegatet und degradieren sichtbar;
- Agents haben keine überlappende Produktdatei-Ownership;
- Performance-Changes liefern Vorher/Nachher-Messwerte;
- Recorder-, Terminal-, Multi-Window- und TCC-Pfade erhalten die in den Findings
  geforderte manuelle macOS-QA;
- neue P0/P1-Maßnahmen haben eine explizite Feature-Regressionsanalyse.

Die Aussage der ursprünglichen Roadmap, nach Welle 1 sei der Crash „strukturell
unmöglich“, ist zu absolut: Der ObjC-Trampolin soll genau die bekannte
AVFoundation-Exception-Klasse abfangen, beweist aber weder die Abwesenheit anderer
Realtime-Thread-Exceptions noch korrekte Recorder-Isolation. Besseres Gate:
**C01/C02 sind reproduzierbar abgefangen, die Aufnahme endet sichtbar und recoverbar,
und die definierte Bluetooth-/Gerätewechsel-Matrix zeigt keinen Prozessabbruch.**

## Schlussvotum

Die Roadmap ist eine belastbare **C01–C16-Fixliste**, aber noch keine vollständige
Umsetzungs-Roadmap des Audits. Mit Welle 0, der P0-Neukalibrierung und exklusiver
Cluster-Ownership wird sie ausführbar. Ohne diese Korrekturen würden Agents gerade in
den gefährlichsten Bereichen — `AudioRecorder`, `AgentSessionStore`,
`AgentTerminalView`, Process-Environment und `Package.swift` — parallel dieselben
Verträge verändern, während mehrere stärkere Datenverlust- und Supervisor-Befunde gar
nicht eingeplant sind.
