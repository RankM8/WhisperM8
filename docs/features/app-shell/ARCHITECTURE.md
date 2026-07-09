---
status: aktiv
updated: 2026-07-09
---

# App-Shell — Architektur

Die App-Shell verbindet persistierte App-Präferenzen und reale macOS-Zustände
mit der SwiftUI-Szenenstruktur. Ihre zentrale Grenze: Sie entscheidet, welche
Hülle sichtbar ist und wohin navigiert wird; die Fachlogik der geöffneten
Diktat-, Chat- und Settings-Flächen bleibt in deren Feature-Bereichen.

## Komponenten

```text
WhisperM8App / AppDelegate
├── Launch-Policy und permission-basiertes Onboarding-Gate
├── Window("Agent Chats")
│   └── AgentChatsPrimaryWindowRoot
├── WindowGroup("Agent Chat Window", UUID)
│   └── AgentChatsSecondaryWindowRoot
├── MenuBarExtra
│   ├── MenuBarView
│   └── AppWindowRequestHost
│       └── WindowRequestHandler
├── Window("WhisperM8")                 Settings
└── Window("WhisperM8 Setup")           Onboarding

AppUsageProfile ──> AppProfileActivator ──> AppPreferences / NSApp
                                      └──> WindowRequestCenter

AppUpdateChecker ──> SidebarUpdateBadge / AboutUpdateSection
MenuBarView ──> AppState ──> AgentTerminalRegistry ──> PTY-Controller
```

### Zuständigkeiten

| Komponente | Rolle |
|------------|-------|
| `AppUsageProfile` | Leitet aus einem Preset Codex-Enrichment, Agent-Chats-Verfügbarkeit und AppKit-Aktivierungs-Policy ab. |
| `AppProfileActivator` | Persistiert das aktive Profil, setzt die Policy und synchronisiert das Primärfenster-Gate; schließt bei Menüleisten-Profilen alle Chat-Fenster unter suspendiertem Close-Tracking. |
| `OnboardingView` | Erzeugt die profilabhängige Schrittfolge, hält Wizard-State und validiert `Next` sowie `Done`. |
| `PermissionService` | Stellt gemeinsame Abfragen und Requests für Mikrofon, Accessibility und Screen Recording bereit; der Wizard prüft Mikrofon und Accessibility zusätzlich direkt. |
| `MenuBarView` | Projiziert App-, Audio- und PTY-Registry-Zustand in Status und Quick Actions. |
| `AgentTerminalRegistry` | Hält die laufenden Vordergrund-PTY-Controller app-weit und terminiert sie gesammelt. |
| `AppUpdateChecker` | Kapselt GitHub-Abfrage, Versionsvergleich, Scheduler, Kill-Switch und Installationskanal-Heuristik. |
| `AppUpdateViews` | Projiziert `AppUpdateChecker.State` als Footer-Badge, Popover und About-Bereich. |
| `WindowRequestCenter` | Veröffentlicht abstrakte Fenster-Requests und bereits aufgelöste Session-Fokus-Wünsche. |
| `WindowRequestHandler` | Übersetzt Requests im SwiftUI-View-Kontext in `openWindow` und App-Aktivierung. |
| `WhisperM8App` / `AppDelegate` | Definiert Szenen, frühe Aktivierungs-Policy, Launch-Routing, Reopen-Verhalten und Single-Instance-Weiterleitung. |

## Datenfluss: Launch und Onboarding

```text
Prozessstart
  │
  ├─ AppDelegate liest Mikrofonstatus + AXIsProcessTrusted()
  │    ├─ eine Permission fehlt ──> NSApp .regular
  │    │                         └─> nach Launch Request .onboarding
  │    └─ beide vorhanden ──────> Profil aus AppPreferences
  │                              ├─ full ──> .regular
  │                              └─ sonst ─> .accessory
  │
  └─ SwiftUI erzeugt erste Agent-Chats-Window-Scene
       ├─ allowsAgentChatsPrimaryWindow == true ──> Store-Primärfenster
       └─ false ──────────────────────────────────> Fenster schließen
```

`needsOnboarding` wird bei jedem Start aus den beiden essenziellen
System-Permissions berechnet. Deshalb hat fehlende Accessibility Vorrang vor
einem gespeicherten Menüleisten-Profil und erzwingt die reguläre Dock-Policy.
Der Request läuft über den am `MenuBarExtra` montierten
`WindowRequestHandler`; dieser öffnet das Onboarding-Fenster und aktiviert die
App.

Im Wizard bleibt die gewählte Profiloption lokaler State, wird bei jeder Wahl
aber sofort in `AppPreferences` geschrieben. Die Schrittliste wird daraus neu
berechnet. Der Permissions-Step pollt Accessibility alle 0,5 Sekunden. Seine
lokalen Flags speisen sowohl das `Next`-Gate als auch das globale `Done`-Gate.

```text
Profilkarte wählen
  ├─ selectedProfile aktualisieren
  └─ AppPreferences.usageProfile sofort persistieren

Done
  └─ AppProfileActivator.apply
       ├─ Profil persistieren
       ├─ NSApp.setActivationPolicy
       └─ allowsAgentChatsPrimaryWindow setzen
            ├─ full ──> Request .agentChats
            └─ sonst ─> Primär- und Sekundärfenster schließen
```

Beim Schließen für ein Menüleisten-Profil suspendiert der Activator das
Close-Tracking des `AgentWindowStore`, fordert das Schließen aller Fenster an
und reaktiviert das Tracking nach 500 Millisekunden. Der persistierte
Fenster-/Tab-State wird dadurch nicht als Nutzer-Schließen interpretiert.

## Datenfluss: Menüleisten-Aktionen

`MenuBarView` liest den Diktatstatus aus `AppState`, die Audiogeräte aus
`AudioDeviceManager` und laufende Vordergrund-Chats aus der globalen
`AgentTerminalRegistry`. Fensteraktionen erzeugen nur einen
`WindowRequest`; das eigentliche `openWindow` bleibt im Handler mit Zugriff auf
die SwiftUI-Environment.

```text
"Stop N running chats"
  └─ AppState.stopAllForegroundSessions()
       └─ AgentTerminalRegistry.terminateAll()
            └─ je laufendem Controller
                 ├─ Ctrl+C
                 ├─ 80 ms
                 ├─ Ctrl+C
                 ├─ 180 ms
                 └─ terminal.terminate()
       └─ betroffene AgentSessionStore-Einträge auf .closed
```

Nur Controller mit `isRunning` werden gezählt und terminiert. Background-Chats
laufen über den Claude-Daemon und besitzen in diesem Pfad keinen registrierten
Vordergrund-PTY; sie sind daher nicht Teil der Operation.

## Datenfluss: Update-Prüfung

```text
App-Launch
  └─ scheduleAutomaticChecks()
       ├─ nach 10 s ─┐
       └─ alle 24 h ─┴─> Kill-Switch prüfen ──> checkNow()

checkNow()
  ├─ vorhandenen activeCheck abwarten
  └─ performCheck()
       ├─ lokale Version lesen und parsen
       ├─ GitHub /releases/latest laden
       ├─ tag_name als SemanticVersion parsen
       └─ remote > lokal?
            ├─ ja  ─> available(UpdateInfo + Brew-Heuristik)
            └─ nein ─> upToDate
```

Fehlende lokale Version, Netzwerkfehler sowie unerwartete oder nicht parsebare
Release-Daten führen zu `failed`. Jeder abgeschlossene Prüfpfad setzt
`lastCheckedAt`. Die Brew-Heuristik prüft lediglich, ob einer der bekannten
Caskroom-Pfade existiert; sie startet keinen Subprozess. Die UI zeigt immer
einen manuellen Homebrew-Pfad und führt keinen Bundle-Tausch aus.

`SidebarUpdateBadge` existiert nur in `available`. Beim Recheck bleibt dieser
State bis zum neuen Resultat bestehen. Innerhalb des Popovers darf der
Copy-Status weder animiert werden noch das feste Icon-Frame verändern. Beide
Regeln vermeiden einen animierten `NSPopover`-Resize während der Interaktion.

## Datenfluss: Fenster- und Fokus-Routing

Ein normaler `WindowRequest` enthält ein logisches Ziel. Settings und
Output & History teilen sich die Window-ID `settings`; der zweite Request
liefert zusätzlich die Settings-Sektions-ID `outputOverview`. Agent Chats und
Onboarding haben eigene IDs. Ein expliziter Agent-Chats-Request setzt vor dem
Publish das Primärfenster-Gate auf `true`.

Für einen Notification-Klick löst `requestSessionFocus` zuerst das Zielfenster
auf: bestehendes Fenster des Tabs oder Primärfenster. Danach öffnet und
selektiert es den Tab im `AgentWindowStore`, expandiert die nötige Projekt- und
gegebenenfalls Parent-Subagent-Gruppe und veröffentlicht erst dann den
`AgentSessionFocusRequest`. Der Handler muss dadurch nur noch das bereits
bestimmte Primärfenster oder die UUID-gebundene WindowGroup öffnen.

Die erste Szene ist absichtlich eine einzelne `Window` statt einer
`WindowGroup`: SwiftUI darf das Agent-Chats-Primärfenster beim Launch automatisch
erzeugen, kann es aber nicht duplizieren. Nur abgelöste Tabs verwenden die
wertgebundene `WindowGroup`. Beim Restore öffnet der Handler ausschließlich
persistierte Sekundärfenster und nur im `full`-Profil. Ein Sekundärfenster ohne
gültige UUID oder Store-Eintrag schließt sich selbst.

Beim Start einer zweiten App-Instanz aktiviert diese die bestehende Instanz,
sendet über `DistributedNotificationCenter` den historisch benannten
Open-Settings-Kanal, der heute Agent Chats anfordert, und beendet sich. Beim
Dock-Reopen fordert der App-Delegate nur im `full`-Profil und nur ohne sichtbare
Fenster erneut das Primärfenster an.

## Invarianten und Gotchas

- Das reale Permission-Paar Mikrofon plus Accessibility ist die
  Onboarding-Wahrheit; ein Abschluss-Flag entscheidet nicht über den Launch.
- Onboarding läuft immer mit `.regular`, selbst wenn bereits ein
  Menüleisten-Profil gespeichert ist.
- Fehlende Accessibility blockiert `Next` im Permissions-Step und `Done` im
  letzten Schritt.
- Die Profilwahl wird sofort persistiert, aber Policy und Abschlussrouting
  ändern sich im Wizard erst bei `Done`.
- `full` ist der migrationssichere Profil-Default.
- Das Agent-Chats-Primärfenster ist eine einzelne erste `Window`-Scene;
  Sekundärfenster gehören ausschließlich zur UUID-`WindowGroup`.
- Explizite Agent-Chats-Requests dürfen das Primärfenster auch aus einem
  Menüleisten-Profil freigeben; der automatische Restore darf das nicht.
- Programmatisches Schließen aller Chat-Fenster muss Close-Tracking
  suspendieren, sonst ginge der wiederherstellbare Store-State verloren.
- `Stop N running chats` betrifft ausschließlich laufende Vordergrund-PTYs und
  setzt die Session-Projektion erst nach der Controller-Terminierung auf
  `.closed`.
- Der Update-Kill-Switch deaktiviert keine manuellen Checks.
- Nur `remote > lokal` ist ein Update; lokale neuere Builds werden nicht zum
  Downgrade aufgefordert.
- Ein sichtbarer `available`-State und die Geometrie des Copy-Feedbacks müssen
  während der Popover-Interaktion stabil bleiben.
- Das Schließen des letzten Fensters beendet die App nicht; Menüleisten-Hotkey
  und Diktat bleiben aktiv.

## Schlüsseldateien

| Pfad | Rolle |
|------|-------|
| `WhisperM8/Models/AppUsageProfile.swift` | Profil-Presets und abgeleitete App-Fähigkeiten. |
| `WhisperM8/Services/Shared/AppProfileActivator.swift` | Laufzeitanwendung des Profils und vollständiges Schließen der Chat-Fenster. |
| `WhisperM8/Views/OnboardingView.swift` | Profilabhängiger Wizard, Permission-Polling und Abschlussrouting. |
| `WhisperM8/Services/Shared/PermissionService.swift` | Gemeinsamer Adapter für macOS-Berechtigungen und Privacy-Panes. |
| `WhisperM8/Views/MenuBarView.swift` | Menüleistenstatus, Audiogeräte und globale Quick Actions. |
| `WhisperM8/Models/AppState.swift` | Fassade für die globale Vordergrund-Session-Terminierung. |
| `WhisperM8/Views/AgentTerminalView.swift` | Globale PTY-Registry und graceful Ctrl+C-bis-Kill-Ablauf. |
| `WhisperM8/Services/Shared/AppUpdateChecker.swift` | Release-State-Machine, Scheduler, Kill-Switch und Brew-Erkennung. |
| `WhisperM8/Services/Shared/SemanticVersion.swift` | Parsing und numerischer Vergleich lokaler und veröffentlichter Versionen. |
| `WhisperM8/Views/AppUpdateViews.swift` | Update-Badge, Popover-Inhalt, Copy-Feedback und About-Projektion. |
| `WhisperM8/Services/Shared/WindowRequestCenter.swift` | Logische Requests, Session-Fokus-Auflösung und `openWindow`-Brücke. |
| `WhisperM8/WhisperM8App.swift` | Szenendeklaration, App-Delegate, Launch-Gates und Lifecycle-Routing. |
| `WhisperM8/Support/AppPreferences.swift` | Persistenz von Nutzungsprofil und Update-Kill-Switch. |

## Test-Cluster

| Pfad | Abdeckung |
|------|-----------|
| `Tests/WhisperM8Tests/PreferencesTests.swift` | Profil-Default, Persistenz, Enrichment-/Agent-Chats-Flags, Aktivierungs-Policies sowie Default und Persistenz des Update-Kill-Switches. |
| `Tests/WhisperM8Tests/WindowAndOverlayTests.swift` | Fenster-Ziel-IDs, Settings-Deep-Link und Freigabe des Primärfensters durch explizite Agent-Chats-Requests. |
| `Tests/WhisperM8Tests/AppUpdateCheckerTests.swift` | Semantic-Version-Parsing, Versionsvergleich, Brew-Flag, Release-URL-Fallback und Fehlerzustände. |
| `Tests/WhisperM8Tests/PermissionSettingsModelTests.swift` | Injizierte Permission-Zustände und Accessibility-Aktionen der Settings-Projektion. |
| `Tests/WhisperM8Tests/AgentWindowStoreTests.swift` | Primärfenster-Schutz, Sekundärfenster, Close-Tracking-Suspension sowie Persistenz- und Restore-Grundlage. |

SwiftUI-Szenenerzeugung, `NSApplication.ActivationPolicy`, echte TCC-Dialoge,
`MenuBarExtra` und das `NSPopover`-Resize-Verhalten sind macOS-UI-Verhalten und
werden manuell geprüft. Für die App-Shell existieren keine erfundenen UI-Tests.

## Keywords

App-Shell-Architektur, `AppUsageProfile`, `AppProfileActivator`,
`AppPreferences`, `OnboardingView`, Permission-Gate, Accessibility,
`AXIsProcessTrusted`, Dock-Policy, Menüleisten-Policy, `MenuBarView`,
`AgentTerminalRegistry`, graceful termination, Vordergrund-PTY,
`AppUpdateChecker.State`, Release-Scheduler, Brew-Receipt, Update-Kill-Switch,
Popover-Invariante, `WindowRequestCenter`, `WindowRequestHandler`,
`AgentSessionFocusRequest`, `WhisperM8App`, SwiftUI Scene, Primärfenster,
Sekundärfenster, Fenster-Restore, Single Instance.
