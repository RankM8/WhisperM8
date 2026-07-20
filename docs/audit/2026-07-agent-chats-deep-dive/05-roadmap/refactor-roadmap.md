---
status: aktiv
updated: 2026-07-20
description: Konsolidierte Refactor- und Fix-Roadmap nach technischer G0–G6-Abnahme; Produktwellen bleiben bis zur formalen User-Freigabe gesperrt.
description_long: Ordnet C01–C16, N01–N16 und die bestätigten Runde-3-/Runde-4-Findings in ausführbare Wellen ein; trotz technisch erfülltem Dokumentationsgate starten W0.1, Identitäts-/Recovery- und Kernwellen erst nach User-Go.
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

## Nachtrag Runde 3 / Workflow 3

### Status und Leseregel

Dieser Nachtrag **ergänzt** die bestehenden Wellen; er schreibt sie nicht
historisch um. Die vollständige Runde-3-Synthese ist
[`06-umsetzung/README.md`](../06-umsetzung/README.md). Die eindeutigen Aliase hier
lösen die vierfach wiederverwendeten Finder-IDs `G01` usw. für die Roadmap auf.

**Keine Umsetzungsfreigabe:** Die Schlussverifikation urteilt „noch nicht
umsetzungsreif“ und nennt fünf P0-Lücken
([`verifikation-schluss.md:27-45`](../06-umsetzung/verifikation-schluss.md)). Die
Vollständigkeitskritik verlangt zusätzlich Traceability, Terminal-Verdicts und
ein gemeinsames Freigabe-Gate
([`runde3-vollstaendigkeits-kritik.md:46-220`](../02-findings/runde3-vollstaendigkeits-kritik.md)).
Die Einordnung in eine Welle ist daher eine Planungszuordnung, kein „Go“.

### Sichtbare, verifikationsbedingte Übersteuerungen bestehender Wellen

Die folgenden Punkte ändern keine historische Formulierung oben, **übersteuern
sie aber verbindlich**, weil die Schlussverifikation den bisherigen Vertrag
widerlegt oder als unimplementierbar bewertet:

1. **ÄNDERUNG W0.1 — kein vollständiger `ProcessRunner`-God-Spy.** Der in W0.1
   genannte „vollständige ProcessRunner-Spy“ wird in minimale Nähte getrennt:
   one-shot argv/cwd/env/fertiges Resultat und kontrollierbarer langlebiger
   Child-Prozess mit Spawnidentität, Ready/Exit und TERM/KILL. Das vorhandene
   `ProcessRunner`-Protokoll exponiert weder Environment noch Handle oder
   Signale (`WhisperM8/Services/AgentChats/BackgroundAgentSpawner.swift:217-230`;
   [`verifikation-schluss.md:294-303`](../06-umsetzung/verifikation-schluss.md)).
2. **ÄNDERUNG W0/W1 — C07 und fehlende Welle-1-Oracles vorziehen.** Vor W1-
   Produktänderungen müssen C07, Child-Environment, Headless-Prävention,
   Git-Stale-Result, WindowStore-Diff und Transcript-Cache abgedeckt sein. Die
   aktuelle Test-Spec lässt diese Verträge aus
   ([`verifikation-schluss.md:269-303`](../06-umsetzung/verifikation-schluss.md)).
3. **ÄNDERUNG W1/W2 — ein gemeinsamer Termination-Contract zuerst.** R2.1 und
   P0.7 ändern denselben App-Quit-Pfad und dürfen nicht als zwei unabhängige
   Umbauten anlaufen. Der heutige App-Hook capturt synchron und antwortet sofort
   `.terminateNow` (`WhisperM8/WhisperM8App.swift:343-351`); Recorder,
   Terminal-Drain/Snapshot, Workspace-Flush und Proxy-Shutdown brauchen vor
   beiden Maßnahmen einen gemeinsamen `.terminateLater`-/Reply-Vertrag.
4. **ÄNDERUNG W2 — „erste passende Hook-ID bindet“ ist ausgesetzt.** P0.5/P0.6/
   P1.3/P1.4 dürfen nicht auf dieser Formulierung implementiert werden. Vorher
   sind capability-gegatete Weg-A/Weg-B-Strategie, launchspezifischer
   Hook-Envelope, Generation-Guard, Config-Root-Ableitung, Claim-API,
   Laufzeit-Branchwechsel und Recovery-Evidenz zu spezifizieren. Die capability-
   gegatete Strategie ist jetzt normativ als `hostAssignedUnsupported`/
   `hostAssignedVerified` in
   [`identitaetsmodell-spec.md` §2.2](../06-umsetzung/identitaetsmodell-spec.md)
   definiert. Der Hook
   transportiert heute keine WhisperM8-Launch-ID
   (`WhisperM8/Services/AgentChats/ClaudeHookEventStore.swift:36-46,121-136`;
   `WhisperM8/Services/AgentChats/ClaudeHookBridge.swift:27-41,218-229`).
5. **ÄNDERUNG W2/W3 — externer History-Write bleibt gesperrt.** Der in der
   Recovery-Spec erwogene Copy+Verify-Pfad in `~/.claude/` ist keine freigegebene
   Maßnahme, solange die Datenhoheitsleitplanke nicht ausdrücklich entschieden
   ist ([`verifikation-schluss.md:161-169`](../06-umsetzung/verifikation-schluss.md)).

### Bestätigte GPT-Findings: eindeutige IDs und Wellen

#### Definition, Skill und Settings

Quelle und Verdictmatrix:
[`runde3-definition-settings.md:373-384`](../04-verifikation/runde3-definition-settings.md).
Finder-G05 ist **widerlegt** und erhält keine Maßnahme.

| Stabile ID | Bestätigter Befund | Welle / Maßnahme | Gate |
|---|---|---|---|
| `R3-DEF-G01` | Generischer Skill-Zielname; Update überschreibt ohne Ownership-/Restore-Vertrag (`WhisperM8/Services/Shared/CLISkillExporter.swift:102-176`). | **W1:** Ownership-Marker, Fremddatei-Guard, Backup/Restore und sichtbarer Konflikt als eigener Change. | Fremde Datei bleibt bytegleich; nur eigene Generation darf aktualisiert/entfernt werden. |
| `R3-DEF-G02` | Ein Profil, das vor dem Main-`skills`-Verzeichnis angelegt wurde, erhält einen später reparierten Symlink nicht zuverlässig (`WhisperM8/Services/AgentChats/ClaudeAccountProfiles.swift:225-275`). | **W1**, nach `R3-DEF-G01`: idempotente profilweite Reconciliation. | Main-Root vor/nach Profil, mehrere Config-Roots, fehlender/defekter/fremder Link. |
| `R3-DEF-G03` | Detached Definition-Sync und Settings-/Proxy-Sync teilen keine Batch-Generation (`WhisperM8/Services/AgentChats/ClaudeGPTAgentDefinition.swift:50-103`; `WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:218-277`). | **W1**, gemeinsam mit GPT-Lifecycle: generationengebundener Multi-Root-Plan/Commit. | Toggle/Portwechsel während Sync endet überall in genau einer aktuellen Generation. |
| `R3-DEF-G04` | Read/Write/Remove-Fehler werden verschluckt oder falsch als Erfolg/No-op klassifiziert (`WhisperM8/Services/AgentChats/ClaudeGPTAgentDefinition.swift:60-94`). | **W1:** typed Result, sichtbarer Fehler, Retry/Reconciliation. | Permission-, Disk- und Remove-Fehler dürfen nie Erfolg melden. |

#### Proxy-Lifecycle

Quelle und Verdictmatrix:
[`runde3-proxy.md:403-414`](../04-verifikation/runde3-proxy.md).

| Stabile ID | Bestätigter Befund | Welle / Maßnahme | Gate |
|---|---|---|---|
| `R3-PROXY-G01` | Ensure gegen Stop/App-Quit ist nicht als ein Lifecycle serialisiert (`WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:218-300`). | **W1:** ein Proxy-/Router-Zustandsautomat unter einem Lifecycle-Owner. | Deterministische Start↔Stop↔Quit-Barrieren; nach Stop kein spätes Ready. |
| `R3-PROXY-G02` | Proxy-Exit bleibt ohne Lifecycle-Recovery; Ownership kann stale bleiben (`WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:286-300,540-557`). | **W1**, nach G01: Exit-Monitor, Ownership-Clear, begrenzte Recovery. | Crash vor/nach Ready, PID-Reuse und App-Neustart. |
| `R3-PROXY-G03` | `claude --bg` kann vor Guard/Router starten und erhält kein Router-/Profil-Environment (`WhisperM8/Views/AgentChatsView+BackgroundAgents.swift:68-95`; `WhisperM8/Services/AgentChats/BackgroundAgentSpawner.swift:78-137,223-258`). | **W1:** Spawn erst nach Ready-Generation; `P1.1`-Environment-Fabrik auf Background erweitern. **GPT-Ship-Blocker.** | Background GPT darf ohne aktuelle Ready-Generation nicht spawnen; Claude-Background bleibt unverändert. |
| `R3-PROXY-G04` | Ein alter `.ready`-Snapshot überlebt Kill-Switch-Wechsel (`WhisperM8/Views/AgentSessionDetailView.swift:393-450,455-509`). | **W1:** Launch-Ticket an Konfigurationsgeneration binden und vor Spawn erneut prüfen. **GPT-Ship-Blocker.** | Toggle an jedem Suspension-Point verhindert den vorbereiteten GPT-Launch. |
| `R3-PROXY-G05` | Backend-/Router-Port wird an mehreren Zeitpunkten live neu gelesen (`WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:218-283`; `WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:85-95,534-542`). | **W1:** immutable Endpoint-Snapshot je Generation. | Portwechsel während Ensure/Forward mischt keine Endpunkte. |

#### Security

Quelle und Verdictmatrix:
[`runde3-security.md:27-39`](../04-verifikation/runde3-security.md). G03 bleibt
bestätigt, ist im Refuter aber auf **niedrig** abgestuft.

| Stabile ID | Bestätigter Befund | Welle / Maßnahme | Gate |
|---|---|---|---|
| `R3-SEC-G01` | Nachbildbares `/healthz` legitimiert einen fremden Listener (`WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:225-283,469-537`). | **W1:** Runtime-ID/PID/Startzeit plus Challenge-gebundene Health-Identität. **GPT-Ship-Blocker.** | Port-Hijack- und stale-PID-Fixtures dürfen nicht als eigene Instanz gelten. |
| `R3-SEC-G02` | Lokale Listener exportieren die Codex-OAuth-Capability ohne Client-Authentisierung (`WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:127-134,403-423,534-575`). | **W1:** per-Generation lokales Client-Credential und Loopback-Bindungsprüfung. **GPT-Ship-Blocker.** | Unauthentisierter lokaler Client erhält keinen Forward; Claude-CLI mit Ticket funktioniert. |
| `R3-SEC-G03` | Geerbtes `CCP_TRAFFIC_LOG` kann vollständiges Payload-Capture aktivieren (`WhisperM8/Services/Shared/LoginShellEnvironment.swift:91-137`; `WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:237-249,545-552`). | **W1 / P1.1:** GPT-Prozessklasse allowlistet Environment; Diagnose nur explizit. | Parent-Canary fehlt im Kind; Opt-in-Diagnose setzt restriktive Dateirechte/Retention. |
| `R3-SEC-G04` | Settings-Toggle sperrt neue Route, beendet Listener aber nicht (`WhisperM8/Views/Settings/Pages/GPTBackendSettingsPage.swift:47-78,329-337`; `WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:286-300`). | **W1**, im Lifecycle-Automaten: getrennte, dokumentierte Router-/Proxy-Shutdown-Policy. | Toggle beendet oder entprivilegiert Listener deterministisch; Re-enable ist sauber. |

#### MixRouter und Übersetzungsvertrag

Quelle und Verdictmatrix:
[`runde3-mixrouter.md:461-474`](../04-verifikation/runde3-mixrouter.md).
`R3-MIX-G01` ist code-seitig bestätigt, braucht vor einem verlustbehafteten
Rewrite aber die dort geforderte echte Providerwechsel-Fixture.

| Stabile ID | Bestätigter Befund | Welle / Maßnahme | Gate |
|---|---|---|---|
| `R3-MIX-G01` | Providerwechsel transportiert inkompatible Thinking-Historie; E2E-Teilvorbehalt bleibt. | **W0 Fixture, frühestens W2 Fix:** Fable→GPT→Fable-Golden-Contract; nur danach gezielte History-Normalisierung. | Kein Rewrite ohne echte CLI-/Proxy-Fixture; Tool-/Text-Historie bleibt vollständig. |
| `R3-MIX-G02` | Bilder in `tool_result` werden verworfen; direkte User-Bilder bleiben erhalten. | **W3 / P1.11-Ergänzung:** Capability sichtbar machen oder Pixel erhalten. | E2E-Fixture für User-Bild und Tool-Result-Bild. |
| `R3-MIX-G03` | `/count_tokens` kann lange alphanumerische Runs massiv unterschätzen. | **W1:** externen Token-Count-Vertrag qualifizieren und Proxy-Fix/Mindestversion festlegen. **GPT-Ship-Blocker für lange Sessions.** | Golden-Korpus einschließlich langer Runs gegen referenzierten Tokenizer. |
| `R3-MIX-G04` | MixRouter-eigene Pre-Head-Fehler werden generischer Plaintext-502. | **W2:** Anthropic-kompatibles lokales Fehlerformat und terminaler SSE-Fehler, soweit sendbar. | Vor/nach Header, Timeout, Disconnect und Upstreamfehler. |
| `R3-MIX-G05` | Client-Disconnect wird während Pre-Header-Denkphase nicht aktiv gelesen. | **W2:** paralleler bounded EOF-Read cancelt die Upstream-Task. | FIN während Denken beendet URLSession und Connection ohne Hänger. |
| `R3-MIX-G06` | Kein globales Parallel-/Bytebudget; bis 64 MiB Body und eigene URLSession je Request (`WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:73-83,403-450,487-575,689-729`). | **W2:** globale Connection-/Bytebudgets, Backpressure und geteilte Session-Policy. | Überlast degradiert begrenzt; Claude-Route und normale Parallelität bleiben funktionsfähig. |
| `R3-MIX-G07` | Produktiver Übersetzungsvertrag ist weder versioniert noch lokal gegen den echten Proxy getestet (`WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:218-283,469-537`; `Tests/WhisperM8Tests/ClaudeGPTMixRouterTests.swift:219-276,463-615`). | **W0 vor allen GPT-Fixes:** Manifest aus Repo/Tag/Hash/Semver/Capabilities plus hermetische Golden-Fixtures. **GPT-Ship-Blocker.** | Unbekannte Version/Capability degradiert sichtbar statt ungeprüft zu starten. |

#### Live-Usage/Kompaktierung

| Stabile ID | Bestätigter Befund | Welle / Maßnahme | Gate |
|---|---|---|---|
| `R3-LIVE-G01` | Subagent-Usage/Kompaktierung ist E2E gebrochen; die frühere Aussage „keine Übersetzung vorhanden“ ist widerlegt. Der Diagnose-Nachtrag lokalisiert den Standardpfad auf nullwertige `message_start`-Usage plus nicht gemergtes finales `message_delta`; zwei Tool-Finish-Pfade liefern zusätzlich `usage=None` ([`gpt-usage-kompaktierung-fix-spec.md:145-235`](../06-umsetzung/gpt-usage-kompaktierung-fix-spec.md)). | **W1:** Ebene 1 ist dokumentiert umgesetzt; offen sind echter Proxy-Terminalevent→Router→CLI/Transcript-Golden-Test, Upstream-Patch oder qualifizierte Mindestversion und enger Fallback. Die große Router-Fill-if-missing-Skizze entfällt. | Hauptchat **und** Modell-Subagent zeigen wachsende Usage und kompaktieren vor dem Limit; `/context` prüft auch die `[1m]`-/272k-Annahme. |

### Verifizierte Recherche-Lücken und Zuordnung

Die Recherche-Verdicts werden **nicht als weitere G-Findings doppelt gezählt**.
Übernommen werden nur tragfähige beziehungsweise bestätigte Lücken; widerlegte,
fragwürdige oder abgelehnte Forderungen bleiben draußen.

| Verifizierte Lücke / Muster | Zuordnung | Roadmap-Folge |
|---|---|---|
| Ready-/Detach-Acceptance, Owner-/Waiter-Trennung, Prozess-/Protokoll-Finalität und Stop-Latch sind tragfähig ([`runde3-recherche-muster.md:157-254`](../04-verifikation/runde3-recherche-muster.md)). | **W1 / R2.4** | Kein neues Paket; R2.4-Gates ausdrücklich um Acceptance-Generation und Stop-vor-Registrierung ergänzen. Kein dauerhafter neuer Control-Broker. |
| Provider-ID bis Timeline und explizites Parse-Outcome sind tragfähig (`WhisperM8/Models/AgentChatTranscript.swift:11-31`; `WhisperM8/Services/AgentChats/ClaudeTranscriptReader.swift:89-117`; [`runde3-recherche-muster.md:255-333`](../04-verifikation/runde3-recherche-muster.md)). | **W3 / P1.11** | `providerSessionID`/Korrelations-ID und `parsed|unknown|malformed` als Golden-Vertrag. Gemeinsamer Full-/Tail-Scanner bleibt bis W4 zurückgestellt. |
| Child-Environment als Prozessklassen-Vertrag mit Kompatibilitäts-Gate ist tragfähig (`WhisperM8/Services/Shared/LoginShellEnvironment.swift:91-137`; [`runde3-recherche-muster.md:409-429`](../04-verifikation/runde3-recherche-muster.md)). | **W1 / P1.1** | PATH/TERM/Profil/MCP-Allowlist pro Prozessklasse; keine Parent-Secrets. |
| Transaktionale Legacy-Keychain-Migration und Profil-Rename ohne Secret in argv sind tragfähig ([`runde3-recherche-muster.md:430-464`](../04-verifikation/runde3-recherche-muster.md)). | **W1 / R2.3 und P1.1** | Bestehende Maßnahmen bestätigt; Write+Readback sowie sicherer Transfer bleiben Gates. |
| Validierter Execution-Plan ist als strukturelle Router-Grenze bestätigt, beim heutigen Zwei-Backend-Scope aber kein akuter Defekt ([`runde3-recherche-proxy.md:309-328`](../04-verifikation/runde3-recherche-proxy.md)). | **W4 / zurückgestellt** | Erst bei zusätzlicher Routingpolicy als typed Plan; kein W1-Big-Bang. |
| Äußerer semantischer Streamabschluss ist im MixRouter lückenhaft, für GPT aber stark durch den Proxy mitigiert; Usage, Ownership, Tool-Result-Bilder, lokale Fehler und Client-FIN sind real ([`runde3-recherche-proxy.md:309-357`](../04-verifikation/runde3-recherche-proxy.md)). | **W0/W1/W2/W3** | Durch `R3-MIX-*`, `R3-PROXY-*`, `R3-SEC-*` und `R3-LIVE-G01` bereits abgedeckt; keine zweite Übersetzungsschicht und keine Doppelzählung. |

Nicht aufgenommen werden MetricKit oder KSCrash als W0/P0-Produktpflicht, ein
vorzeitiger gemeinsamer Scanner, Raw-Byte-Range/Oversize-Base64 in P1.11, ein
neuer dauerhafter Supervisor-Control-Kanal oder zusätzliche GPT-Retries. Die
Recherche-Verifikation bewertet diese Forderungen als fragwürdig oder lehnt sie
ab ([`runde3-recherche-muster.md:35-55,465-477`](../04-verifikation/runde3-recherche-muster.md);
[`runde3-recherche-proxy.md:359-364`](../04-verifikation/runde3-recherche-proxy.md)).

### Noch nicht bestätigte Terminal-Snapshot-Population

Die fünf Findings aus
[`runde3-terminal-snapshots.md`](../02-findings/runde3-terminal-snapshots.md)
werden **nicht** als bestätigte G-Population ausgegeben: Ein dedizierter
Runde-3-Verdictbericht fehlt. Bis zur Urteilsmatrix gilt ein Ship-Stop für den
betroffenen Termination-/Sidecar-Umbau. Bereits codebelegt und daher als offene
Prüfpunkte zu verplanen sind:

- Plaintext-Snapshot ohne TTL/Gesamtbudget (`WhisperM8/Services/AgentChats/TerminalSnapshotStore.swift:14-29,48-60,65-119`) — vorläufig **W2/T1**;
- `delete` ohne Erfolgswert, Tombstone oder Retry (`WhisperM8/Services/AgentChats/TerminalSnapshotStore.swift:109-119`) — vorläufig **W2**;
- Existenzcheck deferiert JSONL, obwohl `load` bei kaputtem/neuem Header `nil`
  liefert (`WhisperM8/Services/AgentChats/TerminalSnapshotStore.swift:70-73,94-106`;
  `WhisperM8/Views/AgentSessionDetailView.swift:201-225,255-260`) — vorläufig
  **W2**, Rot→Grün-Gate vor T1.

G01/G05 sind mit dem gemeinsamen Termination-/Drain-Contract abzugleichen; eine
fünfzeilige finale Verdictmatrix entscheidet Schwere, Duplikate und endgültige
Wellenzuordnung
([`runde3-vollstaendigkeits-kritik.md:140-171,263-270`](../02-findings/runde3-vollstaendigkeits-kritik.md)).

### Freigabe-Gate vor Runde-3-Kernwellen

Vor dem ersten Produktchange an Identitäts-, Terminal- oder GPT-Kernwellen:

- [ ] deduplizierte Finding→Verdict→Maßnahme-Matrix mit Ownern und Tests;
- [ ] alle neun Nacharbeiten aus der Schlussverifikation geschlossen;
- [ ] Terminal-G01–G05-Verdictmatrix und gemeinsamer Termination-Contract;
- [ ] Proxy-/CLI-Version, Capabilities und Golden-Fixtures reproduzierbar
      manifestiert;
- [ ] Fork-Hook-Ereignisfolge live gegen die unterstützte CLI-Version belegt;
- [ ] Inventare korrigiert; Kategorie-1-Tests vor Umbau, Kategorie-2-Tests mit Fix;
- [ ] GPT-Ship-Blocker `R3-PROXY-G03/G04`, `R3-SEC-G01/G02`,
      `R3-MIX-G03/G07` und `R3-LIVE-G01` geschlossen;
- [ ] ältere kritische/hohe Findings außerhalb C/N besitzen einen sichtbaren
      Status oder eine begründete Zurückstellung.

Kleine, nichtdestruktive Vorarbeiten bleiben zulässig, soweit
[`verifikation-schluss.md:348-360`](../06-umsetzung/verifikation-schluss.md) sie
explizit freigibt. Eine Wellenzuordnung allein ersetzt dieses Gate nicht.

## Nachtrag Runde 4

### Status, Leseregel und Freigabe

Dieser Nachtrag ergänzt die bestehenden Wellen, ohne sie umzuschreiben. Er enthält
nur Findings, denen der jeweilige Refuter ein ausdrückliches **BESTÄTIGT**-Urteil
gegeben hat. Nur gezählte, nicht geprüfte oder widerlegte Runde-4-Einträge sind
nicht aufgenommen. Die Abschlusskritik bleibt maßgeblich: Keiner der fünf
P0-Blocker ist entschärft; P0 1 und 3 sind unverändert, P0 2, 4 und 5 verschärft
([`runde4-abschlusskritik.md:13-23`](../02-findings/runde4-abschlusskritik.md)).
Die folgende Zuordnung ist deshalb Planung, kein Produkt-Go.

Wo Finder-IDs kollidieren, wird der Bericht als Alias ergänzt: `R4-PROFILE-01`
aus dem Statusline-/Skill-Bericht heißt hier `R4-STATUS-PROFILE-01`; der
gleichnamige Delta-Befund heißt `R4-DELTA-PROFILE-01` und ist inhaltlich dasselbe
Problem wie `R4-CP-02`, also nur eine Maßnahme.

### W0 — Oracles und Verträge vor Produktänderungen

| Bestätigtes Finding | Wellen-Zuordnung und Gate |
|---|---|
| `R4-WAIT-01` | **W0 Oracle, W1 Fix:** `new → wait --ref` muss spätes Provider-Binding nachladen; heute hält `wait` ein unveränderliches Entry-Array (`WhisperM8/CLI/ChatsWaitEngine.swift:41-67,321-342`) und der Probe liefert ohne externe ID weder Revision noch Transcriptpfad (`WhisperM8/CLI/ChatsStatusProbe.swift:74-86`). |
| `R4-WAIT-02` | **W0 Oracle, W1 Fix:** pro Session ein monotoner Cursor samt Zustandsübergang statt globalem Größenmaximum; Revision ist heute nur die Größe der jeweiligen Datei (`WhisperM8/CLI/ChatsStatusProbe.swift:137-153,186-193`), die Engine vergleicht alle Sessions mit einem Skalar (`WhisperM8/CLI/ChatsWaitEngine.swift:41-50,74-87`). |
| `R4-SCHEMA-01` | **W0 Oracle, W1 Fix:** Future-Version-Sperre und Migration für `contextProfileID`; das Feld ist persistiert (`WhisperM8/Models/AgentChat.swift:178-207,320-466`), die Schema-Version bleibt 1 und wird beim Normalisieren überschrieben (`WhisperM8/Models/AgentChat.swift:602-627`; `WhisperM8/Services/AgentChats/AgentSessionStore.swift:1182-1189`). |
| `R4-AS-11` | **W0 Oracle, W1 Fix · gefixt (`7953cf5`):** Load-Migration dedupliziert lokale Session-IDs stabil, und der Summary-Planer besitzt keine trap-fähige `Dictionary(uniqueKeysWithValues:)`-Vorbedingung mehr (`WhisperM8/Services/AgentChats/AgentSessionStore.swift:1184-1196`; `WhisperM8/Services/AgentChats/SummaryStartupPlanner.swift:7-24`; `Tests/WhisperM8Tests/AgentSessionStoreTests.swift:259-277`; `Tests/WhisperM8Tests/AgentSessionSummarizerTests.swift:160-175`). |

### W1 — Aktiven Schaden und Sicherheitslücken stoppen

| Bestätigtes Finding | Wellen-Zuordnung und Gate |
|---|---|
| `R4-AUTH-01` | **W1:** Control-Mutationen zentral an verifizierte Actor-Capability und zulässige Zielbeziehung binden; heute prüft der Server nur Same-EUID (`WhisperM8/Services/AgentChats/AgentControlServer.swift:228-239`) und der Handler keinen zentralen Auth-Guard (`WhisperM8/Services/AgentChats/AgentControlRequestHandler.swift:30-55`). |
| `R4-AUTH-02` | **W1:** Client authentisiert Socket-Owner, Dateityp, Peer und Response-Korrelation vor Token-/Promptversand; derzeit werden weder `protocolVersion` noch `requestID` geprüft (`WhisperM8/CLI/ChatsControlClient.swift:23-40,50-98`). |
| `R4-IDEM-01` | **W1:** stabile Request-ID über CLI-Retries und ein abfragbarer Outcome; heute erzeugt jeder Aufruf eine UUID (`WhisperM8/CLI/ChatsControlProtocol.swift:71-91`), während ein Server-Timeout die Mutation weiterlaufen lässt (`WhisperM8/Services/AgentChats/AgentControlServer.swift:295-318`). |
| `R4-PROF-01` | **W1:** `session.new` muss Account-, Backend- und Context-Snapshot wie die UI stempeln; der Control-Pfad reicht diese Felder nicht weiter (`WhisperM8/Services/AgentChats/AgentChatLaunchService.swift:77-96`), obwohl sie Launch-Argumente und Environment bestimmen (`WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:61-70,286-302,391-402`). |
| `R4-CP-02` / `R4-DELTA-PROFILE-01` | **W1, eine deduplizierte Maßnahme:** angeforderte Restriktionsprofile müssen bei Settings-I/O fail-closed enden; `prepareSettingsFile` reduziert Fehler auf `nil` (`WhisperM8/Services/AgentChats/ClaudeHookBridge.swift:91-117`) und der Coordinator startet ohne Settings-Argumente weiter (`WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:102-135`; `WhisperM8/Views/AgentSessionDetailView.swift:518-532`). |
| `R4-CP-03` | **W1:** Background-Respawn muss das aktuelle Context-Overlay neu erzeugen oder eine unveränderliche Snapshot-Semantik deklarieren; der Respawn reicht heute nur die Short-ID weiter (`WhisperM8/Views/AgentChatsView+BackgroundAgents.swift:171-199`; `WhisperM8/Services/AgentChats/BackgroundAgentLifecycle.swift:99-106,150-172`). |
| `R4-CP-05` | **W1 / P1.1:** der Environment-Filter sperrt die gesamte `CLAUDE_CODE_*`-Familie auch nach Profil-Overlay; derzeit filtert er nur einzelne Namen (`WhisperM8/Services/AgentChats/ClaudeContextSettingsBuilder.swift:13-24,56-67`), die Overrides gewinnen anschließend gegen das bereinigte Basis-Environment (`WhisperM8/Views/AgentTerminalView.swift:787-799`). |
| `R4-GPTS-01` | **W1, GPT-Ship-Blocker:** Updates brauchen eine unabhängige Publisher-/Signatur-Vertrauenswurzel; für nicht gepinnte Versionen stammen Payload und Hash aus demselben Release (`WhisperM8/Services/AgentChats/ClaudeCodeProxyBinaryInstaller.swift:123-150`), und die UI installiert `releases/latest` direkt (`WhisperM8/Views/Settings/Pages/GPTBackendSettingsPage.swift:353-395`). |
| `R4-GPTL-02` | **W1:** Setup und Refresh erhalten Task-Identität, Generation und Cancellation; `runFullSetup` startet heute unstrukturierte Arbeit ohne Handle (`WhisperM8/Views/Settings/Pages/GPTBackendSettingsPage.swift:404-456`), Refresh schreibt ohne Zustands-/Generationsprüfung zurück (`WhisperM8/Views/Settings/Pages/GPTBackendSettingsPage.swift:460-492`). |
| `R4-PLUG-01` | **W1:** secret-verdächtige Plugin-Konfiguration darf nicht in argv gelangen; freie `key=value`-Zeilen werden derzeit ungefiltert als `--config` serialisiert (`WhisperM8/Views/Settings/Kit/SettingsLineParsing.swift:13-22`; `WhisperM8/Services/AgentChats/ClaudePluginCLI.swift:91-101`). |
| `R4-PLUG-02` | **W1:** Plugin-Operationen erst nach Prozessbaum- und Stream-Finalität freigeben; Timeout signalisiert nur das direkte Child und `forceFinish` umgeht EOF (`WhisperM8/Services/AgentChats/AgentHeadlessCLI.swift:78-111,174-190`), während der Serializer nur Swift-Tasks ordnet (`WhisperM8/Services/AgentChats/ClaudePluginCLI.swift:13-31,162-174`). |
| `R4-STATUS-01` | **W1 · gefixt (`63c2adc`):** `StatuslineInstaller` verwendet für die SwiftPM-Ressource `Bundle.module`; der Regressionstest lädt das gebündelte Skript über den Default-Installer (`WhisperM8/Services/Shared/StatuslineInstaller.swift:18-31,76-82`; `Tests/WhisperM8Tests/StatuslineInstallerTests.swift:43-51`). |
| `R4-SHELL-01` | **W1:** Nutzdaten strikt per `printf` ausgeben und Steuerzeichen entfernen; Modell-, Repo-, MCP- und Profildaten laufen derzeit in ein gemeinsames `echo -e` (`WhisperM8/Resources/whisperm8-statusline.sh:36-56,232-249,369-429`). |
| `R4-INSTALL-01` | **W1:** Statusline-Settings mit Lock/CAS oder Re-Read/Merge schreiben; heute liegt zwischen Vollsnapshot-Read und atomarem Replace keine Konfliktprüfung (`WhisperM8/Services/Shared/StatuslineInstaller.swift:190-216`). |
| `R4-SKILL-01` | **W1:** Ownership-Marker, Fremddatei-Guard und Backup/Restore vor Skill-Update; Byteabweichung führt heute zum bedingungslosen Überschreiben verwalteter Namen (`WhisperM8/Services/Shared/CLISkillExporter.swift:127-177`; `WhisperM8/Views/Settings/Pages/CLISkillsSettingsPage.swift:269-295`). |
| `R4-HCLI-02` | **W1:** Headless-Timeout beendet den Prozessbaum und wartet auf beide EOFs; aktuell signalisiert er nur die Child-PID und `forceFinish` umgeht die Abschlussinvariante (`WhisperM8/Services/AgentChats/AgentHeadlessCLI.swift:69-75,97-106,174-182`). |
| `R4-CTRL-01` | **W1:** Prompt-Inhalt darf den Bracketed-Paste-Block nicht vorzeitig schließen; `sendPrompt` schreibt den Text heute ungefiltert zwischen die Kontrollsequenzen (`WhisperM8/Views/AgentTerminalView.swift:649-661`). |
| `R4-CTRL-02` | **W1:** zielbezogene FIFO und bestätigtes Submit vor `ack: delivered`; Return folgt heute separat nach 80 ms (`WhisperM8/Views/AgentTerminalView.swift:657-667`), der Handler bestätigt vorher und mehrere Verbindungen laufen parallel (`WhisperM8/Services/AgentChats/AgentControlRequestHandler.swift:127-174`; `WhisperM8/Services/AgentChats/AgentControlServer.swift:27-34`). |
| `R4-RESUME-01` | **W1 · gefixt (`3db6d4d`), View-QA offen:** Beide Launch-Fehlerpfade setzen `focusLaunchInFlight` zurück; die manuelle QA bleibt nötig, weil der Zustand View-lokal ist (`WhisperM8/Views/AgentSessionDetailView.swift:176-205,457-469,476-562`). |
| `R4-LIFE-01` | **W1:** Eager GPT-Startup an Preference-Generation und Quit-Barriere binden; der detached Task prüft den Toggle nur vorab (`WhisperM8/WhisperM8App.swift:304-313`), während Quit sofort beendet und Stop nicht über denselben Ensure-Lock serialisiert (`WhisperM8/WhisperM8App.swift:359-367`; `WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:198-205,218-299`). |
| `R4-AS-01` | **W1:** Theme-Settings gegen externe Writer per Lock/CAS oder Re-Read/Merge schützen; der Writer ersetzt einen einmal gelesenen Vollsnapshot ohne Konfliktprüfung (`WhisperM8/Services/AgentChats/ClaudeThemeWriter.swift:108-153`). |
| `R4-AS-03` | **W1 · gefixt (`d375855`):** Der Git-Runner leert stdout vor dem Exit-Wait, schreibt stderr deadlockfrei in eine temporäre Datei und terminiert nach 10 Sekunden mit Eskalation; die Regressionstests decken Pipe-Druck und Deadline ab (`WhisperM8/Services/AgentChats/AgentWorktreeManager.swift:75-133`; `Tests/WhisperM8Tests/AgentWorktreeManagerTests.swift`). |
| `R4-VC-03` | **W1 · gefixt (`3086b9e`):** ffmpeg schreibt stdout nach `/dev/null`, stderr wird vor dem Exit-Wait vollständig geleert und eine 600-Sekunden-Deadline terminiert mit Eskalation; die Regressionstests decken große Ausgabe und Deadline ab (`WhisperM8/CLI/CLIAudioExtractor.swift:200-255`; `Tests/WhisperM8Tests/CLIAudioExtractorTests.swift`). |

### W2/W3 — Nachgelagerte Korrektheit und Härtung

| Bestätigtes Finding | Wellen-Zuordnung und Gate |
|---|---|
| `R4-AUTH-03` / `R4-TOKEN-01` | **W2, eine deduplizierte Maßnahme:** PTY-Capability bei explizitem und natürlichem Ende widerrufen; beide Exitpfade rufen den vorhandenen Registry-Widerruf nicht auf (`WhisperM8/Views/AgentTerminalView.swift:820-842,1014-1025`; `WhisperM8/Services/AgentChats/AgentSessionTokenRegistry.swift:40-44`). |
| `R4-SEC-01` | **W2:** Prompt und Token aus argv beziehungsweise vererbbarer Umgebung entfernen und Audit-Vorschauen redigieren; die heutigen Pfade exponieren beides und speichern die ersten 80 Zeichen (`WhisperM8/CLI/ChatsLiveCommands.swift:110-158,280-316`; `WhisperM8/Views/AgentTerminalView.swift:800-815`; `WhisperM8/Services/AgentChats/ChatsAuditLog.swift:85-94`). |
| `R4-CP-01` | **W2:** Background-Agenten entweder profilbewusst starten oder die Main-Account-Grenze als explizite Capability erzwingen; der Dispatch persistiert kein Profil und der Spawner besitzt kein Environment (`WhisperM8/Views/AgentChatsView+BackgroundAgents.swift:43-64`; `WhisperM8/Services/AgentChats/BackgroundAgentSpawner.swift:78-112,223-258`). |
| `R4-CP-04` | **W2:** Resume-Semantik für `nil`-Context festschreiben und testen; ein fehlender Legacy-Stempel wird zu `nil` dekodiert und fällt beim Resume auf den späteren Projekt-Default zurück (`WhisperM8/Models/AgentChat.swift:315-320,428-466`; `WhisperM8/Services/AgentChats/ClaudeContextProfileStore.swift:109-122`; `WhisperM8/Views/AgentSessionDetailView.swift:513-525`). |
| `R4-GPTL-03` | **W2:** Toggle-off muss Device-Login und UI-State gemeinsam abbrechen; `clearStatus()` löscht heute nur Teile des Page-State und ruft keinen Manager-Teardown (`WhisperM8/Views/Settings/Pages/GPTBackendSettingsPage.swift:101-108,514-550`; `WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:336-346,443-451`). |
| `R4-GPTI-05` | **W2:** Binary und Versionsstempel als crash-recoverbare Transaktion veröffentlichen; Lock und Staging verhindern Parallelmischung, aber Binary-Replace, `chmod` und Stempel-Replace bleiben separate crashbare Schritte (`WhisperM8/Services/AgentChats/ClaudeCodeProxyBinaryInstaller.swift:27-30,169-200`), und der Resolver akzeptiert ein ausführbares Managed Binary auch ohne Stempel (`WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:318-329`). |
| `R4-PLUG-03` | **W2:** Detailcache an Profil und Generation binden; der Key enthält heute nur Plugin-ID/Version und ein Alt-Request darf nach Profilwechsel schreiben (`WhisperM8/Services/AgentChats/ClaudePluginManagerModel.swift:19-21,46-83,156-160`). |
| `R4-PLUG-07` | **W3:** Loaded/Error/Unavailable explizit modellieren; leere Failure-Placeholder gelten heute als vollständig und entfernen den `(partial)`-Hinweis (`WhisperM8/Services/AgentChats/ClaudePluginManagerModel.swift:31-44,66-83`; `WhisperM8/Views/Settings/Pages/ClaudePluginsSettingsPage.swift:163-171`). |
| `R4-STATUS-PROFILE-01` | **W2:** Shared-Item-Symlinks profilweit reconciliieren; `createProfile()` verlinkt nur bereits vorhandene Quellen und der spätere Export repariert Profile nicht (`WhisperM8/Services/AgentChats/ClaudeAccountProfiles.swift:227-272`; `WhisperM8/Services/Shared/CLISkillExporter.swift:107-124,151-179`). |
| `R4-SHELL-02` | **W2:** Usage-Lock atomar claimen und Cache via temp+rename veröffentlichen; Prüfung, Lock-Erzeugung und Cache-Write sind heute getrennt (`WhisperM8/Resources/whisperm8-statusline.sh:125-177`). |
| `R4-UI-01` | **W3 · gefixt (`9592d17`):** Config-Roots werden reihenfolgeerhaltend über ihren standardisierten Pfad dedupliziert; der Regressionstest erhält Main vor Profil und entfernt die Dublette (`WhisperM8/Services/Shared/StatuslineInstaller.swift:32-45`; `Tests/WhisperM8Tests/StatuslineInstallerTests.swift:53-60`). |
| `R4-HCLI-01` | **W2:** vor `SIGKILL` Prozessidentität erneut prüfen oder ein gehaltenes Prozess-/Gruppenhandle verwenden; aktuell liegen `isRunning`-Prüfung und Signal an rohe PID getrennt (`WhisperM8/Services/AgentChats/AgentHeadlessCLI.swift:97-100`). |
| `R4-GPTCTX-01` | **W3:** UI-Grenze für das aktuelle Modell auf das reale 272.000-Limit begrenzen beziehungsweise modellabhängig machen; Preferences akzeptieren derzeit bis 500.000 (`WhisperM8/Support/AppPreferences.swift:298-315`), obwohl die UI 272.000 als nicht erhöhbar bezeichnet (`WhisperM8/Views/Settings/Pages/GPTBackendSettingsPage.swift:265-266`). |
| `R4-AS-04` | **W2:** File-Source-Callbacks an Generation/Identität binden; ein verspäteter Alt-Callback kann derzeit die neue Source über `self.stop()` abbrechen (`WhisperM8/Services/Shared/FileEventSource.swift:39-67`). |
| `R4-AS-06` | **W2:** Double→Int nur nach Endlichkeits- und Bereichsprüfung; Usage und Exitcodes laufen heute durch eine trap-fähige Direktkonvertierung (`WhisperM8/Services/AgentChats/CodexExecEventParser.swift:49-70,89-94`). |
| `R4-VC-02` | **W2:** Chunk-Dauer auf endliche, praktikable Werte und begrenzte Chunkzahl validieren; Parser und Dry-Run besitzen heute keine Endlichkeits-/Darstellbarkeitsprüfung (`WhisperM8/CLI/CLIArguments.swift:111-116`; `WhisperM8/CLI/CLITranscribe.swift:270-280`). |
| `R4-VC-11` | **W1 trotz mittlerer Schwere · gefixt (`e104706`):** Der CLI-Parser akzeptiert nur achtstellige lowercase-Hex-IDs; der Store validiert zusätzlich den symlink-aufgelösten Jobpfad als unmittelbares Kind des Roots vor jedem Zugriff und vor rekursivem Delete (`WhisperM8/CLI/AgentCLIArguments.swift:255-267`; `WhisperM8/Services/AgentChats/AgentJobStore.swift:62-80,208-220`; `Tests/WhisperM8Tests/AgentCLIArgumentsTests.swift`; `Tests/WhisperM8Tests/AgentJobStoreTests.swift`). |

### Verifizierte Alt-Fixstände

- **Kein Alt-Finding ist als vollständig gefixt verifiziert; daher wird keines als
  erledigt markiert.** Die Matrix bestätigt nur Teilfixe.
- `R3-MIX-G07` bleibt **offen (Teilfix)**: Managed Installer und Hash-Pin sind mit
  `0bdff8f`, `c6ac557`, `e445b65` und `1bd655f` belegt, der PATH-Vorrang bleibt
  offen (`WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:318-329`;
  [`runde4-findings-matrix.md:11-15,69-73`](../04-verifikation/runde4-findings-matrix.md)).
- `R3-LIVE-G01` bleibt **offen (Teilfix)**: `17f76dc` belegt den 272k-
  Fensterwert, nicht den Usage-Merge-/Golden-Test-Vertrag
  (`WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:328-344`;
  [`runde4-findings-matrix.md:62-64`](../04-verifikation/runde4-findings-matrix.md)).
- `C04` und `N01` werden ebenfalls nicht als erledigte Fixes etikettiert: Die
  Runde-4-Matrix widerlegt beziehungsweise bestätigt die bisherigen
  Defektbehauptungen nicht, ohne dafür einen Fix-Commit zu belegen
  ([`runde4-findings-matrix.md:19-34`](../04-verifikation/runde4-findings-matrix.md)).

### Runde-4-Freigabe-Gate

Vor W0/W1 müssen G0–G5 der Abschlusskritik geschlossen, alle hohen Runde-4-
Findings mit roten Oracles versehen und die fünf P0-Blocker formal abgenommen
sein. Bis dahin gilt weiterhin kein pauschales Go; insbesondere die
Identitäts-/Recovery-Pakete bleiben gesperrt
([`runde4-abschlusskritik.md:25-78`](../02-findings/runde4-abschlusskritik.md)).
