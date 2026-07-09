---
status: aktiv
updated: 2026-07-09
---

# App-Shell

Die App-Shell umfasst den Start- und Fensterrahmen von WhisperM8: Nutzungsprofil,
Onboarding, Menüleisten-Zugriff, Update-Hinweise und das Routing zwischen den
SwiftUI-Szenen. Fachlogik für Diktat, Agent Chats, CLI und den Inhalt einzelner
Settings-Seiten gehört nicht in diesen Bereich.

## App-Profile

`AppUsageProfile` bietet drei Presets:

| Profil | Codex-Enrichment | Agent Chats | Aktivierungs-Policy |
|--------|------------------|-------------|---------------------|
| `dictationRaw` | nein | nein | `.accessory` — nur Menüleiste, kein Dock und kein Cmd-Tab |
| `dictationEnrichment` | ja | nein | `.accessory` — nur Menüleiste |
| `full` | ja | ja | `.regular` — reguläre Dock-App |

`full` ist zugleich der Default für Installationen ohne gespeichertes Profil,
damit Bestandsnutzer das bisherige Vollverhalten behalten. Im Onboarding wird
eine Profilwahl sofort in `AppPreferences` persistiert. Das schützt die Wahl
beim Abbruch des Wizards, schaltet aber noch nicht die laufende App-Hülle um.
Erst `Done` ruft `AppProfileActivator.apply` auf: Der Activator persistiert das
Profil erneut, setzt die AppKit-Aktivierungs-Policy und aktualisiert das Gate für
das Agent-Chats-Primärfenster.

Das Abschlussrouting folgt anschließend dem Profil. `full` fordert Agent Chats
an. Die beiden Menüleisten-Profile schließen Primär- und Sekundärfenster der
Agent Chats, erhalten deren Store-Zustand aber für einen späteren Rückwechsel.
Der Profilwechsel in den General Settings verwendet denselben Activator und
dasselbe Fensterverhalten unmittelbar.

## Onboarding-Wizard

Der Wizard berechnet seine Schritte aus dem aktuell gewählten Profil:

1. Welcome
2. Profilwahl
3. Mikrofon- und Accessibility-Berechtigung
4. Diktat-Hotkey
5. Groq- oder OpenAI-API-Key
6. optionaler Codex-Verbindungsschritt für `dictationEnrichment` und `full`
7. Test und Abschlussrouting über `Done`

Der Codex-Schritt ist überspringbar. Fehlt Codex später, bleibt Raw-Diktat als
Fallback verfügbar. Der API-Key-Schritt akzeptiert einen neu eingegebenen Key
oder einen bereits im Keychain vorhandenen Key. Der Test selbst ist keine
Abschlussbedingung; `Done` verlangt aber Hotkey, Mikrofon, Accessibility und
einen verfügbaren Transkriptions-Key.

### P1-Invariante: Accessibility erzwingt Onboarding

Der Launch entscheidet nicht über ein `onboardingCompleted`-Flag, sondern liest
bei jedem Start den realen Mikrofon- und Accessibility-Status. Fehlt
Accessibility — ebenso wie bei fehlendem Mikrofonzugriff — gilt
`needsOnboarding`: Noch vor dem ersten Fenster setzt der App-Delegate die
reguläre Dock-Policy, und nach dem Start fordert er das Onboarding-Fenster an.
Damit öffnet fehlende Accessibility den Wizard bei jedem Start erneut, auch bei
einem gespeicherten Menüleisten-Profil.

Im Wizard wird Accessibility alle 0,5 Sekunden über `AXIsProcessTrusted()` neu
geprüft. Solange sie fehlt, ist `Next` im Permissions-Schritt deaktiviert und
auch `Done` bleibt durch die globale Abschlussprüfung gesperrt. Der Wizard kann
daher weder regulär übersprungen noch abgeschlossen werden, bevor macOS den
Zugriff bestätigt.

## Menüleiste

`MenuBarView` ist der immer erreichbare Schnellzugriff. Es zeigt den Zustand
Ready, Recording oder Transcribing, optional die letzte Transkription und den
letzten Fehler sowie den konfigurierten Hotkey. Der Nutzer kann das Eingabegerät
wählen und folgende Quick Actions auslösen:

- WhisperM8 Settings öffnen
- direkt zu Output & History routen
- Agent Chats öffnen
- alle laufenden Vordergrund-Chats stoppen
- die App beenden

Der Stop-Eintrag erscheint nur, wenn die globale `AgentTerminalRegistry`
mindestens einen laufenden Controller enthält, und lautet singular oder plural
`Stop N running chat(s)`. `AppState.stopAllForegroundSessions()` beendet jeden
registrierten Vordergrund-PTY kontrolliert: pro Controller zweimal Ctrl+C mit
kurzen Wartefenstern, danach wird der Subprozess terminiert. Die zugehörigen
Sessions wechseln auf `.closed` und bleiben relaunchbar. Claude-Background-Jobs
bleiben unberührt, weil sie nicht als Vordergrund-PTY in dieser Registry leben.

## Update-Flow

`AppUpdateChecker` vergleicht die installierte semantische Version mit dem
neuesten GitHub Release. Seine veröffentlichte State Machine lautet:

`unknown → checking → upToDate | available | failed`

Nur eine höhere Remote-Version erzeugt `available`; gleiche, ältere und lokale
Dev-Versionen führen nicht zu einem Downgrade-Angebot. Parallel gestartete
Checks werden auf denselben aktiven Task zusammengeführt. Ein erneuter Check im
Zustand `available` behält diesen Zustand bis zum Ergebnis bei, damit Badge und
offenes Popover nicht zwischenzeitlich abgebaut werden.

Der automatische Scheduler prüft zehn Sekunden nach dem App-Start und danach
alle 24 Stunden; der Timer toleriert zehn Minuten Abweichung. Der standardmäßig
aktive Kill-Switch `updateCheckEnabled` lässt sich in General Settings oder per
`defaults write com.whisperm8.app updateCheckEnabled -bool NO` abschalten. Er
betrifft nur automatische Checks; der manuelle Check unter About bleibt
verfügbar.

Der Checker tauscht die App nie selbst aus. Für erkannte Cask-Installationen
zeigt die UI `brew upgrade --cask whisperm8`. Die Erkennung prüft die
Caskroom-Pfade unter `/opt/homebrew` und `/usr/local`, ohne einen Brew-Prozess zu
starten. Für DMG-/Source-Installationen ergänzt die UI den einmaligen Adopt-Pfad
`brew install --cask rankm8/tap/whisperm8 --force`. Release-Notes führen zur
vom GitHub-Release gelieferten URL oder zur Releases-Seite als Fallback.

Das Update-Badge lebt im Agent-Chats-Sidebar-Footer; derselbe Detailinhalt wird
in Settings → About verwendet. Zwei `NSPopover`-Invarianten verhindern einen
bekannten Resize-Crash: Ein Recheck darf ein sichtbares `available` nicht kurz
zu `checking` degradieren, und das Copy-Feedback der Befehlsbox behält eine
feste Icon-Größe ohne animierten Größenwechsel.

## Fenster-Routing

`WindowRequestCenter` entkoppelt Aufrufer von SwiftUIs `openWindow`-Environment.
Requests adressieren Settings, Output & History, Onboarding oder das
Agent-Chats-Primärfenster. `WindowRequestHandler` sitzt am `MenuBarExtra`, öffnet
oder fokussiert das Ziel und aktiviert anschließend die App.

`WhisperM8App` deklariert fünf Scene-Einträge aus drei Szenentypen:

- eine einzelne, als erste Szene deklarierte `Window` für das
  Agent-Chats-Primärfenster;
- eine wertgebundene `WindowGroup` für abgelöste Agent-Chat-Tabs;
- ein einzelnes Settings-Fenster;
- ein einzelnes Onboarding-Fenster;
- zusätzlich das `MenuBarExtra` als dauerhaften Einstieg.

In Menüleisten-Profilen verwirft das Gate das automatisch erzeugte
Agent-Chats-Primärfenster und stellt keine Sekundärfenster wieder her. Ein
expliziter Agent-Chats-Request gibt das Primärfenster dennoch frei. Sekundäre
Fenster werden nur aufgebaut, wenn ihre UUID weiterhin im `AgentWindowStore`
existiert; verwaiste Restore-Fenster schließen sich selbst. Ein Klick auf eine
Agent-Benachrichtigung wählt Tab und Fenster vorab im Store aus und routet dann
zum bereits aufgelösten Primär- oder Sekundärfenster.

## Schlüsseldateien

- `WhisperM8/Models/AppUsageProfile.swift` definiert Profile, Fähigkeiten und Aktivierungs-Policy.
- `WhisperM8/Services/Shared/AppProfileActivator.swift` wendet Profile an und schließt bei Bedarf alle Agent-Chat-Fenster.
- `WhisperM8/Views/OnboardingView.swift` implementiert Schrittfolge, Validierung, Persistenz und Abschlussrouting des Wizards.
- `WhisperM8/Services/Shared/PermissionService.swift` bündelt Berechtigungsstatus, Requests und Sprünge in die macOS-Datenschutzeinstellungen.
- `WhisperM8/Views/MenuBarView.swift` rendert Status, Gerätewahl und Quick Actions der Menüleiste.
- `WhisperM8/Models/AppState.swift` koordiniert das globale Stoppen der Vordergrund-Chats.
- `WhisperM8/Views/AgentTerminalView.swift` enthält Registry und Ctrl+C-bis-Kill-Terminierung der PTYs.
- `WhisperM8/Services/Shared/AppUpdateChecker.swift` implementiert Release-Abfrage, State Machine, Scheduler und Brew-Erkennung.
- `WhisperM8/Views/AppUpdateViews.swift` rendert Update-Badge, Popover, Befehlsboxen und About-Status.
- `WhisperM8/Services/Shared/WindowRequestCenter.swift` vermittelt Fenster- und Session-Fokus-Requests.
- `WhisperM8/WhisperM8App.swift` deklariert Szenen, Launch-Policy, Onboarding-Gate und App-Lifecycle-Routing.

## Keywords

App-Shell, App-Hülle, `AppUsageProfile`, `AppProfileActivator`, Dock-App,
Menüleisten-App, `NSApplication.ActivationPolicy`, Onboarding,
Accessibility, Bedienungshilfen, Mikrofonberechtigung, Profilwahl, Hotkey,
API-Key, Codex-Verbindung, `MenuBarView`, Quick Actions,
`Stop N running chats`, Vordergrund-PTY, Ctrl+C, Background-Jobs,
`AppUpdateChecker`, GitHub Releases, Update-State-Machine, Update-Kill-Switch,
Homebrew Cask, Brew Adopt, `NSPopover`, `WindowRequestCenter`,
`WindowRequestHandler`, `WhisperM8App`, `Window`, `WindowGroup`,
`MenuBarExtra`, Fenster-Routing, Session-Fokus, Primärfenster,
Sekundärfenster.
