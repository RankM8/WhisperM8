---
description: Settings-Dokumentation nach dem Refactor 2026-07-06 mit 10 Seiten, Legacy-Aliasen und Architekturverweisen.
description_long: |
  Übersicht über die aktuelle Settings-Dokumentation von WhisperM8 nach dem
  Settings-Refactor vom 2026-07-06. Beschrieben werden die 10 neuen SettingsPage-
  Seiten in den Gruppen Dictation, Agents, App und Workspace, die Alias-Zuordnung
  der historischen 15 Seiten sowie die Kit/Models/Pages-Architektur.
updated: 2026-07-06 14:05
---

# Settings

Das Settings-Fenster nutzt seit dem Refactor vom **2026-07-06** eine
10-Seiten-Struktur. Die frühere 15-Seiten-Dokumentation bleibt als historische
Referenz erhalten, beschreibt aber den Stand vor dem Refactor.

Aktuelle Code-Aufhängung: `SettingsPage` und `SettingsView` in
`WhisperM8/Views/SettingsView.swift`. Die UI liegt in
`WhisperM8/Views/Settings/Pages/`, gemeinsame Bausteine in
`WhisperM8/Views/Settings/Kit/`, testbare Zustandsmodelle in
`WhisperM8/Views/Settings/Models/`.

## Aktuelle 10 Seiten

| Gruppe | Seite | Route | Page-Datei | Inhalt |
|---|---|---|---|---|
| Dictation | Recording | `recording` | `RecordingSettingsPage.swift` | Hotkey, Mikrofon, Audio-Ducking, Overlay und Auto-Paste. |
| Dictation | Transcription | `transcription` | `TranscriptionSettingsPage.swift` | Transcription-Provider, API-Key, Modell, Preisstand und Sprache. |
| Dictation | AI Output | `ai-output` | `AIOutputSettingsPage.swift` | Codex-Account, Defaults, Modes, Templates und Test Lab als Tabs. |
| Dictation | Context & Privacy | `context` | `ContextPrivacySettingsPage.swift` | Selected Context, Visual Context und Privacy-Hinweise. |
| Agents | Agent Chats | `agent-chats` | `AgentChatsSettingsPage.swift` | Workspace, Notifications, Claude Hooks und Advanced als Tabs. |
| Agents | CLI & Skills | `cli` | `CLISkillsSettingsPage.swift` | CLI-Symlink, Schnellstart-Befehle und installierbare Skills. |
| App | General | `general` | `GeneralSettingsPage.swift` | Usage Profile, Start at Login, Theme und Update-Checks. |
| App | Permissions | `permissions` | `PermissionsSettingsPage.swift` | Microphone, Accessibility und optional Screen Recording. |
| App | About | `about` | `AboutSettingsPage.swift` | Version, Updates und Hersteller-Link. |
| Workspace | Output | `output` | `OutputWorkspacePage.swift` | Latest Run, Output-Archiv, Filter und Löschaktion. |

## Legacy-Aliasse

Alte Deep-Links bleiben kompatibel. `SettingsPage.page(routeID:)` mappt die
historischen Route-IDs auf die neuen Seiten; `applyTabAlias(routeID:)` setzt
zusätzlich die passenden Tabs für AI Output und Agent Chats.

| Historische Doc | Alte Seite | Neue Seite | Neue Page-Datei | Doku-Verweis |
|---|---|---|---|---|
| [01-transcription-api.md](01-transcription-api.md) | Transcription API | Transcription | `TranscriptionSettingsPage.swift` | [Aktuelle 10 Seiten](#aktuelle-10-seiten) |
| [02-codex-chatgpt.md](02-codex-chatgpt.md) | Codex / ChatGPT | AI Output | `AIOutputSettingsPage.swift` / `AIOutputAccountTab.swift` | [AI Output Tabs](ARCHITEKTUR.md#pages) |
| [03-output-overview.md](03-output-overview.md) | Output Overview | Output | `OutputWorkspacePage.swift` | [Output](ARCHITEKTUR.md#pages) |
| [04-history.md](04-history.md) | History | Output | `OutputWorkspacePage.swift` | [Output](ARCHITEKTUR.md#pages) |
| [05-modes.md](05-modes.md) | Modes | AI Output | `AIOutputSettingsPage.swift` / `AIOutputModesTab.swift` | [AI Output Tabs](ARCHITEKTUR.md#pages) |
| [06-templates.md](06-templates.md) | Templates | AI Output | `AIOutputSettingsPage.swift` / `AIOutputTemplatesTab.swift` | [AI Output Tabs](ARCHITEKTUR.md#pages) |
| [07-test-lab.md](07-test-lab.md) | Test Lab | AI Output | `AIOutputSettingsPage.swift` / `AIOutputTestLabTab.swift` | [AI Output Tabs](ARCHITEKTUR.md#pages) |
| [08-agent-chats.md](08-agent-chats.md) | Agent Chats | Agent Chats | `AgentChatsSettingsPage.swift` | [Agent Chats](ARCHITEKTUR.md#pages) |
| [09-claude-code.md](09-claude-code.md) | Claude Code | Agent Chats | `AgentChatsSettingsPage.swift` | [Agent Chats](ARCHITEKTUR.md#pages) |
| [10-permissions.md](10-permissions.md) | Permissions | Permissions | `PermissionsSettingsPage.swift` | [Permissions](ARCHITEKTUR.md#pages) |
| [11-hotkey.md](11-hotkey.md) | Hotkey | Recording | `RecordingSettingsPage.swift` | [Recording](ARCHITEKTUR.md#pages) |
| [12-audio.md](12-audio.md) | Audio | Recording | `RecordingSettingsPage.swift` | [Recording](ARCHITEKTUR.md#pages) |
| [13-behavior.md](13-behavior.md) | Behavior | Recording / Context & Privacy / General | `RecordingSettingsPage.swift`, `ContextPrivacySettingsPage.swift`, `GeneralSettingsPage.swift` | [Strukturvertrag](ARCHITEKTUR.md#kompatibilitätsvertrag) |
| [14-cli-skill.md](14-cli-skill.md) | CLI & Skill | CLI & Skills | `CLISkillsSettingsPage.swift` | [CLI & Skills](ARCHITEKTUR.md#pages) |
| [15-about.md](15-about.md) | About | About | `AboutSettingsPage.swift` | [About](ARCHITEKTUR.md#pages) |

## Architektur

Die aktuelle Struktur ist in [ARCHITEKTUR.md](ARCHITEKTUR.md) dokumentiert:

- Routing und Alias-Vertrag in `SettingsView.swift`.
- Wiederverwendbare SettingsKit-Bausteine unter `Views/Settings/Kit/`.
- Testbare ViewModels unter `Views/Settings/Models/`.
- Page-Komposition unter `Views/Settings/Pages/`.
- Kompatibilitätsvertrag und Test-Landschaft.

## Historische Referenzen

Die 15 historischen Referenzdateien bleiben bewusst im Ordner. Jede Datei trägt
oben einen Warnblock mit Zielseite und Doku-Verweis. Sie dienen nur noch als
Migrations- und Review-Material für Inhalte vor dem Refactor vom 2026-07-06.
