---
status: aktiv
updated: 2026-07-18 18:18
description: Konsolidierte Refactor- und Fix-Roadmap nach zwei adversarialen Verifikationsrunden und Technologie-Scan.
description_long: Ordnet die bestätigten Findings C01–C16 und N01–N16 in ausführbare Wellen ein, verarbeitet die Plan-Verifikation aus Runde 2 und benennt für jede Maßnahme das Feature-Regressions-Gate.
---

# Refactor-/Fix-Roadmap

Grundlage sind alle Findings aus `02-findings/`, die bestätigten Verdicts
[`C01–C16`](../04-verifikation/verdicts.md) und
[`N01–N16`](../04-verifikation/verdicts-runde2.md), der
[`Plan-Review`](plan-review.md) sowie die Vergleiche aus `03-vergleich/`.
Beide Verifikationsrunden bestätigten jeweils alle 16 geprüften Behauptungen.

Aufwand: **S** ≤ ½ Tag · **M** 1–3 Tage · **L** > 3 Tage. Risiko bezeichnet
das Regressionsrisiko des Eingriffs, nicht die Schwere des Problems.

## Verbindliche Leitplanken

- **Keine Feature-Regression:** Jede Maßnahme besitzt unten ein eigenes
  Regressions-Gate. Eine Welle ist erst shipbar, wenn diese Gates, die volle
  Testsuite und die betroffene manuelle macOS-QA bestanden sind.
- **Exklusive Datei-Ownership:** Audio-Lifecycle, Session-Store/Indexer,
  Prozess-/Background-Lifecycle, Terminal und `Package.swift` haben je Welle
  genau einen Owner; Maßnahmen mit überlappenden Produktdateien laufen seriell.
- **Verhaltens-Oracles vor Refactor:** Recorder-, Spawn-/Bind-/Status-,
  Terminal- und Persistenzverträge werden vor strukturellen Umbauten als Tests
  oder dokumentierte manuelle Oracles festgehalten.
- **Daten schützen, dann bereinigen:** Future-Schema-Gates, Backup, Quarantäne,
  Save-Fehler und Retry kommen vor jeder Bestandsmigration.
- **Externe Daten bleiben geschützt:** `~/.claude/` und `~/.codex/` werden
  grundsätzlich nur gelesen. Der bestehende Account-Umzug braucht als explizite
  Ausnahme Copy+Verify vor einem Löschen der Quelle.

## Gestrichene Maßnahme

### ~~P0.8 · Workspace-Save-Debounce mit zusätzlicher Deadline~~

**Gestrichen.** Der Produktions-Store begrenzt eine Dirty-Periode bereits über
`firstDirtyAt` auf zwei Sekunden; die Annahme eines unbegrenzt verschiebbaren
Saves ist veraltet. **(Runde 2: VERWERFEN.)** Die reale Restlücke — sichtbare
Save-Fehler und begrenzter Retry — ist in Welle 1 bei Future-Schema und
Persistenz enthalten. Die injizierbare Deadline-Policy bleibt ausschließlich
ein Testbarkeitsdetail, keine offene Produktmaßnahme.

## Welle 0 — Oracles, Scope und Toolchain-Baseline

### W0.1 · Testoracles und Swift-6-Diagnostik etablieren

- **Was:** Fake-Home, ManualClock/Sleeper, vollständigen ProcessRunner-Spy und
  kontrollierbare File-Events ergänzen; C01/C02, C07, C10 sowie die neuen
  Supervisor-, Persistenz- und Transcript-Invarianten als Tests festhalten.
  Parallel mit stabiler Swift-6.3-Toolchain im Swift-5-Sprachmodus Complete
  Concurrency Checking erfassen, aber noch keine breite Isolation ändern.
- **Warum:** Die volle Suite schützt die kritischen End-to-End-Verträge heute
  nicht ausreichend; die Concurrency-Baseline muss vor P0.3 und Modulumbauten
  stehen.
- **Aufwand/Risiko:** M / niedrig.
- **Regression:** Keine Produktsemantik ändern; bestehende XCTest-Suite bleibt
  grün, neue Swift-Testing-Tests verwenden keine versteckten XCTest-Assertions.

## Welle 1 — Aktiven Schaden stoppen

### P0.1 + P0.2 · Recorder-Start und Reconfiguration absichern

- **Was:** Unmittelbar vor `installTap` und `engine.start()` das Hardwareformat
  erneut lesen und bei Änderung begrenzt neu aufbauen. Der ObjC-Trampolin muss
  eine gefangene Exception explizit als Fehler zurückgeben; sein Vertrag gilt
  nur für die synchron aufgerufenen AVFoundation-Operationen. Nach jedem
  `await` im Configuration-Handler werden Recording-Generation,
  Engine-Identität und Sessionzustand erneut geprüft; Tap-Callback,
  Converter und Datei schreiben nur für die aktive Generation.
- **Warum:** C01/C02 sind bestätigt und erklären App-Abbruch, Zombie-Engine und
  Stale-Converter. **(Runde 2: Die alte `void`-Signatur konnte nicht `throws`
  bridgen; ein synchroner Wrapper fängt keine spätere Realtime-Callback-
  Exception. Daher enger Fehlervertrag plus Generation-/Callback-Schutz.)**
- **Aufwand/Risiko:** M / mittel.
- **Regression:** Adaptertests für Formatwechsel und Cancel während jedes
  Suspension-Points; manuelle Matrix Built-in/Bluetooth, Gerätewechsel,
  Start/Stop und abgezogene Geräte. Kein Prozessabbruch, Aufnahme endet sichtbar
  und recoverbar.

### R2.1 · Laufende Diktataufnahme beim App-Quit sichern (N02)

- **Was:** `applicationShouldTerminate` koordiniert Recorder und Terminal über
  `.terminateLater`: Aufnahme geordnet stoppen/finalisieren oder einen
  recoverbaren Pending-Record persistieren, erst danach Termination bestätigen.
  Quit-Button und System-Quit nutzen denselben Vertrag.
- **Warum:** N02 (hoch, bestätigt) — heute kann die App eine laufende temporäre
  M4A-Aufnahme ohne Abschluss verlieren.
- **Aufwand/Risiko:** M / mittel.
- **Regression:** Manuelle QA für Quit während Capture, Reconfiguration,
  Transkription und Postprocessing; normaler Quit darf nicht hängen und eine
  abgebrochene Aufnahme nicht automatisch versenden.

### R2.2 · Output-Modi fehlertolerant und eindeutig laden (N03, N04)

- **Was:** Doppelte IDs ohne `Dictionary(uniqueKeysWithValues:)` deterministisch
  quarantänisieren; Einträge einzeln dekodieren, inkompatible Records sichern
  und gültige Custom-Modi/Templates erhalten. Vor einem Repair-Save Backup und
  sichtbaren Fehler anbieten.
- **Warum:** N03/N04 (hoch, bestätigt) — doppelte IDs crashen, ein einzelner
  inkompatibler Record kann sonst den gesamten Custom-Bestand überschreiben.
- **Aufwand/Risiko:** M / mittel.
- **Regression:** Golden-Dateien für Duplikate, unbekannte Felder, partielle
  Korruption und Roundtrip; Built-ins, Custom-Modi, Templates und Reihenfolge
  bleiben bei gültigen Dateien unverändert.

### R2.3 · Future-Schema und Keychain-Migration transaktional machen (N05, N06)

- **Was:** Workspace-Dateien mit `schemaVersion > current` read-only öffnen und
  niemals downgraden; korrupte Primärdaten quarantänisieren. Save-Fehler sichtbar
  machen und begrenzt wiederholen. `KeychainManager.save` liefert einen Fehler;
  der Legacy-Key wird erst nach erfolgreichem Write+Readback entfernt.
- **Warum:** N05/N06 (hoch, bestätigt) — Downgrades können neuere Sessiondaten
  überschreiben, fehlgeschlagene Migrationen den einzigen API-Key löschen.
  **(Runde 2: Die gestrichene P0.8-Deadline wird nicht wieder eingeführt;
  adressiert werden die tatsächlich belegten Save-/Retry- und Quit-Lücken.)**
- **Aufwand/Risiko:** M / hoch.
- **Regression:** Versionsmatrix Upgrade/Downgrade, Disk-/Permission-Fehler,
  Keychain-Write-Fehler und Cold-Load-Roundtrip; unbekannte Daten werden weder
  verändert noch still verworfen.

### R2.4 · Codex-Supervisor und Turn-Erfolg als atomaren Vertrag behandeln (N07, N08, N14)

- **Was:** Supervisor bereits beim Spawn in neue Session/Prozessgruppe setzen
  und Start erst nach Ready-/Detach-Handshake persistieren. Stop-Intent vor
  Prozesspublikation merken und unmittelbar nach Registrierung anwenden.
  `.done` verlangt `terminationReason == .exit`, Exit 0, `turn.completed` und
  eine semantisch vollständige finale Nachricht; Transportende allein ist kein
  Erfolg. TERM→KILL trifft die gesamte eigene Prozessgruppe.
- **Warum:** N07/N08 (kritisch) und N14 (hoch), alle bestätigt — der Supervisor
  hängt bis zum späten `setsid()` am Waiter, ein früher Stop geht verloren und
  ein unvollständiger Turn wird heute als Erfolg gespeichert.
- **Aufwand/Risiko:** M–L / hoch.
- **Regression:** Prozess-Harness für Waiter-Abbruch vor/nach Handshake,
  Stop in jedem Spawn-Zustand, Signal/Exit/EOF-Kombinationen, Enkelprozesse und
  App-Restart; echte erfolgreiche Codex-Turns bleiben unverändert fortsetzbar.

### P1.1 · Minimales, profilbewusstes Child-Environment (N09, N10)

- **Was:** Eine klassifizierte Environment-Fabrik für PTY, `--bg`, Attach,
  Logs/Stop/Respawn/Health, `agents --json`, Auto-Namer und Summarizer einführen.
  Nur erforderliche Variablen plus explizite Overrides weitergeben;
  Cloud-Credentials und fremde `SSH_AUTH_SOCK` nicht erben. Beim Profil-Rename
  OAuth-Secrets ohne argv-Klartext über Security-API beziehungsweise sicheren
  stdin-/Keychain-Pfad übertragen. `SupervisorJobReader` und alle Active-
  Background-Pfade erhalten denselben Profil-Root.
- **Warum:** C06 sowie N09/N10 (hoch, bestätigt). **(Runde 2: P1.1 erfasste
  zunächst nicht alle Lifecycle-/Reader-Pfade; die Environment-Grenze umfasst
  nun jeden Spawn und vermeidet Secret-Exposition.)**
- **Aufwand/Risiko:** M / hoch.
- **Regression:** Contract-Matrix pro Profil und Prozessklasse; Login-Shell-
  PATH/Command-Auflösung, Multi-Account, MCP und bestehende Agent-Starts müssen
  funktionieren, während Canary-Secrets im Kind fehlen.

### P0.4a · Neuen Headless-Junk verhindern

- **Was:** Interne Claude-Hilfsläufe mit `--no-session-persistence`,
  strukturierter JSON-Ausgabe, explizitem Scratch-cwd und profilbewusstem
  Minimal-Environment starten; Codex-Äquivalent prüfen. Noch keinen Bestand
  löschen.
- **Warum:** C05 ist bestätigt; der Bestand wächst weiter und belastet Index,
  Merge und UI. **(Runde 2: Prävention und Migration werden getrennt; `/` ist
  ein erlaubtes echtes Projekt und darf nicht pauschal gefiltert werden.)**
- **Aufwand/Risiko:** S / niedrig.
- **Regression:** Auto-Naming/Summarizing für Claude und Codex mit allen Profilen
  testen; ein Hilfslauf erzeugt keine importierbare Session und verliert kein
  Ergebnis.

### P1.6 + P1.7 + P1.9 · Drei unabhängige Quick Wins

- **Was:** Git-Status asynchron, abbrechbar und pfad-/generation-geprüft laden,
  alten Status sofort leeren und Timeout/Drain definieren. WindowStore nur bei
  echter semantischer Änderung publizieren/speichern. Codex-Transcript-Lookups
  über den vorhandenen Locator cachen und bei Move/Miss korrekt invalidieren.
- **Warum:** C13/C14/C16 sind bestätigt. **(Runde 2: Git braucht Stale-Result-
  Schutz; Diff-Gate und Cache benötigen explizite Side-Effect- beziehungsweise
  Invalidierungsverträge.)**
- **Aufwand/Risiko:** je S / niedrig bis mittel; getrennte Changes.
- **Regression:** Git-Projektwechsel mit langsamem Alt-Task, WindowStore-
  Roundtrip samt notwendigen No-op-unabhängigen Nebenwirkungen sowie
  Transcript Hit/Miss/Move/Profile-Wechsel testen.

## Welle 2 — Session-, Background- und Terminal-Korrektheit

### P0.3 · Recorder-Isolation selektiv aufräumen

- **Was:** UI-/Observable-Zustand gezielt auf den Main Actor, seriellen
  Recorderzustand hinter einen eindeutigen Owner und Realtime-/CoreAudio-
  Callbackzustand hinter einen dokumentierten synchronen Vertrag legen.
  `availableDevices`, der indirekte Read von `selectedDeviceID` und
  `currentDefaultDeviceID` erhalten unveränderliche Snapshots.
- **Warum:** C03 ist bestätigt, aber als Härtung eingestuft. **(Runde 2: Kein
  pauschales `@MainActor`; es würde Hot Paths blockieren und übersah den
  indirekten Preference-Read sowie den CoreAudio-Callback-Race.)**
- **Aufwand/Risiko:** M / hoch.
- **Regression:** Swift-6-Diagnostik, TSan soweit praktikabel und manuelle
  Latenz-/Pegel-/Gerätewahl-QA; Audio-Callback darf nie auf dem Main Actor
  warten.

### P0.5 + P0.6 + P1.3 + P1.4 · Autoritative Session-Bindung

- **Was:** Vor Spawn einen Launch-Intent mit lokaler ID, Profil, cwd,
  Start/Fork/Resume und echtem Launch-Zeitpunkt persistieren. Die erste passende
  Hook-ID plus `transcript_path` bindet atomar; belegte IDs werden abgelehnt,
  persistierte Doppel-Rows repariert. Mehrdeutigkeit oder Bindungsverlust wird
  als `recoveryRequired` sichtbar. Erst danach `--session-id`/Fork-Ziel nach
  CLI-Capability aktivieren. Encoder und wiederholter, off-main laufender
  Glob-Fallback bleiben nur Legacy-Discovery; positive Pfade werden gecacht.
  Account-Umzug erfolgt Copy+Verify vor Quellenlöschung.
- **Warum:** C04/C07/C09 sind bestätigt. **(Runde 2: Merge-Fenster und Input-
  Dedup existieren bereits; `createdAt` ist kein Launch-Zeitpunkt. Ein einmaliger
  Glob vor Dateierzeugung reicht nicht. Der Zustandsautomat ersetzt diese
  Zeit-/Disk-Heuristiken als Identitätsquelle.)**
- **Aufwand/Risiko:** L / hoch.
- **Regression:** Zwei parallele Tabs dürfen nie dieselbe ID claimen; Golden-
  Matrix für Start/Resume/Fork, Alt-CLI, Hook-Ausfall, Unicode/Langpfad, `/cd`,
  Profilumzug und persistierte Doppel-Rows. Recovery darf nie still fresh starten.

### P1.2 · Background-Status über offizielle Claude-Schnittstellen reconciliaten

- **Was:** Profilbezogenes `claude agents --json --all` ist die primäre Quelle
  für Background-Zustand; `daemon status` diagnostiziert, internes `state.json`
  bleibt capability-gegateter Fallback. Hook-Matrix um `StopFailure`,
  `SubagentStart/Stop`, `CwdChanged`, `Pre/PostCompact` und gefilterte
  Notifications ergänzen. Fehler degradieren sichtbar statt dauerhaft zu
  `working`.
- **Warum:** C08 ist bestätigt. **(Runde 2: P1.2 folgt erst auf vollständige
  Profilpropagation und umfasst alle Config-Roots; interne Jobdateien sind nicht
  die bevorzugte API.)**
- **Aufwand/Risiko:** M / mittel–hoch.
- **Regression:** Fixtures für alte/neue Claude-Versionen, mehrere Profile,
  Daemon-Tod, App-Restart und JSON-Fehler; Hooks bleiben Status-SSoT und der
  Fallback überschreibt keine stärkere Quelle.

### R2.5 · Terminalprozess nur mit geprüfter Identität beenden (N01)

- **Was:** Registry-Einträge tragen Spawn-Token plus PID/Prozessstart-Identität;
  Restart/Terminate validiert unmittelbar vor dem Signal, dass Controller,
  Session und OS-Prozess noch zusammengehören. Veraltete Aktionen werden
  verworfen und als normaler Start neu bewertet.
- **Warum:** N01 (kritisch, bestätigt) — ein Race kann eine recycelte PID eines
  fremden Prozesses treffen.
- **Aufwand/Risiko:** M / hoch.
- **Regression:** Deterministische PID-Reuse-/Exit-before-restart-Tests; normaler
  Start, Restart, Tab-Close und Stop-all dürfen keine verwaisten Controller
  hinterlassen.

### R2.6 · Auto-Paste an den Aufnahme-Intent binden (N11)

- **Was:** Ziel-App, Fenster-/Session-Identität und Paste-Policy beim
  Aufnahmestart einfrieren; vor Auslieferung Identität erneut prüfen. Bei
  Abweichung nur kopieren und sichtbare Bestätigung verlangen, nicht in das
  aktuell fokussierte fremde Fenster senden.
- **Warum:** N11 (hoch, bestätigt) — vertrauliches Diktat kann während
  Transkription/Nachbearbeitung in einem anderen Chat landen.
- **Aufwand/Risiko:** M / mittel.
- **Regression:** Fokuswechsel zwischen Apps, Fenstern und Agent-Tabs sowie
  geschlossene Ziel-App testen; bisheriger Auto-Paste-Happy-Path und
  Clipboard-Wiederherstellung bleiben erhalten.

### R2.7 · AgentJob-State atomar und monoton aktualisieren (N12, N13)

- **Was:** Orphan-Korrektur, UI-Folgeturn und Supervisor-Fertigstellung nutzen
  denselben Lock-/CAS-Vertrag mit Revision und Re-Read. Statusübergänge sind
  monoton; ein veralteter Snapshot darf `done` nicht zu `failed` und `running`
  nicht zu `spawning` zurücksetzen.
- **Warum:** N12/N13 (hoch, bestätigt) — beide heutigen Vollsnapshot-Writes
  können einen neueren Zustand überschreiben.
- **Aufwand/Risiko:** M / hoch.
- **Regression:** Barrieren-Tests für Orphan-vs.-Completion und UI-vs.-Child-
  Start; Folgeturn, Retry, Stop und Recovery bleiben wiederholbar und
  crash-sicher.

### P0.7 + P1.12 · Terminal-Exit, Drain und Teardown ordnen

- **Was:** Keine Sleeps als Ordnungsgarantie. Output-Drain, Exit-Beobachtung,
  Snapshot und I/O-Close erhalten einen expliziten Zustandsautomaten;
  `detach`, `close` und `stop` sind getrennte Aktionen. Danach Scrollback-Limit,
  Trim-Anzeige, TERM→KILL-Eskalation und SwiftTerm-1.14-Rebase/Selection-Patches
  bearbeiten.
- **Warum:** C10 ist bestätigt. **(Runde 2: Weder `Task.sleep` noch
  `processTerminated` allein ordnen Exit-Callback und PTY-Drain; SwiftTerms
  `terminate()` schließt I/O und cancelt Monitoring, weshalb die Sequenz vor
  dem API-Aufruf feststehen muss.)**
- **Aufwand/Risiko:** M–L / hoch.
- **Regression:** Fake-PTY-Barrieren und manuelle Mehrtab-QA für Ctrl+C,
  Streaming-Exit, Tab-Close, Stop-all und App-Quit; letzte Exit-Bytes müssen
  genau einmal im Snapshot stehen, Auswahl/Scrollposition bleiben intakt.

## Welle 3 — Bereinigung, Performance und Transcript-Vertrag

### P0.4b · Headless-Bestand signaturbasiert migrieren

- **Was:** Erst nach P0.4a eine versionierte Migration mit Dry-Run, Backup,
  referenzieller Prüfung und Restore durchführen. Nur anhand belegbarer
  Headless-Signaturen entfernen; legitime Projekt-`/`-Sessions bleiben.
- **Warum:** C05 ist bestätigt. **(Runde 2: Die Zahl 495/496 ist eine
  Momentaufnahme und kein Löschkriterium; pauschaler Root-Prune ist verworfen.)**
- **Aufwand/Risiko:** M / hoch.
- **Regression:** Fixture mit echtem Root-Projekt, Junk, Referenzen und
  wiederholtem Lauf; Dry-Run entspricht exakt der späteren Mutation und Backup
  lässt sich wiederherstellen.

### P1.5 + P1.8 · Merge und UI-Projektionen erst nach stabilen Store-Invarianten optimieren

- **Was:** Nach ID-/Revisionsinvarianten einen atomar anwendbaren Merge-Planner
  und O(m+n)-Indizes einführen. Alle Aufrufer einschließlich Diktat-Hotpath
  berücksichtigen; Off-Main-Berechnung nur gegen eine Revision, die vor Apply
  erneut validiert wird. Danach P1.7 messen und nur belegte Body-/Sidebar-
  Projektionen optimieren.
- **Warum:** C12/C15 sind bestätigt. **(Runde 2: Off-Main-Merge vor geordneter
  Workspace-Publikation kann einen alten Snapshot veröffentlichen; die
  Maßnahme folgt daher P1.10-Revisionsschutz und umfasst den Diktat-Aufrufer.)**
- **Aufwand/Risiko:** L / hoch.
- **Regression:** Planner-Golden-Tests, Komplexitätsbudget, Large-Workspace-
  Signposts und manuelle Multi-Window-QA; Auswahl, Reihenfolge, Archiv/Branch
  und Diktatkontext bleiben identisch.

### P1.10 · Sammelmaßnahme in vier getrennte Changes auflösen

- **Was:** (1) je zwei statische ISO8601-Formatter mit/ohne Fractional Seconds;
  (2) Scan-Gründe priorisieren und nur tatsächlich aktive Coordinator-Pfade
  ändern; der behauptete zweite Load→Index→Save-Pfad ist gestrichen;
  (3) geteilter Scroll-Monitor beim Terminal-Owner; (4) monotone
  Workspace-Publikation mit Revision und geschützter Callback-Zuweisung.
  Workspace-Vorwärmung nur nach Messung als eigener Change.
- **Warum:** C11 und mehrere code-belegte Nebenbefunde. **(Runde 2: Das alte
  Sammelpaket mischte unabhängige Verträge und enthielt einen veralteten
  Index-Pfad; Formattervarianten dürfen nicht zusammenfallen.)**
- **Aufwand/Risiko:** je S–M / mittel; nicht gemeinsam ausrollen.
- **Regression:** Pro Change eigene Golden-/Ordering-/Lifecycle-Tests und
  Vorher/Nachher-Messung; keine Änderung an Parser-Zeitsemantik, Scan-Resultat,
  Scrollverhalten oder Callback-Reihenfolge.

### P1.11 · Transcript-Korrelation und Schema-Drift sichtbar machen (N15, N16)

- **Was:** Gemeinsames Blockmodell um Provider-Korrelations-IDs ergänzen und
  Claude `tool_use.id`/`tool_result.tool_use_id` sowie Codex `call_id`
  erhalten. Unbekannte, aber syntaktisch gültige Eventtypen zählen,
  degradieren sichtbar und bleiben in diagnostischer Form erhalten. Ein
  versionierter Golden-Korpus deckt aktuelle Claude-/Codex-Schemas, `/cd`,
  Resume-ID-Rotation, Interleaving und Degradationsmatrix ab.
- **Warum:** N15/N16 (hoch, bestätigt) — parallele Ergebnisse werden falsch
  zugeordnet und aktuelle Codex-Events verschwinden lautlos. **(Runde 2: Für
  das alte P1.11 lag zunächst kein Plan-Verdict vor; der Umfang wird deshalb
  nicht pauschal als bestätigt behandelt, sondern auf die nun bestätigten
  N15/N16-Verträge und belegte Golden-Fälle begrenzt.)**
- **Aufwand/Risiko:** M / mittel.
- **Regression:** Providerübergreifende JSONL-Fixtures mit parallelen Tools,
  unbekannten Events und großen Dateien; History darf nichts doppeln,
  verschlucken oder falsch verketten, UI zeigt kontrollierte Degradation.

### T1 · Inkrementelles, output-only Terminal-Recording einführen

- **Was:** Append-only Output-/Resize-Ereignisse mit `0600`, Größen-/Alterslimit,
  atomarem Index und Replay; Eingaben standardmäßig nie aufzeichnen. Der
  Plaintext-Endsnapshot bleibt schneller Fallback.
- **Warum:** Besserer Crash-/Neustart-Scrollback ist mit kleinem Risiko möglich,
  ohne einen Broker oder Prozess-Erhalt zu behaupten.
- **Aufwand/Risiko:** M / mittel.
- **Regression:** Replay aufgezeichneter ANSI-/Resize-Streams, Crash beim Write,
  Retention und Privacy prüfen; keine Prompts, Tokens oder Secrets aus stdin
  dürfen in Recording oder Logs landen.

## Welle 4 — Architektur und Modulgrenzen

### P2.1 + P2.2 · Terminal-Transport und View-Geschäftslogik schrittweise entkoppeln

- **Was:** Zuerst schmales Terminal-Transportinterface
  `receive/send/resize/detach/close` und Lifecycle-Seams schaffen; danach
  Registry/Controller mechanisch splitten. View-nahe Typen für Rendering,
  Keyboard, Scroll, Link und Grid bleiben zunächst im UI. Auch
  `AgentCommandBuilder` als heutiger Consumer wird berücksichtigt.
  Background-Dispatch und Index-Refresh erst nach End-to-End-Harness in
  Services verschieben.
- **Warum:** Die Schichtenverletzung ist real. **(Runde 2: Ein direkter Move
  des Controllers war wegen seiner View-Abhängigkeiten nicht targetfähig;
  P2.2 birgt zusätzlich hohe Stub→Spawn→Persist→Attach-Regressionsfläche.)**
- **Aufwand/Risiko:** L / hoch.
- **Regression:** Mechanischer Move getrennt von Verhalten; Build, Terminal-
  Lifecycle und Background-End-to-End-Harness nach jedem Schritt, inklusive
  Rollback bei definitivem Spawn-Fehler.

### P2.3 + P2.4 · Store-Planner und gemeinsame Scannerbausteine extrahieren

- **Was:** UI-Sidecar-I/O aus dem SessionStore lösen; pure Planung außerhalb
  des Locks ist erlaubt, aber Apply erfolgt atomar nur nach Revisionsvergleich
  oder wird unter derselben Lock-Disziplin neu geplant. Gemeinsame
  JSONL-Scanner-/Datumsbausteine extrahieren, provider-spezifische
  Verzeichnis-, Schema- und Zeitsemantik explizit beibehalten.
- **Warum:** Beide Strukturprobleme sind real. **(Runde 2: Ein aus altem
  Snapshot berechneter `[Mutation]`-Plan durfte keine parallele Änderung
  verlieren; die Indexer sind ähnlich, aber nicht wortgleich.)**
- **Aufwand/Risiko:** M–L / hoch.
- **Regression:** Store-Concurrency-Regressionstest, Planner-Golden-Korpus und
  getrennte Claude-/Codex-Fixtures; Apply ist atomar und Scan-Ergebnisse bleiben
  bitweise beziehungsweise semantisch gleich.

### P2.5 + P2.6 · Modulgrenzen vorbereiten und dann inkrementell schneiden

- **Was:** Zuerst Cross-Modul-Kanten lösen: Logger von `AppPreferences`,
  `AgentCommandBuilder` von `CodexStatusProbe`; Preference-/Statuszugriffe über
  Init-/Closure-Seams. Danach kleine Core-/Process-Leaf-Targets, anschließend
  AgentChats/Dictation, Root-App zuletzt. `package` statt `@_spi` verwenden.
- **Warum:** Modularisierung und DI-Zuwachs sind sinnvoll. **(Runde 2: Es sind
  28 echte `static … shared =`-Deklarationen, nicht 29; der alte
  Foundation/AgentChatsKit-Schnitt war wegen zweier Rückabhängigkeiten nicht
  buildfähig.)**
- **Aufwand/Risiko:** L / hoch.
- **Regression:** Jeder Target-Schnitt einzeln build- und shipbar; Clean-/
  Incremental-Build und volle Tests vor/nachher messen, signiertes Executable,
  Ressourcen und CLI-Symlink unverändert prüfen.

### P2.7 · Guardrails getrennt kalibrieren

- **Was:** Erst `AgentChatsView.swift` um mindestens die nötigen rund 570 LOC
  reduzieren, danach ein schrittweise sinkendes LOC-Budget statt sofortigem
  >2500-Fail aktivieren. Refactoring-Audit, Wertehierarchie und
  `PhpStormLauncher` jeweils als getrennte Doku-/Code-Changes ausrollen.
- **Warum:** Die vier Teilprobleme sind real. **(Runde 2: Ein sofortiger
  2500-LOC-CI-Fail würde den bestehenden Branch ohne vorausgehende Reduktion
  absichtlich rot machen.)**
- **Aufwand/Risiko:** S–M / mittel.
- **Regression:** Gate zunächst warnend und gegen Baseline testen; Launcher-
  Verhaltensparität manuell prüfen, Doku-Updates ändern keine Produktsemantik.

## Welle 5 — Optionale Produktspikes

### P2.8a · Worktree-, Remote-Signal- und Diff-Ideen separat produktisieren

- **Was:** Drei eigenständige Vorhaben: (1) beim vorhandenen Codex-Worktree-
  Flow nur Setup-Hook und Merge-/PR-Pfad ergänzen; (2) Needs-input-Remote-Signal
  als Opt-in; (3) aggregierte read-only Diff-Sicht. Claudes eigener
  `isolation: worktree`-Flow bleibt getrennt erhalten.
- **Warum:** Die Produktchancen sind real. **(Runde 2: Worktree, Branch,
  Ausführung im Worktree, Diff-Zähler und Dirty-Cleanup existieren bereits;
  das frühere Sammelpaket behauptete zu viel und vermischte Claude/Codex.)**
- **Aufwand/Risiko:** je M–L / mittel bis hoch.
- **Regression:** Pro Idee eigener RFC und Erfolgsmetrik; bestehender Codex-
  Cleanup, Claude-Isolation, lokale Arbeit und Branches dürfen nie automatisch
  gelöscht oder vermischt werden.

### P2.8b · Audio-, lokale STT- und Clipboard-Spikes trennen

- **Was:** (1) AUHAL nur hinter `AudioRecordingBackend` prototypisieren und
  AAC, Pegel, Ducking, Gerätewahl/-wechsel vergleichen; (2) lokale
  Transkription als optionalen Provider mit Fallback evaluieren; (3)
  Clipboard-Vollsnapshot, Ownership-Check und Paste-Fallback separat umsetzen.
  Der „Dateisystem-als-Registry“-Punkt ist gestrichen: Für die genannten Stores
  ist kein Defekt belegt und Rekonstruktion existiert bereits.
- **Warum:** Die drei Lücken sind real, aber kein gemeinsames Ticket.
  **(Runde 2: Kein AUHAL-Big-Bang und keine offene Registry-Maßnahme ohne
  belegten Fehler.)**
- **Aufwand/Risiko:** je M–L / hoch.
- **Regression:** Bestehender AVAudioEngine-/Groq-/Whisper- und Paste-Pfad
  bleibt als Fallback; Backend-/Provider-A/B-Matrix und Clipboard-Tests schützen
  Gerätewahl, Qualität, Latenz, Privacy und Nicht-Text-Inhalte.

## Technologie-Entscheidungen

| Thema | Entscheidung | Einordnung für WhisperM8 |
|---|---|---|
| Swift-6-Concurrency-Pfad | **Adoptieren** | Stabile Swift-6.3-Toolchain im Swift-5-Modus und Complete Checking jetzt; Sprachmodus danach pro Leaf-Target, UI/App zuletzt. Keine pauschalen Unsafe-Ausnahmen oder globale MainActor-Isolation. |
| Besserer Terminal-Snapshot/Recording | **Adoptieren** | Output-only ANSI/asciicast-Recording mit Limits und Replay ist die sichere kurzfristige Verbesserung und bleibt Fallback. |
| PTY-Broker | **Später** | Nur Feature-Flag-RFC nach Transport-Naht, korrektem Teardown und Recording; Default erst nach Reaper-, TTL/Cap-, Reconnect-, Upgrade- und Leak-Stresstests. tmux bleibt optional, kein Pflichtbestandteil. |
| OSC 133 und OSC 99/9/777 | **Später** | OSC 133 nur für Shell-Grenzen; Notifications untrusted, rate-limited und nach Hooks dedupliziert. Nie Agent-Turn- oder Status-SSoT. |
| `claude agents --json` | **Adoptieren** | Profilbezogene primäre Background-Reconciliation nach vollständiger Environment-Propagation; `state.json` nur Fallback. |
| `swift-subprocess` | **Später** | Nach stabilem 1.0 einen einfachen headless Command hinter `ProcessRunner` pilotieren. Nicht für PTY, dauerhaften Supervisor oder als Ersatz der Environment-Policy. |

## Ship-Gates je Welle

1. `swift test` vollständig grün; gezielte neue Regressionstests ebenfalls.
2. Kein Cleanup ohne Dry-Run/Backup/Restore, kein Future-Schema-Write.
3. CLI-/Dateiformate capability- oder versionsgegatet und sichtbar degradiert.
4. Performance-Änderungen liefern Vorher/Nachher-Messwerte.
5. Recorder-, Terminal-, Multi-Window-, Multi-Account- und TCC-Pfade erhalten
   die jeweils oben benannte manuelle macOS-QA.
6. Eine Welle ist einzeln shipbar; optionale Technologie-Spikes bleiben hinter
   Feature Flags und dürfen bestehende Funktionen nicht ersetzen.
