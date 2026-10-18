---
status: aktiv
updated: 2026-10-17
description: Schiedssprüche von C2 (4 Sonnet-Schiedsrichter) zu den 17 Befunden, die Finder (P0) und Prüfer (P2/P3) gegensätzlich eingestuft hatten.
---

# C2 Schiedssprüche

17 Sprüche. Seite: pruefer 14, dazwischen 3.

| ID | Finder | Prüfer | Spruch | Blocker | Auslöser | Titel |
|---|---|---|---|---|---|---|
| LR-DIK-001 | P0 | P2 | P2 | — | selten | Beenden rettet laufende Diktate nicht |
| LR-DIK-002 | P0 | P2 | P2 | — | nur durch manuellen Eingriff | Ein inkompatibler Modus führt zum Überschreiben aller Custom-Modi |
| LR-DIK-020 | P0 | P2 | P2 | — | nur durch manuellen Eingriff | Doppelte Output-Mode-IDs beenden die App weiterhin per Trap |
| LR-SH-003 | P0 | P2 | P2 | — | selten | : Fehlgeschlagene Keychain-Migration löscht die einzige persistierte API-Key-Kopie |
| LR-AK-002 | P0 | P2 | P2 | — | nur durch manuellen Eingriff | : Downgrade überschreibt ein neueres Workspace-Schema |
| LR-AK-003 | P0 | P2 | P2 | — | selten | : Zusammenfassungen legen vertraulichen Chat-Inhalt in argv offen |
| LR-AK-004 | P0 | P2 | P2 | — | nur durch manuellen Eingriff | : Skalare Tool-Payloads passieren eine NSException-gefährdete JSON-Serialisierung |
| LR-AK-017 | P0 | P2 | P3 | — | selten | [A3-01] Theme-Synchronisierung überschreibt konkurrierende Nutzereinstellungen |
| LR-AK-018 | P0 | P2 | P3 | — | selten | [A3-02] Queue bestätigt Aufträge und Reservierungen trotz fehlgeschlagener Persistenz |
| LR-SH-001 | P0 | P3 | P3 | — | nur durch manuellen Eingriff | [A3-03] Unbeteiligte Parent-Secrets gelangen ungefiltert in Kindprozesse |
| LR-SH-004 | P0 | P2 | P2 | — | nur durch manuellen Eingriff | : Nicht-UTF-8-Statusline-Skripte werden ohne Fremddatei-Bestätigung überschrieben |
| LR-KO-003 | P0 | P3 | P3 | — | nur durch manuellen Eingriff | Usage-Ping löscht fremde Projektverläufe allein aufgrund eines Namenssuffixes |
| LR-KO-004 | P0 | P2 | P2 | — | selten | Vorgemerkte Kontowechsel können zwischenzeitlich eingegebene Entwürfe verwerfen |
| LR-GPT-001 | P0 | P2 | P2 | — | selten | Jeder lokale Benutzer kann GPT-Konten über den Router ohne Authentisierung benutzen |
| LR-GPT-002 | P0 | P2 | P1 | — | selten | Eine nachgeahmte Health-Antwort genügt zur Übernahme sämtlicher GPT-Prompts |
| LR-GPT-003 | P0 | P2 | P1 | — | selten | Hohe konfigurierte Proxyports bringen die gesamte App beim Profilstart zum Absturz |
| LR-BR-002 | P0 | P2 | P3 | — | nur durch manuellen Eingriff | Apple-App-Passwort wird als Prozessargument offengelegt |

## LR-DIK-001 · Beenden rettet laufende Diktate nicht

*folgt pruefer → P2 · Auslöser: selten*

Die Mechanik stimmt: applicationShouldTerminate antwortet sofort mit .terminateNow, eine laufende Aufnahme wird nicht finalisiert und ein laufender Upload nicht in den FailedRecordings-Store verschoben. P0/P1 trägt der Code trotzdem nicht, und zwar wegen der Wirkung, nicht wegen der Seltenheit: Verloren geht ein einzelnes, flüchtiges Diktat, das der Nutzer selbst durch Beenden bei sichtbarem Overlay abbricht; ein persistierter Bestand ist nicht betroffen, die P1-Untergrenze für Quit-Datenverlust greift deshalb nicht. Das Produkt behandelt eine laufende Aufnahme ohnehin als verwerfbar (ESC löscht sie in cancelRecording, der Erfolgspfad löscht sie nach dem Paste), und FailedRecordingsStore.list() hat in der App keinen Aufrufer außer prune(), pendingRetry liegt nur im Speicher: ein im Quit-Hook gesichertes Diktat wäre nach dem Neustart in der App gar nicht auffindbar, der Fix ist faktisch ein neues Wiederherstellungs-Feature. Beim Beenden während des Uploads liegt die bereits geschlossene M4A weiter im tmp-Ordner, nur ein Beenden mitten in der Aufnahme hinterlässt eine unfertige, vermutlich nicht abspielbare Datei. Kein DoD-Punkt und kein W1-W7-Weg ist verletzt (W5 meint Chats und Tabs); als Härtung sinnvoll, schlank mit synchronem Finalisieren und Verschieben in den Store, ohne .terminateLater-Gate.

**Belege:** `WhisperM8/WhisperM8App.swift:428-440`, `WhisperM8/Services/Dictation/RecordingCoordinator.swift:469-482`, `WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:150`, `WhisperM8/Services/Dictation/FailedRecordingsStore.swift:120-146`, `WhisperM8/Services/Dictation/RecordingCoordinator.swift:62`, `WhisperM8/Services/Dictation/AudioRecorder.swift:133-146`

## LR-DIK-002 · Ein inkompatibler Modus führt zum Überschreiben aller Custom-Modi

*folgt pruefer → P2 · Auslöser: nur durch manuellen Eingriff*

Die Mechanik stimmt: loadModes() liefert bei einem einzigen nicht dekodierbaren Eintrag [], modes fällt auf die Built-ins zurück, und die nächste Änderung in den Einstellungen (addMode, updateMode, setDefault) schreibt diese Ersatzliste ohne Backup über OutputModes.json. Es gibt aber keinen realistischen Auslöser: Kind, ContextCapturePolicy und ProjectAccessPolicy haben seit ihrer Einführung nie einen Fall verloren, alle später ergänzten Felder werden mit decodeIfPresent gelesen, und die Pflichtfelder existieren seit dem ersten Commit, sodass Update wie Downgrade über alle bisherigen Releases fehlerfrei dekodieren. Übrig bleiben Handedit, eine beschädigte Datei (Schreiben ist atomar) oder ein künftiger neuer Enum-Fall mit anschließendem Downgrade, also die Obergrenze P2. Der Schaden ist begrenzt, denn verloren gingen nur Metadaten der Custom-Modi (Name, Label, Template-Verweis, Overrides); die Prompt-Texte liegen separat in PostProcessingTemplates.json. Billiger Fix (Backup vor dem ersten Überschreiben nach einem Ladefehler, Einträge einzeln tolerant dekodieren), spätestens vor dem ersten Schemawechsel nach dem Launch einzubauen, aber weder Kern-P1 noch W6-Verstoß.

**Belege:** `WhisperM8/Services/Dictation/OutputModeStore.swift:64-70`, `WhisperM8/Services/Dictation/OutputModeStore.swift:126-134`, `WhisperM8/Views/Settings/Models/OutputModesViewModel.swift:210-213`, `WhisperM8/Models/OutputMode.swift:98-118`, `WhisperM8/Models/SelectedContext.swift:3-6`

## LR-DIK-020 · Doppelte Output-Mode-IDs beenden die App weiterhin per Trap

*folgt pruefer → P2 · Auslöser: nur durch manuellen Eingriff*

Der Trap ist real und beim Start erreichbar: AppState.selectedOutputMode ruft schon beim Initialisieren OutputMode.defaultMode() über OutputModeStore.modes in normalized() auf, und Dictionary(uniqueKeysWithValues:) bricht bei doppelten IDs per Precondition ab, bei jedem Start erneut (Crash-Loop). Die App erzeugt aber nie doppelte IDs: createCustomMode vergibt seit dem ersten Commit UUIDs, saveModes läuft selbst durch normalized() und würde vor dem Schreiben abbrechen, und die geschriebene Datei ist atomar und nach normalized() eindeutig. Ein Duplikat entsteht nur durch Handedit (klassisch: Eintrag kopiert, ID nicht geändert) oder fremdes Zusammenführen; kein Update-, Downgrade-, Quit- oder Gerätewechsel-Pfad erzeugt es, daher gilt die Obergrenze P2. P2 statt P3 wegen der Crash-Loop-Wirkung ohne erkennbare Ursache für den Nutzer und des trivialen Fixes; er sollte zusammen mit LR-DIK-002 gebaut werden, weil ein tolerantes Einzel-Decoding sonst selbst Duplikate einführen könnte.

**Belege:** `WhisperM8/Services/Dictation/OutputModeStore.swift:162`, `WhisperM8/Services/Dictation/OutputModeStore.swift:88-90`, `WhisperM8/Services/Dictation/OutputModeStore.swift:100-103`, `WhisperM8/Models/AppState.swift:32`

## LR-SH-003 · : Fehlgeschlagene Keychain-Migration löscht die einzige persistierte API-Key-Kopie

*folgt pruefer → P2 · Auslöser: selten*

Der Code-Pfad stimmt: save() loggt Fehler nur, load() löscht den UserDefaults-Wert trotzdem, und Onboarding wie Einstellungen setzen apiKeyAvailable = true unabhängig vom Ergebnis. Die Migrations-Prämisse des Finders ist für ausgelieferte Builds jedoch nicht erreichbar: Der Commit mit Keychain-Speicherung und Migration (c728ca2, 04.02.2026 11:18) ist Vorfahre des ersten Release-Tags v1.0.0 (12:19), kein getaggtes Release hat den Key je ausschließlich in UserDefaults gehalten, ein Legacy-Wert kann höchstens auf einer Entwicklermaschine liegen. Real bleibt der Teil, dass die Oberfläche 'gespeichert' meldet, obwohl der Keychain-Write scheiterte (zum Beispiel gesperrter oder defekter Schlüsselbund, abgelehnter Zugriffsdialog); dann scheitert das erste Diktat mit 'No API key configured. Please enter your API key in settings.', der Key ist neu eingebbar, es geht kein Nutzerinhalt verloren und nichts leckt. Ein fehlender Erfolgsvertrag im Schlüsselspeicher des Kern-Pfads F-DIK-02 ist ein spürbarer Mangel mit S-Fix (save liefert Bool, Legacy-Wert nur nach Erfolg löschen, 'gespeichert' nur nach Erfolg anzeigen), aber weder Datenverlust im P0-Sinn noch ein W2-Verstoß bei einem nur selten gestörten Schlüsselbund.

**Belege:** `WhisperM8/Services/Shared/KeychainManager.swift:30-34`, `WhisperM8/Services/Shared/KeychainManager.swift:61-67`, `WhisperM8/Views/OnboardingView.swift:635-640`, `WhisperM8/Views/Settings/Pages/TranscriptionSettingsPage.swift:107-112`, `WhisperM8/Services/Dictation/TranscriptionModels.swift:72-73`, `git: c728ca2 (2026-02-04 11:18) ist Vorfahre von Tag v1.0.0 (2026-02-04 12:19)`

## LR-AK-002 · : Downgrade überschreibt ein neueres Workspace-Schema

*folgt pruefer → P2 · Auslöser: nur durch manuellen Eingriff*

Die Mechanik stimmt: `migratedWorkspace` setzt `schemaVersion` bedingungslos auf 1, `loadBody` legt ein `pre-migration`-Backup an und speichert sofort zurück; das Backup bleibt liegen, wird aber nie automatisch eingespielt. Einen Auslöser gibt es heute nicht: `currentSchemaVersion` war seit v2.0.0 nie etwas anderes als 1, im Workspace-Modell kam seit v2.20.0 nur das Labs-Feld `gptProfileName` hinzu, und W6 betrifft nur Updates vorwärts. Eine Datei mit schemaVersion >= 2 entsteht nur per Handedit oder durch eine künftige Version, und selbst dann bleibt das Original im Backup erhalten (kein endgültiger Verlust). Für die Planung wichtig: Ein Guard schützt nur, wenn er in dem älteren Build steckt, auf den der Nutzer zurückgeht — er gehört deshalb (Aufwand M) in den Launch-Build und vor den ersten Schema-Bump, ist aber kein Blocker. P2 statt P0; das Duplikat LR-AK-029 folgt diesem Spruch.

**Belege:** `WhisperM8/Models/AgentChat.swift:595`, `WhisperM8/Services/AgentChats/AgentSessionStore.swift:1502`, `WhisperM8/Services/AgentChats/AgentWorkspaceRepository.swift:54-64`, `WhisperM8/Models/AgentChat.swift:87`

## LR-AK-003 · : Zusammenfassungen legen vertraulichen Chat-Inhalt in argv offen

*folgt dazwischen → P2 · Auslöser: selten*

Die Gegenstelle des Prüfers trägt nicht: Auf macOS 26 zeigt `ps -axww` einem normalen Benutzer die vollen Argumente fremder Prozesse (an root- und _windowserver-Prozessen gemessen), und auf dieser Maschine sind `~/.claude` 0700 und die Claude-Transcripts 0600 — argv ist für Claude-Chats damit ein neuer Lesekanal für andere lokale Konten (Codex-Rollouts sind 0644, dort nichts Neues). Der Prompt (bis 6000 Zeichen Chat-Auszug plus Commit-Meldungen und Testkommandos) steht bei jedem Lauf bis zu 60 s im argv, die Auto-Zusammenfassung ist standardmäßig an, und das Muster ist kein Repo-Standard: der Diktatpfad übergibt seinen Prompt per stdin (`codex exec -`). Trotzdem bleibt es bei P2: Ausnutzen braucht ein zweites lokales Konto, das genau in diesem Fenster `ps` abfragt, die App übergibt keine eigenen Zugangsdaten, die Auszüge sind je Nachricht auf 280/500 Zeichen gekürzt, und der Inhalt geht ohnehin an denselben Anbieter. Die DoD-Zeile 'Keine Secrets in argv' lese ich eng (Zugangsdaten der App), deshalb kein Blocker; der Fix (stdin, `claude -p` liest stdin) passt in die erste Welle, die Datenfluss-Seite der Zusammenfassungen läuft separat als LR-ONB-008.

**Belege:** `WhisperM8/Services/AgentChats/AgentSessionSummarizer.swift:35-39`, `WhisperM8/Services/AgentChats/AgentSessionSummarizer.swift:87-104`, `WhisperM8/Services/AgentChats/AgentHeadlessCLI.swift:39-48`, `WhisperM8/Services/Dictation/CodexSupport.swift:89`, `WhisperM8/Support/AppPreferences.swift:240`

## LR-AK-004 · : Skalare Tool-Payloads passieren eine NSException-gefährdete JSON-Serialisierung

*folgt pruefer → P2 · Auslöser: nur durch manuellen Eingriff*

Die Mechanik ist bestätigt und per ObjC-Probe gemessen: `+[NSJSONSerialization dataWithJSONObject:options:error:]` wirft auf macOS 26 für NSNumber und NSNull als Top-Level eine Objective-C-Exception ('Invalid top-level type in JSON write'), `try?` fängt sie nicht, und um die Reader liegt kein `ObjCException.catching`. Es fehlt aber jeder reale Erzeuger: In 4.838 lokalen Claude-Transcript-Dateien (main plus 6 Profil-Roots, 234.351 tool_use-Zeilen) hat kein einziges `input` eine andere Form als Objekt, in 5,6 GB Codex-Rollouts kommt `tool_search_call` nicht vor, und Fixtures und Tests decken nur Objekte ab. Auslösen kann es nur ein von Hand erzeugtes oder durch Format-Drift eines Drittprogramms verändertes Transcript — dann aber deterministisch bei jedem Lesen (Verlaufsansicht, Diktat-Kontext-Tail, Zusammenfassung). P2 ohne Blocker, weil die DoD-Zeile 'kein bekannter Weg' reale Pfade wie SIGPIPE oder installTap meint und hier kein Erzeuger existiert; der Fix ist trivial (`isValidJSONObject` wie im Search-Extractor, Aufwand S) und sollte trotzdem vor dem Launch mit.

**Belege:** `WhisperM8/Services/AgentChats/ClaudeTranscriptReader.swift:374-381`, `WhisperM8/Services/AgentChats/ClaudeTranscriptReader.swift:351`, `WhisperM8/Services/AgentChats/CodexTranscriptReader.swift:155-160`, `WhisperM8/Services/AgentChats/Search/ChatSearchContentExtractor.swift:209`, `Tests/WhisperM8Tests/AgentTestSupport.swift:58`

## LR-AK-017 · [A3-01] Theme-Synchronisierung überschreibt konkurrierende Nutzereinstellungen

*folgt pruefer → P3 · Auslöser: selten*

Der Read-Modify-Write ist tatsächlich ungesperrt, aber das Fenster zwischen `Data(contentsOf:)` (Z. 108) und `replaceItemAt` (Z. 153) beträgt Millisekunden und öffnet sich nur, wenn `theme` vom Zielwert abweicht (Z. 121), also beim Start nach geändertem Erscheinungsbild oder bei einem Hell/Dunkel-Wechsel. Die CLI schreibt `~/.claude/settings.json` selten (auf der Entwicklermaschine zuletzt vor sechs Tagen, trotz täglich vieler Sessions; die laufend geschriebene Datei ist `~/.claude.json`), Mid-Write-Parsefehler werden abgefangen, und das Restrisiko steht im Dateikopf. Verloren ginge höchstens eine einzelne Einstellung, W5 ist nicht berührt: P3, kein Blocker. Die eigentliche Launch-Frage — dass die App überhaupt, auch im Diktatprofil ohne Claude und ohne Profil-Gate, in die Fremddatei schreibt — ist W7 und läuft über LR-BR-001/-005; ein Theme-Transport per `--settings` würde dort entschieden und erledigt diesen Befund mit. LR-SH-002/-005/-011 folgen diesem Spruch für den Theme-Writer-Teil.

**Belege:** `WhisperM8/Services/AgentChats/ClaudeThemeWriter.swift:108-153`, `WhisperM8/Services/AgentChats/ClaudeThemeWriter.swift:121`, `WhisperM8/Services/AgentChats/ClaudeThemeWriter.swift:16-19`, `WhisperM8/WhisperM8App.swift:277`

## LR-AK-018 · [A3-02] Queue bestätigt Aufträge und Reservierungen trotz fehlgeschlagener Persistenz

*folgt pruefer → P3 · Auslöser: selten*

Der Code-Befund stimmt: `persist()` und `read()` verschlucken alle Fehler, `enqueue` und `reserveNext` melden trotzdem Erfolg, und ein Decode-Fehler würde von `reconcileOnLaunch` als leere Queue zurückgeschrieben. Die Auslöser sind aber eng: ein volles oder unbeschreibbares App-Support-Verzeichnis (dann scheitert die ganze App) oder eine Datei, die dieser Code nie so schreibt — Schreiben ist atomar, befüllt wird nur über den Control-Socket, und bei idle laufen `sendPrompt` und `markDelivered` im selben MainActor-Durchlauf, das Doppelzustell-Fenster ist praktisch null. Echtes Verlustpotenzial hat nur der Downgrade-Fall (der `State`-Enum dekodiert nicht tolerant, ein neuer Zustand verwürfe die ganze Queue), und betroffen sind kurzlebige Folgeaufträge eines Erweitert-Features (F-AUT-01), keine Chats oder Modi. P3, kein Blocker; mitnehmen sollte man 'Original sichern statt `[]` zurückzuschreiben'.

**Belege:** `WhisperM8/Services/AgentChats/AgentPromptQueueStore.swift:149-167`, `WhisperM8/Services/AgentChats/AgentPromptQueueDelivery.swift:70-71`, `WhisperM8/Services/AgentChats/AgentPromptQueue.swift:61-72`, `WhisperM8/WhisperM8App.swift:333`, `WhisperM8/Services/AgentChats/AgentControlRequestHandler.swift:1014-1063`

## LR-SH-001 · [A3-03] Unbeteiligte Parent-Secrets gelangen ungefiltert in Kindprozesse

*folgt pruefer → P3 · Auslöser: nur durch manuellen Eingriff*

Das Durchreichen der Start-Umgebung ist die Aufgabe eines Terminal-Hosts, kein Leck: Die Kinder (claude, codex, Shell) laufen als derselbe Nutzer, und `processEnvironment` entfernt gezielt nur Routing-/Identitätsvariablen (CLAUDE_CODE_*, CLAUDE_CONFIG_DIR, ANTHROPIC_CUSTOM_HEADERS, CCP_CONFIG_DIR) und lässt den Rest bewusst durch. Die DoD-Zeile „keine Secrets in vererbter Umgebung“ trifft die eigenen Secrets der App, und die gelangen nirgends in ein Kind-Env: Die Keychain-Keys werden nur im Prozess bzw. im CLI gelesen (RecordingCoordinator:89, CLITranscribe:316-319), es gibt kein setenv/putenv, und als einziges Geheimnis wird das gewollte Session-Token eingespeist (AgentTerminalView:899-904). Bei Dock-/Spotlight-/Login-Start (W1-Zielgruppe) enthält die launchd-Umgebung keine Nutzer-Secrets; sie landen nur bei Start aus einer Shell (`open` reicht die Aufrufer-Umgebung durch, Makefile:69), also dort, wo der Entwickler sie selbst exportiert hat und im Chat auch erwartet (AWS_PROFILE, Proxy-/Bedrock-/API-Key-Variablen). Es entsteht weder Rechteausweitung noch Abfluss an Dritte oder andere lokale Benutzer; die vorgeschlagene Allowlist (laut Finder selbst Risiko hoch) würde legitime Setups brechen und ist nicht zu empfehlen. Sinnvoll höchstens: die DoD-Zeile auf „App-eigene Secrets“ präzisieren, damit das Muster nicht erneut gemeldet wird (siehe die Duplikate LR-SH-006/-010), und einen Regressionstest „keine App-eigenen Keys im Kind-Env“ ergänzen.

**Belege:** `WhisperM8/Services/Shared/LoginShellEnvironment.swift:106-127`, `WhisperM8/Views/AgentTerminalView.swift:879-904`, `WhisperM8/Services/Dictation/RecordingCoordinator.swift:89`, `WhisperM8/CLI/CLITranscribe.swift:316-319`, `Makefile:69-70`, `docs/audit/2026-10-launch-readiness/00-scope/launch-definition.md:57`

## LR-SH-004 · : Nicht-UTF-8-Statusline-Skripte werden ohne Fremddatei-Bestätigung überschrieben

*folgt pruefer → P2 · Auslöser: nur durch manuellen Eingriff*

Die Mechanik stimmt: `try? String(contentsOf:encoding:.utf8)` macht aus „Datei vorhanden, aber nicht UTF-8“ ein nil, `status()` meldet `.missing`, `foreignScriptURL()` übersieht die Datei, und `install()` überschreibt sie atomar ohne Bestätigung und ohne Backup (StatuslineInstaller:168-172, 215-220, 266-279). Der Auslöser ist jedoch eng: Es gibt keinen Auto-Install, einziger Aufrufer ist der Install-/Update-Button der Einstellungen (CLISkillsSettingsPage:553-562, 698-709), und jedes UTF-8-Fremdskript, der Normalfall, wird erkannt und per Dialog bestätigt (Test StatuslineInstallerTests:268-284). Betroffen wäre nur, wer genau an einem der zwei Pfade ein selbst geschriebenes Skript in Legacy-Kodierung liegen hat — eine Handarbeit-Konstellation, kein normaler Nutzerweg. Verloren ginge ein einzelnes, leicht wiederherstellbares Nutzerskript, kein WhisperM8-Bestand (Aufnahmen, Modi, Chats, Schlüssel) und kein Transcript. Das ist ein echter Guard-Bypass mit billigem Fix (Existenz getrennt von Dekodierbarkeit prüfen, nicht dekodierbar = foreign), aber weder P0/P1 noch ein DoD- oder W1-W7-Verstoß.

**Belege:** `WhisperM8/Services/Shared/StatuslineInstaller.swift:168-172`, `WhisperM8/Services/Shared/StatuslineInstaller.swift:215-220`, `WhisperM8/Services/Shared/StatuslineInstaller.swift:266-279`, `WhisperM8/Views/Settings/Pages/CLISkillsSettingsPage.swift:553-562`, `WhisperM8/Views/Settings/Pages/CLISkillsSettingsPage.swift:698-709`, `Tests/WhisperM8Tests/StatuslineInstallerTests.swift:268-284`

## LR-KO-003 · Usage-Ping löscht fremde Projektverläufe allein aufgrund eines Namenssuffixes

*folgt pruefer → P3 · Auslöser: nur durch manuellen Eingriff*

Der Mechanismus stimmt, der Auslöser ist aber praktisch nicht erreichbar: `cleanupPingArtifacts` löscht jeden `projects/`-Eintrag mit Suffix `-whisperm8-limit-ping` rekursiv und ohne Backup (ClaudeAccountLimitPinger:42-44, 166-174), doch ein fremdes Projekt müsste auf genau diese Komponentenfolge enden — den internen Hilfsordnernamen der App, den der Nutzer selbst so wählen müsste. Dasselbe Suffix lässt der Indexer ohnehin überspringen (ClaudeSessionIndexer:88-103); ein kollidierendes Projekt wäre in der App also schon vor jeder Löschung unsichtbar und im Entwicklungsbetrieb längst aufgefallen. Der Lauf passiert nur nach einem Klick auf Update/↻ (AgentChatsClaudeAccountsTab:414-419, AgentUsagePopovers:280-287) und nur im Profil des gepingten Kontos. Realistisch betroffen wären allenfalls Entwickler mit einem Ordner dieses Namens, nicht die Zielgruppe; das ist Härtung, kein Datenverlust-Pfad im normalen Gebrauch. Der Finder-Fix (exakt den aus `encodeClaudeCwd(workDirectory.path)` berechneten Ordner löschen, den Indexer-Skip mit umstellen) ist S und risikoarm und sollte wegen der unwiderruflichen Löschung trotzdem in der nächsten Härtungsrunde mitgenommen werden.

**Belege:** `WhisperM8/Services/AgentChats/ClaudeAccountLimitPinger.swift:42-44`, `WhisperM8/Services/AgentChats/ClaudeAccountLimitPinger.swift:166-174`, `WhisperM8/Services/AgentChats/ClaudeSessionIndexer.swift:88-103`, `WhisperM8/Views/Settings/Pages/AgentChatsClaudeAccountsTab.swift:414-419`, `WhisperM8/Views/AgentUsagePopovers.swift:280-287`

## LR-KO-004 · Vorgemerkte Kontowechsel können zwischenzeitlich eingegebene Entwürfe verwerfen

*folgt pruefer → P2 · Auslöser: selten*

Die Lücke ist im Code real: `recheckPending` gruppiert die bereiten Chats nach Zielkonto, entnimmt sie schon vor der Verarbeitung aus `pending` und arbeitet die Gruppen nacheinander ab; `switchRunning` ruft `terminate` ohne erneute Prüfung von Status, Entwurf und Hintergrund-Tasks, obwohl die Vorgängergruppe bis zu 5 s in `waitForExit` suspendiert (AccountSwitchCoordinator:175-217, 224-246; AccountMoveStopResume:166-168). `execute` prüft direkt vor dem Anhalten dagegen neu (:123-141), und innerhalb einer Gruppe liegt kein await zwischen Prüfung und `terminate` — nur der Fall mit mehreren Zielkonten hat das Fenster, im Regelfall (ein Ziel) tritt es nicht auf. Der Auslöser braucht gleichzeitige Vormerkungen zu verschiedenen Zielkonten, die im selben 2-s-Tick bereit werden, plus Eingabe oder Turnstart im zweiten Chat während der Wartezeit. Folge ist der Verlust eines ungesendeten Entwurfs (heuristisch erkannt) oder eines gerade begonnenen Turns; der Chat wird danach im Zielkonto fortgesetzt, Transcript, Workspace und Journal bleiben intakt, es gehen also keine persistierten Nutzerdaten verloren. Erweitert-Feature (nur P0 blockiert), kein Nutzerweg W1-W7 betroffen; der Re-Check direkt vor `terminate` mit Rückfall auf „vormerken“ ist klein und unkritisch.

**Belege:** `WhisperM8/Services/AgentChats/AccountSwitchCoordinator.swift:175-217`, `WhisperM8/Services/AgentChats/AccountSwitchCoordinator.swift:224-246`, `WhisperM8/Services/AgentChats/AccountSwitchCoordinator.swift:123-141`, `WhisperM8/Services/AgentChats/AccountMoveStopResume.swift:166-168`, `Tests/WhisperM8Tests/AccountSwitchTests.swift:304-316`

## LR-GPT-001 · Jeder lokale Benutzer kann GPT-Konten über den Router ohne Authentisierung benutzen

*folgt pruefer → P2 · Auslöser: selten*

Der Mechanismus stimmt am Code, die Schwere nicht: Der Router bindet nur 127.0.0.1 (ClaudeGPTMixRouter.swift:250-254), nimmt jede Verbindung ohne Credential an (:725-748) und lässt das Konto über einen frei setzbaren Header wählen, notfalls mit Hintergrundstart der Instanz (:921-958). Es fließt aber kein Secret ab: Der Router injiziert nie Zugangsdaten und entfernt Auth-Header vor dem Codex-Upstream (:639-646); die Antwort geht nur an den Absender seines eigenen Requests, der Schaden ist fremder Kontingentverbrauch unter dem Konto des Nutzers. Auslöser wäre ein böswilliger zweiter macOS-Benutzer (Loopback gilt systemweit); Prozesse desselben Benutzers liegen innerhalb der Vertrauensgrenze, da sie ~/.gpt-profiles ohnehin lesen können. Das Backend ist Default aus, Proxy und Router starten nur bei aktivem Toggle (AppPreferences.swift:268-271, WhisperM8App.swift:359). Der Finder-Fix griffe zu kurz, solange die Proxy-Direktports offen bleiben (die App startet den Proxy ohne Client-Geheimnis, ClaudeCodeProxyManager.swift:864-894), und bräche ohne Token-Injektion bestehende Sessions; realistisch sind ein eingefrorener Token per ANTHROPIC_CUSTOM_HEADERS oder die dokumentierte Single-User-Annahme. P2, kein Blocker: Labs, kein DoD-Punkt und kein Weg W1-W7 betroffen.

**Belege:** `WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:250-254`, `WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:725-748`, `WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:921-958`, `WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:639-646`, `WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:864-894`, `WhisperM8/Support/AppPreferences.swift:268-271`, `WhisperM8/WhisperM8App.swift:359-377`

## LR-GPT-002 · Eine nachgeahmte Health-Antwort genügt zur Übernahme sämtlicher GPT-Prompts

*folgt dazwischen → P1 · Auslöser: selten*

Die Lücke ist am Code real und schwerer, als die Prüfer-Note nahelegt: ensureRunning überspringt den eigenen Start, sobald irgendein Listener 200/JSON/{ok:true} liefert (ClaudeCodeProxyManager.swift:404-412, 1346-1367) - eine statische, nachbildbare Konstante ohne Prozess-, UID- oder Instanzbindung -, danach adressiert der Router blind 127.0.0.1:<Backend-Port> (ClaudeGPTMixRouter.swift:186-195) und reicht Verlauf und Tool-Inhalte weiter. Das Diktat braucht nicht einmal den Health-Trick: Für main gilt der Port immer als bekannt (ClaudeCodeProxyManager.swift:563-566), das Audio geht ohne Probe an den Listener (ChatGPTSubscriptionTranscription.swift:231-251), und der Orphan-Guard fasst fremde Listener bewusst nie an (ClaudeCodeProxyOrphanGuard.swift:61-63). Ein Squatter kann außerdem Antworten samt tool_use in die Claude-Sitzung des Opfers einspeisen, also nicht nur mitlesen. Dagegen stehen harte Voraussetzungen: ein böswilliger anderer lokaler Benutzer (Same-UID-Malware liegt ohnehin innerhalb der Vertrauensgrenze), der den Port vor dem Proxy belegt hält, und Labs-Opt-in (GPT-Backend, bei Audio zusätzlich Diktat-Anbieter ChatGPT) auf einem Mehrbenutzer-Mac - für die Single-User-Zielgruppe selten. Ein Leck an andere lokale Benutzer bleibt auch in Labs ein Sicherheitsthema, daher P1 statt P2, wegen Opt-in und Mehrbenutzer-Voraussetzung aber nicht P0; kein Blocker, weil die DoD-Regel zu P0 nur Kern und Erweitert umfasst und kein Weg W1-W7 über das Backend läuft.

**Belege:** `WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:404-412`, `WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:1346-1367`, `WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:186-195`, `WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:563-566`, `WhisperM8/Services/Dictation/ChatGPTSubscriptionTranscription.swift:231-251`, `WhisperM8/Services/AgentChats/ClaudeCodeProxyOrphanGuard.swift:61-63`

## LR-GPT-003 · Hohe konfigurierte Proxyports bringen die gesamte App beim Profilstart zum Absturz

*folgt dazwischen → P1 · Auslöser: selten*

Der Trap ist real und der einzige ungeprüfte Port-Cast der App: allocateProfilePort addiert 10 auf den Hauptport (ClaudeCodeProxyManager.swift:727-739), isPortFree ruft UInt16(port) ohne Bereichsprüfung (:751), während Router und Health-Probe den Bereich prüfen (ClaudeGPTMixRouter.swift:236, ClaudeCodeProxyManager.swift:1303). Der Hauptport kommt unvalidiert aus der Einstellung (AppPreferences.swift:273-279, Textfeld GPTBackendSettingsPage.swift:270-276); schon der gültige Port 65535 genügt. Ausgelöst wird er nicht durch Datei- oder Defaults-Eingriffe, sondern über normale Abläufe mit angemeldetem Zusatzkonto: Chat-Start (AgentSessionDetailView.swift:371-378), Konto aktivieren (GPTAccountsSection.swift:447-448), 503-Pfad des Routers (ClaudeGPTMixRouter.swift:939) oder ChatGPT-Diktat; die ganze App stirbt samt Diktat und Chats, und der Absturz wiederholt sich bei jedem solchen Start. Gegen P0 spricht die Reichweite: Labs, Default aus, Zusatzkonto nötig und ein Port ab 65526, den kaum jemand wählt - selten, aber UI-erreichbar und damit nach dem Maßstab mindestens P1, nicht P2. Kein Blocker: Die DoD-Regeln zu P0/P1 gelten für Kern und Erweitert, kein Weg W1-W7 läuft hierüber; der Fix ist S (Eingabe auf 1024-65535 begrenzen, UInt16(exactly:), erschöpften Bereich als Fehler melden, Grenztests 65525/65535/Int.max).

**Belege:** `WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:727-739`, `WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:751`, `WhisperM8/Support/AppPreferences.swift:273-279`, `WhisperM8/Views/Settings/Pages/GPTBackendSettingsPage.swift:270-276`, `WhisperM8/Views/AgentSessionDetailView.swift:371-378`, `WhisperM8/Views/Settings/Pages/GPTAccountsSection.swift:447-448`, `WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:939`

## LR-BR-002 · Apple-App-Passwort wird als Prozessargument offengelegt

*folgt pruefer → P3 · Auslöser: nur durch manuellen Eingriff*

Die Zeilen 111-115 reichen das Passwort tatsächlich per --password im argv von notarytool weiter (scripts/build-dmg.sh:114), aber nur als Fallback hinter dem bevorzugten --keychain-profile (:103-108) und nur, wenn der Maintainer APPLE_ID, APPLE_TEAM_ID und das Passwort von Hand als Umgebungsvariablen setzt. Der Zweig liegt hinter DEVELOPER_ID_APPLICATION (:96) und läuft heute nirgends: release.yml ruft make dmg ohne jede Apple-Variable auf und baut bewusst ad-hoc (.github/workflows/release.yml:5-9, 55-56), und kein aktuelles Dokument beschreibt diesen Weg. Die DoD-Zeile 'Keine Secrets in argv' (launch-definition.md:57) meint App und Kindprozesse beim Nutzer, nicht ein Maintainer-Skript; es gibt keinen Endnutzer-Abfluss und keinen betroffenen Weg W1-W7. Übrig bleibt Hygiene: ein widerrufbares App-Passwort ist während der Notarisierung per ps auf dem Maintainer-Rechner sichtbar, daher P3 (eine Stufe unter dem Prüfer) und kein Blocker. Die Korrektur gehört in die E4-Pipeline (LR-BR-003): Keychain-Profil oder API-Key (--key/--key-id/--issuer) statt --password; dass notarytool 1.1.0 für --password einen @env:-Verweis versteht, belegt die lokale Hilfe nicht.

**Belege:** `scripts/build-dmg.sh:103-119`, `scripts/build-dmg.sh:96`, `scripts/build-dmg.sh:114`, `.github/workflows/release.yml:5-9`, `.github/workflows/release.yml:55-56`, `docs/audit/2026-10-launch-readiness/00-scope/launch-definition.md:57`
