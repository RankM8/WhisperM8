---
status: aktiv
updated: 2026-10-17
description: Lagebild der App-Hülle (Start, Onboarding, Einstellungen, Menüleiste, Updates, Rechte, Fensterrouting, Theme) auf Stand a8e0f35 - Zweck, Datenfluss, Schlüsseldateien, Persistenz, Abhängigkeiten, Invarianten, Risiken.
---

# Lagebild: App-Hülle (onboarding-shell)

Stand: Commit `a8e0f35`. Ausgeklammert (Delta-Lauf): Agent-Chats-UI, `AgentWindowStore`, Jarvis-Board, Control-Server, `CLI/Chats*`, `Resources/claude-plugin/`. Diese Seite beschreibt nur, wie die Hülle sie startet, gatet und routet.

## Zweck

Die Hülle macht aus dem Binary eine bedienbare Mac-App. Sie entscheidet beim Start, ob die App als Dock-App oder reine Menüleisten-App läuft (Nutzungsprofil). Sie führt neue Nutzer durch Profil, Rechte, Hotkey, API-Key und Testdiktat, hält Einstellungen, Menüleiste und Update-Hinweis bereit und routet Fensteranfragen zwischen den Szenen. Außerdem zeichnet sie beim Start Hintergrunddienste an (Plugin, Symlink, Theme-Sync, Scans, Proxy) und kümmert sich um sauberes Beenden (SIGTERM, Marker, Ducking).

## Datenfluss

```
Binary (CLIEntryPoint)  --GUI-Pfad-->  SigpipeGuard.install, GUILaunchGuard
        |
        v
WhisperM8App.init: Single-Instance-Check (2. Instanz -> DistributedNotification "openSettings" -> beendet sich)
        |  setupHotkeys: KeyboardShortcuts.toggleRecording (keyDown startet, keyUp stoppt) -> AppState
        v
AppDelegate.applicationWillFinishLaunching
   wantsDock = needsOnboarding(Mikrofon+Accessibility) || usageProfile.wantsAgentChats
   -> NSApp.setActivationPolicy(.regular | .accessory)
        v
AppDelegate.applicationDidFinishLaunching  (SIGTERM-Handler, Plugin, Notifications, UpdateChecker,
   Theme-Sync, Retention, Memory/MCP-Sync, CLI-Symlink, Login-Shell-Prewarm, Scans, Control-Server,
   Crash-Recovery, VoiceGate, Proxy-Start)  ->  falls needsOnboarding: +0,5 s request(.onboarding)
        v
Szenen:  Window "Agent Chats" (erste Szene, Gate allowsAgentChatsPrimaryWindow)
         WindowGroup Sekundärfenster | MenuBarExtra(MenuBarView) | Window "settings" | Window "onboarding"
        ^
WindowRequestCenter.request(...)  <-- Menüleiste, Cmd+, , Onboarding-Done, Profilwechsel, Notification-Klick
        |  @Published latestRequest -> WindowRequestHandler (openWindow + activate)

Onboarding:  Welcome -> Profil -> Rechte -> Hotkey -> API-Key/Modell -> [Codex nur Enrichment/Full] -> Test
             Done -> AppProfileActivator.apply(profil) -> .agentChats öffnen ODER Agent-Fenster schließen
Einstellungen: GeneralSettingsPage (Profil) -> AppProfileActivator.apply + closeAgentChatWindows
Update:  AppUpdateChecker (10 s nach Start, dann 24 h) -> GitHub /releases/latest -> State
         -> SidebarUpdateBadge (nur Agent-Chats-Fenster) + AboutUpdateSection -> kopierbarer brew-Befehl
Theme:   ThemeManager (Override + KVO effectiveAppearance) -> preferredColorScheme je Szene,
         NSApp.appearance, Notification an Terminals, ClaudeThemeWriter (~/.claude.json)
Beenden: SIGTERM -> NSApp.terminate -> applicationShouldTerminate (Marker, Close-Tracking, Ctrl+C an PTYs)
         -> .terminateNow -> applicationWillTerminate (Ducking zurück, Fenster-Flush)
```

## Schlüsseldateien

- `WhisperM8/WhisperM8App.swift` - Szenen, Hotkey-Anbindung, Single-Instance, `AppDelegate` (Aktivierungs-Policy, gesamter Start, Onboarding-Routing, Quit, Notification-Delegate), `MenuBarIcon`.
- `WhisperM8/Views/OnboardingView.swift` - Wizard mit sieben Schritten, profilabhängiger Folge, Gates `canProceed`/`canFinish` und Live-Testdiktat.
- `WhisperM8/Models/AppUsageProfile.swift` - Profil-Enum `dictationRaw`/`dictationEnrichment`/`full` mit Policy, Enrichment- und Agent-Chats-Schalter; Default `full`.
- `WhisperM8/Services/Shared/AppProfileActivator.swift` - wendet ein Profil zur Laufzeit an (Pref, Policy, Fenster-Gate) und schließt alle Agent-Fenster ohne Store-Verlust.
- `WhisperM8/Views/SettingsView.swift` - `SettingsPage`-Enum (13 Seiten, 5 Gruppen), Sidebar ohne `List`, Routen-Auflösung.
- `WhisperM8/Views/Settings/Models/SettingsRouteTarget.swift` - Alt-Routen-Aliasse (`api`, `codex`, `modes`, `behavior`, `claudeCode` ...) auf Seiten und Tabs.
- `WhisperM8/Views/Settings/Pages/*` - die Seiten; Hüllen-relevant sind `GeneralSettingsPage` (Profil, Login-Start, Theme, Update-Schalter), `PermissionsSettingsPage`, `AboutSettingsPage`, `CLISkillsSettingsPage` (Symlink-Status, Skills, Statusline). Dictation-, Konten-, GPT-, Hooks- und Agent-Chats-Seiten gehören inhaltlich zu ihren Subsystemen.
- `WhisperM8/Views/Settings/Kit/*` und `Models/PermissionSettingsModel.swift` - Bausteine und testbares Modell (injizierte Provider, cancelbares Polling).
- `WhisperM8/Views/MenuBarView.swift` - Statuszeile, letzte Transkription, Hotkey, Mikrofonwahl, Voice-Gate-/Callout-Einträge, Fenster-Einstiege, "Stop all", Quit.
- `WhisperM8/Services/Shared/AppUpdateChecker.swift` und `Views/AppUpdateViews.swift` - GitHub-Release-Check, Cask-Heuristik, Badge, Details mit `brew upgrade --cask whisperm8` bzw. Adopt-Befehl; nie Selbst-Update.
- `WhisperM8/Services/Shared/PermissionService.swift` - Mikrofon, Accessibility, Bildschirmaufnahme prüfen, anfragen, Systemeinstellungen-Panes öffnen.
- `WhisperM8/Services/Shared/CLISymlinkInstaller.swift` - idempotenter Symlink `~/.local/bin/whisperm8` auf das App-Binary; überschreibt nie eine reguläre Datei.
- `WhisperM8/Services/Shared/WindowRequestCenter.swift` - Fensteranfragen, Debug-Routen, Session-/Fenster-Fokus, Distributed Notification, Primärfenster-Gate, Restore der Sekundärfenster.
- `WhisperM8/Support/AppTheme.swift` und `ThemeManager.swift` - 22 dynamische Farb-Tokens; Erscheinungsbild-Override, KVO und Claude-Theme-Sync.
- `WhisperM8/Info.plist` und `WhisperM8.entitlements` - `LSUIElement=false`, Min-OS 14.0, Version 2.21.0, Mikrofon-/Bildschirm-/Spracherkennungs-Texte; nicht sandboxed, nur `audio-input` und `network.client`.

## Zustände und Persistenz

- UserDefaults (`AppPreferences`, Bundle `com.whisperm8.app`): `usageProfile` (Schreiber: Onboarding-Auswahl sofort, `AppProfileActivator`), `appearanceOverride` (ThemeManager), `updateCheckEnabled` (General-Seite per `@AppStorage`, Lesen über `AppPreferences`), `autoPasteEnabled` (Onboarding und Recording-Seite), Transkriptions-Provider/-Modell (`TranscriptionSettings`).
- Hotkey: `KeyboardShortcuts`-Name `toggleRecording` (Bibliothek, UserDefaults). Start bei Anmeldung: `LaunchAtLogin` (System, kein eigener Key).
- Kein "Onboarding erledigt"-Flag. Onboarding öffnet sich allein über fehlende Rechte (Mikrofon + Accessibility).
- API-Keys: Schlüsselbund über `KeychainManager`; Onboarding schreibt bei jeder Eingabeänderung (siehe LR-ONB-006/007).
- Dateisystem: `~/.local/bin/whisperm8` (Symlink, Schreiber: `CLISymlinkInstaller` beim Start und per Button), `~/.claude.json` (Theme, Schreiber: `ClaudeThemeWriter`).
- Flüchtig: `WindowRequestCenter.latestRequest`/`pendingSettingsRouteID`/`allowsAgentChatsPrimaryWindow`, `AppUpdateChecker.state`, Onboarding-`@State`.
- Fenster-/Tab-State liegt im `AgentWindowStore` (ausgeklammert); die Hülle ruft nur `suspendCloseTracking`/`flush`.

## Externe Abhängigkeiten

- TCC: Mikrofon (Pflicht), Bedienungshilfen (Pflicht, Auto-Paste und markierter Text), Bildschirmaufnahme (optional, erst bei Clip-Nutzung), Benachrichtigungen (beim Start angefragt), Spracherkennung (nur Voice Gate).
- Netz: `api.github.com/repos/RankM8/WhisperM8/releases/latest` (Update-Check, 15 s Timeout, Kill-Switch `updateCheckEnabled`).
- CLIs: `codex` (Statusprobe und Login im Onboarding-Schritt), `claude` (nur über Start-Prewarm `which`), `brew` (nur als angezeigter Befehl; der Cask-Receipt-Check liest `/opt/homebrew|/usr/local/Caskroom/whisperm8`).
- Bibliotheken: KeyboardShortcuts, LaunchAtLogin-Modern, SwiftUI-Szenen (`Window`, `WindowGroup`, `MenuBarExtra`).
- Distribution: nur Brew-Cask; App selbst signiert, nicht notarisiert (Quarantäne-Entfernung im Cask-`postflight`).

## Invarianten (jeder Umbau muss sie erhalten)

1. Die Aktivierungs-Policy wird vor dem ersten Fenster gesetzt (`applicationWillFinishLaunching`); Onboarding läuft immer als reguläre, fokussierbare App.
2. Onboarding öffnet permission-basiert, nicht über ein Done-Flag; Codex-Schritt nur für Profile mit Enrichment.
3. Das letzte geschlossene Fenster beendet die App nicht (Hotkey und Menüleiste bleiben); Reopen öffnet Agent Chats nur im Profil `full`.
4. Das Primärfenster ist die erste Szene und eine einzelne `Window`-Scene (kein Doppelfenster); in Menüleisten-Profilen blitzt es nicht auf (`allowsAgentChatsPrimaryWindow`); nur ein expliziter `.agentChats`-Request hebt das auf.
5. Ein Profilwechsel schließt Agent-Fenster programmatisch mit pausiertem Close-Tracking, damit "Zurück zu Full" alles wiederherstellt.
6. SIGTERM wird zum regulären AppKit-Quit (`SigpipeGuard.installNoOpHandler` statt `SIG_IGN`, sonst erben Chat-Shells das Signal); `applicationShouldTerminate` bleibt der früheste Hook und setzt Marker und Close-Tracking vor jedem Fenster-Teardown.
7. Das Ducking wird beim Beenden immer zurückgestellt (`applicationWillTerminate`).
8. Der Update-Check ist reine Anzeige: nur `remote > lokal` meldet, ein laufendes `.available` wird beim Re-Check nie auf `.checking` herabgestuft (NSPopover-Crash), `CopyableCommandBox` ändert beim Kopieren die Größe nicht.
9. Der Symlink überschreibt nie eine reguläre Datei; der Single-Instance-Check ruft die laufende Instanz nach vorn, statt zu duplizieren.
10. Schwere Starts laufen off-main (Login-Shell/`which`-Prewarm, Retention, Memory-/MCP-Sync, Symlink); der Settings-Sidebar-Stack bleibt ohne `List(selection:)`.
11. Settings-Alt-Routen bleiben aufgelöst (Debug-Kanal `whisperm8 debug open settings/<seite>`, ältere Deep-Links); `SettingsView` wertet die Route zweimal aus (`onAppear` plus Publisher).
12. Dark/Light: jede Szene bekommt `preferredColorScheme` aus `ThemeManager`, `NSApp.appearance` ist gesetzt, damit NSPanel und MenuBarExtra folgen.

## Top-Risiken (Verweis auf `findings.jsonl`)

- Datenverlust beim Beenden: `applicationShouldTerminate` antwortet sofort `.terminateNow`, laufende Aufnahme und Transkription gehen verloren - LR-ONB-001, LR-DIK-001 (P0).
- Fremde Konfiguration überschrieben: Theme-Sync beim Start ohne Profil-Gate und ohne Merge schreibt `~/.claude.json` bzw. `settings.json` - LR-SH-002, LR-AK-017, LR-SH-005, LR-SH-011 (alle P0); Statusline-Installer - LR-SH-004 (P0), LR-BR-001.
- Schlüsselbund: Onboarding speichert jeden getippten Zwischenstand; Migration kann die einzige Kopie löschen - LR-ONB-006, LR-ONB-007, LR-SH-003 (P0).
- Onboarding-Lücken für Laien: kein Codex- und kein Claude-Installationsschritt (LR-ONB-002, LR-ONB-003, LR-ONB-017, LR-DIK-015), Mikrofon-Sackgasse (LR-ONB-004), Setup kann nach Rechtevergabe unvollständig verschwinden (LR-ONB-005), Erfolgsmeldung trotz ungültigem Key (LR-ONB-013).
- Updates: Diktatprofile sehen keinen Hinweis (LR-ONB-009), Dialog endet beim Terminal-Befehl (LR-ONB-010).
- Settings: Labs und Expertenseiten stehen im Normalpfad (LR-ONB-012), Datenschutztext widerspricht Zusammenfassungen (LR-ONB-008, LR-AK-010), Vorlagen-Save wird nach Fehler gesperrt (LR-ONB-015), Proxy-Port-Absturz über die GPT-Seite (LR-GPT-003, P0), Konto entfernen ohne Prozessschutz (LR-KO-005).
- Start: Login-Shell-Abfrage kann den Hauptthread blockieren (LR-SH-007); Waisen-Schutz beim Start beendet extern gestartete Proxys (LR-GPT-006).
- Qualität: UI hart zweisprachig (LR-ONB-011), Modellwahl ohne Tastatur (LR-ONB-014), zu geringer Kontrast (LR-ONB-016), Handbuch verweist auf entfernte Seiten (LR-DOK-005), README bewirbt DMG/Source (LR-DOK-001).
