---
status: roh
updated: 2026-10-17
description: Workflow A, A6 Shared-Infrastruktur, Querschnitt — Rohbefunde des GPT-Finders (aus der strukturierten Rückgabe erzeugt, noch unverifiziert).
---

# A6 Shared-Infrastruktur, Querschnitt

> Unverifiziert. Schweregrade sind die Einschätzung des Finders; Workflow C prüft sie gegen.

## Kurzfazit

A6 liefert elf statisch belegte Befunde: fünf P0, fünf P1 und einen P2; zehn sind Launch-Blocker. Schwerpunkte sind Credential-Verlust beziehungsweise -Exposition, destruktive Installationsfehler, unbeschränkte Shell-Wartezeiten und Eingriffe in bestehende CLI-Setups. Besonders eindeutig ist die widersprüchliche Plugin-Vererbung: Der allgemeine Resolver löscht CLAUDE_CODE_PLUGIN_DIRS, bevor Bootstrap den Wert erhalten möchte. Datenfluss des Subsystems: App-Start/CLI → Preferences und Login-Umgebung → Installer beziehungsweise echte CLI-Prozesse; Datei-Ereignisse und Sprach-/Debug-Anfragen führen über getrennte Services zurück zur App. Persistiert werden Schlüsselbund-Einträge, UserDefaults, Plugin-Versionen im Application Support sowie externe Symlinks, Skills und Statusline-Einstellungen. Bewusst erhalten bleiben sollten SIGPIPE-Handler statt SIG_IGN, der ObjC-Exception-Shim, O_CLOEXEC im FileEventSource, der unabhängige Stall-Watchdog, detail-gegatete Performance-Zähler und die atomare versionierte Plugin-Ablage. Debug ist standardmäßig aus; Speak prüft Tokens vor einer Sprecherzuordnung und protokolliert selbst keinen Ansagetext. Keine Dateien wurden verändert; die Markdown-Ablage muss der Hauptagent übernehmen.

## Befunde

### LR-SH-003 (A6-01) · : Fehlgeschlagene Keychain-Migration löscht die einzige persistierte API-Key-Kopie

*P0 · Launch-Blocker · datenintegritaet · Konfidenz hoch · Aufwand M · Risiko mittel*

**Features:** F-DIK-02  ·  **Alt-ID:** N06

**Beleg:** `WhisperM8/Services/Shared/KeychainManager.swift:23-34`, `WhisperM8/Services/Shared/KeychainManager.swift:61-66`, `WhisperM8/Views/Settings/Pages/TranscriptionSettingsPage.swift:107-112`, `WhisperM8/Views/OnboardingView.swift:635-640`

**Szenario:** Nach einem Update liegt der API-Key nur in UserDefaults. Der Schlüsselbund ist gesperrt oder verweigert den Schreibzugriff. load() ruft save() auf; dieses protokolliert den Fehler lediglich. Trotzdem wird der UserDefaults-Wert gelöscht. Der aktuelle Aufruf liefert den Key noch zurück, spätere Aufrufe finden keine persistierte Kopie mehr. Derselbe fehlende Erfolgsvertrag lässt Onboarding und Einstellungen nach erfolglosem Speichern apiKeyAvailable=true anzeigen.

**Fix:** Speichern als throwing/Result-Vertrag mit injizierbaren Security-Aufrufen ausführen. Legacy-Wert erst nach bestätigtem Schreiben und geeignetem Readback entfernen; bei Fehler erhalten und eine verständliche Wiederholungsmöglichkeit anzeigen. Cache und UI dürfen nur bestätigten Zustand übernehmen. Regressionstests für gesperrten Schlüsselbund, verweigerten Zugriff und erfolgreiche Wiederholung ergänzen.

### LR-KO-010 (A6-02) · : Profilumbenennung übergibt den vollständigen OAuth-Grant als Prozessargument

*P0 · Launch-Blocker · security · Konfidenz hoch · Aufwand M · Risiko mittel · Duplikat von LR-KO-001*

**Features:** F-KO-01  ·  **Alt-ID:** N10

**Beleg:** `WhisperM8/Services/AgentChats/ClaudeAccountProfiles.swift:422-435`, `WhisperM8/Services/AgentChats/ClaudeAccountProfiles.swift:460-470`

**Szenario:** Ein angemeldetes Zusatzprofil wird umbenannt. Der aus dem Schlüsselbund gelesene Secret-String wird unverändert hinter -w an security add-generic-password übergeben. Während dieses Prozesses steht der Grant einschließlich enthaltener Tokens in argv und kann durch Prozesslisten beziehungsweise Diagnosewerkzeuge erfasst werden.

**Fix:** Den Grant ausschließlich über die nativen Security-APIs im Prozess übertragen, ohne Secret in argv oder Umgebung. Bestehende Rollback-Reihenfolge, profilabhängige Service-Namen und Erhalt des alten Grants bis zur bestätigten Zielanlage bewahren. Einen Test ergänzen, der Secret-Übergabe an Prozessrunner ausschließt.

### LR-SH-004 (A6-03) · : Nicht-UTF-8-Statusline-Skripte werden ohne Fremddatei-Bestätigung überschrieben

*P0 · Launch-Blocker · datenintegritaet · Konfidenz hoch · Aufwand S · Risiko niedrig*

**Features:** F-APP-03

**Beleg:** `WhisperM8/Services/Shared/StatuslineInstaller.swift:167-172`, `WhisperM8/Services/Shared/StatuslineInstaller.swift:215-220`, `WhisperM8/Services/Shared/StatuslineInstaller.swift:266-278`, `WhisperM8/Views/Settings/Pages/CLISkillsSettingsPage.swift:553-562`

**Szenario:** Unter ~/.claude/statusline-command.sh liegt ein eigenes, ausführbares Shellskript mit einem Latin-1-kodierten Umlaut im Kommentar. String(contentsOf:encoding:.utf8) scheitert. status() und foreignScriptURL() behandeln dies nicht als vorhandene Fremddatei. Der normale Install-Klick überschreibt das Skript atomar, ohne die vorgesehene Fremddatei-Bestätigung und ohne Backup. Der ursprüngliche Dateiinhalt geht verloren.

**Fix:** Existenz, Lesbarkeit, Dekodierbarkeit und Ownership getrennt prüfen. Eine vorhandene, nicht lesbare oder nicht dekodierbare Datei muss Installation und Update ohne ausdrückliche Konfliktbehandlung stoppen. Vor bestätigtem Ersetzen bytegenau sichern; Tests mit nicht-UTF-8-Dateien und Lesefehlern ergänzen.

### LR-SH-005 (A6-04) · : Statusline- und Theme-Schreiber verlieren konkurrierende settings.json-Änderungen

*P0 · Launch-Blocker · race · Konfidenz hoch · Aufwand L · Risiko hoch · Duplikat von LR-AK-017*

**Features:** F-APP-03, F-AC-02  ·  **Alt-ID:** R4-INSTALL-01

**Beleg:** `WhisperM8/Services/Shared/StatuslineInstaller.swift:328-358`, `WhisperM8/Services/AgentChats/ClaudeThemeWriter.swift:71-78`, `WhisperM8/Services/AgentChats/ClaudeThemeWriter.swift:108-153`, `WhisperM8/WhisperM8App.swift:273-278`

**Szenario:** Der Statusline-Installer liest settings.json. Danach ergänzt eine laufende CLI einen Permission-Eintrag oder der Hintergrund-Theme-Schreiber schreibt seine Änderung. Anschließend ersetzt der Installer die gesamte Datei aus seinem älteren Snapshot. Der dazwischen bestätigte Eintrag verschwindet. Auch umgekehrt kann der Theme-Schreiber gerade installierte Statusline-Einträge entfernen. Atomare Einzelwrites verhindern dieses Lost Update nicht.

**Fix:** Alle eigenen settings.json-Mutationen über einen gemeinsamen transaktionalen Schreibpfad serialisieren und auf den neuesten Stand mergen. Änderungen externer Schreiber konservativ erkennen und bei Konflikt abbrechen beziehungsweise erneut einlesen; atomare Writes nicht als gegenseitigen Ausschluss behandeln. Vorversionen sichern, Konflikte sichtbar machen und deterministische Interleaving-Tests ergänzen. Fremde Schlüssel, Dateirechte und vorhandene Symlinks müssen erhalten bleiben.

### LR-SH-006 (A6-05) · : Der allgemeine Prozessresolver vererbt nicht benötigte Parent-Secrets

*P0 · Launch-Blocker · security · Konfidenz hoch · Aufwand L · Risiko hoch · Duplikat von LR-SH-001*

**Features:** F-AC-02, F-DIK-09  ·  **Alt-ID:** N09

**Beleg:** `WhisperM8/Services/Shared/LoginShellEnvironment.swift:91-108`, `WhisperM8/Services/Shared/LoginShellEnvironment.swift:119-145`, `WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:830-840`, `WhisperM8/Services/Dictation/CodexPostProcessor.swift:83-84`, `WhisperM8/Views/AgentTerminalView.swift:879-908`

**Szenario:** Die App startet mit einem exportierten, für WhisperM8 nicht benötigten AWS_SECRET_ACCESS_KEY oder vergleichbaren Dienst-Token. processEnvironment() kopiert das vollständige Parent-Environment und entfernt nur wenige Namensgruppen. Damit erhält schon /usr/bin/which dieses Secret; ebenso erhalten es jeder neue Agent und der Codex-Nachbearbeitungsprozess, unabhängig vom gewählten Konto oder Projekt.

**Fix:** Prozessklassen mit begrenzter Basisumgebung einführen. Systemproben brauchen keine Anbieter-Secrets; Agenten erhalten nur ausdrücklich benötigte oder bewusst freigegebene Zugangsdaten. PATH, Locale, Terminalfarben, explizite Profilzuordnung, gewollte Plugin-Pfade und erforderliche Authentifizierung erhalten. Tests müssen sowohl Secret-Ausschluss als auch funktionsfähige CLI-Umgebungen belegen.

### LR-SH-007 (A6-06) · : Die Login-Shell-Abfrage kann den ersten Chatstart dauerhaft auf dem Hauptthread blockieren

*P1 · Launch-Blocker · performance · Konfidenz hoch · Aufwand M · Risiko mittel*

**Features:** F-AC-02, F-APP-08

**Beleg:** `WhisperM8/Services/Shared/LoginShellEnvironment.swift:59-79`, `WhisperM8/Services/Shared/LoginShellEnvironment.swift:174-193`, `WhisperM8/WhisperM8App.swift:308-317`, `WhisperM8/Views/AgentTerminalView.swift:870-879`

**Szenario:** Die Login-Konfiguration wartet auf einen nicht verfügbaren Dienst oder schreibt mehr Diagnoseausgabe als in den ungelesenen stdout-/stderr-Puffer passt. queryLoginShellPath() wartet ohne Timeout auf Prozessende und liest stdout erst danach; stderr wird nie geleert. Startet ein Chat vor Abschluss des Hintergrund-Prewarms, findet path keinen Cache und führt denselben blockierenden Loader selbst aus. Der Hauptthread kann dadurch unbegrenzt stehen; die Vorwärmung verhindert diesen Pfad nicht.

**Fix:** Shellabfrage mit Deadline, SIGTERM/SIGKILL-Kaskade, geschlossenem stdin und parallel geleerten, begrenzten Ausgaben ausführen. Den Hauptthread niemals auf die Auflösung warten lassen: dort sofort einen brauchbaren Cache/Fallback verwenden oder den Launch asynchron vorbereiten. Gleichzeitige Erstabfragen zusammenfassen. Tests für hängende Shell, volle Ausgabepuffer und Chatstart während des Prewarms ergänzen.

### LR-PJ-001 (A6-07) · : Die Plugin-Migration räumt fremde, ungestempelte Skills automatisch weg

*P1 · Launch-Blocker · korrektheit · Konfidenz hoch · Aufwand S · Risiko niedrig*

**Features:** F-AUT-02

**Beleg:** `WhisperM8/Services/Shared/CLISkillExporter.swift:314-326`, `WhisperM8/Services/Shared/WhisperM8ClaudePlugin.swift:309-325`, `WhisperM8/Services/Shared/WhisperM8ClaudePlugin.swift:363-379`, `WhisperM8/Support/AppPreferences.swift:524-534`

**Szenario:** Ein neuer Nutzer besitzt bereits einen eigenen ~/.claude/skills/codex-subagent/SKILL.md, der nicht aus WhisperM8 stammt und keinen Install-Stempel hat. installState() liefert unknownDrift. Die standardmäßig aktive Erststart-Migration schützt nur modifiedLocally und Symlink-Verzeichnisse und verschiebt den fremden Skill deshalb ungefragt in den versteckten Backup-Ordner. Der eigene Slash-Befehl fehlt danach auch in außerhalb der App gestarteten CLIs. Ein Backup verhindert den Funktionsausfall nicht.

**Fix:** Automatischen Umzug auf nachweislich eigene, unveränderte Installationen beschränken. Unbekannte oder ungestempelte Abweichungen unverändert lassen und bei Bedarf einen ausdrücklich bestätigten Umzug anbieten. Die versionierte Plugin-Ablage, Symlink-Schutz und Sicherung bestätigter Umzüge erhalten. Einen Test mit fremdem, ungestempeltem Nicht-Jarvis-Skill ergänzen.

### LR-BR-001 (A6-08) · : Brew-Zap lässt installierte Statuslines und fremde Konfigurationsänderungen zurück

*P1 · Launch-Blocker · infra · Konfidenz hoch · Aufwand L · Risiko hoch*

**Features:** F-APP-03, F-APP-06, F-AUT-02

**Beleg:** `scripts/update-cask.sh:40-53`, `WhisperM8/Services/Shared/StatuslineInstaller.swift:259-294`, `WhisperM8/Services/Shared/StatuslineInstaller.swift:343-358`, `WhisperM8/Services/Shared/CLISymlinkInstaller.swift:13-35`, `WhisperM8/Services/Shared/WhisperM8ClaudePlugin.swift:293-301`

**Szenario:** Der Nutzer installiert über die Einstellungen die Statusline und deinstalliert danach per brew uninstall --zap. Der generierte Cask entfernt nur drei app-eigene Library-Verzeichnisse beziehungsweise Dateien. Die beiden Skripte, Statusline-Einträge in ~/.claude/settings.json, Install-Stempel, verschobene lose Skills und ~/.local/bin/whisperm8 werden weder entfernt noch wiederhergestellt. Damit bleiben die von W7 ausdrücklich ausgeschlossenen Fremdänderungen bestehen; der CLI-Symlink zeigt zusätzlich auf das entfernte Binary.

**Fix:** Ein Ownership- und Restore-Journal für externe Installationsänderungen führen und einen vom Cask verwendbaren, app-unabhängigen Bereinigungspfad vorsehen. Nur unveränderte eigene Einträge entfernen, zuvor gesicherte Fremdeinträge konfliktbewusst wiederherstellen und umgezogene Skills wieder anbieten. Niemals ~/.claude pauschal löschen oder Nutzer-Transcripts und zwischenzeitliche Änderungen überschreiben. W7 mit vorhandener Fremdkonfiguration testen.

### LR-ONB-017 (A6-09) · : Das Codex-Login-Skript quotiert den aufgelösten Binary-Pfad nicht

*P1 · Launch-Blocker · korrektheit · Konfidenz hoch · Aufwand S · Risiko niedrig*

**Features:** F-APP-01, F-DIK-09

**Beleg:** `WhisperM8/Services/Dictation/CodexSupport.swift:191-205`, `WhisperM8/Services/Dictation/CodexSupport.swift:223-230`, `WhisperM8/Views/OnboardingView.swift:335-337`

**Szenario:** Codex ist ausführbar unter einem gültigen PATH-Verzeichnis mit Leerzeichen installiert, beispielsweise /Volumes/Tools Suite/bin/codex. Die Auflösung findet den vollständigen Pfad, das erzeugte .command-Skript enthält ihn jedoch unquotiert vor login. Die Shell versucht /Volumes/Tools auszuführen statt Codex. Der angebotene Anmeldeweg funktioniert nicht und der Nutzer kann W3 darüber nicht abschließen.

**Fix:** Binary-Pfad über einen zentralen Shell-Literal-Escaper einfügen, der Leerzeichen, Apostrophe und Metazeichen korrekt behandelt. Die echte CLI und deren interaktiven Login im Terminal beibehalten. Skriptgenerierung als pure Funktion testen, mindestens mit Leerzeichen und Apostroph im Pfad.

### LR-PJ-002 (A6-10) · : Die Umgebungssäuberung entfernt fremde Plugin-Verzeichnisse vor deren angeblichem Erhalt

*P1 · Launch-Blocker · korrektheit · Konfidenz hoch · Aufwand S · Risiko mittel*

**Features:** F-AUT-02, F-AC-02

**Beleg:** `WhisperM8/Services/Shared/LoginShellEnvironment.swift:106-108`, `WhisperM8/Services/Shared/WhisperM8ClaudePlugin.swift:236-250`, `WhisperM8/Services/Shared/WhisperM8ClaudePlugin.swift:385-391`, `WhisperM8/Views/AgentTerminalView.swift:879-885`

**Szenario:** Die App erbt CLAUDE_CODE_PLUGIN_DIRS mit einem bewusst konfigurierten eigenen Plugin-Pfad. processEnvironment() entfernt jedoch sämtliche CLAUDE_CODE_*-Variablen, einschließlich genau dieser Variable. Bootstrap.launchEnvironment() liest den angeblich zu erhaltenden Wert erst aus dieser bereinigten Umgebung und bekommt immer nil. Neue Chats erhalten dadurch nur das WhisperM8-Plugin; eigene Plugin-Tools und Befehle fehlen. Bei ausgeschaltetem WhisperM8-Plugin wird der fremde Wert ebenfalls nicht wiederhergestellt.

**Fix:** Die gewollte Plugin-Pfadliste vor der Kontextbereinigung erfassen oder gezielt von deren Entfernung ausnehmen. Nur verschachtelte Session-/Routing-Variablen entfernen; fremde Plugin-Pfade in ursprünglicher Reihenfolge erhalten, den eigenen Pfad dedupliziert ergänzen und beim Kill-Switch ausschließlich das eigene Plugin weglassen. Einen Integrationstest über Resolver und Bootstrap ergänzen, nicht nur über launchEnvironment() mit direkt übergebenem inherited-Wert.

### LR-SH-008 (A6-11) · : Fehlerhafte Transkriptionsantworten schreiben diktierte Inhalte in öffentliche Logs

*P2 · privacy · Konfidenz hoch · Aufwand S · Risiko niedrig*

**Features:** F-DIK-02

**Beleg:** `WhisperM8/Services/Dictation/MultipartTranscriptionClient.swift:72-79`, `WhisperM8/Services/Dictation/MultipartTranscriptionClient.swift:104-111`, `WhisperM8/Services/Shared/Logger.swift:61-86`

**Szenario:** Der Anbieter liefert HTTP 200 mit einer abgeschnittenen oder anderweitig nicht dekodierbaren JSON-Antwort, deren Anfang bereits vertraulichen diktierten Text enthält. Die Decoder-Fehlerbehandlung protokolliert die ersten 500 Zeichen des gesamten Antworttexts. Logger.debug markiert die fertige Nachricht als public; bei aktiviertem Datei-Logging wird sie zusätzlich unredigiert lokal gespeichert. Der Fehlerpfad macht damit Inhalte sichtbar, während der Erfolgsfall nur deren Länge protokolliert.

**Fix:** Keine rohen Antwortkörper protokollieren. Für Diagnose Status, Byteanzahl und strukturellen Decoder-Fehler ohne Nutzinhalt erfassen; etwaige ausdrücklich benötigte Inhaltsdiagnose separat und bewusst freigeben. Mit einer fehlerhaften Antwort samt vertraulichem Beispieltext testen, dass weder os_log-Nachricht noch Dateilog den Inhalt enthalten.

## Nicht abgedeckt

- Keine Produktdateien, Tests oder Konfigurationen geändert; keine Builds, Tests oder App-Starts ausgeführt. Alle Befunde beruhen auf statischer Analyse, nicht auf Laufzeit-Reproduktionen.
- Die angeforderten Markdown-Berichte wurden aufgrund der übergeordneten Vorgabe, keine Report-/Summary-Dateien zu schreiben, nicht angelegt. Vorgesehene Zielpfade für den Hauptagenten: /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/docs/audit/2026-10-launch-readiness/02-findings/A6-shared-infra.md und /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/docs/audit/2026-10-launch-readiness/01-lagebild/shared-infra.md.
- Transport-Sicherheit des Control-Sockets, Peer-UID, Socket-/Lock-Dateirechte und Dispatch zu Debug/Speak bleiben dem Delta-Lauf vorbehalten: AgentControlServer und die übrigen AgentControlRequestHandler-Dateien waren ausgeklammert. Die beiden ausdrücklich erlaubten Debug-/Speak-Erweiterungen wurden geprüft; dort ist Debug am Flag gegated und die Sprecheridentität tokengeprüft. Daraus folgt keine vollständige Zertifizierung des Transportwegs.
- AgentChatsView-Erweiterungen, Grid-/Tab-/Sidebar-/Switcher-Views, Workspace-/Layout-Stores, Jarvis-Board, Chats-CLI sowie Plugin-Mod wurden nicht inhaltlich auditiert. Automatisierte Querschnittssuchen ersetzen keine Prüfung dieser ausgeschlossenen Komponenten.
- AppUpdateChecker, AppProfileActivator, PermissionService und WindowRequestCenter wurden für die angenommene A5-Zuständigkeit nicht vertieft geprüft. Die genaue A5-Dateiliste lag diesem Auftrag nicht bei.
- 23 Shared-Service-Dateien und beide ausdrücklich genannten Support-Dateien wurden vollständig gelesen; große Querschnittsdateien wurden nur an relevanten Aufrufketten gelesen. files_read enthält auch solche teilweise gelesenen Dateien, aber keine ausschließlich durchsuchten Dateien.
- Swift-6-Bereitschaft, tatsächliche Startzeit, CPU-/Speicherbudgets und Main-Actor-I/O außerhalb der verifizierten Aufrufketten sind nicht abschließend bewertet. @unchecked Sendable, Test-Hooks und Singletons wurden nicht ohne nachgewiesenes Fehlerszenario als Defekte gemeldet.
- Die Juli-Matrizen und der Refactoring-Audit wurden nach den betroffenen Themen durchsucht. N06, N09, N10 und R4-INSTALL-01 sind weiterhin codebelegt. Alte Skill-Overwrite-Befunde wurden nicht pauschal übernommen: CLISkillExporter besitzt inzwischen Bestätigungs- und Symlink-Guards.
- W7 wurde hier für externe Installationsreste geprüft, nicht für tatsächliche Prozessbeendigung oder Proxy-/Socket-Cleanup beim Brew-Uninstall.

## Gelesene Dateien

54 Dateien:

- `docs/audit/2026-10-launch-readiness/00-scope/launch-definition.md`
- `docs/audit/2026-10-launch-readiness/00-scope/feature-inventar.md`
- `WhisperM8/Services/Shared/KeychainManager.swift`
- `WhisperM8/Services/Shared/Logger.swift`
- `WhisperM8/Services/Shared/LoginShellEnvironment.swift`
- `WhisperM8/Services/Shared/FileEventSource.swift`
- `WhisperM8/Services/Shared/SigpipeGuard.swift`
- `WhisperM8/Services/Shared/ObjCException.swift`
- `WhisperM8/Services/Shared/StatuslineInstaller.swift`
- `WhisperM8/Services/Shared/CLISkillExporter.swift`
- `WhisperM8/Services/Shared/WhisperM8ClaudePlugin.swift`
- `WhisperM8/Services/Shared/DebugControl.swift`
- `WhisperM8/Services/Shared/SpeechCallouts.swift`
- `WhisperM8/Services/Shared/CLISymlinkInstaller.swift`
- `WhisperM8/Services/Shared/MainThreadStallMonitor.swift`
- `WhisperM8/Services/Shared/StallWatchdog.swift`
- `WhisperM8/Services/Shared/PerformanceCounters.swift`
- `WhisperM8/Services/Shared/CodexGlobalConfigReader.swift`
- `WhisperM8/Services/Shared/PhpStormLauncher.swift`
- `WhisperM8/Services/Shared/ViewSnapshotRenderer.swift`
- `WhisperM8/Services/Shared/SemanticVersion.swift`
- `WhisperM8/Services/Shared/SystemSoundCatalog.swift`
- `WhisperM8/Services/Shared/PerformanceSignposts.swift`
- `WhisperM8/Services/Shared/GridPerformanceTracker.swift`
- `WhisperM8/Services/Shared/CodexModelCatalog.swift`
- `WhisperM8/Support/AppPreferences.swift`
- `WhisperM8/Support/TextNormalizer.swift`
- `WhisperM8/Support/ThemeManager.swift`
- `WhisperM8/CLI/CLIEntryPoint.swift`
- `WhisperM8/CLI/DebugCLICommand.swift`
- `WhisperM8/CLI/SpeakCLICommand.swift`
- `WhisperM8/CLI/SessionRefResolver.swift`
- `WhisperM8/Services/AgentChats/AgentControlRequestHandler+Speak.swift`
- `WhisperM8/Services/AgentChats/AgentControlRequestHandler+Debug.swift`
- `WhisperM8/WhisperM8App.swift`
- `WhisperM8/Services/Dictation/MultipartTranscriptionClient.swift`
- `WhisperM8/Services/Dictation/CodexSupport.swift`
- `WhisperM8/Services/Dictation/CodexStatusCache.swift`
- `WhisperM8/Services/Dictation/CodexPostProcessor.swift`
- `WhisperM8/Views/OnboardingView.swift`
- `WhisperM8/Views/Settings/Models/CodexConnectionModel.swift`
- `WhisperM8/Views/Settings/Pages/CLISkillsSettingsPage.swift`
- `WhisperM8/Views/Settings/Pages/TranscriptionSettingsPage.swift`
- `WhisperM8/Views/AgentTerminalView.swift`
- `WhisperM8/Services/AgentChats/AgentCommandBuilder.swift`
- `WhisperM8/Services/AgentChats/AgentHeadlessCLI.swift`
- `WhisperM8/Services/AgentChats/GitProjectStatus.swift`
- `WhisperM8/Services/AgentChats/AgentWorktreeManager.swift`
- `WhisperM8/Services/AgentChats/ClaudeAccountProfiles.swift`
- `WhisperM8/Services/AgentChats/ClaudeThemeWriter.swift`
- `WhisperM8/Services/AgentChats/AgentSessionStore.swift`
- `Tests/WhisperM8Tests/LoginShellEnvironmentTests.swift`
- `Tests/WhisperM8Tests/WhisperM8ClaudePluginTests.swift`
- `scripts/update-cask.sh`
