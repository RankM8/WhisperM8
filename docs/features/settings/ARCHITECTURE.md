---
description: Architektur der aktuellen Settings-Seiten nach dem Refactor 2026-07-06.
description_long: |
  Beschreibt das SettingsPage-Routing, Legacy-Aliasse, SettingsKit-Bausteine,
  ViewModels, Page-Komposition, Kompatibilitätsvertrag und Testabdeckung der
  Settings-Architektur. Alle Belege verweisen auf den aktuellen Code-Stand nach
  dem Refactor.
updated: 2026-07-06 14:05
---

# Settings-Architektur

Die Settings-Architektur ist nach dem Refactor vom **2026-07-06** dreigeteilt:
`SettingsView.swift` routet Seiten und Legacy-Aliasse, `Views/Settings/Kit/`
stellt wiederverwendbare UI-Bausteine bereit, `Views/Settings/Models/` kapselt
testbare Zustandslogik und `Views/Settings/Pages/` enthält die eigentlichen
Settings-Seiten.

## Routing

`SettingsPage` definiert die 10 aktuellen Seiten als `CaseIterable`-Enum:
`recording`, `transcription`, `ai-output`, `context`, `agent-chats`, `cli`,
`general`, `permissions`, `about` und `output`
(`WhisperM8/Views/SettingsView.swift:3`). Jede Seite hat Titel, SF-Symbol und
Subtitle in derselben Datei (`WhisperM8/Views/SettingsView.swift:46`,
`WhisperM8/Views/SettingsView.swift:71`, `WhisperM8/Views/SettingsView.swift:96`).

Die Sidebar gruppiert die Seiten in vier Gruppen:

| Gruppe | Seiten | Code-Beleg |
|---|---|---|
| Dictation | Recording, Transcription, AI Output, Context & Privacy | `WhisperM8/Views/SettingsView.swift:136` |
| Agents | Agent Chats, CLI & Skills | `WhisperM8/Views/SettingsView.swift:138` |
| App | General, Permissions, About | `WhisperM8/Views/SettingsView.swift:139` |
| Workspace | Output | `WhisperM8/Views/SettingsView.swift:140` |

`SettingsView` nutzt bewusst einen statischen `ScrollView` statt
`List(selection:)`, damit die Sidebar beim Öffnen keinen falschen Scroll-Offset
annimmt (`WhisperM8/Views/SettingsView.swift:145`). Die Detailseite wird über
`detailView(for:)` aufgelöst (`WhisperM8/Views/SettingsView.swift:255`).

## Kompatibilitätsvertrag

Der Kompatibilitätsvertrag ist: neue Routes werden direkt über den Raw-Value
aufgelöst, alte Route-IDs bleiben als Aliasse gültig. `SettingsPage.page(routeID:)`
prüft zuerst den neuen Raw-Value und mappt danach historische IDs
(`WhisperM8/Views/SettingsView.swift:17`).

| Alte Route-ID | Neue Seite | Zusatzverhalten |
|---|---|---|
| `api` | Transcription | Kein Tab. |
| `codex` | AI Output | Tab `Account & Defaults`. |
| `modes` | AI Output | Tab `Modes`. |
| `templates` | AI Output | Tab `Templates`. |
| `testLab` | AI Output | Tab `Test Lab`. |
| `outputOverview`, `history` | Output | Fusionierte Seite ohne Tab. |
| `agentChats` | Agent Chats | Tab `Workspace`. |
| `claudeCode` | Agent Chats | Tab `Claude Hooks`. |
| `hotkey`, `audio` | Recording | Fusionierte Seite ohne Tab. |
| `behavior` | General | Der alte Inhalt ist auf Recording, Context & Privacy und General verteilt. |
| `permissions`, `cli`, `about` | Gleichnamige neue Seite | Direkter Alias. |

`applyTabAlias(routeID:)` hält alte Deep-Links auf Tab-Ebene kompatibel:
`codex`, `modes`, `templates` und `testLab` setzen den AI-Output-Tab;
`agentChats` und `claudeCode` setzen den Agent-Chats-Tab
(`WhisperM8/Views/SettingsView.swift:188`). Für `outputOverview` und `history`
gibt es nach der Fusion bewusst keinen Zusatz-State
(`WhisperM8/Views/SettingsView.swift:203`).

## Kit

`Views/Settings/Kit/` enthält die wiederverwendbaren Zeilen, Panels und
Feedback-Helfer. Die Bausteine sind klein gehalten und verwenden AppTheme-Tokens
statt lokaler Farbwerte.

| Baustein | Zweck | Code-Beleg |
|---|---|---|
| `SettingsSection` | Einheitlicher Abschnitt mit Überschrift und Trennlinie. | `WhisperM8/Views/Settings/Kit/SettingsSection.swift:3` |
| `SettingsRow` | Baseline für Label, Subtitle und trailing Control. | `WhisperM8/Views/Settings/Kit/SettingsRow.swift:3` |
| `SettingsToggleRow`, `SettingsPickerRow`, `SettingsSliderRow`, `SettingsStepperRow` | Standardisierte Controls für boolesche, Auswahl- und numerische Werte. | `WhisperM8/Views/Settings/Kit/SettingsToggleRow.swift:3`, `WhisperM8/Views/Settings/Kit/SettingsPickerRow.swift:3`, `WhisperM8/Views/Settings/Kit/SettingsSliderRow.swift:3`, `WhisperM8/Views/Settings/Kit/SettingsStepperRow.swift:3` |
| `SettingsStatusRow`, `SettingsStatusTone` | Statuszeilen mit Ton-Mapping auf AppTheme-Tokens. | `WhisperM8/Views/Settings/Kit/SettingsStatusRow.swift:3`, `WhisperM8/Views/Settings/Kit/SettingsStatusTone.swift:3` |
| `SettingsTabs` | Tab-Auswahlmodell für AI Output und Agent Chats. | `WhisperM8/Views/Settings/Kit/SettingsTabs.swift:3` |
| `SettingsCopyCommandRow`, `ClipboardClient`, `SettingsFeedbackState` | Kopieraktionen mit injizierbarem Clipboard und kurzlebigem Feedback. | `WhisperM8/Views/Settings/Kit/SettingsCopyCommandRow.swift:3`, `WhisperM8/Views/Settings/Kit/ClipboardClient.swift:3`, `WhisperM8/Views/Settings/Kit/SettingsFeedbackState.swift:4` |

## Models

Die Models kapseln Logik, die ohne SwiftUI-Rendering testbar bleiben soll.

| Model | Verantwortung | Code-Beleg |
|---|---|---|
| `CodexConnectionModel` | Codex-Status und CLI-Version (Modell-Warnungen sind katalogbasiert in den Views, via `CodexModelCatalog`). | `WhisperM8/Views/Settings/Models/CodexConnectionModel.swift:4` |
| `OutputModesViewModel` | Modes laden, aktivieren, Defaults setzen, Custom Modes verwalten. | `WhisperM8/Views/Settings/Models/OutputModesViewModel.swift:4` |
| `TemplateEditorModel` | Templates laden, duplizieren, validieren und speichern. | `WhisperM8/Views/Settings/Models/TemplateEditorModel.swift:4` |
| `OutputArchiveViewModel` | Persistierte Reports laden, filtern, selektieren und löschen. | `WhisperM8/Views/Settings/Models/OutputArchiveViewModel.swift:30` |
| `PermissionSettingsModel` | Berechtigungsstatus, Header-Ton und cancellable Polling. | `WhisperM8/Views/Settings/Models/PermissionSettingsModel.swift:4` |
| `AgentCLIArgumentsPreview` | Kleine Parser-/Renderer-Logik für Agent-CLI-Argumentvorschau. | `WhisperM8/Views/Settings/Models/AgentCLIArgumentsPreview.swift:3` |

## Pages

Jede sichtbare Settings-Seite lebt unter `Views/Settings/Pages/`. Fusionierte
Seiten bündeln ehemalige Einzelseiten, Tabs halten detaillierte Unterbereiche
auffindbar.

| Neue Seite | Page-Datei | Inhalt / belegte Struktur |
|---|---|---|
| Recording | `RecordingSettingsPage.swift` | Hotkey, Mikrofon, Audio Ducking, Recording Overlay und Auto-Paste (`WhisperM8/Views/Settings/Pages/RecordingSettingsPage.swift:24`, `WhisperM8/Views/Settings/Pages/RecordingSettingsPage.swift:38`, `WhisperM8/Views/Settings/Pages/RecordingSettingsPage.swift:52`, `WhisperM8/Views/Settings/Pages/RecordingSettingsPage.swift:68`). |
| Transcription | `TranscriptionSettingsPage.swift` | Provider, API-Key, Modell, Preis und Sprache (`WhisperM8/Views/Settings/Pages/TranscriptionSettingsPage.swift:35`, `WhisperM8/Views/Settings/Pages/TranscriptionSettingsPage.swift:67`, `WhisperM8/Views/Settings/Pages/TranscriptionSettingsPage.swift:90`). |
| AI Output | `AIOutputSettingsPage.swift` | Tabs `Account & Defaults`, `Modes`, `Templates`, `Test Lab` (`WhisperM8/Views/Settings/Pages/AIOutputSettingsPage.swift:3`, `WhisperM8/Views/Settings/Pages/AIOutputSettingsPage.swift:67`). |
| Context & Privacy | `ContextPrivacySettingsPage.swift` | Text Context, Visual Context und Privacy-Hinweise (`WhisperM8/Views/Settings/Pages/ContextPrivacySettingsPage.swift:15`, `WhisperM8/Views/Settings/Pages/ContextPrivacySettingsPage.swift:23`, `WhisperM8/Views/Settings/Pages/ContextPrivacySettingsPage.swift:51`). |
| Agent Chats | `AgentChatsSettingsPage.swift` | Tabs `Workspace`, `Notifications`, `Claude Hooks`, `Advanced` (`WhisperM8/Views/Settings/Pages/AgentChatsSettingsPage.swift:5`, `WhisperM8/Views/Settings/Pages/AgentChatsSettingsPage.swift:68`). |
| CLI & Skills | `CLISkillsSettingsPage.swift` | CLI-Symlink, Befehlsbeispiele und Skills (`WhisperM8/Views/Settings/Pages/CLISkillsSettingsPage.swift:39`, `WhisperM8/Views/Settings/Pages/CLISkillsSettingsPage.swift:61`, `WhisperM8/Views/Settings/Pages/CLISkillsSettingsPage.swift:86`, `WhisperM8/Views/Settings/Pages/CLISkillsSettingsPage.swift:115`). |
| General | `GeneralSettingsPage.swift` | Usage Profile, Startup, Appearance und Updates (`WhisperM8/Views/Settings/Pages/GeneralSettingsPage.swift:17`, `WhisperM8/Views/Settings/Pages/GeneralSettingsPage.swift:30`, `WhisperM8/Views/Settings/Pages/GeneralSettingsPage.swift:38`, `WhisperM8/Views/Settings/Pages/GeneralSettingsPage.swift:54`). |
| Permissions | `PermissionsSettingsPage.swift` | Required- und Optional-Permissions mit Polling (`WhisperM8/Views/Settings/Pages/PermissionsSettingsPage.swift:16`, `WhisperM8/Views/Settings/Pages/PermissionsSettingsPage.swift:30`, `WhisperM8/Views/Settings/Pages/PermissionsSettingsPage.swift:54`). |
| About | `AboutSettingsPage.swift` | App-Info, Version, Updates und Hersteller-Link (`WhisperM8/Views/Settings/Pages/AboutSettingsPage.swift:34`, `WhisperM8/Views/Settings/Pages/AboutSettingsPage.swift:39`, `WhisperM8/Views/Settings/Pages/AboutSettingsPage.swift:68`, `WhisperM8/Views/Settings/Pages/AboutSettingsPage.swift:85`). |
| Output | `OutputWorkspacePage.swift` | Latest Run und Archiv-Workspace mit Filter/Delete (`WhisperM8/Views/Settings/Pages/OutputWorkspacePage.swift:19`, `WhisperM8/Views/Settings/Pages/OutputWorkspacePage.swift:66`, `WhisperM8/Views/Settings/Pages/OutputWorkspacePage.swift:88`). |

## Test-Landschaft

| Testdatei | Deckt ab |
|---|---|
| `Tests/WhisperM8Tests/SettingsRouteMappingTests.swift` | Legacy-Route-IDs, Raw-Value-Routing und unbekannte Routes (`Tests/WhisperM8Tests/SettingsRouteMappingTests.swift:5`). |
| `Tests/WhisperM8Tests/SettingsKitTests.swift` | Feedback-State, Copy-Action, Status-Ton-Mapping und Tab-Selection-Fallbacks (`Tests/WhisperM8Tests/SettingsKitTests.swift:6`, `Tests/WhisperM8Tests/SettingsKitTests.swift:46`, `Tests/WhisperM8Tests/SettingsKitTests.swift:61`, `Tests/WhisperM8Tests/SettingsKitTests.swift:71`). |
| `Tests/WhisperM8Tests/SettingsSourceGuardTests.swift` | `@AppStorage`-Keys müssen in `PreferenceKeys` oder als UI-State-Ausnahme dokumentiert sein (`Tests/WhisperM8Tests/SettingsSourceGuardTests.swift:5`). |
| `Tests/WhisperM8Tests/AIOutputModelsTests.swift` | Codex-Connection, OutputModes- und TemplateEditor-Modelle (`Tests/WhisperM8Tests/AIOutputModelsTests.swift:16`, `Tests/WhisperM8Tests/AIOutputModelsTests.swift:33`, `Tests/WhisperM8Tests/AIOutputModelsTests.swift:113`). |
| `Tests/WhisperM8Tests/OutputArchiveViewModelTests.swift` | Latest-Report-Quelle, Filterdelegation, Delete und Selection im Output-Archiv (`Tests/WhisperM8Tests/OutputArchiveViewModelTests.swift:7`, `Tests/WhisperM8Tests/OutputArchiveViewModelTests.swift:28`, `Tests/WhisperM8Tests/OutputArchiveViewModelTests.swift:79`, `Tests/WhisperM8Tests/OutputArchiveViewModelTests.swift:93`). |
| `Tests/WhisperM8Tests/PermissionSettingsModelTests.swift` | Header-Ton, Required-vs.-Optional-Logik und cancellable Polling (`Tests/WhisperM8Tests/PermissionSettingsModelTests.swift:7`, `Tests/WhisperM8Tests/PermissionSettingsModelTests.swift:43`, `Tests/WhisperM8Tests/PermissionSettingsModelTests.swift:70`). |
| `Tests/WhisperM8Tests/AgentCLIArgumentsPreviewTests.swift` | Agent-Argumentparser und Preview-Rendering (`Tests/WhisperM8Tests/AgentCLIArgumentsPreviewTests.swift:4`). |
| `Tests/WhisperM8Tests/OutputModeCompatTests.swift` | JSON-Kompatibilität alter Output-Modes und Normalisierung (`Tests/WhisperM8Tests/OutputModeCompatTests.swift:19`). |

## Pflege-Regeln

- Neue Settings-Seiten werden in `SettingsPage`, `pageGroups`, `detailView(for:)`
  und `SettingsRouteMappingTests` nachgezogen.
- Neue wiederverwendbare Controls gehören nach `Views/Settings/Kit/` und sollten
  eine fokussierte Model- oder Kit-Abdeckung in `SettingsKitTests` bekommen.
- Neue persistente `@AppStorage`-Keys müssen über `PreferenceKeys` laufen oder
  bewusst in `SettingsSourceGuardTests` als UI-State-Ausnahme dokumentiert werden.
- Alte Route-IDs dürfen nur entfernt werden, wenn der Kompatibilitätsvertrag hier
  und in `SettingsRouteMappingTests` bewusst geändert wird.
