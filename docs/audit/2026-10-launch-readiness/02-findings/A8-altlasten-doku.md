---
status: roh
updated: 2026-10-17
description: Workflow A, A8 Altlasten + Doku — Rohbefunde des GPT-Finders (aus der strukturierten Rückgabe erzeugt, noch unverifiziert).
---

# A8 Altlasten + Doku

> Unverifiziert. Schweregrade sind die Einschätzung des Finders; Workflow C prüft sie gegen.

## Kurzfazit

17 statisch belegte Befunde, darunter fortbestehende Crash-, Datenverlust- und Secret-Probleme aus dem Juli. Keine pauschale Übernahme historischer Offen-Status; die vollständige Altlastenprüfung bleibt offen. Heutiger bestätigter Altstatus: N03/N04/N05/N06/N08/N09/N10/N11/N12/N13/N14 und R4-AS-01/R4-INSTALL-01 bestehen; R4-SCHEMA-01 ist im weiterhin fehlenden Future-Schema-Schutz mit erfasst. Positiv geprüft: C05 ist für Auto-Naming durch native Titelübernahme entfallen; C13 arbeitet im heutigen Inspector off-main und stale-geschützt; C16 delegiert an einen zentralen Locator; R4-AS-11 besitzt Load-Deduplizierung; R3-DEF-G01/R4-SKILL-01 haben inzwischen konservative Fremddatei-/Symlink-Guards; R4-STATUS-01 nutzt Bundle.module; R4-SHELL-01 verwendet Sanitizing und printf statt echo -e. Die alten Context-Profile-Implementierungen zu R4-CP-02/03/05 und R4-DELTA-PROFILE-01 sowie der frühere Plugin-Manager zu R4-PLUG-01/02 sind entfernt; daraus folgt keine Freigabe neuer Ersatzpfade oder des weiter vorhandenen Headless-Runners. TerminalSnapshotStore und die alten Snapshot-Views sind entfernt; R3-TERM-G02/G03 betreffen keinen aktiven Snapshot-Schreibpfad mehr, LegacyDataCleanup räumt Altbestände best-effort weg. Bewusst erhalten bleiben sollten native PTYs, Tap-Exception-Guards, Rettung fehlgeschlagener Aufnahmen, konservative Skill-Ownership und nichtdestruktive Fremddatei-Guards. Die Anwenderdokumentation ist deutlich hinter dem Produkt zurück; CLAUDE.md verursacht zusätzlich rund 11.300–15.100 geschätzte Kontext-Tokens pro Session. Alle Pfadbelege beziehen sich auf /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness; kein Rohbericht gespeichert.

## Befunde

### LR-DIK-020 (A8-01) · Doppelte Output-Mode-IDs beenden die App weiterhin per Trap

*P0 · Launch-Blocker · robustheit · Konfidenz hoch · Aufwand S · Risiko niedrig*

**Features:** F-DIK-09  ·  **Alt-ID:** N03

**Beleg:** `WhisperM8/Services/Dictation/OutputModeStore.swift:162`, `WhisperM8/Services/Dictation/OutputModeStore.swift:64-69`

**Szenario:** OutputModes.json enthält zwei ansonsten gültige Einträge mit derselben nicht stillgelegten ID. Das Laden erreicht Dictionary(uniqueKeysWithValues:); dessen Vorbedingung beendet den Prozess statt eines abfangbaren Decode-Fehlers.

**Fix:** Vor der Dictionary-Konstruktion deterministisch deduplizieren, Originaldatei sichern und beschädigte Einträge sichtbar melden. Built-in-Reihenfolge, benutzerdefinierte Anpassungen und Migration stillgelegter Modi erhalten; Regressionstest mit doppelter Custom- und Built-in-ID ergänzen.

### LR-DIK-021 (A8-02) · Ein defekter Modus kann sämtliche benutzerdefinierten Modi vernichten

*P0 · Launch-Blocker · datenintegritaet · Konfidenz hoch · Aufwand M · Risiko mittel · Duplikat von LR-DIK-002*

**Features:** F-DIK-09  ·  **Alt-ID:** N04

**Beleg:** `WhisperM8/Services/Dictation/OutputModeStore.swift:126-134`, `WhisperM8/Models/OutputMode.swift:105-119`, `WhisperM8/Views/Settings/Models/OutputModesViewModel.swift:45-57`

**Szenario:** In einer Datei mit mehreren Custom-Modi enthält ein Eintrag etwa einen unbekannten kind-Wert. Der Decode des gesamten Arrays scheitert; die App zeigt kommentarlos nur Built-ins. Ein anschließendes Hinzufügen oder Bearbeiten speichert diesen Ersatzbestand und überschreibt alle bisherigen Custom-Modi.

**Fix:** Fehlende Datei von beschädigter Datei unterscheiden; Original sichern, Einträge einzeln validieren und bei unvollständigem Load vollständiges Überschreiben sperren. Gültige Custom-Modi und unbekannte Originaldaten bis zur bestätigten Reparatur erhalten.

### LR-SH-009 (A8-03) · Fehlgeschlagene Keychain-Migration löscht die einzige gespeicherte Schlüsselkopie

*P0 · Launch-Blocker · datenintegritaet · Konfidenz hoch · Aufwand S · Risiko niedrig · Duplikat von LR-SH-003*

**Features:** F-DIK-02  ·  **Alt-ID:** N06

**Beleg:** `WhisperM8/Services/Shared/KeychainManager.swift:10-34`, `WhisperM8/Services/Shared/KeychainManager.swift:61-66`

**Szenario:** Ein Legacy-API-Key liegt noch in UserDefaults; SecItemUpdate/SecItemAdd scheitert beispielsweise wegen verweigerten Keychain-Zugriffs. save liefert keinen Fehler zurück, load entfernt trotzdem den Legacywert. Nach Ende des aktuellen Aufrufs ist der Schlüssel nicht dauerhaft gespeichert.

**Fix:** Keychain-Speichern muss einen überprüfbaren Erfolg zurückgeben. Legacywert erst nach erfolgreichem Write und ungecachetem Readback entfernen; bei Fehler erhalten und handlungsfähige Meldung anzeigen. Migration und reguläres Speichern mit injizierten Security-Aufrufen testen.

### LR-KO-011 (A8-04) · Profil-Rename übergibt den vollständigen OAuth-Grant als Prozessargument

*P0 · Launch-Blocker · security · Konfidenz hoch · Aufwand M · Risiko mittel · Duplikat von LR-KO-001*

**Features:** F-KO-01  ·  **Alt-ID:** N10

**Beleg:** `WhisperM8/Services/AgentChats/ClaudeAccountProfiles.swift:422-426`, `WhisperM8/Services/AgentChats/ClaudeAccountProfiles.swift:460-477`

**Szenario:** Ein angemeldetes Zusatzprofil wird umbenannt. Der aus dem Schlüsselbund gelesene Secret-JSON-String wird als Argument nach security add-generic-password -w gesetzt und ist während dieses Prozesses in dessen argv sichtbar.

**Fix:** Den Keychain-Umzug über Security.framework ohne Secret in argv ausführen. Alten Login erst nach erfolgreichem Anlegen und Verifizieren löschen; bestehenden Verzeichnis-Rollback und Profilstempel-Umzug erhalten.

### LR-SH-010 (A8-05) · Subprozesse erben weiterhin nicht benötigte Secrets der App-Umgebung

*P0 · Launch-Blocker · security · Konfidenz hoch · Aufwand M · Risiko mittel · Duplikat von LR-SH-001*

**Features:** F-AC-02, F-DIK-09  ·  **Alt-ID:** N09

**Beleg:** `WhisperM8/Services/Shared/LoginShellEnvironment.swift:92-94`, `WhisperM8/Services/Shared/LoginShellEnvironment.swift:109-155`, `WhisperM8/Services/AgentChats/AgentSupervisorLauncher.swift:50`

**Szenario:** WhisperM8 wird aus einer Umgebung mit beispielsweise AWS_SECRET_ACCESS_KEY oder einem fremden Diensttoken gestartet. processEnvironment kopiert das gesamte Dictionary und entfernt nur bestimmte Identitäts-/Routingvariablen; anschließend gestartete Hilfsprozesse und Agenten erhalten auch diese sachfremden Secrets.

**Fix:** Umgebungen pro Prozessklasse aus einer dokumentierten Allowlist aufbauen. PATH, Locale, Terminalfähigkeiten und ausdrücklich benötigte Account-/Launch-Overrides erhalten; fremde Credentials nicht pauschal vererben. Mit Canary-Secrets gegen alle Prozessklassen testen.

### LR-AK-029 (A8-06) · Workspace-Load schreibt höhere Schema-Versionen ohne Schreibsperre zurück

*P0 · Launch-Blocker · datenintegritaet · Konfidenz hoch · Aufwand M · Risiko mittel · Duplikat von LR-AK-002*

**Features:** F-AC-01  ·  **Alt-ID:** N05, R4-SCHEMA-01

**Beleg:** `WhisperM8/Services/AgentChats/AgentWorkspaceRepository.swift:51-64`, `WhisperM8/Services/AgentChats/AgentSessionStore.swift:1499-1503`, `WhisperM8/Models/AgentChat.swift:595-620`

**Szenario:** Nach einem Versions-Rollback liegt ein strukturell noch dekodierbarer Workspace mit schemaVersion größer als 1 und zusätzlichen Feldern vor. migratedWorkspace setzt die Version auf 1; das Repository speichert sofort die reduzierte bekannte Struktur. Die Hauptdatei verliert die unbekannten Daten bereits beim Laden; das pre-migration-Backup verhindert nicht diesen destruktiven Downgrade.

**Fix:** Schema-Version vor fachlicher Migration prüfen. Höhere Versionen unverändert und schreibgeschützt erhalten, keinen normalen Store-Writer darauf zulassen und einen verständlichen Versionshinweis anzeigen. Bekannte Migrationen, Deduplizierung und Recovery-Backups für unterstützte Versionen erhalten.

### LR-SH-011 (A8-07) · Settings-Schreiber können parallel hinzugefügte fremde Konfiguration überschreiben

*P0 · Launch-Blocker · datenintegritaet · Konfidenz hoch · Aufwand M · Risiko mittel · Duplikat von LR-AK-017*

**Features:** F-AC-02  ·  **Alt-ID:** R4-AS-01, R4-INSTALL-01

**Beleg:** `WhisperM8/Services/AgentChats/ClaudeThemeWriter.swift:107-153`, `WhisperM8/Services/Shared/StatuslineInstaller.swift:328-358`, `WhisperM8/Support/ThemeManager.swift:82-90`

**Szenario:** Der Theme-Writer liest settings.json; anschließend ergänzt der Statusline-Installer oder die externe CLI einen anderen Schlüssel. Der Theme-Writer ersetzt danach die gesamte Datei aus seinem alten Snapshot und entfernt die zwischenzeitliche Änderung. Zusätzlich behandelt wireSettings eine bestehende, aber nicht lesbare Datei bei vorhandenem Verzeichnis als leeres Objekt und kann sie vollständig ersetzen.

**Fix:** App-eigene Writer über einen gemeinsamen Transaktionspfad serialisieren und Lesefehler bestehender Dateien immer fail-closed behandeln. Für nicht kooperierende externe Writer globale Vollsnapshot-Writes möglichst durch offizielle CLI-/sessionlokale Settings ersetzen; ein appinterner Lock allein schützt davor nicht. Fremdschlüssel, Symlinks und explizite Ersetzungsbestätigungen erhalten.

### LR-DIK-022 (A8-08) · Auto-Paste fügt trotz gescheiterter Zielaktivierung in die Vordergrund-App ein

*P1 · Launch-Blocker · korrektheit · Konfidenz hoch · Aufwand M · Risiko mittel · Duplikat von LR-DIK-007*

**Features:** F-DIK-01  ·  **Alt-ID:** N11

**Beleg:** `WhisperM8/Services/Dictation/PasteService.swift:81-92`, `WhisperM8/Services/Dictation/PasteService.swift:126-142`

**Szenario:** Die zuvor erfasste Ziel-App wurde während der Transkription beendet oder ihre Aktivierung gelingt nicht. Nach einer Sekunde meldet waitForActivation lediglich einen Timeout; der folgende globale Cmd+V landet trotzdem in der inzwischen vorderen anderen App. Auch nach erfolgreicher Aktivierung gibt es vor Text und Anhängen weitere ungeschützte Wartefenster.

**Fix:** Aktivierung muss einen Erfolgswert liefern. Unmittelbar vor jedem Paste Ziel und aktuellen Zustellvorgang erneut prüfen; bei Abweichung nur kopieren und verständlich darauf hinweisen. Text-/Anhangreihenfolge und Clipboard-Fallback erhalten.

### LR-AK-030 (A8-09) · Codex-Job gilt ohne bestätigten Turn-Abschluss als erfolgreich

*P1 · korrektheit · Konfidenz hoch · Aufwand M · Risiko mittel · Duplikat von LR-AK-028*

**Features:** F-AC-12  ·  **Alt-ID:** N08

**Beleg:** `WhisperM8/Services/AgentChats/CodexTurnExecutor.swift:83-119`, `WhisperM8/Services/AgentChats/CodexExecRunner.swift:39-51`, `WhisperM8/Services/AgentChats/CodexExecRunner.swift:493-502`

**Szenario:** Ein gestarteter codex-Prozess liefert Exit 0, aber weder turn.completed noch eine letzte Antwort, etwa bei einem unvollständigen oder inkompatiblen Eventstrom. Das Resultat enthält keine Completion-Invariante; mapOutcome erzeugt trotzdem done und der Supervisor persistiert Erfolg.

**Fix:** Semantischen Turn-Abschluss im Stream-State erfassen und im Resultat verlangen. Fehlender Abschluss erhält einen eigenen unvollständig/fehlgeschlagen-Ausgang. Tolerantes Parsen eines vorhandenen, aber nicht strukturierten Reports darf erhalten bleiben; es ist nicht dasselbe wie ein fehlender Turn.

### LR-AK-031 (A8-10) · Job-State-Korrektur und PID-Nachtrag überschreiben neuere Zustände

*P1 · race · Konfidenz hoch · Aufwand M · Risiko mittel*

**Features:** F-AC-12  ·  **Alt-ID:** N12, N13

**Beleg:** `WhisperM8/Services/AgentChats/AgentJobStore.swift:164-181`, `WhisperM8/Services/AgentChats/AgentJobStore.swift:285-305`, `WhisperM8/Views/SubagentJobDetailView.swift:491-496`, `WhisperM8/Services/AgentChats/AgentJobSupervisor.swift:77-87`

**Szenario:** Die App liest einen aktiven Job. Bevor sie den alten Snapshot als verwaist zurückschreibt, beendet der Supervisor ihn und persistiert done; die Korrektur ersetzt den fertigen Zustand durch failed. Beim Follow-up kann entsprechend der ungesperrte PID-Nachtrag einen zuvor gelesenen spawning-Snapshot über den inzwischen unter Lock geschriebenen running-Zustand legen.

**Fix:** Alle Änderungen an state.json einschließlich Korrektur, Transition und PID-Publikation in dieselbe prozessübergreifende Transaktion aufnehmen. Innerhalb des Locks neu lesen und erwartete Generation/Zustand prüfen. Bestehenden atomaren Dateiersatz und genau-einmal-Prompt-Claim erhalten; keine rekursiven flock-Aufrufe einführen.

### LR-AK-032 (A8-11) · Stop vor der Codex-Prozessregistrierung bleibt wirkungslos

*P1 · race · Konfidenz hoch · Aufwand M · Risiko mittel · Duplikat von LR-AK-023*

**Features:** F-AC-12  ·  **Alt-ID:** N14

**Beleg:** `WhisperM8/Services/AgentChats/AgentJobSupervisor.swift:45-51`, `WhisperM8/Services/AgentChats/AgentJobSupervisor.swift:126-130`, `WhisperM8/Services/AgentChats/CodexExecRunner.swift:274-286`, `WhisperM8/Services/AgentChats/CodexExecRunner.swift:327-335`

**Szenario:** Stop trifft ein, bevor CodexExecRunner seinen Process veröffentlicht. requestStop setzt nur den Supervisor-Merker; runner.terminate ist mangels Handle ein No-op. Danach wird der Prozess dennoch gestartet und registriert, ohne den Merker erneut auszuwerten. Der vermeintlich gestoppte Job arbeitet weiter und kann bei Exit 0 sogar done werden.

**Fix:** Abbruch als dauerhaften Runner-Latch führen und atomar mit Prozessregistrierung prüfen; auch vor Launch auf Stop reagieren. Der Supervisor muss bestätigten Stop von erfolgreichem Abschluss unterscheiden. Echte CLI-Ausführung und persistierte Jobs beibehalten.

### LR-DOK-003 (A8-12) · Öffentliche Installationsanleitungen widersprechen dem einzigen Launch-Weg

*P1 · Launch-Blocker · doku · Konfidenz hoch · Aufwand S · Risiko niedrig · Duplikat von LR-DOK-001*

**Features:** F-APP-01, F-APP-04

**Beleg:** `README.md:65-84`, `docs/USER_GUIDE.md:14-17`, `docs/USER_GUIDE.md:40-51`, `docs/README.md:77-92`, `docs/audit/2026-10-launch-readiness/00-scope/launch-definition.md:79-80`

**Szenario:** Ein nicht technischer Nutzer folgt dem User Guide: Er soll per Git-SSH klonen und selbst kompilieren, obwohl er nur Homebrew besitzt. Der Brew-Weg fehlt dort vollständig. Die Root-README bietet daneben DMG plus manuelles Entfernen der Quarantäne an; damit führt die offizielle Anleitung vom festgelegten W1-Pfad weg.

**Fix:** Alle Endnutzer-Einstiege auf Brew-Installation, Brew-Update und Brew-Deinstallation vereinheitlichen. Source-Build und Packaging ausschließlich als klar getrennte Entwicklerreferenz führen. Nach E4-Umsetzung Gatekeeper-Umgehung nicht weiter bewerben; bis dahin keinen bereits notarisierten Ist-Stand behaupten.

### LR-DOK-004 (A8-13) · Das Handbuch empfiehlt vollständige Datenlöschung als normale Fehlerbehebung

*P1 · Launch-Blocker · doku · Konfidenz hoch · Aufwand S · Risiko niedrig*

**Features:** F-AC-01, F-DIK-09, F-APP-04

**Beleg:** `docs/USER_GUIDE.md:20-22`, `docs/USER_GUIDE.md:56-64`, `docs/USER_GUIDE.md:200-207`, `scripts/clean-install.sh:68-71`, `docs/README.md:27-29`

**Szenario:** Ein Nutzer mit vorhandenen Chats und Custom-Modi folgt bei einem gewöhnlichen Startproblem oder einer bereits vorhandenen älteren Installation der hervorgehobenen Empfehlung make clean-install. Das Skript löscht den gesamten Application-Support-Ordner einschließlich Workspace, Reports und Custom-Konfiguration. Die unmittelbar betreffende Handbuchstelle nennt nur Rechte, Cache und Einstellungen; eine Sicherung wird nicht angeleitet.

**Fix:** Nichtdestruktive Fehlerbehebung und Brew-Update zuerst beschreiben. Vollreset nur als getrennte letzte Option mit konkreter Liste verlorener Daten, Sicherungs-/Wiederherstellungsanleitung und ausdrücklicher Entscheidung dokumentieren. Den absichtlich destruktiven Entwickler-Reset selbst nicht still umdefinieren.

### LR-DOK-005 (A8-14) · Das Anwenderhandbuch führt zu nicht mehr vorhandenen Einstellungsseiten

*P1 · Launch-Blocker · doku · Konfidenz hoch · Aufwand M · Risiko niedrig*

**Features:** F-DIK-02, F-DIK-09, F-DIK-12, F-AC-02, F-APP-03

**Beleg:** `docs/USER_GUIDE.md:88-105`, `docs/USER_GUIDE.md:150-180`, `WhisperM8/Views/SettingsView.swift:3-16`, `WhisperM8/Views/SettingsView.swift:24-49`

**Szenario:** Ein Erstnutzer sucht nach der Anleitung die Tabs API, Hotkey, Behavior oder Audio. Die App besitzt stattdessen Transcription, Recording und General. Für Nutzungsprofile, die erforderliche Codex-Anmeldung zur Umformulierung und den ersten Agent-Chat fehlen entsprechende Nutzerwege im Handbuch ganz.

**Fix:** Handbuch entlang W2–W4 mit den tatsächlichen Seitennamen und Profilen neu strukturieren: Key unter Transcription, Hotkey/Audio unter Recording, Profil unter General und KI-Verbindung unter AI Output. Geführte CLI-Installation erst nach ihrer Implementierung als vorhandene Funktion beschreiben.

### LR-DOK-006 (A8-15) · Aktive Feature-Doku beschreibt abgelöste Transcript- und Titelpfade

*P2 · Launch-Blocker · doku · Konfidenz hoch · Aufwand S · Risiko niedrig*

**Features:** F-AC-07, F-AC-08

**Beleg:** `docs/features/agent-chats/ui/README.md:180-192`, `docs/features/agent-chats/sessions/README.md:138-150`, `WhisperM8/Views/Transcript/AgentTranscriptContainerView.swift:5-19`, `WhisperM8/Views/Transcript/AgentTranscriptContainerView.swift:69`, `WhisperM8/Services/AgentChats/AgentSessionAutoNamer.swift:188-196`

**Szenario:** Nutzer oder Wartende suchen anhand der als aktiv markierten Doku eine Timeline-/Bubble-Ansicht beziehungsweise einen headless Titelgenerierungsaufruf. Die genannten Views sind entfernt; tatsächlich rendert ein NSTextView den Verlauf und Titel werden nativ übernommen. Die Doku vermittelt damit auch falsche Erwartungen an Titel-Kosten und Zeitpunkt.

**Fix:** UI-README und zugehörige Architekturabschnitte auf TranscriptTextRenderer/TranscriptTextView umstellen; TimelineBuilder nur dort dokumentieren, wo er weiterhin für Summary-/Datenprojektionen verwendet wird. Titelübernahme bei Turn-Ende, Priorität nativer Titel und Vorrang manueller Namen beschreiben; keine entfernten UI-Deckel wieder einführen.

### LR-DOK-007 (A8-16) · Die Datenschutzerklärung im Handbuch verschweigt dauerhaft gesicherte Abbruch-Audios

*P2 · Launch-Blocker · doku · Konfidenz hoch · Aufwand S · Risiko niedrig*

**Features:** F-DIK-01, F-DIK-02

**Beleg:** `docs/USER_GUIDE.md:273-278`, `WhisperM8/Services/Dictation/RecordingCoordinator+Failure.swift:42-59`, `WhisperM8/Services/Dictation/FailedRecordingsStore.swift:42-54`, `WhisperM8/Services/Dictation/FailedRecordingsStore.swift:63-111`

**Szenario:** Ein Nutzer bricht eine laufende Transkription vertraulicher Sprache ab. Anders als die pauschale Aussage über temporäre Audiodaten erwarten lässt, wird auch dieser Abbruch ohne Fehlerdialog nach Application Support/WhisperM8/FailedRecordings verschoben. Das Handbuch erklärt weder diesen Ort noch die Aufbewahrungs-/Löschmöglichkeiten.

**Fix:** Erfolgs-, Fehler- und Abbruchfall ausdrücklich unterscheiden; lokale Rettungskopien, Ort und tatsächliche Aufräumpolitik erklären. Die sinnvolle Datenrettung nicht entfernen. Maximalalter nicht als garantierte zeitgesteuerte Löschung bewerben, wenn nur preserve/prune die Bereinigung anstoßen.

### LR-DOK-008 (A8-17) · Automatisch geladene Projektregeln sind ein widersprüchliches Feature- und Vorfallarchiv

*P2 · Launch-Blocker · doku · Konfidenz hoch · Aufwand M · Risiko niedrig*

**Features:** —

**Beleg:** `CLAUDE.md:135-156`, `CLAUDE.md:158`, `CLAUDE.md:169-178`, `AGENTS.md:43-49`, `docs/features/voice-gate.md:92-99`, `docs/audit/2026-10-launch-readiness/00-scope/launch-definition.md:74-75`

**Szenario:** Jede neue Session bekommt 45.324 Zeichen Projektregeln, geschätzt 11.300–15.100 Tokens allein für diese Datei. Neben Arbeitsregeln stehen lange Vorfallgeschichten und inzwischen widersprüchliche Behauptungen: generell read-only für externe Roots trotz dokumentierter Integrationswrites sowie explizite Gerätebindung ohne System-Default trotz der in der Voice-Gate-Doku erklärten Bluetooth-Ausnahme. Wartende können daraus falsche Änderungsgrenzen oder Hardwareannahmen ableiten.

**Fix:** Kurze verbindliche Arbeitsregeln und Guard-Invarianten behalten, Historie verlinken statt injizieren. Zielorte: Runtime/Binding nach docs/features/agent-chats/sessions/ARCHITECTURE.md; Terminal/Verlauf nach docs/features/agent-chats/ui/terminal.md und UI-Architektur; Konten/Memory/MCP in eine Konten-Feature-Doku; GPT-Lifecycle in eine GPT-Backend-Feature-Doku; Absturzschutz in App-Shell-Architektur/ADR; Voice Gate, Board und Callouts in ihre bestehenden Feature-Dateien. AGENTS.md auf dieselben aktuellen Regeln verweisen lassen. Tokenschätzung ist keine Tokenizer-Messung.

## Nicht abgedeckt

- A8 ist eine Teilprüfung, kein vollständiger Abschluss des umfangreichen Auftrags. Es wurde keine Berichtdatei geschrieben; die Befunde stehen ausschließlich in dieser strukturierten Rückgabe. report_path ist deshalb leer. Kein Produktcode, keine Tests und keine Konfiguration wurden geändert; keine Builds, Tests oder App-Starts ausgeführt.
- files_read enthält auch abschnittsweise gelesene Dateien. Insbesondere REFACTORING-AUDIT.md, AgentSessionStore.swift, AgentChat.swift, ClaudeAccountProfiles.swift, AudioRecorder.swift, CodexExecRunner.swift, SubagentJobDetailView.swift, WhisperM8App.swift und einzelne Pläne wurden nicht vollständig gelesen. Eine vollständige Statusmatrix aller 41 hoch priorisierten Juni-Einträge und aller 26 Quick Wins wurde nicht erstellt; die Juni-Liste besitzt überwiegend keine stabilen Finding-IDs.
- Zurückgestellt (Delta-Lauf): C14/C15 sowie R4-AUTH-01/02, R4-IDEM-01, R4-WAIT-01/02, R4-PROF-01 und R4-CTRL-01/02. Ebenfalls keine Prüfung der ausgeklammerten Grid-/Tab-/Sidebar-/Workspace-Implementierungen oder der Plugin-Ressourcen.
- C06 und R3-PROXY-G03: Die heutige BackgroundAgentSpawner-Signatur besitzt inzwischen environmentOverrides; die entscheidenden Aufrufer liegen aber im ausgeklammerten Bereich. Kein fortbestehender Account-/Ready-Fehler behauptet.
- Nicht abschließend gegen heutigen Code geprüft: C01/C02/C03/C04/C07/C08/C09/C10/C11/C12, N01/N02/N07/N15/N16, R4-HCLI-02/R4-RESUME-01/R4-AS-03/R4-VC-03. Bei C01/C02 wurde der wichtige neue Tap-Guard bestätigt, nicht die vollständige Engine-/Reconfiguration-Invariante. N01 und C04 waren bereits in der historischen Gegenprüfung nicht als offene Hoch-Defekte bestätigt; nicht ungeprüft wieder aufnehmen.
- GPT-Lifecycle, Router, Installer und externe Proxy-Verträge wurden nicht neu verifiziert: R3-PROXY-G01/02/04/05, R3-SEC-G01/02/03/04, R3-MIX-G01 bis G07, R3-LIVE-G01 sowie R4-GPTS-01/R4-GPTL-02/R4-LIFE-01. Alte Versions-Pins beweisen keine heutigen Proxy-Defekte; Labs-Prüfung muss Seiteneffekte auf Sicherheit/Daten gezielt nachholen.
- Von 40 Markdown-Dateien unter docs/features wurde nur eine Auswahl inhaltlich geprüft. Keine vollständige Link-/Symbol-/Lokalisierungsprüfung sämtlicher Feature-Dokumente. Die vorhandenen historischen Gate-Abnahmen sind Spezifikationsabnahmen, keine heutigen Produktnachweise.
- Planinventur: 22 Top-Level-Einträge ohne Index, 23 Markdown-Dateien rekursiv. Mindestens fünf Vorhaben werden als umgesetzt geführt und liegen dennoch unter docs/plans: claude-account-switcher.md, claude-in-chrome-shared.md, kontextmenu-vereinheitlichung.md, tab-switcher-workspace.md und whisperm8-chats-cli/. Zusätzlich sind jarvis-supervisor/ abgelöst und kompakt-chat-fenster.md verworfen. Das ist eine statusbasierte Untergrenze, keine vollständig codeverifizierte Zählung aller Markdown-/HTML-Pläne.
- Planindex-Widerspruch beobachtet, nicht als P2-Produktbefund des erweiterten Features hochgestuft: docs/plans/README.md:12 nennt S6–S8 Voice-Callouts offen; docs/plans/whisperm8-plugin.md:2 nennt S1–S7 umgesetzt und nur S8 zurückgestellt. docs/features/speech-callouts.md beschreibt bereits den ausgelieferten Systemstimmen-Pfad.

## Gelesene Dateien

59 Dateien:

- `docs/audit/2026-10-launch-readiness/00-scope/launch-definition.md`
- `docs/audit/2026-10-launch-readiness/00-scope/feature-inventar.md`
- `README.md`
- `docs/USER_GUIDE.md`
- `docs/ARCHITECTURE.md`
- `docs/README.md`
- `docs/plans/README.md`
- `docs/adr/0001-kein-stack-wechsel.md`
- `CLAUDE.md`
- `AGENTS.md`
- `docs/refactor/REFACTORING-AUDIT.md`
- `docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/findings-matrix.md`
- `docs/audit/2026-07-agent-chats-deep-dive/04-verifikation/runde4-findings-matrix.md`
- `docs/audit/2026-07-agent-chats-deep-dive/04-verifikation/runde4-context-profile.md`
- `docs/audit/2026-07-agent-chats-deep-dive/04-verifikation/runde4-plugin-manager.md`
- `docs/audit/2026-07-agent-chats-deep-dive/06-umsetzung/umsetzungsplan.md`
- `docs/audit/2026-07-agent-chats-deep-dive/06-umsetzung/freigabe-gates-g0-g6.md`
- `docs/features/agent-chats/sessions/README.md`
- `docs/features/agent-chats/ui/README.md`
- `docs/features/voice-gate.md`
- `docs/features/speech-callouts.md`
- `docs/plans/claude-account-switcher.md`
- `docs/plans/claude-in-chrome-shared.md`
- `docs/plans/kontextmenu-vereinheitlichung.md`
- `docs/plans/tab-switcher-workspace.md`
- `docs/plans/whisperm8-plugin.md`
- `scripts/clean-install.sh`
- `WhisperM8/Services/Dictation/OutputModeStore.swift`
- `WhisperM8/Models/OutputMode.swift`
- `WhisperM8/Services/Shared/KeychainManager.swift`
- `WhisperM8/Services/AgentChats/AgentWorkspaceRepository.swift`
- `WhisperM8/Services/AgentChats/AgentSessionStore.swift`
- `WhisperM8/Models/AgentChat.swift`
- `WhisperM8/Services/Shared/LoginShellEnvironment.swift`
- `WhisperM8/Services/AgentChats/ClaudeAccountProfiles.swift`
- `WhisperM8/Services/AgentChats/CodexTurnExecutor.swift`
- `WhisperM8/Services/AgentChats/CodexExecRunner.swift`
- `WhisperM8/Services/AgentChats/AgentSupervisorLauncher.swift`
- `WhisperM8/Services/AgentChats/AgentJobSupervisor.swift`
- `WhisperM8/Services/AgentChats/AgentJobStore.swift`
- `WhisperM8/Views/SubagentJobDetailView.swift`
- `WhisperM8/Services/AgentChats/ClaudeThemeWriter.swift`
- `WhisperM8/Support/ThemeManager.swift`
- `WhisperM8/Services/Shared/StatuslineInstaller.swift`
- `WhisperM8/Services/Shared/CLISkillExporter.swift`
- `WhisperM8/Services/AgentChats/AgentSessionAutoNamer.swift`
- `WhisperM8/Services/AgentChats/GitProjectStatus.swift`
- `WhisperM8/Views/ProjectDetailPanel.swift`
- `WhisperM8/Services/AgentChats/CodexTranscriptReader.swift`
- `WhisperM8/Services/AgentChats/LegacyDataCleanup.swift`
- `WhisperM8/Services/Dictation/AudioRecorder.swift`
- `WhisperM8/Services/Dictation/PasteService.swift`
- `WhisperM8/Services/Dictation/FailedRecordingsStore.swift`
- `WhisperM8/Services/Dictation/RecordingCoordinator+Failure.swift`
- `WhisperM8/Views/Settings/Models/OutputModesViewModel.swift`
- `WhisperM8/Views/SettingsView.swift`
- `WhisperM8/Views/Transcript/AgentTranscriptContainerView.swift`
- `WhisperM8/Resources/whisperm8-statusline.sh`
- `WhisperM8/WhisperM8App.swift`
