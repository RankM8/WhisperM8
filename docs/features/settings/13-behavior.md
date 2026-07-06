---
description: Settings-Seite „Behavior" — vollständige Referenz aller Optionen
description_long: |
  Vollständige Referenz der Settings-Seite „Behavior" im WhisperM8-Settings-Fenster.
  Dokumentiert werden UI-Aufbau, Defaults, Persistenz, Laufzeitwirkung, Datenfluss,
  Querverweise und UX-Beobachtungen für die Sammelseite App → Behavior.
updated: 2026-07-06 14:05
status: ✅ Validiert (Opus-Gegenprüfung 2026-07-06, 0 Mängel)
---

> ⚠️ HISTORISCH (Stand vor Refactor 2026-07-06) — Inhalte beschreiben die alte Seite; neue Seite: `RecordingSettingsPage.swift`, `ContextPrivacySettingsPage.swift` und `GeneralSettingsPage.swift` + Doku-Verweis [ARCHITEKTUR: Kompatibilitätsvertrag](ARCHITEKTUR.md#kompatibilitätsvertrag).

# Settings: Behavior

> **Sidebar-Gruppe:** App · **View:** `WhisperM8/Views/Settings/BehaviorSettingsView.swift` · **Enum-Case:** `ControlCenterSection.behavior` (`WhisperM8/Views/SettingsView.swift`)
>
> **Primäre Quell-Dateien:** `BehaviorSettingsView.swift`, `Support/AppPreferences.swift`

## 1. Zweck & Überblick

Die Seite „Behavior" ist die Sammelseite für laufzeitnahe App-Verhaltensoptionen: Nutzungsprofil, Erscheinungsbild, Auto-Paste, Kontext-Capture, Audio-Ducking, Recording-Overlay und Login-Start liegen in einer einzigen `Form` unter `ControlCenterSection.behavior`. (`WhisperM8/Views/Settings/BehaviorSettingsView.swift:20`, `WhisperM8/Views/SettingsView.swift:16`, `WhisperM8/Views/SettingsView.swift:104`)

Das Nutzungsprofil ist dabei der stärkste Schalter: Es entscheidet, ob Codex-Enrichment verfügbar ist, ob Agent Chats aktiv sind und ob WhisperM8 als Dock-App oder Menüleisten-App läuft. (`WhisperM8/Models/AppUsageProfile.swift:20`, `WhisperM8/Models/AppUsageProfile.swift:28`, `WhisperM8/Models/AppUsageProfile.swift:33`)

Die übrigen Controls wirken direkt auf Diktat-Delivery, Kontext-Erfassung, Systemlautstärke und Recording-Pill; die meisten Werte sind als `@AppStorage` an `UserDefaults` gebunden. (`WhisperM8/Views/Settings/BehaviorSettingsView.swift:5`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:15`, `WhisperM8/Support/AppPreferences.swift:360`, `WhisperM8/Support/AppPreferences.swift:378`)

## 2. UI-Aufbau

Die Seite ist eine gruppierte SwiftUI-`Form` mit acht Sections in dieser Reihenfolge: „Usage", „Erscheinungsbild", eine unbenannte Auto-Paste-Section, „Selected Context", „Visual Context", „Audio Ducking", „Recording Overlay" und eine unbenannte Launch-at-Login-Section. (`WhisperM8/Views/Settings/BehaviorSettingsView.swift:21`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:22`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:37`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:55`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:65`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:73`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:97`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:115`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:144`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:148`)

„Usage" enthält einen `Picker("Profile")` über alle `AppUsageProfile`-Cases und zeigt darunter die Summary des gewählten Profils an. (`WhisperM8/Views/Settings/BehaviorSettingsView.swift:23`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:24`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:32`, `WhisperM8/Models/AppUsageProfile.swift:40`, `WhisperM8/Models/AppUsageProfile.swift:49`)

„Erscheinungsbild" enthält einen segmentierten Theme-Picker ohne sichtbares Label und einen Hinweistext, dass „System" macOS folgt und „Hell"/„Dunkel" auch Claude Code über `~/.claude.json` umstellt. (`WhisperM8/Views/Settings/BehaviorSettingsView.swift:38`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:47`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:48`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:50`)

Die Auto-Paste-Section besteht aus einem Toggle und einem dynamischen Hilfetext, der je nach Zustand zwischen automatischem Einfügen und reinem Clipboard-Kopieren unterscheidet. (`WhisperM8/Views/Settings/BehaviorSettingsView.swift:56`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:58`)

„Selected Context" enthält einen Toggle für markierten Text und einen Hilfetext zu kontextbewussten Modi wie Slack, WhatsApp und Email. (`WhisperM8/Views/Settings/BehaviorSettingsView.swift:66`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:68`)

„Visual Context" enthält Toggle, Screenshot-Stepper, Screen-Clip-Slider, Delete-Toggle und einen Permission-/Clipboard-Hinweis. (`WhisperM8/Views/Settings/BehaviorSettingsView.swift:74`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:76`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:82`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:90`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:92`)

„Audio Ducking" zeigt den Target-Volume-Slider nur bedingt an, nämlich wenn „Reduce system volume while recording" aktiv ist. (`WhisperM8/Views/Settings/BehaviorSettingsView.swift:98`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:100`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:103`)

„Recording Overlay" enthält Overlay-Stil, Confirm-Button, Mini-Mode-Picker, Reset-Button und erklärende Texte zu Stop-Verhalten, Hover-Verhalten und Positionspersistenz. (`WhisperM8/Views/Settings/BehaviorSettingsView.swift:116`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:123`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:125`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:129`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:131`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:135`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:139`)

Die letzte Section enthält `LaunchAtLogin.Toggle("Start at Login")` aus dem SwiftPM-Paket `LaunchAtLogin-Modern`. (`WhisperM8/Views/Settings/BehaviorSettingsView.swift:145`, `Package.swift:15`, `Package.swift:30`)

## 3. Optionen im Detail

### Profile

| Aspekt | Wert |
|---|---|
| Control | `Picker("Profile")` über `AppUsageProfile.allCases`; sichtbare Werte sind „Dictation only", „Dictation + AI enrichment" und „Full (with Agent Chats)". (`WhisperM8/Views/Settings/BehaviorSettingsView.swift:23`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:24`, `WhisperM8/Models/AppUsageProfile.swift:41`, `WhisperM8/Models/AppUsageProfile.swift:43`) |
| Default | `AppUsageProfile.defaultProfile == .full`; `AppPreferences.usageProfile` fällt bei fehlendem Wert auf `full` zurück. (`WhisperM8/Models/AppUsageProfile.swift:17`, `WhisperM8/Models/AppUsageProfile.swift:18`, `WhisperM8/Support/AppPreferences.swift:25`, `WhisperM8/Support/AppPreferences.swift:26`) |
| Persistenz | UserDefaults-Key `usageProfile`; exakter Key in `PreferenceKeys.usageProfile`. (`WhisperM8/Support/AppPreferences.swift:23`, `WhisperM8/Support/AppPreferences.swift:28`, `WhisperM8/Support/AppPreferences.swift:358`) |
| Gelesen von | `BehaviorSettingsView` initialisiert und synchronisiert den Picker aus `AppPreferences.shared.usageProfile`; `OutputMode.defaultMode` und `OutputMode.availableBuiltInModes` lesen das Profil für Codex-abhängige Modi; `WindowRequestCenter` liest es für das Agent-Chats-Fenster-Gate. (`WhisperM8/Views/Settings/BehaviorSettingsView.swift:18`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:149`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:151`, `WhisperM8/Models/OutputMode.swift:237`, `WhisperM8/Models/OutputMode.swift:255`, `WhisperM8/Services/Shared/WindowRequestCenter.swift:71`, `WhisperM8/Services/Shared/WindowRequestCenter.swift:75`) |
| Wirkung | Bei Änderung ruft die View `applyProfileChange`, persistiert über `AppProfileActivator.apply`, setzt `NSApp` auf Dock- oder Menüleisten-Policy und erlaubt oder sperrt Agent-Chats-Fenster; bei `full` wird Agent Chats angefordert, sonst werden primäre und sekundäre Agent-Chats-Fenster geschlossen. (`WhisperM8/Views/Settings/BehaviorSettingsView.swift:28`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:157`, `WhisperM8/Services/Shared/AppProfileActivator.swift:13`, `WhisperM8/Services/Shared/AppProfileActivator.swift:14`, `WhisperM8/Services/Shared/AppProfileActivator.swift:15`, `WhisperM8/Services/Shared/AppProfileActivator.swift:16`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:159`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:164`) |
| Abhängigkeiten | Ohne Codex-Enrichment fallen Codex-abhängige Default-Modi effektiv auf Raw zurück und die Overlay-Modusliste filtert Codex-abhängige Modi aus. (`WhisperM8/Models/OutputMode.swift:239`, `WhisperM8/Models/OutputMode.swift:242`, `WhisperM8/Models/OutputMode.swift:243`, `WhisperM8/Models/OutputMode.swift:252`, `WhisperM8/Models/OutputMode.swift:257`, `WhisperM8/Models/OutputMode.swift:258`) |

### Theme

| Aspekt | Wert |
|---|---|
| Control | Segmentierter `Picker("Theme")` über `AppearanceOverride.allCases`; das Label ist versteckt. (`WhisperM8/Views/Settings/BehaviorSettingsView.swift:38`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:42`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:47`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:48`) |
| Default | `AppearanceOverride.system`; fehlende oder ungültige Werte fallen auf `.system` zurück. (`WhisperM8/Support/AppPreferences.swift:71`, `WhisperM8/Support/AppPreferences.swift:73`, `WhisperM8/Support/AppPreferences.swift:74`) |
| Persistenz | UserDefaults-Key `appearanceOverride`; exakter Key in `PreferenceKeys.appearanceOverride`. (`WhisperM8/Support/AppPreferences.swift:71`, `WhisperM8/Support/AppPreferences.swift:76`, `WhisperM8/Support/AppPreferences.swift:390`) |
| Gelesen von | `BehaviorSettingsView` bindet an `ThemeManager.shared.override`; Scene-Roots verwenden `themeManager.override.preferredColorScheme`; `ThemeManager` lädt den gespeicherten Override beim Init. (`WhisperM8/Views/Settings/BehaviorSettingsView.swift:16`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:38`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:40`, `WhisperM8/WhisperM8App.swift:13`, `WhisperM8/WhisperM8App.swift:38`, `WhisperM8/WhisperM8App.swift:64`, `WhisperM8/WhisperM8App.swift:73`, `WhisperM8/WhisperM8App.swift:86`, `WhisperM8/WhisperM8App.swift:95`, `WhisperM8/Support/ThemeManager.swift:24`, `WhisperM8/Support/ThemeManager.swift:26`) |
| Wirkung | `system` gibt `nil` an `.preferredColorScheme` weiter und folgt macOS; `light` und `dark` erzwingen ein SwiftUI- und AppKit-Schema, posten bei Änderung eine Theme-Notification und synchronisieren Claude Code über `ClaudeThemeWriter`. (`WhisperM8/Support/AppearanceOverride.swift:31`, `WhisperM8/Support/AppearanceOverride.swift:34`, `WhisperM8/Support/AppearanceOverride.swift:42`, `WhisperM8/Support/AppearanceOverride.swift:45`, `WhisperM8/Support/ThemeManager.swift:55`, `WhisperM8/Support/ThemeManager.swift:59`, `WhisperM8/Support/ThemeManager.swift:63`, `WhisperM8/Support/ThemeManager.swift:75`, `WhisperM8/Support/ThemeManager.swift:82`) |
| Abhängigkeiten | Der Hinweistext koppelt den Settings-Schalter sichtbar an Claude Code und `~/.claude.json`; der tatsächliche Schreibpfad liegt in `ThemeManager.recompute`. (`WhisperM8/Views/Settings/BehaviorSettingsView.swift:50`, `WhisperM8/Support/ThemeManager.swift:80`, `WhisperM8/Support/ThemeManager.swift:82`) |

### Auto-paste after transcription

| Aspekt | Wert |
|---|---|
| Control | Toggle „Auto-paste after transcription" mit dynamischem Hilfetext. (`WhisperM8/Views/Settings/BehaviorSettingsView.swift:56`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:58`) |
| Default | `true`; `@AppStorage` setzt lokal `true`, und `AppPreferences.isAutoPasteEnabled` nutzt `boolWithDefault(true)`. (`WhisperM8/Views/Settings/BehaviorSettingsView.swift:5`, `WhisperM8/Support/AppPreferences.swift:41`, `WhisperM8/Support/AppPreferences.swift:42`) |
| Persistenz | UserDefaults-Key `autoPasteEnabled`; exakter Key in `PreferenceKeys.autoPasteEnabled`. (`WhisperM8/Views/Settings/BehaviorSettingsView.swift:5`, `WhisperM8/Support/AppPreferences.swift:43`, `WhisperM8/Support/AppPreferences.swift:360`) |
| Gelesen von | `RecordingCoordinator+Transcription` liest `AppPreferences.shared.isAutoPasteEnabled`; Onboarding liest denselben `@AppStorage`-Key. (`WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:61`, `WhisperM8/Views/OnboardingView.swift:581`, `WhisperM8/Views/OnboardingView.swift:669`) |
| Wirkung | Wenn aktiv und der Output-Mode nicht Chat ist, kopiert die Pipeline den finalen Text und sendet Cmd+V an die Ziel-App; wenn inaktiv, wird nur ins Clipboard kopiert und das Overlay geschlossen. (`WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:61`, `WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:78`, `WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:84`, `WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:87`, `WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:102`, `WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:104`) |
| Abhängigkeiten | Auto-Paste benötigt Accessibility-Permission und ein vorher erfasstes Ziel-App-Fenster; bei fehlender Permission oder fehlendem Target liefert `PasteService` Fehler zurück. (`WhisperM8/Services/Dictation/PasteService.swift:58`, `WhisperM8/Services/Dictation/PasteService.swift:61`, `WhisperM8/Services/Dictation/PasteService.swift:65`, `WhisperM8/Services/Dictation/PasteService.swift:69`, `WhisperM8/Services/Dictation/PasteService.swift:75`) |

### Use selected text as context

| Aspekt | Wert |
|---|---|
| Control | Toggle „Use selected text as context" mit Hilfetext zu kontextbewussten Modi. (`WhisperM8/Views/Settings/BehaviorSettingsView.swift:66`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:68`) |
| Default | `true`; `@AppStorage` setzt lokal `true`, und `AppPreferences.isSelectedContextCaptureEnabled` nutzt `boolWithDefault(true)`. (`WhisperM8/Views/Settings/BehaviorSettingsView.swift:11`, `WhisperM8/Support/AppPreferences.swift:111`, `WhisperM8/Support/AppPreferences.swift:112`) |
| Persistenz | UserDefaults-Key `selectedContextCaptureEnabled`; exakter Key in `PreferenceKeys.selectedContextCaptureEnabled`. (`WhisperM8/Views/Settings/BehaviorSettingsView.swift:11`, `WhisperM8/Support/AppPreferences.swift:113`, `WhisperM8/Support/AppPreferences.swift:373`) |
| Gelesen von | `SelectedContextService.capture` liest den Schalter vor Accessibility- oder Clipboard-Capture; `RecordingCoordinator+Clipboard.importClipboardText` liest ihn beim Live-Clipboard-Import. (`WhisperM8/Services/Dictation/SelectedContextService.swift:9`, `WhisperM8/Services/Dictation/SelectedContextService.swift:10`, `WhisperM8/Services/Dictation/RecordingCoordinator+Clipboard.swift:164`, `WhisperM8/Services/Dictation/RecordingCoordinator+Clipboard.swift:167`) |
| Wirkung | Wenn aktiv, versucht WhisperM8 beim Recording-Start ausgewählten Text per Accessibility oder Clipboard-Fallback zu übernehmen und importiert später kopierten Text ins Live-Kontext-Bundle; wenn inaktiv, geben beide Pfade keinen Selected-Text-Kontext zurück. (`WhisperM8/Services/Dictation/SelectedContextService.swift:16`, `WhisperM8/Services/Dictation/SelectedContextService.swift:30`, `WhisperM8/Services/Dictation/SelectedContextService.swift:39`, `WhisperM8/Services/Dictation/RecordingCoordinator+Clipboard.swift:98`, `WhisperM8/Services/Dictation/RecordingCoordinator+Clipboard.swift:180`, `WhisperM8/Services/Dictation/RecordingCoordinator+Clipboard.swift:193`) |
| Abhängigkeiten | Der initiale Capture läuft parallel nach Aufnahmestart und merged in das `TranscriptContextBundle`; Accessibility-Permission ist für den Clipboard-Fallback nötig. (`WhisperM8/Services/Dictation/RecordingCoordinator+Context.swift:12`, `WhisperM8/Services/Dictation/RecordingCoordinator+Context.swift:20`, `WhisperM8/Services/Dictation/RecordingCoordinator+Context.swift:54`, `WhisperM8/Services/Dictation/SelectedContextService.swift:25`, `WhisperM8/Services/Dictation/SelectedContextService.swift:27`) |

### Allow screenshots and screen clips as context

| Aspekt | Wert |
|---|---|
| Control | Toggle „Allow screenshots and screen clips as context". (`WhisperM8/Views/Settings/BehaviorSettingsView.swift:74`) |
| Default | `true`; `@AppStorage` setzt lokal `true`, und `AppPreferences.isVisualContextCaptureEnabled` nutzt `boolWithDefault(true)`. (`WhisperM8/Views/Settings/BehaviorSettingsView.swift:12`, `WhisperM8/Support/AppPreferences.swift:116`, `WhisperM8/Support/AppPreferences.swift:117`) |
| Persistenz | UserDefaults-Key `visualContextCaptureEnabled`; exakter Key in `PreferenceKeys.visualContextCaptureEnabled`. (`WhisperM8/Views/Settings/BehaviorSettingsView.swift:12`, `WhisperM8/Support/AppPreferences.swift:118`, `WhisperM8/Support/AppPreferences.swift:374`) |
| Gelesen von | `RecordingCoordinator+Context.captureInteractiveScreenshot` und `RecordingCoordinator+Clipboard.importClipboardScreenshotIfNeeded` lesen den Schalter; `observeClipboardChange` nutzt ihn für automatische Screenshot-Imports. (`WhisperM8/Services/Dictation/RecordingCoordinator+Context.swift:110`, `WhisperM8/Services/Dictation/RecordingCoordinator+Context.swift:112`, `WhisperM8/Services/Dictation/RecordingCoordinator+Clipboard.swift:92`, `WhisperM8/Services/Dictation/RecordingCoordinator+Clipboard.swift:212`, `WhisperM8/Services/Dictation/RecordingCoordinator+Clipboard.swift:214`) |
| Wirkung | Wenn aktiv, können interaktive Screenshots, Clipboard-Screenshots und Screen-Clips als Kontext ins Recording-Bundle aufgenommen werden; Clipboard-Bilddaten werden während Recording, Transcribing und Post-Processing beobachtet. (`WhisperM8/Services/Dictation/RecordingCoordinator+Context.swift:122`, `WhisperM8/Services/Dictation/RecordingCoordinator+Context.swift:129`, `WhisperM8/Services/Dictation/RecordingCoordinator+Clipboard.swift:70`, `WhisperM8/Services/Dictation/RecordingCoordinator+Clipboard.swift:76`, `WhisperM8/Services/Dictation/RecordingCoordinator+Clipboard.swift:92`, `WhisperM8/Services/Dictation/RecordingCoordinator+Clipboard.swift:147`) |
| Abhängigkeiten | Screen-Clips benötigen Screen-Recording-Permission; Screenshots respektieren zusätzlich das Limit `maxScreenshotsPerRecording`. (`WhisperM8/Views/Settings/BehaviorSettingsView.swift:92`, `WhisperM8/Services/Dictation/RecordingCoordinator+Clipboard.swift:20`, `WhisperM8/Services/Dictation/RecordingCoordinator+Clipboard.swift:21`, `WhisperM8/Services/Dictation/RecordingCoordinator+Clipboard.swift:132`) |

### Screenshots per recording

| Aspekt | Wert |
|---|---|
| Control | `Stepper("Screenshots per recording: ...")` mit Wertebereich `1...AppPreferences.maximumScreenshotsPerRecording`. (`WhisperM8/Views/Settings/BehaviorSettingsView.swift:76`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:77`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:79`) |
| Default | `20`; `defaultMaxScreenshotsPerRecording` und `maximumScreenshotsPerRecording` stehen beide auf `20`. (`WhisperM8/Support/AppPreferences.swift:6`, `WhisperM8/Support/AppPreferences.swift:7`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:13`) |
| Persistenz | UserDefaults-Key `maxScreenshotsPerRecording`; exakter Key in `PreferenceKeys.maxScreenshotsPerRecording`. (`WhisperM8/Views/Settings/BehaviorSettingsView.swift:13`, `WhisperM8/Support/AppPreferences.swift:121`, `WhisperM8/Support/AppPreferences.swift:128`, `WhisperM8/Support/AppPreferences.swift:375`) |
| Gelesen von | Screenshot-Capture, Clipboard-Screenshot-Import und Visual-Attachment-Delivery lesen das Limit. (`WhisperM8/Services/Dictation/RecordingCoordinator+Context.swift:113`, `WhisperM8/Services/Dictation/RecordingCoordinator+Clipboard.swift:132`, `WhisperM8/Services/Dictation/VisualAttachmentDeliveryBuilder.swift:20`) |
| Wirkung | Das Limit stoppt weitere Screenshot-Aufnahmen mit „Maximum screenshots for this recording reached." und begrenzt die Anzahl der später vorbereiteten visuellen Paste-Anhänge. (`WhisperM8/Services/Dictation/RecordingCoordinator+Context.swift:113`, `WhisperM8/Services/Dictation/RecordingCoordinator+Context.swift:114`, `WhisperM8/Services/Dictation/RecordingCoordinator+Clipboard.swift:132`, `WhisperM8/Services/Dictation/RecordingCoordinator+Clipboard.swift:133`, `WhisperM8/Services/Dictation/VisualAttachmentDeliveryBuilder.swift:24`) |
| Abhängigkeiten | Der Getter normalisiert fehlende Werte auf `20` und clampet gespeicherte Werte auf das Maximum; eine Migration hebt alte `3`-Defaults auf `20` an. (`WhisperM8/Support/AppPreferences.swift:123`, `WhisperM8/Support/AppPreferences.swift:124`, `WhisperM8/Support/AppPreferences.swift:125`, `WhisperM8/Support/AppPreferences.swift:340`, `WhisperM8/Support/AppPreferences.swift:347`) |

### Max screen clip

| Aspekt | Wert |
|---|---|
| Control | Slider „Max screen clip" mit Bereich `5...60`, Schrittweite `5` und Sekundenanzeige. (`WhisperM8/Views/Settings/BehaviorSettingsView.swift:82`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:84`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:85`) |
| Default | `30` Sekunden; `@AppStorage` setzt lokal `30.0`, und `AppPreferences.maxScreenRecordingDuration` fällt bei fehlendem oder nichtpositivem Wert auf `30` zurück. (`WhisperM8/Views/Settings/BehaviorSettingsView.swift:14`, `WhisperM8/Support/AppPreferences.swift:132`, `WhisperM8/Support/AppPreferences.swift:134`, `WhisperM8/Support/AppPreferences.swift:135`) |
| Persistenz | UserDefaults-Key `maxScreenRecordingDuration`; exakter Key in `PreferenceKeys.maxScreenRecordingDuration`. (`WhisperM8/Views/Settings/BehaviorSettingsView.swift:14`, `WhisperM8/Support/AppPreferences.swift:137`, `WhisperM8/Support/AppPreferences.swift:377`) |
| Gelesen von | `RecordingCoordinator+Clipboard.scheduleScreenClipLimit` liest die Dauer. (`WhisperM8/Services/Dictation/RecordingCoordinator+Clipboard.swift:47`, `WhisperM8/Services/Dictation/RecordingCoordinator+Clipboard.swift:49`) |
| Wirkung | Nach Ablauf der eingestellten Dauer stoppt der Screen-Clip automatisch und wird als Kontext angehängt, sofern Recording und Clip noch aktiv sind. (`WhisperM8/Services/Dictation/RecordingCoordinator+Clipboard.swift:50`, `WhisperM8/Services/Dictation/RecordingCoordinator+Clipboard.swift:51`, `WhisperM8/Services/Dictation/RecordingCoordinator+Clipboard.swift:52`, `WhisperM8/Services/Dictation/RecordingCoordinator+Clipboard.swift:53`) |
| Abhängigkeiten | Der Slider gehört zur Visual-Context-Section, aber `startScreenClip` selbst prüft den globalen Visual-Context-Schalter nicht vor dem Start. (`WhisperM8/Views/Settings/BehaviorSettingsView.swift:73`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:82`, `WhisperM8/Services/Dictation/RecordingCoordinator+Clipboard.swift:9`, `WhisperM8/Services/Dictation/RecordingCoordinator+Clipboard.swift:13`) |

### Delete visual context files after processing

| Aspekt | Wert |
|---|---|
| Control | Toggle „Delete visual context files after processing". (`WhisperM8/Views/Settings/BehaviorSettingsView.swift:90`) |
| Default | `false`; `@AppStorage` setzt lokal `false`, und `AppPreferences.deleteContextFilesAfterProcessing` nutzt `boolWithDefault(false)`. (`WhisperM8/Views/Settings/BehaviorSettingsView.swift:15`, `WhisperM8/Support/AppPreferences.swift:140`, `WhisperM8/Support/AppPreferences.swift:141`) |
| Persistenz | UserDefaults-Key `deleteContextFilesAfterProcessing`; exakter Key in `PreferenceKeys.deleteContextFilesAfterProcessing`. (`WhisperM8/Views/Settings/BehaviorSettingsView.swift:15`, `WhisperM8/Support/AppPreferences.swift:142`, `WhisperM8/Support/AppPreferences.swift:378`) |
| Gelesen von | `VisualContextCaptureService.cleanup` liest den Schalter; `RecordingCoordinator+Transcription` ruft Cleanup am Ende erfolgreicher Delivery auf. (`WhisperM8/Services/Dictation/VisualContextCaptureService.swift:181`, `WhisperM8/Services/Dictation/VisualContextCaptureService.swift:182`, `WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:138`, `WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:139`) |
| Wirkung | Wenn aktiv, löscht Cleanup alle Kontext-Anhänge und separate Thumbnails aus dem Dateisystem; wenn inaktiv, kehrt Cleanup sofort zurück. (`WhisperM8/Services/Dictation/VisualContextCaptureService.swift:182`, `WhisperM8/Services/Dictation/VisualContextCaptureService.swift:184`, `WhisperM8/Services/Dictation/VisualContextCaptureService.swift:185`, `WhisperM8/Services/Dictation/VisualContextCaptureService.swift:186`, `WhisperM8/Services/Dictation/VisualContextCaptureService.swift:187`) |
| Abhängigkeiten | Das Löschen betrifft Anhänge im `TranscriptContextBundle`, die durch Screenshot-, Annotation-, Screen-Clip- oder Visual-Frame-Pfade entstehen. (`WhisperM8/Services/Dictation/RecordingCoordinator+Context.swift:192`, `WhisperM8/Services/Dictation/RecordingCoordinator+Context.swift:198`, `WhisperM8/Services/Dictation/RecordingCoordinator+Context.swift:205`, `WhisperM8/Services/Dictation/VisualContextCaptureService.swift:184`) |

### Reduce system volume while recording

| Aspekt | Wert |
|---|---|
| Control | Toggle „Reduce system volume while recording". (`WhisperM8/Views/Settings/BehaviorSettingsView.swift:98`) |
| Default | `true`; `@AppStorage` setzt lokal `true`, und `AppPreferences.isAudioDuckingEnabled` nutzt `boolWithDefault(true)`. (`WhisperM8/Views/Settings/BehaviorSettingsView.swift:6`, `WhisperM8/Support/AppPreferences.swift:46`, `WhisperM8/Support/AppPreferences.swift:47`) |
| Persistenz | UserDefaults-Key `audioDuckingEnabled`; exakter Key in `PreferenceKeys.audioDuckingEnabled`. (`WhisperM8/Views/Settings/BehaviorSettingsView.swift:6`, `WhisperM8/Support/AppPreferences.swift:48`, `WhisperM8/Support/AppPreferences.swift:361`) |
| Gelesen von | `AudioDuckingManager.isEnabled` liest `AppPreferences.shared.isAudioDuckingEnabled`; `RecordingCoordinator.startRecording` ruft `AudioDuckingManager.shared.beginCapture()` vor `audioRecorder.startRecording()`. (`WhisperM8/Services/Dictation/AudioDuckingManager.swift:78`, `WhisperM8/Services/Dictation/AudioDuckingManager.swift:80`, `WhisperM8/Services/Dictation/RecordingCoordinator.swift:145`, `WhisperM8/Services/Dictation/RecordingCoordinator.swift:146`, `WhisperM8/Services/Dictation/RecordingCoordinator.swift:147`) |
| Wirkung | Wenn aktiv, erfasst der Manager die aktuelle Output-Device-Lautstärke, senkt sie während der Aufnahme und stellt sie beim Stop wieder her; wenn inaktiv, verlässt `beginCapture` den Pfad ohne Ducking. (`WhisperM8/Services/Dictation/AudioDuckingManager.swift:95`, `WhisperM8/Services/Dictation/AudioDuckingManager.swift:97`, `WhisperM8/Services/Dictation/AudioDuckingManager.swift:119`, `WhisperM8/Services/Dictation/AudioDuckingManager.swift:123`, `WhisperM8/Services/Dictation/RecordingCoordinator.swift:307`, `WhisperM8/Services/Dictation/RecordingCoordinator.swift:308`) |
| Abhängigkeiten | Der Target-Volume-Slider ist in der UI nur sichtbar, wenn dieser Toggle aktiv ist. (`WhisperM8/Views/Settings/BehaviorSettingsView.swift:100`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:103`) |

### Target volume

| Aspekt | Wert |
|---|---|
| Control | Bedingt sichtbarer Slider „Target volume" mit Bereich `0.05...0.3`, Schrittweite `0.05` und Prozentanzeige. (`WhisperM8/Views/Settings/BehaviorSettingsView.swift:100`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:102`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:103`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:104`) |
| Default | `0.2` beziehungsweise 20 %; `@AppStorage` setzt lokal `0.2`, und `AppPreferences.audioDuckingFactor` fällt bei fehlendem oder nichtpositivem Wert auf `0.2` zurück. (`WhisperM8/Views/Settings/BehaviorSettingsView.swift:7`, `WhisperM8/Support/AppPreferences.swift:51`, `WhisperM8/Support/AppPreferences.swift:53`, `WhisperM8/Support/AppPreferences.swift:54`) |
| Persistenz | UserDefaults-Key `audioDuckingFactor`; exakter Key in `PreferenceKeys.audioDuckingFactor`. (`WhisperM8/Views/Settings/BehaviorSettingsView.swift:7`, `WhisperM8/Support/AppPreferences.swift:56`, `WhisperM8/Support/AppPreferences.swift:362`) |
| Gelesen von | `AudioDuckingManager.targetVolume` liest `AppPreferences.shared.audioDuckingFactor`. (`WhisperM8/Services/Dictation/AudioDuckingManager.swift:83`, `WhisperM8/Services/Dictation/AudioDuckingManager.swift:85`) |
| Wirkung | Der Wert wird als Ziel-Lautstärke verwendet, auf die kontrollierbare Output-Geräte während des Recordings geduckt werden. (`WhisperM8/Services/Dictation/AudioDuckingManager.swift:191`, `WhisperM8/Services/Dictation/AudioDuckingManager.swift:192`, `WhisperM8/Services/Dictation/AudioDuckingManager.swift:202`, `WhisperM8/Services/Dictation/AudioDuckingManager.swift:203`) |
| Abhängigkeiten | Der Manager clampet den gespeicherten Wert intern zusätzlich auf `0.01...1`, während die UI nur `0.05...0.3` anbietet. (`WhisperM8/Views/Settings/BehaviorSettingsView.swift:103`, `WhisperM8/Services/Dictation/AudioDuckingManager.swift:85`) |

### Overlay UI

| Aspekt | Wert |
|---|---|
| Control | Segmentierter `Picker("Overlay UI")` über `OverlayStyle.allCases` mit den Display-Namen „Full" und „Mini". (`WhisperM8/Views/Settings/BehaviorSettingsView.swift:116`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:117`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:121`, `WhisperM8/Windows/RecordingPanel.swift:4`, `WhisperM8/Windows/RecordingPanel.swift:8`) |
| Default | `OverlayStyle.mini`; `@AppStorage` setzt lokal `mini`, und `AppPreferences.overlayStyleRaw` fällt auf `OverlayStyle.mini.rawValue` zurück. (`WhisperM8/Views/Settings/BehaviorSettingsView.swift:8`, `WhisperM8/Support/AppPreferences.swift:59`, `WhisperM8/Support/AppPreferences.swift:60`) |
| Persistenz | UserDefaults-Key `overlayStyle`; exakter Key in `PreferenceKeys.overlayStyle` und zusätzlich als `OverlayPositionStore.styleKey` gespiegelt. (`WhisperM8/Views/Settings/BehaviorSettingsView.swift:8`, `WhisperM8/Support/AppPreferences.swift:61`, `WhisperM8/Support/AppPreferences.swift:363`, `WhisperM8/Windows/RecordingPanel.swift:43`, `WhisperM8/Windows/RecordingPanel.swift:44`) |
| Gelesen von | `OverlayPositionStore.loadStyle` liest den gespeicherten Stil; `OverlayController.show` und `OverlayController.update` übernehmen ihn ins Overlay. (`WhisperM8/Windows/RecordingPanel.swift:53`, `WhisperM8/Windows/RecordingPanel.swift:54`, `WhisperM8/Windows/RecordingPanel.swift:55`, `WhisperM8/Windows/RecordingPanel.swift:471`, `WhisperM8/Windows/RecordingPanel.swift:694`) |
| Wirkung | `full` rendert ein permanent expandiertes Overlay-Layout; `mini` rendert eine kompakte Pill, deren zusätzliche Controls per Hover expandieren. (`WhisperM8/Views/RecordingPillView.swift:35`, `WhisperM8/Views/RecordingPillView.swift:38`, `WhisperM8/Views/RecordingPillView.swift:51`, `WhisperM8/Views/RecordingPillView.swift:54`, `WhisperM8/Views/RecordingPillView.swift:112`, `WhisperM8/Views/RecordingPillView.swift:132`) |
| Abhängigkeiten | Der Stil beeinflusst Default-Positionierung und Legacy-Positionsmigration über `legacyPanelSize` und `defaultResolution`. (`WhisperM8/Windows/RecordingPanel.swift:17`, `WhisperM8/Windows/RecordingPanel.swift:19`, `WhisperM8/Windows/RecordingPanel.swift:100`, `WhisperM8/Windows/RecordingPanel.swift:102`, `WhisperM8/Windows/RecordingPanel.swift:110`, `WhisperM8/Windows/RecordingPanel.swift:114`) |

### Show Confirm Button (✓)

| Aspekt | Wert |
|---|---|
| Control | Toggle „Show Confirm Button (✓)" mit Hilfetext, dass der Button Recording stoppt und Transcription startet. (`WhisperM8/Views/Settings/BehaviorSettingsView.swift:123`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:125`) |
| Default | `true`; `@AppStorage` setzt lokal `true`, und `AppPreferences.showConfirmButtonInOverlay` nutzt `boolWithDefault(true)`. (`WhisperM8/Views/Settings/BehaviorSettingsView.swift:9`, `WhisperM8/Support/AppPreferences.swift:106`, `WhisperM8/Support/AppPreferences.swift:107`) |
| Persistenz | UserDefaults-Key `showConfirmButtonInOverlay`; exakter Key in `PreferenceKeys.showConfirmButtonInOverlay`. (`WhisperM8/Views/Settings/BehaviorSettingsView.swift:9`, `WhisperM8/Support/AppPreferences.swift:108`, `WhisperM8/Support/AppPreferences.swift:372`) |
| Gelesen von | `OverlayController.show` und `OverlayController.update` lesen den Wert in `showConfirmButton`; `RecordingPillView` rendert den Confirm-Button nur bei Recording-Phase und aktivem Wert. (`WhisperM8/Windows/RecordingPanel.swift:466`, `WhisperM8/Windows/RecordingPanel.swift:689`, `WhisperM8/Views/RecordingPillView.swift:57`, `WhisperM8/Views/RecordingPillView.swift:58`) |
| Wirkung | Wenn sichtbar, ruft der ✓-Button `stopAndTranscribe` auf und landet im gleichen Stop-Pfad wie der Hotkey. (`WhisperM8/Views/RecordingPillView.swift:57`, `WhisperM8/Views/RecordingPillView.swift:58`, `WhisperM8/Services/Dictation/RecordingCoordinator.swift:207`, `WhisperM8/Services/Dictation/RecordingCoordinator.swift:211`) |
| Abhängigkeiten | Der Button erscheint nur während `.recording`; der Cancel-Button bleibt daneben unabhängig sichtbar. (`WhisperM8/Views/RecordingPillView.swift:57`, `WhisperM8/Views/RecordingPillView.swift:62`) |

### Show mode picker in Mini overlay

| Aspekt | Wert |
|---|---|
| Control | Toggle „Show mode picker in Mini overlay" mit Hilfetext zum Hover-Verhalten. (`WhisperM8/Views/Settings/BehaviorSettingsView.swift:129`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:131`) |
| Default | `true`; `@AppStorage` setzt lokal `true`, und `AppPreferences.showModePickerInMiniOverlay` nutzt `boolWithDefault(true)`. (`WhisperM8/Views/Settings/BehaviorSettingsView.swift:10`, `WhisperM8/Support/AppPreferences.swift:99`, `WhisperM8/Support/AppPreferences.swift:100`) |
| Persistenz | UserDefaults-Key `showModePickerInMiniOverlay`; exakter Key in `PreferenceKeys.showModePickerInMiniOverlay`. (`WhisperM8/Views/Settings/BehaviorSettingsView.swift:10`, `WhisperM8/Support/AppPreferences.swift:101`, `WhisperM8/Support/AppPreferences.swift:371`) |
| Gelesen von | `OverlayController.show` und `OverlayController.update` lesen den Wert; `RecordingPillView.miniLayout` entscheidet damit, ob der Mode-Chip kollabiert sichtbar bleibt. (`WhisperM8/Windows/RecordingPanel.swift:465`, `WhisperM8/Windows/RecordingPanel.swift:688`, `WhisperM8/Views/RecordingPillView.swift:161`, `WhisperM8/Views/RecordingPillView.swift:163`) |
| Wirkung | Wenn aktiv, bleibt der Mode-Chip im Mini-Overlay permanent sichtbar; wenn inaktiv, erscheint er nur im Hover-Expand. (`WhisperM8/Views/RecordingPillView.swift:161`, `WhisperM8/Views/RecordingPillView.swift:163`, `WhisperM8/Views/RecordingPillView.swift:164`) |
| Abhängigkeiten | Derselbe Key wird auch auf der Modes-Seite unter „Behavior" als „Show mode chip in Mini overlay" angeboten. (`WhisperM8/Views/OutputModesView.swift:11`, `WhisperM8/Views/OutputModesView.swift:96`, `WhisperM8/Views/OutputModesView.swift:104`) |

### Reset Overlay Position

| Aspekt | Wert |
|---|---|
| Control | Button „Reset Overlay Position". (`WhisperM8/Views/Settings/BehaviorSettingsView.swift:135`) |
| Default | Kein gespeicherter Boolean-Wert; ohne Custom-Position nutzt das Overlay die per Stil berechnete Default-Position. (`WhisperM8/Windows/RecordingPanel.swift:91`, `WhisperM8/Windows/RecordingPanel.swift:93`, `WhisperM8/Windows/RecordingPanel.swift:488`, `WhisperM8/Windows/RecordingPanel.swift:489`) |
| Persistenz | Löscht UserDefaults-Keys `overlayPositionX`, `overlayPositionY`, `overlayAnchorMaxX`, `overlayAnchorMinX`, `overlayAnchorY`; die Legacy-Keys sind in `OverlayPositionStore` definiert, die Anchor-Keys ebenfalls. (`WhisperM8/Windows/RecordingPanel.swift:46`, `WhisperM8/Windows/RecordingPanel.swift:47`, `WhisperM8/Windows/RecordingPanel.swift:49`, `WhisperM8/Windows/RecordingPanel.swift:50`, `WhisperM8/Windows/RecordingPanel.swift:51`, `WhisperM8/Windows/RecordingPanel.swift:64`, `WhisperM8/Windows/RecordingPanel.swift:69`) |
| Gelesen von | `OverlayController.show` lädt gespeicherte Anchors über `OverlayPositionStore.loadAnchor`; Drags speichern Anchors über `OverlayPositionStore.saveAnchor`. (`WhisperM8/Windows/RecordingPanel.swift:480`, `WhisperM8/Windows/RecordingPanel.swift:484`, `WhisperM8/Windows/RecordingPanel.swift:487`, `WhisperM8/Windows/RecordingPanel.swift:496`, `WhisperM8/Windows/RecordingPanel.swift:502`) |
| Wirkung | Der Settings-Button löscht nur die gespeicherte Position; der Overlay-Doppelklick löscht dieselben Keys und animiert zusätzlich die aktuell sichtbare Pill zur Default-Position. (`WhisperM8/Views/Settings/BehaviorSettingsView.swift:135`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:136`, `WhisperM8/Windows/RecordingPanel.swift:827`, `WhisperM8/Windows/RecordingPanel.swift:838`, `WhisperM8/Windows/RecordingPanel.swift:850`) |
| Abhängigkeiten | Der Hilfetext nennt Dragging und Doppelklick-Reset als zweite Bedienmöglichkeit; das Hosting-View ruft bei Doppelklick `resetToDefaultPosition()` auf. (`WhisperM8/Views/Settings/BehaviorSettingsView.swift:139`, `WhisperM8/Windows/RecordingPanel.swift:513`, `WhisperM8/Windows/RecordingPanel.swift:514`) |

### Start at Login

| Aspekt | Wert |
|---|---|
| Control | `LaunchAtLogin.Toggle("Start at Login")`. (`WhisperM8/Views/Settings/BehaviorSettingsView.swift:145`) |
| Default | Kein `AppPreferences`-Default; der Toggle liest `SMAppService.mainApp.status == .enabled` als aktuellen macOS-Status. (`.build/checkouts/LaunchAtLogin-Modern/Sources/LaunchAtLogin/LaunchAtLogin.swift:13`, `.build/checkouts/LaunchAtLogin-Modern/Sources/LaunchAtLogin/LaunchAtLogin.swift:14`) |
| Persistenz | Kein UserDefaults-Key in `PreferenceKeys`; die Library registriert oder deregistriert `SMAppService.mainApp`. (`WhisperM8/Support/AppPreferences.swift:355`, `WhisperM8/Support/AppPreferences.swift:400`, `.build/checkouts/LaunchAtLogin-Modern/Sources/LaunchAtLogin/LaunchAtLogin.swift:19`, `.build/checkouts/LaunchAtLogin-Modern/Sources/LaunchAtLogin/LaunchAtLogin.swift:24`, `.build/checkouts/LaunchAtLogin-Modern/Sources/LaunchAtLogin/LaunchAtLogin.swift:26`) |
| Gelesen von | Die Library-View bindet einen SwiftUI-Toggle an `LaunchAtLogin.observable.isEnabled`, der wiederum `LaunchAtLogin.isEnabled` liest und schreibt. (`.build/checkouts/LaunchAtLogin-Modern/Sources/LaunchAtLogin/LaunchAtLogin.swift:46`, `.build/checkouts/LaunchAtLogin-Modern/Sources/LaunchAtLogin/LaunchAtLogin.swift:48`, `.build/checkouts/LaunchAtLogin-Modern/Sources/LaunchAtLogin/LaunchAtLogin.swift:51`, `.build/checkouts/LaunchAtLogin-Modern/Sources/LaunchAtLogin/LaunchAtLogin.swift:81`, `.build/checkouts/LaunchAtLogin-Modern/Sources/LaunchAtLogin/LaunchAtLogin.swift:96`) |
| Wirkung | Aktivieren registriert die Haupt-App als Login Item; Deaktivieren deregistriert sie. (`.build/checkouts/LaunchAtLogin-Modern/Sources/LaunchAtLogin/LaunchAtLogin.swift:19`, `.build/checkouts/LaunchAtLogin-Modern/Sources/LaunchAtLogin/LaunchAtLogin.swift:24`, `.build/checkouts/LaunchAtLogin-Modern/Sources/LaunchAtLogin/LaunchAtLogin.swift:25`, `.build/checkouts/LaunchAtLogin-Modern/Sources/LaunchAtLogin/LaunchAtLogin.swift:26`) |
| Abhängigkeiten | Das Paket ist als SwiftPM-Dependency eingebunden und wird in `BehaviorSettingsView` importiert. (`Package.swift:15`, `Package.swift:30`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:2`) |

## 4. Datenfluss & Persistenz

Die meisten Controls speichern sofort über `@AppStorage` in `UserDefaults`, weil die View die Keys direkt bindet. (`WhisperM8/Views/Settings/BehaviorSettingsView.swift:5`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:15`)

`AppPreferences` ist die typisierte Lese- und Schreibschicht über denselben `UserDefaults`-Speicher und definiert die zugehörigen `PreferenceKeys`. (`WhisperM8/Support/AppPreferences.swift:3`, `WhisperM8/Support/AppPreferences.swift:9`, `WhisperM8/Support/AppPreferences.swift:11`, `WhisperM8/Support/AppPreferences.swift:355`)

Der Profile-Picker ist nicht direkt `@AppStorage`, sondern hält lokalen `@State`, synchronisiert sich auf `onAppear` aus `AppPreferences` und schreibt Änderungen über `AppProfileActivator.apply`. (`WhisperM8/Views/Settings/BehaviorSettingsView.swift:18`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:28`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:149`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:151`, `WhisperM8/Services/Shared/AppProfileActivator.swift:13`, `WhisperM8/Services/Shared/AppProfileActivator.swift:14`)

Der Theme-Picker schreibt nicht direkt in `@AppStorage`, sondern ruft `ThemeManager.setOverride`, das persistiert, `NSApp.appearance` setzt und das aufgelöste Farbschema neu berechnet. (`WhisperM8/Views/Settings/BehaviorSettingsView.swift:38`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:40`, `WhisperM8/Support/ThemeManager.swift:55`, `WhisperM8/Support/ThemeManager.swift:59`, `WhisperM8/Support/ThemeManager.swift:63`, `WhisperM8/Support/ThemeManager.swift:64`)

Recording-bezogene Werte werden überwiegend live beim Start oder während der Pipeline gelesen: Auto-Paste bei Delivery, Selected Context beim Capture und Clipboard-Import, Visual Context beim Screenshot-Import, Audio-Ducking beim `beginCapture`, Overlay-Werte bei `show` und `update`. (`WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:61`, `WhisperM8/Services/Dictation/SelectedContextService.swift:10`, `WhisperM8/Services/Dictation/RecordingCoordinator+Clipboard.swift:92`, `WhisperM8/Services/Dictation/AudioDuckingManager.swift:96`, `WhisperM8/Windows/RecordingPanel.swift:465`, `WhisperM8/Windows/RecordingPanel.swift:466`, `WhisperM8/Windows/RecordingPanel.swift:471`, `WhisperM8/Windows/RecordingPanel.swift:688`, `WhisperM8/Windows/RecordingPanel.swift:694`)

Für die dokumentierten `AppPreferences`-Werte ist kein Neustart nötig, weil die relevanten Pfade die Werte beim nächsten Recording, beim Overlay-Update oder direkt beim Settings-Change erneut lesen. (`WhisperM8/Views/Settings/BehaviorSettingsView.swift:28`, `WhisperM8/Support/ThemeManager.swift:55`, `WhisperM8/Services/Dictation/RecordingCoordinator.swift:145`, `WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:61`, `WhisperM8/Windows/RecordingPanel.swift:688`)

Launch-at-Login ist der Sonderfall: Der Wert liegt nicht in `AppPreferences`, sondern wird über `SMAppService.mainApp` vom macOS-ServiceManagement verwaltet. (`.build/checkouts/LaunchAtLogin-Modern/Sources/LaunchAtLogin/LaunchAtLogin.swift:13`, `.build/checkouts/LaunchAtLogin-Modern/Sources/LaunchAtLogin/LaunchAtLogin.swift:24`, `.build/checkouts/LaunchAtLogin-Modern/Sources/LaunchAtLogin/LaunchAtLogin.swift:26`)

## 5. Querverweise

Die Onboarding-Konfiguration verwendet denselben `autoPasteEnabled`-Key und bietet dadurch einen zweiten Einstieg für Auto-Paste. (`WhisperM8/Views/OnboardingView.swift:581`, `WhisperM8/Views/OnboardingView.swift:669`)

Die Modes-Seite verwendet denselben `showModePickerInMiniOverlay`-Key und nennt ihn dort „Show mode chip in Mini overlay". (`WhisperM8/Views/OutputModesView.swift:11`, `WhisperM8/Views/OutputModesView.swift:96`, `WhisperM8/Views/OutputModesView.swift:104`)

Die Modes-Seite verweist bei gesperrtem Codex-Enrichment ausdrücklich auf „Behavior → Usage" als Ort zum Freischalten der Enrichment-Profile. (`WhisperM8/Views/OutputModesView.swift:21`, `WhisperM8/Views/OutputModesView.swift:34`)

Die Audio-Seite ist eine eigene App-Settings-Sektion neben Behavior, obwohl Audio-Ducking und Target Volume auf der Behavior-Seite liegen. (`WhisperM8/Views/SettingsView.swift:15`, `WhisperM8/Views/SettingsView.swift:16`, `WhisperM8/Views/SettingsView.swift:235`, `WhisperM8/Views/SettingsView.swift:239`)

Die Hotkey-Seite ist ebenfalls eine eigene App-Settings-Sektion, während der Confirm-Button explizit als äquivalent zum Hotkey-Stop beschrieben wird. (`WhisperM8/Views/SettingsView.swift:14`, `WhisperM8/Views/SettingsView.swift:232`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:125`, `WhisperM8/Services/Dictation/RecordingCoordinator.swift:207`)

Die App-Scenes wenden den Theme-Override auf Agent-Chats-Fenster, Menüleisten-View, Settings und Onboarding an. (`WhisperM8/WhisperM8App.swift:38`, `WhisperM8/WhisperM8App.swift:64`, `WhisperM8/WhisperM8App.swift:73`, `WhisperM8/WhisperM8App.swift:86`, `WhisperM8/WhisperM8App.swift:95`)

## 6. UX-Beobachtungen (Rohmaterial fürs Redesign)

Die Seite hat klaren Sammelbecken-Charakter: Profil, Theme, Auto-Paste, Textkontext, Screenshot-/Clip-Kontext, Audio-Ducking, Overlay-Anatomie, Overlay-Position und Login-Start liegen zusammen unter „Behavior", obwohl die Sidebar bereits eigene Bereiche für Output, Hotkey und Audio hat. (`WhisperM8/Views/Settings/BehaviorSettingsView.swift:22`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:37`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:55`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:65`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:73`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:97`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:115`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:144`, `WhisperM8/Views/SettingsView.swift:14`, `WhisperM8/Views/SettingsView.swift:15`)

Audio-Ducking wirkt thematisch eher wie „Audio", weil es Systemlautstärke und Target Volume steuert, während die Audio-Seite separat existiert. (`WhisperM8/Views/Settings/BehaviorSettingsView.swift:97`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:98`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:102`, `WhisperM8/Views/SettingsView.swift:15`, `WhisperM8/Views/SettingsView.swift:235`)

Der Confirm-Button ist inhaltlich ein Hotkey-/Recording-Control, weil der Hilfetext ihn als denselben Stop-und-Transcribe-Pfad wie den Hotkey beschreibt. (`WhisperM8/Views/Settings/BehaviorSettingsView.swift:123`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:125`, `WhisperM8/Services/Dictation/RecordingCoordinator.swift:207`, `WhisperM8/Services/Dictation/RecordingCoordinator.swift:211`)

Der Mini-Mode-Picker ist eine Output-/Modes-Option und taucht doppelt auf: einmal in Behavior als „Show mode picker in Mini overlay" und einmal in Modes als „Show mode chip in Mini overlay". (`WhisperM8/Views/Settings/BehaviorSettingsView.swift:129`, `WhisperM8/Views/OutputModesView.swift:96`, `WhisperM8/Views/OutputModesView.swift:104`)

„Profile" ist fachlich sehr mächtig, aber der Section-Name „Usage" und die Sidebar-Bezeichnung „Behavior" machen nicht unmittelbar sichtbar, dass hier Dock-App vs. Menüleisten-App, Agent Chats und Codex-Enrichment geschaltet werden. (`WhisperM8/Views/Settings/BehaviorSettingsView.swift:22`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:23`, `WhisperM8/Models/AppUsageProfile.swift:20`, `WhisperM8/Models/AppUsageProfile.swift:28`, `WhisperM8/Models/AppUsageProfile.swift:33`)

Die Benennung ist teilweise uneinheitlich: Die UI mischt Deutsch („Erscheinungsbild", „Hell", „Dunkel") mit Englisch („Usage", „Profile", „Selected Context", „Visual Context", „Audio Ducking", „Recording Overlay", „Start at Login"). (`WhisperM8/Views/Settings/BehaviorSettingsView.swift:22`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:23`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:37`, `WhisperM8/Support/AppearanceOverride.swift:17`, `WhisperM8/Support/AppearanceOverride.swift:18`, `WhisperM8/Support/AppearanceOverride.swift:19`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:65`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:73`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:97`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:115`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:145`)

Die „Visual Context"-Section zeigt Stepper, Slider und Delete-Toggle auch dann an, wenn „Allow screenshots and screen clips as context" ausgeschaltet ist; nur die Audio-Ducking-Section blendet ihr abhängiges Detail-Control bedingt aus. (`WhisperM8/Views/Settings/BehaviorSettingsView.swift:74`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:76`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:82`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:90`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:100`)

„Reset Overlay Position" hat als Settings-Button keinen unmittelbaren sichtbaren Effekt, wenn das Overlay gerade nicht offen ist; der gleiche Reset ist im Overlay über Doppelklick mit Animation implementiert. (`WhisperM8/Views/Settings/BehaviorSettingsView.swift:135`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:136`, `WhisperM8/Windows/RecordingPanel.swift:827`, `WhisperM8/Windows/RecordingPanel.swift:838`, `WhisperM8/Windows/RecordingPanel.swift:850`)

## 7. Offene Fragen

Der exakte macOS-Speicherort des Login-Item-Status ist aus dem Repo nicht sichtbar, weil `LaunchAtLogin.Toggle` über `SMAppService.mainApp` liest und schreibt statt über `AppPreferences` oder `PreferenceKeys`. (`.build/checkouts/LaunchAtLogin-Modern/Sources/LaunchAtLogin/LaunchAtLogin.swift:13`, `.build/checkouts/LaunchAtLogin-Modern/Sources/LaunchAtLogin/LaunchAtLogin.swift:24`, `WhisperM8/Support/AppPreferences.swift:355`, `WhisperM8/Support/AppPreferences.swift:400`)

Unklar bleibt aus dem Code, ob „Max screen clip" bei deaktiviertem Visual-Context-Toggle bewusst weiter steuerbar bleiben soll, weil `startScreenClip` selbst keinen Guard auf `isVisualContextCaptureEnabled` enthält, während Screenshot-Pfade diesen Guard haben. (`WhisperM8/Views/Settings/BehaviorSettingsView.swift:74`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:82`, `WhisperM8/Services/Dictation/RecordingCoordinator+Clipboard.swift:9`, `WhisperM8/Services/Dictation/RecordingCoordinator+Clipboard.swift:13`, `WhisperM8/Services/Dictation/RecordingCoordinator+Context.swift:112`, `WhisperM8/Services/Dictation/RecordingCoordinator+Clipboard.swift:214`)

Zu validieren ist, ob die doppelte Platzierung von `showModePickerInMiniOverlay` in Behavior und Modes beabsichtigt ist oder im Redesign zusammengeführt werden soll. (`WhisperM8/Views/Settings/BehaviorSettingsView.swift:129`, `WhisperM8/Views/OutputModesView.swift:104`)
