---
description: Referenz der Settings-Seite „Claude Code" mit Hook-Bridge, Notifications, Fertig-Ton und Diagnostik.
description_long: |
  Vollständige Referenz der Settings-Seite „Claude Code" im WhisperM8-Settings-Fenster.
  Die Seite dokumentiert Hook-Status, Benachrichtigungen, Ton-Auswahl, externe Hook-Konflikte und die erzeugte Claude-Code-Settings-Vorschau.
  Persistenz, Laufzeitwirkung und UX-Befunde sind gegen den aktuellen Working Tree belegt.
updated: 2026-07-06 10:04
status: ✅ Validiert (Opus-Gegenprüfung 2026-07-06, 3 Zeilenverweise + 1 Ergänzung korrigiert)
---

# Settings: Claude Code

> **Sidebar-Gruppe:** Agents · **View:** `WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift` · **Enum-Case:** `ControlCenterSection.claudeCode` (`WhisperM8/Views/SettingsView.swift`)
>
> **Primäre Quell-Dateien:** `ClaudeCodeSettingsView.swift`

## 1. Zweck & Überblick

Die Settings-Seite „Claude Code" bündelt die Claude-spezifische Laufzeit-Infrastruktur der Agent Chats: Session-Hooks, Live-Status-Erkennung, Rückfrage-/Fertig-Benachrichtigungen, Fertig-Ton und Hook-Diagnostik (`WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:4`). Die Seite ist im Settings-Fenster als `ControlCenterSection.claudeCode` mit dem Label „Claude Code" definiert und gehört zusammen mit „Agent Chats" zur Sidebar-Gruppe „Agents" (`WhisperM8/Views/SettingsView.swift:11`, `WhisperM8/Views/SettingsView.swift:12`, `WhisperM8/Views/SettingsView.swift:102`). Der wichtigste operative Zweck ist der Master-Schalter für die Claude-Code-Hook-Bridge: Ist er aktiv, startet WhisperM8 Claude-Chats mit einer temporären `--settings`-Datei; ist er deaktiviert, fallen die Statusdaten auf den gröberen Transcript-Watcher zurück (`WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:48`, `WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:50`, `WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:98`). Die Seite betrifft normale interaktive Claude-Chats und Background-Agent-Spawns; Claude Agents View und Codex bekommen diese Hook-Bridge nicht (`WhisperM8/Views/AgentSessionDetailView.swift:226`, `WhisperM8/Views/AgentSessionDetailView.swift:234`, `WhisperM8/Views/AgentChatsView+BackgroundAgents.swift:68`).

## 2. UI-Aufbau

Die View ist ein gruppiertes SwiftUI-`Form` mit den Abschnitten „Live-Status", „Benachrichtigungen", „Ton", optional „Eigene Claude-Hooks erkannt" und einer abschließenden Erklärung (`WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:23`, `WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:25`, `WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:33`). Beim Anzeigen ruft die View `refresh()` auf; dabei werden System-Sounds geladen, globale Claude-Hooks read-only inspiziert, die JSON-Vorschau erzeugt und der macOS-Notification-Status abgefragt (`WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:34`, `WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:230`, `WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:241`).

Von oben nach unten:

- „Live-Status" zeigt abhängig vom Hook-Schalter entweder „Session-Hooks aktiv" oder „Session-Hooks deaktiviert", darunter den Toggle „Session-Hooks verwenden" und eine Legende für `working`, `awaitingInput` und `idle` (`WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:39`, `WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:46`, `WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:56`, `WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:61`).
- „Benachrichtigungen" zeigt bei verweigerter macOS-Berechtigung einen Warnhinweis mit Button zu den Systemeinstellungen, danach zwei Notification-Toggles und den Test-Notification-Button (`WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:82`, `WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:84`, `WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:97`, `WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:101`). Eine Caption erklärt, dass Banner auch im Vordergrund erscheinen und ein Klick den betreffenden Chat öffnet (`WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:114`).
- „Ton" enthält den Fertig-Ton-Toggle, einen Sound-Picker, einen Play-Button und den Hinweis, dass Rückfragen bewusst lautlos bleiben (`WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:122`, `WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:124`, `WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:127`, `WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:148`).
- „Eigene Claude-Hooks erkannt" erscheint nur, wenn `externalHookFindings` nicht leer ist; die Findings kommen aus `ExternalClaudeHooksInspector.inspectUserSettings()` (`WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:28`, `WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:166`, `WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:232`).
- „Wie funktioniert das?" ist ein `DisclosureGroup`, das die `claude --settings <datei>`-Erklärung und eine textselektierbare JSON-Vorschau der generierten Hook-Settings enthält (`WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:205`, `WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:207`, `WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:209`, `WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:212`).

## 3. Optionen im Detail

### Live-Status-Anzeige und Statuslegende

| Aspekt | Wert |
|---|---|
| Control | Read-only Statuszeile mit Symbol sowie drei `AgentStatusIndicator`-Legendenzeilen (`working`, `awaitingInput`, `idle`) (`WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:41`, `WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:62`, `WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:70`). |
| Default | Die Anzeige folgt initial dem Default von `hooksEnabled = true`, also „Session-Hooks aktiv" (`WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:10`, `WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:46`). |
| Persistenz | Keine eigene Persistenz; die Anzeige liest indirekt den UserDefaults-Key `claudeHooksEnabled` über `@AppStorage(PreferenceKeys.claudeHooksEnabled)` (`WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:10`, `WhisperM8/Support/AppPreferences.swift:396`). |
| Gelesen von | `ClaudeCodeSettingsView.liveStatusSection` (`WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:39`), `AgentStatusIndicator` über `legendRow(status:text:)` (`WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:70`). |
| Wirkung | Die Statuszeile erklärt den aktiven oder deaktivierten Hook-Modus; die Legende macht sichtbar, welche Sidebar-Indikatoren „arbeitet", „wartet auf dich" und „bereit" bedeuten (`WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:48`, `WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:62`, `WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:64`). |
| Abhängigkeiten | Hängt vom Toggle „Session-Hooks verwenden" ab, weil `hooksEnabled` sowohl Symbol als auch Beschreibung umschaltet (`WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:42`, `WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:48`). |

### Session-Hooks verwenden

| Aspekt | Wert |
|---|---|
| Control | Toggle „Session-Hooks verwenden" (`WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:56`). |
| Default | `true` in `@AppStorage` und `AppPreferences.boolWithDefault(true, ...)` (`WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:10`, `WhisperM8/Support/AppPreferences.swift:285`, `WhisperM8/Support/AppPreferences.swift:327`). |
| Persistenz | UserDefaults-Key `claudeHooksEnabled`, definiert als `PreferenceKeys.claudeHooksEnabled = "claudeHooksEnabled"` (`WhisperM8/Support/AppPreferences.swift:396`). |
| Gelesen von | Settings-View via `@AppStorage(PreferenceKeys.claudeHooksEnabled)` (`WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:10`), Laufzeit via `AppPreferences.shared.isClaudeHooksEnabled` im `AgentStatusPreferences.current()`-Snapshot (`WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:12`, `WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:15`). |
| Wirkung | Bei aktivem Wert erzeugt `AgentSessionStatusCoordinator.prepareLaunchArguments` `--settings <path>` für interaktive Claude-Launches; bei deaktiviertem Wert gibt die Methode eine leere Argumentliste zurück (`WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:98`, `WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:102`). Für Background-Agent-Spawns liefert `prepareBackgroundSettingsFile` entsprechend einen Settings-Pfad oder `nil` (`WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:106`, `WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:107`). |
| Abhängigkeiten | Gilt laut UI-Hinweis nur für neu gestartete Chats; laufende Sessions behalten ihre aktuelle Konfiguration bis zum Chat-Neustart (`WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:57`). Die Hook-Bridge wird nur für normale interaktive Claude-Sessions vor dem Command-Build injiziert, nicht für Codex, Claude Agents View oder den späteren `claude attach` eines Background-Chats (`WhisperM8/Views/AgentSessionDetailView.swift:222`, `WhisperM8/Views/AgentSessionDetailView.swift:234`, `WhisperM8/Views/AgentSessionDetailView.swift:237`). |

### macOS-Mitteilungen deaktiviert: Systemeinstellungen öffnen

| Aspekt | Wert |
|---|---|
| Control | Bedingte Warnzeile mit Button „Systemeinstellungen öffnen" (`WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:84`, `WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:91`). |
| Default | Nicht sichtbar, solange `notificationAuthStatus` nicht `.denied` ist; der State startet als `nil` und wird beim Refresh aus `UNUserNotificationCenter.current().notificationSettings()` gesetzt (`WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:16`, `WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:84`, `WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:241`). |
| Persistenz | Keine App-Persistenz; der Status liegt bei macOS `UNUserNotificationCenter`, die View speichert ihn nur temporär in `@State notificationAuthStatus` (`WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:16`, `WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:241`). |
| Gelesen von | `ClaudeCodeSettingsView.notificationSection` (`WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:82`), `refresh()` (`WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:230`). |
| Wirkung | Der Button öffnet die URL `x-apple.systempreferences:com.apple.preference.notifications` über `NSWorkspace.shared.open` (`WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:260`, `WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:262`). |
| Abhängigkeiten | Betrifft die Sichtbarkeit und Zustellbarkeit der beiden Notification-Toggles; die App fordert Notification-Rechte mit `.alert` und `.sound` an (`WhisperM8/WhisperM8App.swift:327`, `WhisperM8/WhisperM8App.swift:328`). |

### Wenn ein Agent fertig ist

| Aspekt | Wert |
|---|---|
| Control | Toggle „Wenn ein Agent fertig ist" (`WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:97`). |
| Default | `true` in `@AppStorage` und `AppPreferences.boolWithDefault(true, ...)` (`WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:11`, `WhisperM8/Support/AppPreferences.swift:292`, `WhisperM8/Support/AppPreferences.swift:327`). |
| Persistenz | UserDefaults-Key `agentStopNotificationEnabled`, definiert als `PreferenceKeys.agentStopNotificationEnabled = "agentStopNotificationEnabled"` (`WhisperM8/Support/AppPreferences.swift:397`). |
| Gelesen von | Settings-View via `@AppStorage(PreferenceKeys.agentStopNotificationEnabled)` (`WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:11`), Laufzeit via `AgentStatusPreferences.current()` (`WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:16`). |
| Wirkung | Bei `turnCompleted` postet der Koordinator eine User-Notification nur, wenn `stopNotificationEnabled` aktiv ist (`WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:266`, `WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:270`). Dieselbe Präferenz steuert auch Notifications für abgeschlossene oder fehlgeschlagene Subagent-Jobs (`WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:280`, `WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:285`). |
| Abhängigkeiten | Die Notification selbst wird über `UNAgentUserNotificationPoster` ohne `content.sound` gesendet, weil der Fertig-Ton separat über `NSSound` läuft (`WhisperM8/Services/AgentChats/AgentSessionNotifier.swift:42`, `WhisperM8/Services/AgentChats/AgentSessionNotifier.swift:49`, `WhisperM8/Services/AgentChats/AgentSessionNotifier.swift:63`). |

### Bei Rückfragen (Berechtigung, Frage, Plan-Freigabe)

| Aspekt | Wert |
|---|---|
| Control | Toggle „Bei Rückfragen (Berechtigung, Frage, Plan-Freigabe)" (`WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:98`). |
| Default | `true` in `@AppStorage` und `AppPreferences.boolWithDefault(true, ...)` (`WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:12`, `WhisperM8/Support/AppPreferences.swift:299`, `WhisperM8/Support/AppPreferences.swift:327`). |
| Persistenz | UserDefaults-Key `agentAwaitingNotificationEnabled`, definiert als `PreferenceKeys.agentAwaitingNotificationEnabled = "agentAwaitingNotificationEnabled"` (`WhisperM8/Support/AppPreferences.swift:398`). |
| Gelesen von | Settings-View via `@AppStorage(PreferenceKeys.agentAwaitingNotificationEnabled)` (`WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:12`), Laufzeit via `AgentStatusPreferences.current()` (`WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:17`). |
| Wirkung | Bei einem `inputRequested`-Effekt postet der Koordinator nur dann eine Rückfrage-Notification, wenn `awaitingNotificationEnabled` aktiv ist (`WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:273`, `WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:274`). Rückfragegründe sind `permission`, `question` und `planApproval`, die zu Notification-Texten für Berechtigung, Frage und Plan-Freigabe gemappt werden (`WhisperM8/Services/AgentChats/AgentSessionStateMachine.swift:49`, `WhisperM8/Services/AgentChats/AgentSessionStateMachine.swift:58`). |
| Abhängigkeiten | Präzise Rückfrage-Erkennung hängt an Claude-Hook-Events: `PermissionRequest` und `PreToolUse` mit `AskUserQuestion` oder `ExitPlanMode` erzeugen `awaitingInput`; ohne Hook-Bridge bleibt laut UI nur gröbere Transcript-Erkennung ohne Rückfrage-Erkennung und ohne Notifications (`WhisperM8/Services/AgentChats/AgentSessionStateMachine.swift:198`, `WhisperM8/Services/AgentChats/AgentSessionStateMachine.swift:210`, `WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:50`). |

### Test-Notification senden

| Aspekt | Wert |
|---|---|
| Control | Button mit Label „Test-Notification senden" und Symbol `bell.badge`; daneben erscheint bei Erfolg oder Fehler ein temporärer Feedback-Text (`WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:100`, `WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:104`, `WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:106`). |
| Default | Kein gespeicherter Zustand; `feedback` startet als `nil` (`WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:21`, `WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:106`). |
| Persistenz | Keine Persistenz; der Button erzeugt eine einmalige `UNNotificationRequest` mit zufälligem Identifier (`WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:252`). |
| Gelesen von | `sendTestNotification()` in `ClaudeCodeSettingsView` (`WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:247`). |
| Wirkung | Sendet eine Test-Benachrichtigung mit Titel „Statusmaschine-Chat", Untertitel „WhisperM8 · Test" und Body „Agent ist fertig und wartet auf dich."; der Klick routet bewusst nicht zu einer Session, weil kein `localSessionID` gesetzt wird (`WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:246`, `WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:249`, `WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:253`). |
| Abhängigkeiten | Funktioniert praktisch nur, wenn macOS Notifications für WhisperM8 erlaubt; die View zeigt bei `.denied` denselben Abschnitt mit Warnhinweis an (`WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:84`, `WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:253`). |

### Ton, wenn ein Agent fertig ist

| Aspekt | Wert |
|---|---|
| Control | Toggle „Ton, wenn ein Agent fertig ist" (`WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:124`). |
| Default | `true` in `@AppStorage` und `AppPreferences.boolWithDefault(true, ...)` (`WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:13`, `WhisperM8/Support/AppPreferences.swift:269`, `WhisperM8/Support/AppPreferences.swift:327`). |
| Persistenz | UserDefaults-Key `agentStopSoundEnabled`, definiert als `PreferenceKeys.agentStopSoundEnabled = "agentStopSoundEnabled"` (`WhisperM8/Support/AppPreferences.swift:394`). |
| Gelesen von | Settings-View via `@AppStorage(PreferenceKeys.agentStopSoundEnabled)` (`WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:13`), Laufzeit via `AgentStatusPreferences.current()` (`WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:18`). |
| Wirkung | Bei `turnCompleted` spielt der Koordinator den konfigurierten Sound nur, wenn `stopSoundEnabled` aktiv ist (`WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:266`, `WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:268`). |
| Abhängigkeiten | Der Sound-Picker und der Play-Button werden deaktiviert, wenn dieser Toggle aus ist (`WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:133`, `WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:144`). Rückfragen bleiben unabhängig davon lautlos (`WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:148`, `WhisperM8/Services/AgentChats/AgentSessionNotifier.swift:42`). |

### Sound

| Aspekt | Wert |
|---|---|
| Control | Picker „Sound" mit Auswahl aus `soundChoices`; der Picker ist auf maximal 260 Punkte Breite begrenzt (`WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:127`, `WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:132`). |
| Default | `SystemSoundCatalog.fallbackSoundName`, derzeit „Glass" (`WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:14`, `WhisperM8/Services/Shared/SystemSoundCatalog.swift:7`). |
| Persistenz | UserDefaults-Key `agentStopSoundName`, definiert als `PreferenceKeys.agentStopSoundName = "agentStopSoundName"` (`WhisperM8/Support/AppPreferences.swift:395`). |
| Gelesen von | Settings-View via `@AppStorage(PreferenceKeys.agentStopSoundName)` (`WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:14`), `AppPreferences.agentStopSoundName` für die Laufzeit (`WhisperM8/Support/AppPreferences.swift:276`, `WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:19`). |
| Wirkung | Jede Änderung des Pickers spielt den neu gewählten Sound sofort probeweise ab; beim Turn-Ende nutzt der Koordinator denselben Namen für `playSound(preferences.stopSoundName)` (`WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:134`, `WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:135`, `WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:268`). |
| Abhängigkeiten | Die Auswahl kommt aus `/System/Library/Sounds` und umfasst `.aiff`, `.aif` und `.caf`; wenn keine Liste verfügbar ist, fällt `soundChoices` auf den gespeicherten Soundnamen zurück (`WhisperM8/Services/Shared/SystemSoundCatalog.swift:6`, `WhisperM8/Services/Shared/SystemSoundCatalog.swift:20`, `WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:154`). Unbekannte oder verwaiste Namen fallen beim Abspielen auf „Glass" zurück (`WhisperM8/Services/Shared/SystemSoundCatalog.swift:25`, `WhisperM8/Services/Shared/SystemSoundCatalog.swift:28`). |

### Sound anspielen

| Aspekt | Wert |
|---|---|
| Control | Borderless Button mit `play.circle`-Icon und Help-Text „Sound anspielen" (`WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:138`, `WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:141`, `WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:145`). |
| Default | Kein gespeicherter Zustand; nutzt den aktuellen `stopSoundName`, dessen Default „Glass" ist (`WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:14`, `WhisperM8/Services/Shared/SystemSoundCatalog.swift:7`). |
| Persistenz | Keine eigene Persistenz; liest den UserDefaults-Wert `agentStopSoundName` über die Picker-Bindung (`WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:127`, `WhisperM8/Support/AppPreferences.swift:395`). |
| Gelesen von | `ClaudeCodeSettingsView.soundSection` (`WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:122`). |
| Wirkung | Ruft `SystemSoundCatalog.play(stopSoundName)` auf und spielt damit den aktuell ausgewählten Sound sofort ab (`WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:138`, `WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:139`). |
| Abhängigkeiten | Deaktiviert, wenn „Ton, wenn ein Agent fertig ist" deaktiviert ist (`WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:144`). |

### Eigene Claude-Hooks erkannt

| Aspekt | Wert |
|---|---|
| Control | Bedingter read-only Abschnitt mit Warnsymbol, erklärendem Text und einer Liste erkannter globaler Hook-Einträge (`WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:166`, `WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:168`, `WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:176`). |
| Default | Nicht sichtbar, weil `externalHookFindings` als leeres Array startet (`WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:18`, `WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:28`). |
| Persistenz | Keine App-Persistenz; die Findings werden beim Refresh read-only aus der globalen Claude-Konfiguration inspiziert (`WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:232`, `WhisperM8/Services/AgentChats/ExternalClaudeHooksInspector.swift:3`). |
| Gelesen von | `ClaudeCodeSettingsView.externalHooksSection` (`WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:166`), `ExternalClaudeHooksInspector.inspectUserSettings()` (`WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:232`). |
| Wirkung | Warnt vor doppelten Meldungen, wenn globale User-Hooks auf Events registriert sind, die WhisperM8 selbst abdeckt; WhisperM8 ändert diese Dateien laut UI-Text nie (`WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:171`). Die Liste zeigt Event-Name, optionalen Matcher, Quelle unter `~/.claude/…` und einen gekürzten Command-Preview (`WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:179`, `WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:181`, `WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:187`, `WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:191`). |
| Abhängigkeiten | Verglichen wird gegen `ClaudeHookSettingsBuilder.trackedEventNames`, also `SessionStart`, `SessionEnd`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `PostToolUseFailure`, `PermissionRequest` und `Stop` (`WhisperM8/Services/AgentChats/ExternalClaudeHooksInspector.swift:29`, `WhisperM8/Services/AgentChats/ClaudeHookSettingsBuilder.swift:25`). |

### Wie funktioniert das?

| Aspekt | Wert |
|---|---|
| Control | `DisclosureGroup` „Wie funktioniert das?" mit lokalem `@State isExplainerExpanded` (`WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:19`, `WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:207`). |
| Default | Eingeklappt, weil `isExplainerExpanded` als `false` initialisiert ist (`WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:19`). |
| Persistenz | Keine Persistenz; lokaler SwiftUI-State `isExplainerExpanded` (`WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:19`). |
| Gelesen von | `ClaudeCodeSettingsView.explainerSection` (`WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:205`). |
| Wirkung | Erklärt, dass WhisperM8 beim Chat-Start `claude --settings <datei>` übergibt, jeder Hook in eine Session-eigene Datei schreibt und globale oder Projekt-Settings nicht verändert werden (`WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:209`). |
| Abhängigkeiten | Die Erklärung ist an die JSON-Vorschau gekoppelt, die beim Refresh aus `ClaudeHookSettingsBuilder.serializedSettings` erzeugt wird (`WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:233`, `WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:235`). |

### Hook-Settings-Vorschau

| Aspekt | Wert |
|---|---|
| Control | Textselektierbare, monospaced JSON-Vorschau in einem `ScrollView` mit maximal 240 Punkten Höhe (`WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:212`, `WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:214`, `WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:219`). |
| Default | Leer bis zum ersten `refresh()`; dann wird ein Beispielpfad `~/Library/Application Support/WhisperM8/claude-session-events/<session>.jsonl` serialisiert (`WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:20`, `WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:233`, `WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:234`). |
| Persistenz | Keine Persistenz; lokaler SwiftUI-State `hookSettingsPreview` (`WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:20`). |
| Gelesen von | `ClaudeCodeSettingsView.explainerSection` (`WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:205`), `ClaudeHookSettingsBuilder.serializedSettings(eventFilePath:)` (`WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:235`, `WhisperM8/Services/AgentChats/ClaudeHookSettingsBuilder.swift:62`). |
| Wirkung | Macht transparent, welche Hook-Konfiguration WhisperM8 später als `--settings`-Datei erzeugt; der Builder schreibt für jedes getrackte Event einen Command-Hook, der das stdin-JSON als JSONL-Zeile an die Event-Datei anhängt (`WhisperM8/Services/AgentChats/ClaudeHookSettingsBuilder.swift:36`, `WhisperM8/Services/AgentChats/ClaudeHookSettingsBuilder.swift:42`, `WhisperM8/Services/AgentChats/ClaudeHookSettingsBuilder.swift:89`). |
| Abhängigkeiten | Die reale Settings-Datei wird pro lokaler Session unter `~/Library/Application Support/WhisperM8/claude-hooks/<UUID>.json` geschrieben, die Event-Datei unter `~/Library/Application Support/WhisperM8/claude-session-events/<UUID>.jsonl` (`WhisperM8/Services/AgentChats/ClaudeHookSettingsBuilder.swift:129`, `WhisperM8/Services/AgentChats/ClaudeHookSettingsBuilder.swift:134`, `WhisperM8/Services/AgentChats/ClaudeHookSettingsBuilder.swift:146`). |

## 4. Datenfluss & Persistenz

Alle fünf echten Settings-Werte werden sofort über `@AppStorage` in UserDefaults geschrieben: `claudeHooksEnabled`, `agentStopNotificationEnabled`, `agentAwaitingNotificationEnabled`, `agentStopSoundEnabled` und `agentStopSoundName` (`WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:10`, `WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:14`, `WhisperM8/Support/AppPreferences.swift:394`). `AppPreferences` liest dieselben Keys mit Defaults (`true` für die Bool-Werte, „Glass" für den Soundnamen), und `AgentStatusPreferences.current()` erstellt daraus den Laufzeit-Snapshot für den Koordinator (`WhisperM8/Support/AppPreferences.swift:268`, `WhisperM8/Support/AppPreferences.swift:276`, `WhisperM8/Support/AppPreferences.swift:284`, `WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:12`).

Der Hook-Schalter wird beim Vorbereiten eines Launches gelesen, nicht dauerhaft in eine Session kopiert: `prepareLaunchArguments` liefert nur bei aktivem Hook-Schalter `--settings <path>`, und `prepareBackgroundSettingsFile` liefert nur bei aktivem Hook-Schalter einen Settings-Dateipfad (`WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:102`, `WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:107`). Für interaktive Claude-Chats ruft `AgentSessionDetailView.prepareCommand()` die Hook-Argumente vor dem Command-Build ab und startet das Hook-Tracking nach dem Launch (`WhisperM8/Views/AgentSessionDetailView.swift:222`, `WhisperM8/Views/AgentSessionDetailView.swift:238`, `WhisperM8/Views/AgentSessionDetailView.swift:250`). Für Background-Agents wird der Settings-Pfad bereits beim `claude --bg`-Spawn übergeben; der spätere `claude attach` darf keine zweite Bridge starten (`WhisperM8/Views/AgentChatsView+BackgroundAgents.swift:68`, `WhisperM8/Views/AgentChatsView+BackgroundAgents.swift:78`, `WhisperM8/Views/AgentChatsView+BackgroundAgents.swift:92`).

Die Bridge schreibt vor dem Launch eine 0600-Settings-Datei und eine leere 0600-Event-Datei, gibt den Settings-Pfad zurück und beobachtet danach das Event-JSONL per DispatchSource statt per Polling (`WhisperM8/Services/AgentChats/ClaudeHookBridge.swift:65`, `WhisperM8/Services/AgentChats/ClaudeHookBridge.swift:79`, `WhisperM8/Services/AgentChats/ClaudeHookBridge.swift:88`, `WhisperM8/Services/AgentChats/ClaudeHookBridge.swift:93`, `WhisperM8/Services/AgentChats/ClaudeHookBridge.swift:104`, `WhisperM8/Services/AgentChats/ClaudeHookBridge.swift:130`). Hook-Events werden geparst, an den `AgentSessionStatusCoordinator` geliefert und dort in Statusübergänge, Notifications, Sound und externe Session-ID-Bindung übersetzt (`WhisperM8/Services/AgentChats/ClaudeHookEventStore.swift:109`, `WhisperM8/Services/AgentChats/ClaudeHookBridge.swift:218`, `WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:88`, `WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:193`, `WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:247`). Wenn Hook-Events lebendig sind, ignoriert der Koordinator normale Transcript-Statusmeinungen zugunsten der Hooks; ohne lebendige Hook-Bridge gelten Transcript-Entscheidungen als Fallback (`WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:63`, `WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:217`, `WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:230`).

Notifications werden aus State-Machine-Effekten erzeugt: `turnCompleted` nutzt Fertig-Ton und Fertig-Notification, `inputRequested` nutzt die Rückfrage-Notification (`WhisperM8/Services/AgentChats/AgentSessionStateMachine.swift:124`, `WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:263`). Der Notification-Poster setzt Titel, Projektuntertitel, Body und `localSessionID` in `userInfo`; ein Klick auf die Notification fokussiert danach den passenden Chat über `WindowRequestCenter.requestSessionFocus` (`WhisperM8/Services/AgentChats/AgentSessionNotifier.swift:48`, `WhisperM8/Services/AgentChats/AgentSessionNotifier.swift:55`, `WhisperM8/WhisperM8App.swift:350`, `WhisperM8/WhisperM8App.swift:358`, `WhisperM8/Services/Shared/WindowRequestCenter.swift:112`).

## 5. Querverweise

- `SettingsView` führt „Agent Chats" und „Claude Code" gemeinsam in der Gruppe „Agents"; Auswahl von „Agent Chats" öffnet zusätzlich das Agent-Chats-Fenster, Auswahl von „Claude Code" bleibt im Settings-Detail (`WhisperM8/Views/SettingsView.swift:129`, `WhisperM8/Views/SettingsView.swift:142`, `WhisperM8/Views/SettingsView.swift:223`, `WhisperM8/Views/SettingsView.swift:226`).
- Die Settings-Seite „Agent Chats" enthält weiterhin Provider-Auswahl, Auto-Rename, Terminal-Bell und Extra-Argumente; sie verweist explizit darauf, dass Fertig-Ton und Turn-Ende-Benachrichtigungen zu „Claude Code" umgezogen sind (`WhisperM8/Views/Settings/AgentChatsAccessView.swift:33`, `WhisperM8/Views/Settings/AgentChatsAccessView.swift:46`, `WhisperM8/Views/Settings/AgentChatsAccessView.swift:57`, `WhisperM8/Views/Settings/AgentChatsAccessView.swift:62`).
- `AgentCommandBuilder` baut die tatsächlichen Claude-Argumente; vom Caller injizierte Hook-Argumente stehen ganz vorne, danach folgen die nutzerdefinierten Claude-Extra-Argumente aus der Agent-Chats-Seite (`WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:211`, `WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:214`, `WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:217`).
- `ClaudeHookSettingsBuilder` ist die Quelle der erzeugten Hook-Settings und tracked die Events `SessionStart`, `SessionEnd`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `PostToolUseFailure`, `PermissionRequest` und `Stop` (`WhisperM8/Services/AgentChats/ClaudeHookSettingsBuilder.swift:25`).
- `ExternalClaudeHooksInspector` ist der read-only Abgleich gegen globale Claude-Code-Settings; die Settings-Seite visualisiert die Findings, ändert aber keine `~/.claude/`-Dateien (`WhisperM8/Services/AgentChats/ExternalClaudeHooksInspector.swift:3`, `WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:171`).
- `AgentSessionRetentionService` räumt verwaiste Hook-Settings- und Event-Dateien aus den App-Support-Unterordnern auf, behält aber Dateien aktueller lokaler Sessions (`WhisperM8/Services/AgentChats/AgentSessionRetentionService.swift:3`, `WhisperM8/Services/AgentChats/AgentSessionRetentionService.swift:18`, `WhisperM8/Services/AgentChats/AgentSessionRetentionService.swift:20`).

## 6. UX-Beobachtungen (Rohmaterial fürs Redesign)

1. Die Trennung zwischen „Agent Chats" und „Claude Code" ist fachlich nachvollziehbar, aber erklärungsbedürftig: „Agent Chats" konfiguriert Workspace-Verhalten, Provider-Default, Auto-Rename, Terminal-Bell und CLI-Extra-Argumente, während „Claude Code" Status-Hooks, Benachrichtigungen und Fertig-Ton behandelt (`WhisperM8/Views/Settings/AgentChatsAccessView.swift:33`, `WhisperM8/Views/Settings/AgentChatsAccessView.swift:46`, `WhisperM8/Views/Settings/AgentChatsAccessView.swift:62`, `WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:4`). Der Verweis „Fertig-Ton und Benachrichtigungen … sind zu Claude Code umgezogen" hilft, ist aber nur auf der Agent-Chats-Seite sichtbar; wer direkt auf „Claude Code" landet, sieht die umgekehrte Abgrenzung nicht (`WhisperM8/Views/Settings/AgentChatsAccessView.swift:57`, `WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:40`).

2. Die Seite mischt deutsche und englische Begriffe: Abschnittstitel und viele Erklärtexte sind deutsch, aber Controls wie „Test-Notification senden", technische Labels wie `matcher`, `--settings`, „Hook", „Session", „Stop-Hook" und „Sound" bleiben englisch oder halbenglisch (`WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:97`, `WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:104`, `WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:127`, `WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:148`, `WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:182`). Für Developer ist das präzise, für weniger technische Nutzer aber uneinheitlich, besonders weil „Benachrichtigungen" und „Notification" direkt nebeneinander stehen (`WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:82`, `WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:104`).

3. Die Seite ist transparent, aber dicht: Live-Status, Hook-Bridge, macOS-Berechtigungen, Benachrichtigungsrouting, System-Sounds, externe Hook-Konflikte und JSON-Vorschau stehen auf einer einzelnen Settings-Seite (`WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:25`, `WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:31`, `WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:207`). Positiv ist, dass der Code technische Risiken direkt erklärt: globale `~/.claude/settings.json` bleibt unangetastet, laufende Sessions brauchen Neustart für neue Hook-Konfiguration und externe Hooks können doppelte Meldungen verursachen (`WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:49`, `WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:57`, `WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:171`).

4. Der Tonbereich hat eine gute lokale Rückmeldung, weil sowohl Picker-Änderung als auch Play-Button den gewählten Sound sofort abspielen (`WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:134`, `WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:138`). Die Produktlogik „Rückfragen sind bewusst lautlos" ist fachlich klar, aber sie steht nur als Fließtext unter dem Tonbereich und nicht neben dem Rückfrage-Toggle (`WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:98`, `WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:148`).

## 7. Offene Fragen

- Ob der Button „Systemeinstellungen öffnen" auf allen unterstützten macOS-14+-Versionen direkt in den Notification-Bereich der App springt, ist aus dem Code nicht belegbar; der Code öffnet nur die generische URL `x-apple.systempreferences:com.apple.preference.notifications` (`WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:260`).
- Die Settings-Seite zeigt nicht, ob bereits laufende Sessions aktuell mit oder ohne Hook-Bridge gestartet wurden; aus dem UI-Hinweis ist nur ersichtlich, dass Änderungen erst für neu gestartete Chats gelten (`WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:57`).
- Der Code belegt, dass `ExternalClaudeHooksInspector` read-only arbeitet und die View globale Hook-Findings anzeigt; die konkrete Parsing-Abdeckung aller möglichen Claude-Code-Settings-Varianten wurde hier nicht validiert (`WhisperM8/Services/AgentChats/ExternalClaudeHooksInspector.swift:3`, `WhisperM8/Views/Settings/ClaudeCodeSettingsView.swift:176`).
