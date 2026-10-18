---
status: roh
updated: 2026-10-17
description: Workflow A, A7 Build, Release, Tests — Rohbefunde des GPT-Finders (aus der strukturierten Rückgabe erzeugt, noch unverifiziert).
---

# A7 Build, Release, Tests

> Unverifiziert. Schweregrade sind die Einschätzung des Finders; Workflow C prüft sie gegen.

## Kurzfazit

A7 statisch geprüft; keine Builds, Tests oder App-Starts ausgeführt. Neun Befunde: ein P0, sechs P1 und zwei P2; sechs sind Launch-Blocker. Die wichtigsten Lücken betreffen Apple-Vertrauen, den defekten Developer-ID-Pfad, Architektur-Unterstützung, Deinstallation und fehlende Test-Gates vor Veröffentlichung. Positiv sind der Tag-/Plist-Versionsabgleich, SHA256 im Cask, eingecheckte Dependency-Pins und der verpflichtende Resource-Accessor-Patch. Die abweichenden Ressourcenlisten in Package.swift und Makefile sind nicht automatisch fehlerhaft: Das vollständige SwiftPM-Ressourcenbundle wird zusätzlich kopiert. Die Teststichprobe enthält solide Isolierung sowie Persistenz-, Recovery- und Migrationstests; eine vollständige End-to-End-Abdeckung ist daraus nicht ableitbar. Bericht und Lagebild wurden wegen der übergeordneten Vorgabe, keine Markdown-Berichtsdateien zu schreiben, nicht angelegt; sämtliche Ergebnisse stehen hier.

## Befunde

### LR-BR-002 (A7-01) · Apple-App-Passwort wird als Prozessargument offengelegt

*P0 · Launch-Blocker · security · Konfidenz hoch · Aufwand S · Risiko niedrig*

**Features:** —

**Beleg:** `scripts/build-dmg.sh:109-115`

**Szenario:** Der Maintainer verwendet den vorgesehenen Notarisierungsweg mit APPLE_ID, APPLE_TEAM_ID und APPLE_APP_SPECIFIC_PASSWORD. Das expandierte Passwort steht dann im Argumentvektor von xcrun/notarytool und kann während der Übertragung über Prozessinspektion ausgelesen werden. Dies verletzt die explizite Launch-Anforderung, keine Secrets in argv zu übergeben.

**Fix:** Den Passwort-Argumentpfad entfernen und ausschließlich vorab eingerichtete Keychain-Credentials über --keychain-profile verwenden. Fehlende Credentials im Release-Modus vor dem Build mit einer handlungsorientierten Fehlermeldung ablehnen; Secret-Werte nicht protokollieren.

### LR-BR-003 (A7-02) · Öffentliche Releases umgehen Gatekeeper statt E4 umzusetzen

*P1 · Launch-Blocker · infra · Konfidenz hoch · Aufwand L · Risiko mittel*

**Features:** F-APP-04, F-APP-07

**Beleg:** `.github/workflows/release.yml:5-9`, `.github/workflows/release.yml:55-56`, `Makefile:364-371`, `scripts/build-dmg.sh:31-52`, `scripts/build-dmg.sh:102-119`, `scripts/update-cask.sh:42-47`

**Szenario:** Ein normaler Versions-Tag veröffentlicht weiterhin ein ad-hoc-signiertes, nicht notarisiertes DMG. Der Cask entfernt anschließend rekursiv die Quarantäne. Es gibt weder eine Developer-ID-Provisionierung in CI noch eine verpflichtende Notarisierung. Damit erfüllt der einzige öffentliche Installationsweg die beschlossene Vertrauensanforderung E4 nicht; der bisherige Quarantäne-Workaround ersetzt sie ausdrücklich nicht.

**Fix:** Lokale Dev-Signierung und öffentliche Distribution trennen. Im Release-Job Developer-ID-Zertifikat in einer temporären Keychain bereitstellen, Hardened Runtime und Zeitstempel erzwingen, Notarisierung mit akzeptiertem Ergebnis verlangen, stapeln und Ticket/Gatekeeper-Vertrauen prüfen. Den Cask-postflight zur Quarantäne-Entfernung danach entfernen. Stabile Bundle-ID sowie unveränderte Ressourcen- und PTY-Funktion erhalten.

### LR-BR-004 (A7-03) · Developer-ID-Build bricht am fehlenden Frameworks-Ordner ab

*P1 · Launch-Blocker · korrektheit · Konfidenz hoch · Aufwand S · Risiko niedrig*

**Features:** —

**Beleg:** `scripts/build-dmg.sh:5`, `scripts/build-dmg.sh:32-48`, `Makefile:320-354`

**Szenario:** DEVELOPER_ID_APPLICATION ist gesetzt und das aktuelle SwiftPM-Bundle wurde gebaut. Das Makefile erzeugt Contents/MacOS und Contents/Resources, aber kein Contents/Frameworks. find auf dem fehlenden Ordner liefert trotz unterdrückter Fehlermeldung Status 1; durch pipefail und errexit endet das Skript vor der äußeren Developer-ID-Signierung und vor dem DMG. Die Shell-Semantik wurde mit einer ausschließlich lesenden Probe bestätigt.

**Fix:** Den optionalen Frameworks-Pfad vor find auf Existenz prüfen. Ein fehlender Ordner muss erlaubt sein, echte Signierfehler eingebetteter Komponenten dagegen müssen weiterhin abbrechen. Einen Packaging-Test für das aktuelle Bundle ohne Frameworks und einen für eingebetteten Code hinzufügen.

### LR-BR-005 (A7-04) · Cask-Deinstallation besitzt keinen Prozess- und Integrationsabbau

*P1 · Launch-Blocker · robustheit · Konfidenz hoch · Aufwand L · Risiko hoch*

**Features:** F-APP-06, F-AUT-05

**Beleg:** `scripts/update-cask.sh:40-54`, `Makefile:218-221`, `scripts/sync-skills.sh:34-38`, `scripts/sync-skills.sh:421-445`

**Szenario:** Der Nutzer führt brew uninstall --zap whisperm8 bei laufender App aus. Der erzeugte Cask hat keine uninstall-Aktion zum Beenden der App oder ihrer selbst gestarteten Hilfsprozesse, sondern nur drei trash-Pfade. Eine bereits laufende App wird dadurch nicht kontrolliert heruntergefahren. Außerdem bleiben Integrationen außerhalb dieser drei Pfade, etwa der CLI-Symlink und installierte Statusline-Dateien unter ~/.claude, unberücksichtigt. Der explizite Nutzerweg W7 ist damit nicht implementiert.

**Fix:** Einen gezielten, geordneten Uninstall-Pfad samt Cask-uninstall-Stanza schaffen: App beenden und Ende abwarten, ausschließlich eigene Hilfsprozesse abbauen und nur nach Ownership-Prüfung eigene Symlinks/Claude-Integrationen entfernen beziehungsweise vorherige Einstellungen wiederherstellen. Zusatzprofil-Daten mit Lösch-/Behalten-Entscheidung inventarisieren; niemals pauschal ~/.claude, ~/.codex oder fremde Proxys löschen. W7 auf einer frischen Brew-Installation testen.

### LR-BR-006 (A7-05) · Cask akzeptiert beide Mac-Architekturen, das DMG enthält nur die Build-Architektur

*P1 · Launch-Blocker · korrektheit · Konfidenz hoch · Aufwand M · Risiko mittel*

**Features:** F-APP-02

**Beleg:** `Makefile:176-190`, `Makefile:323`, `scripts/build-dmg.sh:27-29`, `scripts/update-cask.sh:30-40`, `docs/DMG_BAUEN.md:5`

**Szenario:** Das DMG wird auf dem dokumentierten Apple-Silicon-Buildrechner erstellt. swift build ohne Architekturparameter erzeugt das native arm64-Executable; genau dieses wird ins einzige DMG kopiert. Der Cask prüft lediglich macOS Sonoma, nicht die CPU. Ein Intel-Mac mit macOS 14 kann die Installation daher erfolgreich abschließen, die App aber nicht ausführen. Die Launch-Definition schließt Intel-Macs nicht aus.

**Fix:** Entweder ein Universal-Bundle bauen und beide Mach-O-Architekturen prüfen oder getrennte arm64-/x86_64-Assets mit architekturbewusstem Cask erzeugen. Falls ausschließlich Apple Silicon unterstützt werden soll, diese Produktentscheidung ausdrücklich treffen und im Cask vor der Installation durchsetzen. Architekturabhängige Build-Ausgabepfade sowie alle Ressourcen korrekt übernehmen.

### LR-BR-007 (A7-06) · Tag-Releases werden ohne Test-Gate veröffentlicht

*P1 · Launch-Blocker · infra · Konfidenz hoch · Aufwand M · Risiko niedrig*

**Features:** —

**Beleg:** `.github/workflows/ci.yml:10-13`, `.github/workflows/ci.yml:41-44`, `.github/workflows/release.yml:12-15`, `.github/workflows/release.yml:55-70`

**Szenario:** Ein Commit enthält einen Compile-Fehler ausschließlich im Testtarget oder einen fehlgeschlagenen Regressionstest und erhält einen Versions-Tag. Der Tag-Workflow baut nur das Produkt und veröffentlicht anschließend DMG und Cask. Er führt keine Tests aus und wartet nicht auf einen erfolgreichen Testlauf desselben Commits; der separate CI-Workflow läuft nicht auf Tags. So kann eine Version trotz nachweislich kaputter Tests ausgeliefert werden.

**Fix:** Die vollständigen Tests desselben getaggten SHA als verpflichtige Voraussetzung des Release-Jobs ausführen, beispielsweise über einen wiederverwendbaren Workflow und needs. Veröffentlichung erst nach grünen Tests und erfolgreicher Bundle-Prüfung erlauben; ein älterer grüner main-Lauf darf nicht genügen.

### LR-BR-008 (A7-07) · Clean-Install beendet fremde Prozesse und kann sich selbst töten

*P1 · robustheit · Konfidenz hoch · Aufwand M · Risiko mittel*

**Features:** —

**Beleg:** `scripts/clean-install.sh:14-19`, `Makefile:252-272`, `scripts/build-dmg.sh:80`

**Szenario:** Das Skript wird über einen absoluten Pfad gestartet, dessen Repo-Name whisperm8 enthält. pkill -9 -f whisperm8 trifft dann auch den ausführenden bash-Prozess und beendet den Reset vorzeitig. Zusätzlich trifft die unbeschränkte Suche beliebige andere Prozesse mit diesem Text in argv, beispielsweise einen Editor mit dem Projektpfad oder laufende Compiler. Die gezielte, geordnete Prozessauswahl des Makefiles wird hier gerade nicht verwendet.

**Fix:** Die bestehende präzise GUI-Prozessauswahl und den geordneten SIGTERM-/Wartepfad zentral wiederverwenden. Eigene PID/Prozessidentität absichern; keine Substring-SIGKILL-Suche über alle Argumentvektoren. Direkten Skriptaufruf aus einer App-Session ebenfalls abfangen und destruktive Recovery nicht als allgemeine Fehlerbehebung bewerben.

### LR-BR-009 (A7-08) · Store-Test verwechselt Scheduler-Verzögerung mit blockierendem Flush

*P2 · infra · Konfidenz mittel · Aufwand S · Risiko niedrig*

**Features:** F-AC-09

**Beleg:** `Tests/WhisperM8Tests/AgentWorkspaceStoreTests.swift:306-337`, `Tests/WhisperM8Tests/TestTiming.swift:4-16`

**Szenario:** Der Testprozess wird zwischen Date()-Start und der Messung nach store.flush() auf einem belasteten Runner länger als 100 ms nicht eingeplant. Obwohl flush nicht auf Persistenz wartet, schlägt XCTAssertLessThan(..., 0.1) fehl. Der vorhandene TestTiming-Kommentar dokumentiert genau dieses Problem der Wandzeitmessung unter paralleler Last; dieser Test verwendet weiterhin die empfindliche Wandzeitgrenze.

**Fix:** Die Nichtblockierung über ein kontrolliertes Synchronisationsprotokoll prüfen: Persistenz bleibt gesperrt, während die Rückkehr von flush unabhängig bestätigt wird. Einen großzügigen Deadlock-Timeout verwenden, nicht ein 100-ms-Performance-Budget. Thread-CPU-Zeit allein wäre hier kein Ersatz, weil sie blockierendes Warten ebenfalls nicht misst.

### LR-DOK-002 (A7-09) · DMG-Anleitung verspricht einen nicht mehr unterstützten Build ohne Xcode

*P2 · doku · Konfidenz hoch · Aufwand S · Risiko niedrig*

**Features:** —

**Beleg:** `docs/DMG_BAUEN.md:3-6`, `docs/DMG_BAUEN.md:16-30`, `docs/DMG_BAUEN.md:45-53`, `Makefile:9-10`

**Szenario:** Ein Maintainer folgt der DMG-Anleitung auf einem Mac mit CommandLineTools, aber ohne vollständiges Xcode. Die Anleitung behauptet, ein Dependency-Preview-Patch plus DEVELOPER_DIR=/Library/Developer/CommandLineTools genüge. Das Makefile überschreibt diese Umgebungsvariable jedoch mit /Applications/Xcode.app/Contents/Developer; der Build scheitert am fehlenden Toolchain-Pfad. Die Anleitung nennt außerdem den manuellen Gatekeeper-Override statt des beschlossenen Brew-/Notarisierungswegs.

**Fix:** Die Anleitung auf den kanonischen Xcode-/Makefile-Build und die neue verbindliche Developer-ID-/Notarisierungskette umstellen. Den alten Checkout-Patch und die CommandLineTools-Ausweichanweisung entfernen; öffentliche Installation ausschließlich über den Brew-Cask dokumentieren.

## Nicht abgedeckt

- Keine Markdown-Berichtsdateien geschrieben: Die übergeordnete Arbeitsanweisung untersagt Bericht-/Zusammenfassungsdateien. report_path ist deshalb leer. Der Hauptagent muss Rohbericht und Lagebild aus diesem Objekt übernehmen.
- Keine Ausführung von swift build, swift test, make, App, Release-Skripten oder Brew. Signatur-, Gatekeeper-, TCC-Update- und Uninstall-Verhalten benötigen anschließend einen isolierten Integrationstest.
- Die tatsächlich veröffentlichte Tap-Datei und GitHub-Release-Artefakte wurden nicht extern abgerufen. Bewertet wurde ausschließlich deren Generator und Pipeline im angegebenen Worktree.
- Teststichprobe statt Vollprüfung der 50.430 Testzeilen; AgentCommandBuilderTests.swift nur Zeilen 1–350 gelesen. Die übrigen aufgeführten Testdateien wurden vollständig gelesen.
- Kein belastbarer Testnachweis für die vollständigen Nutzerwege W1–W4 und W6–W7, reale TCC-/Keychain-Fehler oder Installation/Login der externen CLIs. Die Stichprobe prüft überwiegend pure Logik beziehungsweise injizierte Teilschritte; fehlende End-to-End-Nachweise wurden nicht als bewiesene Produktfehler ausgegeben.
- Snapshot-Galerie wird ohne WHISPERM8_SNAPSHOT_DIR absichtlich übersprungen und erzeugt Bilder statt visueller Referenzvergleiche. Kein automatischer Nachweis für Lokalisierung, Interaktion oder vollständiges Onboarding.
- Explizit ausgeschlossene UI-, Layout-, Control-Server-, Chats-CLI- und Plugin-Implementierungen nicht geprüft. Crash-Recovery- und Snapshot-Tests wurden nur hinsichtlich Teststruktur gelesen; referenzierte ausgeschlossene Implementierungen wurden nicht geöffnet.
- Kein vollständiges Inventar aller Profil-, Hook-, OAuth-, Keychain-, LaunchAtLogin- und ~/.claude-Integrationen für den Uninstall-Fix erstellt. Diese müssen vor einer Löschimplementierung nach Ownership und erforderlicher Wiederherstellung getrennt werden.
- Nicht als Launch-Befund gewertet: Fehlerbehandlung und Versionsbereinigung des ausschließlich entwicklerseitigen sync-skills-Plugin-Pfads. Die Bash-Semantik eines mit '||' aufgerufenen Funktionskörpers wurde lesend bestätigt; Laufzeitfolgen für ausgeschlossene Plugin-Implementierungen wurden nicht untersucht.
- Keine pauschale Reproduzierbarkeitsrüge für 'from:'-Dependencies: Package.resolved enthält konkrete Revisionen. Kein belegter zusätzlicher Build-Performance-Gewinn gegenüber dem bereits isolierten inkrementellen Dev-Build ermittelt.
- Legacy-Abgleich: Juli-Findings-Matrix vollständig gelesen; Runde-4-Matrix und Refactoring-Audit thematisch durchsucht. Für die gemeldeten Befunde keine passende alte ID gefunden.

## Gelesene Dateien

33 Dateien:

- `docs/audit/2026-10-launch-readiness/00-scope/launch-definition.md`
- `docs/audit/2026-10-launch-readiness/00-scope/feature-inventar.md`
- `Makefile`
- `Package.swift`
- `Package.resolved`
- `.github/workflows/ci.yml`
- `.github/workflows/release.yml`
- `WhisperM8/Info.plist`
- `WhisperM8/WhisperM8.entitlements`
- `scripts/build-dmg.sh`
- `scripts/build.sh`
- `scripts/clean-install.sh`
- `scripts/patch-resource-accessors.sh`
- `scripts/perf-load.sh`
- `scripts/perf-report.sh`
- `scripts/run.sh`
- `scripts/setup-codesign-cert.sh`
- `scripts/sync-skills.sh`
- `scripts/test-claude-plugin.sh`
- `scripts/ui-snapshots.sh`
- `scripts/update-cask.sh`
- `docs/DMG_BAUEN.md`
- `AGENTS.md`
- `Tests/WhisperM8Tests/AgentWorkspaceStoreTests.swift`
- `Tests/WhisperM8Tests/RecordingCoordinatorTranscriptionTests.swift`
- `Tests/WhisperM8Tests/CLISkillExporterTests.swift`
- `Tests/WhisperM8Tests/StoreFormatCompatTests.swift`
- `Tests/WhisperM8Tests/PreferencesTests.swift`
- `Tests/WhisperM8Tests/UISnapshotGallery.swift`
- `Tests/WhisperM8Tests/AgentCrashRecoveryTests.swift`
- `Tests/WhisperM8Tests/TestTiming.swift`
- `Tests/WhisperM8Tests/AgentCommandBuilderTests.swift`
- `docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/findings-matrix.md`
