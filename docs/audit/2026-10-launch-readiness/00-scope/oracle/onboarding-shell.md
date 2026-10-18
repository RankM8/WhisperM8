---
status: aktiv
updated: 2026-10-17
description: Regressions-Oracle der App-Hülle (Onboarding, Einstellungen, Menüleiste, Update, Rechte, Profil, Symlink, Absturzschutz-Verdrahtung) auf Stand a8e0f35 - Ergänzungen und Korrekturen zum Juli-Inventar.
---

# Regressions-Oracle: App-Hülle (Stand a8e0f35)

## Leseregel

Das Oracle beschreibt Verhalten, das kein Fix unbeabsichtigt ändern darf. Die Juli-Einträge (`DI-xx`, `AC-xx` in `docs/audit/2026-07-agent-chats-deep-dive/06-umsetzung/`) gelten weiter, sofern sie hier nicht ersetzt werden. Ein Eintrag "(aktualisiert)" ersetzt den gleichnamigen Juli-Eintrag. Einträge "F-…" sind neu seit Juli. "Befund-Bezug" nennt die LR-IDs aus `findings.jsonl`; ein Fix darf die Invarianten ändern, wenn der Befund es verlangt, muss das aber bewusst und mit Test tun. Zeilenangaben gelten auf `a8e0f35`.

## Korrekturen an Juli-Einträgen

### DI-42 (aktualisiert) · App-Quit während Diktat, Ducking-Sicherheitsnetz und PTY-Interrupt

- **Funktion:** Menü-Quit, Cmd+Q und SIGTERM laufen über `NSApp.terminate`. `applicationShouldTerminate` beendet den Absturz-Marker sauber (`AgentCrashRecoveryMarker.endRunCleanly`), pausiert das Fenster-Close-Tracking und sendet an alle noch laufenden Chat-PTYs zweimal Ctrl+C mit gemeinsamer Wartezeit; danach `.terminateNow`. `applicationWillTerminate` stellt aktives Ducking sofort zurück und schreibt den Fenster-State (`WhisperM8/WhisperM8App.swift:428`, `WhisperM8/WhisperM8App.swift:446`, `WhisperM8/Views/AgentTerminalView.swift:448`).
- **Einstiegspunkt:** `WhisperM8/WhisperM8App.swift:428`, `WhisperM8/WhisperM8App.swift:446`, `WhisperM8/Views/MenuBarView.swift:131`, SIGTERM-Umleitung `WhisperM8/WhisperM8App.swift:220`.
- **Sichtbares Verhalten:** Die App beendet sich ohne dauerhaft abgesenkte Systemlautstärke. Beim Quit mit laufenden Chats gibt es einen kleinen Blockier-Moment auf dem Main Thread (zwei `usleep`, zusammen rund 260 ms, nicht pro Chat). Eine gerade laufende Aufnahme oder Transkription wird weiterhin weder finalisiert noch gesichert (`applicationShouldTerminate` antwortet ohne Gate).
- **Erhaltungsinvarianten:** (1) Marker-Ende vor dem PTY-Tod, sonst startet der nächste Lauf fälschlich die Crash-Recovery. (2) Der Interrupt-Pfad kostet konstant einmal Wartezeit, nicht pro Chat. (3) `suspendCloseTracking` bleibt der früheste Hook, sonst wirft der Teardown die Sekundärfenster aus dem Store. (4) SIGTERM wird mit `SigpipeGuard.installNoOpHandler` plus DispatchSource umgeleitet, nie mit `SIG_IGN`. (5) Eine Quit-Härtung (Wunsch von LR-ONB-001) darf nicht hängen und niemals eine abgebrochene Aufnahme automatisch transkribieren oder einfügen; sie muss Recorder und Ducking geordnet abschließen und die Punkte 1 bis 4 erhalten.
- **Befund-Bezug:** LR-ONB-001, LR-DIK-001 (P0). Roadmap-Bezug Juli: `N02`/`R2.1`.

## Neue Einträge

### F-APP-01 · Onboarding-Delta seit Juli (Ergänzung zu DI-40)

- **Funktion:** Wizard mit Schritten Willkommen, Profil, Rechte, Hotkey, API-Key/Modell, optional Codex, Test. Die Schrittfolge ergibt sich aus dem gewählten Profil (`WhisperM8/Views/OnboardingView.swift:38`).
- **Einstiegspunkt:** `WhisperM8/Views/OnboardingView.swift:19`, Fenster `Window("WhisperM8 Setup", id: "onboarding")` in `WhisperM8/WhisperM8App.swift:92`, Auto-Öffnung `WhisperM8/WhisperM8App.swift:392`, Abschluss `WhisperM8/Views/OnboardingView.swift:134`.
- **Sichtbares Verhalten:** Beim Start ohne Mikrofon oder Accessibility öffnet sich der Wizard nach 0,5 s. "Next" ist bis zum Erfüllen des Schritt-Gates gesperrt (Rechte beide, Hotkey gesetzt, Key vorhanden); "Done" verlangt zusätzlich alles zusammen. Rechte werden alle 0,5 s gepollt, der Hotkey alle 0,3 s. Die Profilwahl wird sofort in `usageProfile` geschrieben, die Aktivierungs-Policy und die Fenster erst bei "Done" (`AppProfileActivator.apply`). Bei `full` öffnet "Done" Agent Chats, bei Menüleisten-Profilen schließt es alle Agent-Fenster. Der Codex-Schritt kann nur Login im Terminal öffnen und den Status neu prüfen, er installiert nichts. Es gibt keinen Claude-Schritt. Provider-Auswahl bietet "ChatGPT-Abo" nur bei aktivem GPT-Backend oder bereits gewähltem Provider an. Der Test-Schritt zeigt Recording, Transcribing, Ergebnis oder Fehler live aus `AppState`.
- **Erhaltungsinvarianten:** (1) Kein Done-Flag; Öffnung bleibt permission-basiert. (2) Profil-Persistenz bei Auswahl bleibt, sonst geht die Wahl beim Wizard-Abbruch verloren. (3) Codex-Schritt nur bei `wantsCodexEnrichment` und immer überspringbar; ohne Codex fallen Enrichment-Modi auf Raw zurück. (4) Der Codex-Statusprobe-Aufruf läuft off-main. (5) Provider-Wechsel sichert einen getippten Key des alten Providers, leert das Feld und wechselt auf das Default-Modell des neuen Providers. (6) Erstinstallation setzt Groq und `whisper-large-v3` als Default (`TranscriptionSettings.migrateIfNeeded`, `WhisperM8/Models/TranscriptionProvider.swift:179`). (7) Fenstergröße fest 520x560. Der Key wird derzeit bei jeder Texteingabe gespeichert (`WhisperM8/Views/OnboardingView.swift:635`); ein Fix darf das ändern, muss aber "vorhandener Key bleibt erhalten" sichern.
- **Befund-Bezug:** LR-ONB-002, LR-ONB-003, LR-ONB-004, LR-ONB-005, LR-ONB-006, LR-ONB-007, LR-ONB-013, LR-ONB-014, LR-ONB-017, LR-ONB-011, LR-SH-003.

### F-APP-02 · Menüleiste und Szenen-Verdrahtung (Ergänzung zu DI-39 und AC-48)

- **Funktion:** `MenuBarExtra` im Menüstil mit Statuszeile, letzter Transkription (100 Zeichen), Fehler, Hotkey-Anzeige, Mikrofon-Picker, Voice-Gate-Abschnitt und Callout-Stumm-Schalter (nur bei aktivem Feature), Einstiegen "Open WhisperM8...", "Output & History...", "Agent Chats...", "Stop N running chats" und Quit.
- **Einstiegspunkt:** `WhisperM8/WhisperM8App.swift:70`, `WhisperM8/Views/MenuBarView.swift:4`, Fenster-Gate `WhisperM8/WhisperM8App.swift:120`, Policy `WhisperM8/WhisperM8App.swift:213`.
- **Sichtbares Verhalten:** Das Menü zeigt "Agent Chats..." in jedem Profil; ein expliziter Klick hebt das Primärfenster-Gate auf, auch in Menüleisten-Profilen. "Stop all" erscheint nur bei laufenden PTYs. Cmd+, ist doppelt belegt (Menüleiste und Befehlsmenü "WhisperM8").
- **Erhaltungsinvarianten:** (1) Die Menüleiste bleibt ohne offenes Fenster bedienbar. (2) Die Gate-Logik in `AgentChatsPrimaryWindowRoot.resolveIfNeeded` ruft vor dem Schließen kein Fenster auf, das erscheint (`Color.clear` statt `ProgressView`). (3) Sekundärfenster ohne Store-Eintrag schließen sich selbst. (4) Wiederherstellung der Sekundärfenster nur im Profil `full`. (5) `applicationShouldHandleReopen` öffnet Agent Chats nur ohne sichtbares Fenster und nur in `full`. (6) Die zweite Instanz beendet sich und weckt die laufende per Distributed Notification (Name bleibt historisch `com.whisperm8.app.openSettings`).
- **Befund-Bezug:** LR-ONB-005, LR-ONB-009, LR-ONB-001.

### F-APP-03 · Einstellungen: Seitenstruktur, Routing, Allgemein/Berechtigungen/Info

- **Funktion:** 13 Seiten in fünf Gruppen (Dictation: Recording, Transcription, AI Output, Context & Privacy; Agents: Agent Chats, CLI & Skills; Claude Code: Accounts, Hooks, GPT-Backend; App: General, Permissions, About; Workspace: Output). Sidebar als statischer Stack, Route aus `WindowRequestCenter`.
- **Einstiegspunkt:** `WhisperM8/Views/SettingsView.swift:3`, `WhisperM8/Views/SettingsView.swift:125`, `WhisperM8/Views/Settings/Models/SettingsRouteTarget.swift:6`, `WhisperM8/Views/Settings/Pages/GeneralSettingsPage.swift:4`, `WhisperM8/Views/Settings/Pages/PermissionsSettingsPage.swift:3`, `WhisperM8/Views/Settings/Pages/AboutSettingsPage.swift:4`.
- **Sichtbares Verhalten:** Alle Profile sehen dieselbe ungefilterte Navigation, inklusive GPT-Backend und Hooks. Alt-Routen (`api`, `codex`, `modes`, `templates`, `testLab`, `outputOverview`, `history`, `agentChats`, `claudeCode`, `hotkey`, `audio`, `behavior`) landen auf den neuen Seiten und Tabs. General: Profil-Picker, Start bei Anmeldung, Theme, Auto-Update-Schalter. Permissions: Mikrofon und Accessibility als "Required", Bildschirmaufnahme als "Optional", Polling im Sekundentakt nur solange die Seite sichtbar ist. About: Version (Build nur, wenn abweichend), Update-Bereich, Credits.
- **Erhaltungsinvarianten:** (1) Jede Alt-Route bleibt aufgelöst; `SettingsRouteTarget.resolve` kennt keine Route doppelt. (2) Die Sidebar nutzt kein `List(selection:)` (Scroll-Offset-Fehler). (3) Die Route wird beim Öffnen zweimal gelesen (sofort und im nächsten Runloop-Durchlauf, weil `@Published` in `willSet` meldet). (4) Das Auswählen von "Agent Chats" öffnet nie automatisch den Hub. (5) Ein Profilwechsel in General wirkt live: `AppProfileActivator.apply`, bei `full` `.agentChats`-Request, sonst alle Agent-Fenster schließen. (6) Das Permissions-Polling wird beim Verlassen der Seite gestoppt. (7) `PermissionSettingsModel` bleibt über injizierte Provider testbar. (8) Ein verweigertes Mikrofon führt zu "Open Settings" statt zu einem erneuten Request (`microphonePrimaryButtonTitle`).
- **Befund-Bezug:** LR-ONB-012, LR-ONB-015, LR-ONB-016, LR-ONB-008, LR-AK-010, LR-GPT-003, LR-KO-005, LR-DOK-005, LR-ONB-011.

### F-APP-04 · Update-Hinweis und Update-Prüfung

- **Funktion:** `AppUpdateChecker` fragt GitHub nach dem neuesten Release, vergleicht semantische Versionen und erkennt Cask-Installationen am Caskroom-Pfad. Anzeige: Badge in der Agent-Chats-Sidebar, Details im Popover und in About, jeweils mit kopierbarem Befehl `brew upgrade --cask whisperm8`; ohne Cask-Receipt zusätzlich `brew install --cask rankm8/tap/whisperm8 --force`.
- **Einstiegspunkt:** `WhisperM8/Services/Shared/AppUpdateChecker.swift:12`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:97`, `WhisperM8/Views/AppUpdateViews.swift:9`, `WhisperM8/Views/AppUpdateViews.swift:38`, `WhisperM8/Views/AppUpdateViews.swift:124`, Start `WhisperM8/WhisperM8App.swift:253`.
- **Sichtbares Verhalten:** Erster Check 10 s nach dem Start, danach alle 24 h (Toleranz 10 min); manueller Check in About immer möglich. Nur `remote > lokal` meldet ein Update, lokale Dev-Builds mit gleicher oder höherer Version nie. Fehler zeigen eine deutsche Meldung (offline, unerwartete Antwort, unbekannte Version). Das Badge existiert nur in der Agent-Chats-Sidebar; Menüleisten-Profile sehen den Hinweis nur auf der About-Seite.
- **Erhaltungsinvarianten:** (1) Die App ersetzt sich nie selbst. (2) Ein vorhandenes `.available` wird beim Re-Check nicht auf `.checking` herabgestuft (Popover-Crash, reproduziert 2026-07-03). (3) `CopyableCommandBox` ändert die Größe beim Kopieren nicht und nutzt kein `withAnimation`. (4) Parallele `checkNow`-Aufrufe teilen sich eine Task. (5) Kill-Switch `updateCheckEnabled` stoppt nur die Automatik, nicht den manuellen Check. (6) Repo-Slug und Befehle müssen zum Release-Workflow und Cask passen. (7) Die Hinweistexte nennen Neustart, Beenden laufender Chats und erneute Rechte-Abfragen.
- **Befund-Bezug:** LR-ONB-009, LR-ONB-010, LR-DOK-001.

### F-APP-05 · Start bei Anmeldung

- **Funktion:** Schalter "Start at Login" über `LaunchAtLogin.Toggle` auf der General-Seite.
- **Einstiegspunkt:** `WhisperM8/Views/Settings/Pages/GeneralSettingsPage.swift:34`.
- **Sichtbares Verhalten:** Der Zustand liegt im System (SMAppService), nicht in `AppPreferences`. Mit Profil `dictationRaw`/`dictationEnrichment` startet die App als Menüleisten-Eintrag.
- **Erhaltungsinvarianten:** Der Schalter bleibt neben dem Profil-Picker; es gibt keinen eigenen persistierten Key; Policy und Fenster-Gate hängen allein am Profil, nicht am Login-Start.
- **Befund-Bezug:** keiner direkt; Verteilungsrisiko über LR-BR-001 (Brew-Zap).

### F-APP-06 · CLI-Symlink `whisperm8`

- **Funktion:** Legt `~/.local/bin/whisperm8` als Symlink auf das aktuelle App-Binary an, damit CLI und Skills denselben signierten Keychain-Zugriff nutzen.
- **Einstiegspunkt:** `WhisperM8/Services/Shared/CLISymlinkInstaller.swift:10`, Start `WhisperM8/WhisperM8App.swift:305`, Button "Create Link" in `WhisperM8/Views/Settings/Pages/CLISkillsSettingsPage.swift:32`.
- **Sichtbares Verhalten:** Beim Start (Hintergrund-Task) wird das Verzeichnis angelegt und der Link gesetzt; ein bereits korrekter Link bleibt, ein falscher wird ersetzt, eine reguläre Datei am Zielpfad bleibt unberührt (nur Debug-Log). Die Seite "CLI & Skills" zeigt den Status und kann den Link neu anlegen.
- **Erhaltungsinvarianten:** (1) Idempotent. (2) Niemals eine reguläre Datei überschreiben. (3) Ziel ist das aufgelöste Binary im Bundle (`Contents/MacOS/WhisperM8`), nicht ein temporärer Pfad; ein Dev-Build zieht den Link um. (4) Fehler brechen den Start nie ab. (5) Der Link bleibt Voraussetzung für `whisperm8 transcribe`, `chats` und die Skills.
- **Befund-Bezug:** LR-BR-001 (Zap lässt Reste zurück), LR-SH-004, LR-SH-005 (Statusline-Schreiber auf derselben Seite).

### F-APP-07 · Berechtigungen (Ergänzung zu DI-41)

- **Funktion:** `PermissionService` prüft und fragt Mikrofon, Accessibility und Bildschirmaufnahme an und öffnet die Datenschutz-Panes; `Info.plist` liefert die Begründungstexte.
- **Einstiegspunkt:** `WhisperM8/Services/Shared/PermissionService.swift:6`, `WhisperM8/WhisperM8.entitlements:5`, `WhisperM8/Info.plist:17`.
- **Sichtbares Verhalten:** Onboarding nutzt Mikrofon und Accessibility als Pflicht; im Onboarding ist die Mikrofon-Anfrage ein einmaliger Request ohne Weg in die Systemeinstellungen bei Ablehnung (die Permissions-Seite hat diesen Weg). Benachrichtigungen werden beim Start angefragt (`.alert`, `.sound`). Die App ist nicht sandboxed; Entitlements nur `audio-input` und `network.client`. `LSUIElement` ist `false`, die Policy wird zur Laufzeit gesetzt.
- **Erhaltungsinvarianten:** (1) Bildschirmaufnahme bleibt optional und blockiert Audio-Diktat nie. (2) Accessibility-Prompt öffnet die Pane (`kAXTrustedCheckOptionPrompt`). (3) Die drei Usage-Description-Texte bleiben vorhanden (fehlen sie, bricht der Request ab). (4) Gleiche Signatur-Identität bei Updates, sonst Re-Prompts (Hinweis im Update-Dialog).
- **Befund-Bezug:** LR-ONB-004, LR-ONB-005.

### F-APP-08 · Absturzschutz und Start-Verdrahtung in der Hülle

- **Funktion:** Reihenfolge im GUI-Start: `SigpipeGuard.install` im Entry-Point, danach SIGTERM-Umleitung, Plugin-Bootstrap, Notification-Delegate, Stall-Monitor, Retention, Hintergrund-Migrationen, Symlink, Prewarm, Scans, Control-Server, Crash-Recovery, Proxy-Start.
- **Einstiegspunkt:** `WhisperM8/CLI/CLIEntryPoint.swift:26`, `WhisperM8/WhisperM8App.swift:220`.
- **Sichtbares Verhalten:** Der Start blockiert nicht auf Subprozessen; Login-Shell-PATH und `which claude/codex` werden im Hintergrund vorgewärmt. Ein GPT-Backend wird nur bei aktivem Toggle hochgefahren, der Orphan-Guard räumt dort vor `ensureRunning` einen veralteten Proxy.
- **Erhaltungsinvarianten:** (1) SIGPIPE bleibt abgefangen (Handler, nicht `SIG_IGN`). (2) `MainThreadStallMonitor` startet immer. (3) `ClaudePluginBootstrap.run` läuft vor dem ersten Chat-Start. (4) Alle Disk-/Subprozess-Arbeiten laufen detached. (5) Die Crash-Recovery startet nach dem Control-Server und vor den Scan-Monitoren in der heutigen Reihenfolge; eine Umordnung ändert, welche Tabs zurückkommen.
- **Befund-Bezug:** LR-SH-007, LR-GPT-006, LR-SH-002 (Theme-Sync-Start), LR-ONB-001.

### F-DIK-12 · Nutzungsprofile `dictationRaw` / `dictationEnrichment` / `full`

- **Funktion:** Das Profil steuert, ob Codex-Enrichment (alle Modi außer Raw) verfügbar ist, ob Agent Chats aktiv sind und ob die App als Dock-App oder Menüleisten-App läuft. Default `full`, auch für Bestandsnutzer.
- **Einstiegspunkt:** `WhisperM8/Models/AppUsageProfile.swift:9`, `WhisperM8/Services/Shared/AppProfileActivator.swift:13`, `WhisperM8/Services/Shared/WindowRequestCenter.swift:91`, Onboarding `WhisperM8/Views/OnboardingView.swift:230`, Settings `WhisperM8/Views/Settings/Pages/GeneralSettingsPage.swift:15`.
- **Sichtbares Verhalten:** `full` = Dock-Icon, Primärfenster beim Start und Reopen; die zwei anderen Profile = `.accessory`, kein Dock-Icon, kein Cmd-Tab, kein automatisches Agent-Fenster. Profilwechsel in den Einstellungen wirkt sofort; der Store-State (offene Tabs) bleibt erhalten, ein Rückwechsel zu `full` stellt Fenster wieder her. Texte der Auswahl sind englisch.
- **Erhaltungsinvarianten:** (1) Fehlender oder unbekannter gespeicherter Wert fällt auf `full`. (2) Policy-Berechnung `wantsAgentChats ? .regular : .accessory` bleibt eine Quelle. (3) `allowsAgentChatsPrimaryWindow` startet aus dem Profil und wird nur von einem expliziten Agent-Chats-Request oder `AppProfileActivator` gesetzt. (4) Das Schließen läuft über `closeAgentChatWindows` (pausiertes Close-Tracking, 500 ms Verzögerung vor dem Wiedereinschalten). (5) Das Profil darf nie stillschweigend wechseln (Bestandsnutzer sehen nach einem Update dasselbe Verhalten).
- **Befund-Bezug:** LR-ONB-012, LR-ONB-009, LR-ONB-003.

### F-APP-09 · Theme-Verwaltung und Claude-Theme-Sync (Hülle)

- **Funktion:** `ThemeManager` hält den Erscheinungs-Override (`system`/`light`/`dark`), löst das aktuelle Schema auf, setzt `NSApp.appearance`, benachrichtigt Terminals und lässt `ClaudeThemeWriter` das Claude-Theme in `~/.claude.json` nachziehen (debounced). Beim App-Start läuft ein einmaliger Initial-Sync.
- **Einstiegspunkt:** `WhisperM8/Support/ThemeManager.swift:10`, `WhisperM8/Support/ThemeManager.swift:67`, `WhisperM8/Support/ThemeManager.swift:89`, Start `WhisperM8/WhisperM8App.swift:277`, Tokens `WhisperM8/Support/AppTheme.swift:12`.
- **Sichtbares Verhalten:** Jede Szene bekommt `preferredColorScheme` aus `ThemeManager.override`. Wechsel des macOS-Erscheinungsbilds wirkt bei Einstellung "System" sofort (KVO). Der Start-Sync läuft auch ohne Wechsel und ohne Profil-Gate.
- **Erhaltungsinvarianten:** (1) Auflösung `resolve(override:systemAppearance:)` bleibt rein und testbar. (2) `NSApp.appearance` wird gesetzt, weil NSPanel und MenuBarExtra sonst nicht folgen. (3) Schnelle Toggles erzeugen nur einen Schreibvorgang (Debounce). (4) Ein Fix am Writer (LR-SH-002/005) muss fremde Schlüssel in `~/.claude.json` bzw. `settings.json` erhalten und den Start-Sync profil- und zustandsabhängig machen, ohne das sichtbare Theme-Verhalten der App zu ändern.
- **Befund-Bezug:** LR-SH-002, LR-AK-017, LR-SH-005, LR-SH-011 (alle P0), LR-ONB-016 (Kontrast `textTertiary`).
