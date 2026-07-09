---
description: Settings-Seite „Codex / ChatGPT" — vollständige Referenz aller Controls, Persistenzstellen und Wirkungen
description_long: |
  Vollständige Referenz der Settings-Seite „Codex / ChatGPT" im Settings-Fenster.
  Dokumentiert sind alle sichtbaren, dynamischen und bedingt sichtbaren Controls mit
  Defaultwerten, Persistenzorten, Aufrufstellen, konkreter Wirkung im Diktat- und
  Agent-Chat-Pfad sowie UX-Beobachtungen für das Settings-Redesign.
updated: 2026-07-06 14:05
status: ✅ Validiert (Opus-Gegenprüfung 2026-07-06, 0 Fehler)
---

> ⚠️ HISTORISCH (Stand vor Refactor 2026-07-06) — Inhalte beschreiben die alte Seite; neue Seite: `AIOutputSettingsPage.swift` / `AIOutputAccountTab.swift` + Doku-Verweis [ARCHITEKTUR: Pages](../../features/settings/ARCHITECTURE.md#pages).

# Settings: Codex / ChatGPT

> **Sidebar-Gruppe:** Accounts · **View:** `WhisperM8/Views/CodexSettingsView.swift` · **Enum-Case:** `ControlCenterSection.codex` (`WhisperM8/Views/SettingsView.swift`)
>
> **Primäre Quell-Dateien:** `CodexSettingsView.swift`, `Services/Dictation/PostProcessingService*`, `Support/AppPreferences.swift`

## 1. Zweck & Überblick

Die Seite bündelt den ChatGPT-/Codex-Zugang für Codex-gestütztes Post-Processing und die globalen Codex-Defaults für Modell, Thinking, Speed und visuelle Eingaben; sie steht als `ControlCenterSection.codex` unter der Sidebar-Gruppe „Accounts" und rendert `CodexSettingsView()` im Detailbereich (`WhisperM8/Views/SettingsView.swift:5`, `WhisperM8/Views/SettingsView.swift:98`, `WhisperM8/Views/SettingsView.swift:207`). Sie richtet sich an Nutzer, die Enrichment-Modi wie Clean/Email/Slack nutzen, weil alle nicht-Raw-Modi über Codex-Post-Processing laufen (`WhisperM8/Models/OutputMode.swift:29`, `WhisperM8/Models/OutputMode.swift:33`). Die Seite ist außerdem die manuelle Diagnosefläche für Codex-Installation, ChatGPT-Login und Codex-CLI-Version, weil `refresh()` beim Öffnen Status und Version direkt über `CodexStatusProbe` abfragt (`WhisperM8/Views/CodexSettingsView.swift:126`, `WhisperM8/Views/CodexSettingsView.swift:131`). Die Transcription-API-Keys sind ausdrücklich getrennt, denn die Codex-Seite sagt, dass der Codex-CLI-Login separat vom OpenAI-Transcription-API-Key ist und WhisperM8 keine ChatGPT-Browser-Sessions oder privaten Tokens liest (`WhisperM8/Views/CodexSettingsView.swift:51`).

## 2. UI-Aufbau

Die Seite ist ein grouped SwiftUI-`Form` mit vier Sections und Navigationstitel „Codex" (`WhisperM8/Views/CodexSettingsView.swift:31`, `WhisperM8/Views/CodexSettingsView.swift:123`, `WhisperM8/Views/CodexSettingsView.swift:124`, `WhisperM8/Views/CodexSettingsView.swift:125`).

1. „ChatGPT Subscription via Codex" zeigt zuerst eine Statuszeile, danach zwei Buttons für Login/Reconnect und erneute Prüfung sowie einen erklärenden Hinweis zur Trennung vom Transcription-API-Key (`WhisperM8/Views/CodexSettingsView.swift:33`, `WhisperM8/Views/CodexSettingsView.swift:34`, `WhisperM8/Views/CodexSettingsView.swift:41`, `WhisperM8/Views/CodexSettingsView.swift:51`).
2. „Post-processing Model" enthält die Picker „Model", „Thinking" und „Speed", jeweils mit dynamischem Hilfetext, danach die Statuszeile „Codex CLI" mit Version und eine nur bedingt sichtbare Warnung für GPT-5.5 zusammen mit Codex-Versionen, deren String `0.120.` enthält (`WhisperM8/Views/CodexSettingsView.swift:56`, `WhisperM8/Views/CodexSettingsView.swift:57`, `WhisperM8/Views/CodexSettingsView.swift:67`, `WhisperM8/Views/CodexSettingsView.swift:77`, `WhisperM8/Views/CodexSettingsView.swift:87`, `WhisperM8/Views/CodexSettingsView.swift:95`).
3. „Visual Input" enthält den Picker „Screen clips", den dazugehörigen Hilfetext und einen immer sichtbaren orangefarbenen Hinweis, dass `codex exec` aktuell `--image`, aber kein `--video` exponiert (`WhisperM8/Views/CodexSettingsView.swift:102`, `WhisperM8/Views/CodexSettingsView.swift:103`, `WhisperM8/Views/CodexSettingsView.swift:109`, `WhisperM8/Views/CodexSettingsView.swift:113`).
4. „Privacy" enthält nur einen erklärenden Text zur stabilen nicht-interaktiven Ausführung und zum Raw-Fallback bei fehlendem Codex (`WhisperM8/Views/CodexSettingsView.swift:118`, `WhisperM8/Views/CodexSettingsView.swift:119`).

## 3. Optionen im Detail

### Status

| Aspekt | Wert |
|---|---|
| Control | Statusanzeige als `HStack` mit Label „Status" und `Text(status.displayText)`; grün nur bei `.signedIn`, sonst sekundär (`WhisperM8/Views/CodexSettingsView.swift:34`, `WhisperM8/Views/CodexSettingsView.swift:37`, `WhisperM8/Views/CodexSettingsView.swift:38`). |
| Default | `CodexConnectionStatus.unknown`, weil `@State private var status = CodexConnectionStatus.unknown` gesetzt ist (`WhisperM8/Views/CodexSettingsView.swift:8`). |
| Persistenz | Keine App-Persistenz; der Wert lebt nur in `@State`, und die App speichert dafür weder UserDefaults-Key noch Keychain-Eintrag in dieser View (`WhisperM8/Views/CodexSettingsView.swift:8`, `WhisperM8/Views/CodexSettingsView.swift:131`). |
| Gelesen von | `WhisperM8/Views/CodexSettingsView.swift:37`, `WhisperM8/Views/CodexSettingsView.swift:133`, `WhisperM8/Services/Dictation/CodexSupport.swift:169`. |
| Wirkung | Die Anzeige spiegelt das Ergebnis von `codex login status`; `CodexStatusProbe.status()` unterscheidet `.notInstalled`, `.signedIn`, `.notSignedIn` und `.installed` über Command-Resolution und CLI-Ausgabe (`WhisperM8/Services/Dictation/CodexSupport.swift:169`, `WhisperM8/Services/Dictation/CodexSupport.swift:170`, `WhisperM8/Services/Dictation/CodexSupport.swift:172`, `WhisperM8/Services/Dictation/CodexSupport.swift:175`, `WhisperM8/Services/Dictation/CodexSupport.swift:179`, `WhisperM8/Services/Dictation/CodexSupport.swift:185`). |
| Abhängigkeiten | Post-Processing nutzt im Hot-Path denselben Status semantisch, aber über `CodexStatusCache.shared.status()` statt über die frische Settings-Probe (`WhisperM8/Services/Dictation/CodexPostProcessor.swift:6`, `WhisperM8/Services/Dictation/CodexPostProcessor.swift:13`, `WhisperM8/Services/Dictation/CodexPostProcessor.swift:25`). |

### Sign in with ChatGPT / Reconnect ChatGPT

| Aspekt | Wert |
|---|---|
| Control | Button mit dynamischem Titel: bei `.signedIn` „Reconnect ChatGPT", sonst „Sign in with ChatGPT" (`WhisperM8/Views/CodexSettingsView.swift:42`). |
| Default | Der initial sichtbare Titel ist „Sign in with ChatGPT", weil `status` bis zum ersten `refresh()` `.unknown` ist und nur `.signedIn` den Reconnect-Titel auslöst (`WhisperM8/Views/CodexSettingsView.swift:8`, `WhisperM8/Views/CodexSettingsView.swift:42`). |
| Persistenz | Keine WhisperM8-Persistenz; der Button schreibt nur ein temporäres Terminal-Skript nach `FileManager.default.temporaryDirectory/WhisperM8-Codex-Login.command` und startet `codex login` (`WhisperM8/Services/Dictation/CodexSupport.swift:194`, `WhisperM8/Services/Dictation/CodexSupport.swift:195`, `WhisperM8/Services/Dictation/CodexSupport.swift:196`, `WhisperM8/Services/Dictation/CodexSupport.swift:198`). |
| Gelesen von | `WhisperM8/Views/CodexSettingsView.swift:42`, `WhisperM8/Views/CodexSettingsView.swift:43`, `WhisperM8/Services/Dictation/CodexSupport.swift:188`. |
| Wirkung | Wenn ein `codex`-Binary gefunden wird, öffnet WhisperM8 ein ausführbares `.command`-Skript in Terminal; wenn kein Binary gefunden wird, öffnet es stattdessen eine OpenAI-Hilfe-URL (`WhisperM8/Services/Dictation/CodexSupport.swift:188`, `WhisperM8/Services/Dictation/CodexSupport.swift:189`, `WhisperM8/Services/Dictation/CodexSupport.swift:190`, `WhisperM8/Services/Dictation/CodexSupport.swift:205`, `WhisperM8/Services/Dictation/CodexSupport.swift:206`, `WhisperM8/Services/Dictation/CodexSupport.swift:210`). |
| Abhängigkeiten | Das Login-Skript löst selbst keinen Status-Refresh aus; die Seite aktualisiert erst über `onAppear`/`refresh()` oder den Button „Check Again" (`WhisperM8/Views/CodexSettingsView.swift:126`, `WhisperM8/Views/CodexSettingsView.swift:131`, `WhisperM8/Views/CodexSettingsView.swift:46`). |

### Check Again

| Aspekt | Wert |
|---|---|
| Control | Button „Check Again" in der ChatGPT-Subscription-Section (`WhisperM8/Views/CodexSettingsView.swift:46`). |
| Default | Immer sichtbar; es gibt keine Disable- oder Sichtbarkeitsbedingung im Button-Block (`WhisperM8/Views/CodexSettingsView.swift:41`, `WhisperM8/Views/CodexSettingsView.swift:46`). |
| Persistenz | Keine Persistenz; der Button überschreibt nur den lokalen `@State`-Wert `status` mit einem frischen `CodexStatusProbe().status()` (`WhisperM8/Views/CodexSettingsView.swift:8`, `WhisperM8/Views/CodexSettingsView.swift:47`). |
| Gelesen von | `WhisperM8/Views/CodexSettingsView.swift:46`, `WhisperM8/Views/CodexSettingsView.swift:47`, `WhisperM8/Services/Dictation/CodexSupport.swift:169`. |
| Wirkung | Er führt unmittelbar `codex login status` aus, statt den Diktat-Hot-Path-Cache zu nutzen (`WhisperM8/Services/Dictation/CodexSupport.swift:172`, `WhisperM8/Services/Dictation/CodexStatusCache.swift:3`, `WhisperM8/Services/Dictation/CodexPostProcessor.swift:13`). |
| Abhängigkeiten | Die gleiche Statusprüfung erscheint auch in „Output Overview" mit eigenem „Check Again"-Button (`WhisperM8/Views/OutputOverviewView.swift:26`, `WhisperM8/Views/OutputOverviewView.swift:35`, `WhisperM8/Views/OutputOverviewView.swift:36`). |

### Hinweis „official Codex CLI login"

| Aspekt | Wert |
|---|---|
| Control | Sekundärer Caption-Text unter den Login-Buttons (`WhisperM8/Views/CodexSettingsView.swift:51`, `WhisperM8/Views/CodexSettingsView.swift:52`, `WhisperM8/Views/CodexSettingsView.swift:53`). |
| Default | Immer sichtbar (`WhisperM8/Views/CodexSettingsView.swift:51`). |
| Persistenz | Keine Persistenz; statischer View-Text (`WhisperM8/Views/CodexSettingsView.swift:51`). |
| Gelesen von | `WhisperM8/Views/CodexSettingsView.swift:51`. |
| Wirkung | Der Text grenzt Codex-CLI-Login gegen den OpenAI-/Groq-Transcription-Key ab; die API-Settings speichern Transcription-Keys separat via `KeychainManager.save(key:provider.keychainKey, value:)` (`WhisperM8/Views/CodexSettingsView.swift:51`, `WhisperM8/Views/Settings/APISettingsView.swift:39`, `WhisperM8/Views/Settings/APISettingsView.swift:89`). |
| Abhängigkeiten | Die Trennung ist UX-relevant, weil die Codex-Seite keine Keychain-Felder besitzt, während die API-Seite Keychain-Status und API-Key-Eingabe zeigt (`WhisperM8/Views/CodexSettingsView.swift:31`, `WhisperM8/Views/Settings/APISettingsView.swift:30`, `WhisperM8/Views/Settings/APISettingsView.swift:46`). |

### Model

| Aspekt | Wert |
|---|---|
| Control | Picker „Model" über `CodexPostProcessingModel.allCases` mit sichtbaren Displaynamen GPT-5.5, GPT-5.4 und GPT-5.2 (`WhisperM8/Views/CodexSettingsView.swift:57`, `WhisperM8/Views/CodexSettingsView.swift:58`, `WhisperM8/Models/CodexPostProcessingModel.swift:3`, `WhisperM8/Models/CodexPostProcessingModel.swift:4`). |
| Default | `gpt-5.5`, weil `@AppStorage("codexPostProcessingModel")` auf `CodexPostProcessingModel.defaultModel.rawValue` fällt und `defaultModel = .gpt55` ist (`WhisperM8/Views/CodexSettingsView.swift:4`, `WhisperM8/Models/CodexPostProcessingModel.swift:32`). |
| Persistenz | UserDefaults-Key `codexPostProcessingModel`; der zentrale Key ist `PreferenceKeys.codexPostProcessingModel = "codexPostProcessingModel"` (`WhisperM8/Views/CodexSettingsView.swift:4`, `WhisperM8/Support/AppPreferences.swift:145`, `WhisperM8/Support/AppPreferences.swift:379`). |
| Gelesen von | `WhisperM8/Views/CodexSettingsView.swift:11`, `WhisperM8/Services/Dictation/CodexPostProcessor.swift:70`, `WhisperM8/Models/OutputMode.swift:101`, `WhisperM8/Views/AgentChatsView+SessionLifecycle.swift:47`, `WhisperM8/Services/AgentChats/AgentSessionStore.swift:417`. |
| Wirkung | Für Diktat-Post-Processing wird der aufgelöste Moduswert als `-m <model>` in `codex exec` übergeben; pro Output-Mode kann dieser globale Default durch `codexModelRawOverride` übersteuert werden (`WhisperM8/Services/Dictation/CodexPostProcessor.swift:67`, `WhisperM8/Services/Dictation/CodexPostProcessor.swift:70`, `WhisperM8/Services/Dictation/CodexSupport.swift:63`, `WhisperM8/Services/Dictation/CodexSupport.swift:64`, `WhisperM8/Models/OutputMode.swift:101`). |
| Abhängigkeiten | Output Modes zeigen und verwenden denselben globalen Wert, solange „Use global Codex model" aktiv ist; bei Override liegt der Wert in `OutputModes.json` im Feld `codexModelRawOverride` (`WhisperM8/Views/OutputModesView.swift:13`, `WhisperM8/Views/OutputModesView.swift:174`, `WhisperM8/Views/OutputModesView.swift:176`, `WhisperM8/Models/OutputMode.swift:78`, `WhisperM8/Services/Dictation/OutputModeStore.swift:194`). |

### Model-Hilfetext

| Aspekt | Wert |
|---|---|
| Control | Dynamischer Caption-Text `Text(selectedModel.detail)` direkt unter dem Model-Picker (`WhisperM8/Views/CodexSettingsView.swift:63`, `WhisperM8/Views/CodexSettingsView.swift:64`). |
| Default | Bei Defaultmodell GPT-5.5 lautet der Text „Default. Best quality when your Codex CLI supports it." (`WhisperM8/Models/CodexPostProcessingModel.swift:23`, `WhisperM8/Models/CodexPostProcessingModel.swift:24`, `WhisperM8/Models/CodexPostProcessingModel.swift:32`). |
| Persistenz | Keine eigene Persistenz; der Text wird aus dem persistierten Model-Rohwert abgeleitet (`WhisperM8/Views/CodexSettingsView.swift:11`, `WhisperM8/Views/CodexSettingsView.swift:63`). |
| Gelesen von | `WhisperM8/Views/CodexSettingsView.swift:63`, `WhisperM8/Models/CodexPostProcessingModel.swift:21`. |
| Wirkung | Rein informativ; der tatsächliche CLI-Effekt entsteht durch den Model-Picker und `CodexInvocation.arguments(... model:)` (`WhisperM8/Services/Dictation/CodexSupport.swift:53`, `WhisperM8/Services/Dictation/CodexSupport.swift:64`). |
| Abhängigkeiten | Der Text ändert sich live mit `selectedModelRaw`, weil `selectedModel` jedes Rendering über `CodexPostProcessingModel.resolve(selectedModelRaw)` berechnet wird (`WhisperM8/Views/CodexSettingsView.swift:11`, `WhisperM8/Views/CodexSettingsView.swift:12`). |

### Thinking

| Aspekt | Wert |
|---|---|
| Control | Picker „Thinking" über `CodexReasoningEffort.allCases` mit Low, Medium, High und Extra High (`WhisperM8/Views/CodexSettingsView.swift:67`, `WhisperM8/Views/CodexSettingsView.swift:68`, `WhisperM8/Models/CodexReasoningEffort.swift:3`, `WhisperM8/Models/CodexReasoningEffort.swift:11`). |
| Default | `medium`, weil `@AppStorage("codexReasoningEffort")` auf `CodexReasoningEffort.defaultEffort.rawValue` fällt und `defaultEffort = .medium` ist (`WhisperM8/Views/CodexSettingsView.swift:5`, `WhisperM8/Models/CodexReasoningEffort.swift:37`). |
| Persistenz | UserDefaults-Key `codexReasoningEffort`; der zentrale Key ist `PreferenceKeys.codexReasoningEffort = "codexReasoningEffort"` (`WhisperM8/Views/CodexSettingsView.swift:5`, `WhisperM8/Support/AppPreferences.swift:150`, `WhisperM8/Support/AppPreferences.swift:380`). |
| Gelesen von | `WhisperM8/Views/CodexSettingsView.swift:15`, `WhisperM8/Services/Dictation/CodexPostProcessor.swift:71`, `WhisperM8/Models/OutputMode.swift:109`, `WhisperM8/Views/AgentChatsView+SessionLifecycle.swift:48`, `WhisperM8/Services/AgentChats/AgentSessionStore.swift:418`. |
| Wirkung | Für Diktat-Post-Processing wird der Wert als `-c model_reasoning_effort=<effort>` an `codex exec` übergeben; pro Output-Mode kann dieser globale Default durch `codexReasoningEffortRawOverride` übersteuert werden (`WhisperM8/Services/Dictation/CodexPostProcessor.swift:71`, `WhisperM8/Services/Dictation/CodexSupport.swift:65`, `WhisperM8/Models/OutputMode.swift:109`, `WhisperM8/Models/OutputMode.swift:24`). |
| Abhängigkeiten | Interaktive Codex-Agent-Chats übernehmen beim Anlegen ebenfalls diesen globalen Wert in die Session; spätere Starts nutzen dann den Session-Wert als `model_reasoning_effort` (`WhisperM8/Views/AgentChatsView+SessionLifecycle.swift:48`, `WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:128`, `WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:129`). |

### Thinking-Hilfetext

| Aspekt | Wert |
|---|---|
| Control | Dynamischer Caption-Text `Text(selectedReasoningEffort.detail)` unter dem Thinking-Picker (`WhisperM8/Views/CodexSettingsView.swift:73`, `WhisperM8/Views/CodexSettingsView.swift:74`). |
| Default | Bei Medium lautet der Text „Default. Balanced quality and speed." (`WhisperM8/Models/CodexReasoningEffort.swift:28`, `WhisperM8/Models/CodexReasoningEffort.swift:29`, `WhisperM8/Models/CodexReasoningEffort.swift:37`). |
| Persistenz | Keine eigene Persistenz; abgeleitet aus UserDefaults-Key `codexReasoningEffort` (`WhisperM8/Views/CodexSettingsView.swift:5`, `WhisperM8/Views/CodexSettingsView.swift:73`). |
| Gelesen von | `WhisperM8/Views/CodexSettingsView.swift:73`, `WhisperM8/Models/CodexReasoningEffort.swift:24`. |
| Wirkung | Rein informativ; der eigentliche Prozessparameter wird im Codex-Argumentbau gesetzt (`WhisperM8/Services/Dictation/CodexSupport.swift:65`). |
| Abhängigkeiten | Output Modes zeigen den globalen Thinking-Wert als Hilfetext, wenn kein Override gesetzt ist (`WhisperM8/Views/OutputModesView.swift:192`, `WhisperM8/Views/OutputModesView.swift:194`, `WhisperM8/Views/OutputModesView.swift:195`). |

### Speed

| Aspekt | Wert |
|---|---|
| Control | Picker „Speed" über `CodexServiceTier.allCases` mit Fast und Standard (`WhisperM8/Views/CodexSettingsView.swift:77`, `WhisperM8/Views/CodexSettingsView.swift:78`, `WhisperM8/Models/CodexServiceTier.swift:3`, `WhisperM8/Models/CodexServiceTier.swift:9`). |
| Default | `fast`, weil `@AppStorage("codexServiceTier")` auf `CodexServiceTier.defaultTier.rawValue` fällt und `defaultTier = .fast` ist (`WhisperM8/Views/CodexSettingsView.swift:6`, `WhisperM8/Models/CodexServiceTier.swift:39`). |
| Persistenz | UserDefaults-Key `codexServiceTier`; der zentrale Key ist `PreferenceKeys.codexServiceTier = "codexServiceTier"` (`WhisperM8/Views/CodexSettingsView.swift:6`, `WhisperM8/Support/AppPreferences.swift:155`, `WhisperM8/Support/AppPreferences.swift:381`). |
| Gelesen von | `WhisperM8/Views/CodexSettingsView.swift:19`, `WhisperM8/Services/Dictation/CodexPostProcessor.swift:72`, `WhisperM8/Models/OutputMode.swift:117`, `WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:54`, `WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:115`. |
| Wirkung | `fast` ergänzt `-c features.fast_mode=true` und `-c service_tier=fast`; `standard` ergänzt `-c service_tier=default` (`WhisperM8/Models/CodexServiceTier.swift:27`, `WhisperM8/Models/CodexServiceTier.swift:30`, `WhisperM8/Models/CodexServiceTier.swift:31`, `WhisperM8/Models/CodexServiceTier.swift:35`). |
| Abhängigkeiten | Agent-Chat-Launches lesen den aktuellen globalen Service-Tier zur Laufzeit über `AgentCommandBuilder.codexServiceTierResolver`, während Model und Thinking beim Session-Anlegen in die Session kopiert werden (`WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:54`, `WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:115`, `WhisperM8/Services/AgentChats/AgentSessionStore.swift:417`). |

### Speed-Hilfetext

| Aspekt | Wert |
|---|---|
| Control | Dynamischer Caption-Text `Text(selectedServiceTier.detail)` unter dem Speed-Picker (`WhisperM8/Views/CodexSettingsView.swift:83`, `WhisperM8/Views/CodexSettingsView.swift:84`). |
| Default | Bei Fast lautet der Text „Default. Uses Codex Fast mode for lower latency on supported ChatGPT plans." (`WhisperM8/Models/CodexServiceTier.swift:20`, `WhisperM8/Models/CodexServiceTier.swift:21`, `WhisperM8/Models/CodexServiceTier.swift:39`). |
| Persistenz | Keine eigene Persistenz; abgeleitet aus UserDefaults-Key `codexServiceTier` (`WhisperM8/Views/CodexSettingsView.swift:6`, `WhisperM8/Views/CodexSettingsView.swift:83`). |
| Gelesen von | `WhisperM8/Views/CodexSettingsView.swift:83`, `WhisperM8/Models/CodexServiceTier.swift:18`. |
| Wirkung | Rein informativ; die Prozesswirkung entsteht durch `configArguments` des gewählten Service-Tiers (`WhisperM8/Models/CodexServiceTier.swift:27`). |
| Abhängigkeiten | Die Modes-Seite nennt denselben Wert „Fast mode" beziehungsweise „global speed", wodurch dieselbe Einstellung unter anderen Begriffen auftaucht (`WhisperM8/Views/OutputModesView.swift:210`, `WhisperM8/Views/OutputModesView.swift:212`, `WhisperM8/Views/OutputModesView.swift:213`). |

### Codex CLI

| Aspekt | Wert |
|---|---|
| Control | Statusanzeige als Caption-HStack mit Label „Codex CLI" und `Text(codexVersion)` (`WhisperM8/Views/CodexSettingsView.swift:87`, `WhisperM8/Views/CodexSettingsView.swift:88`, `WhisperM8/Views/CodexSettingsView.swift:90`, `WhisperM8/Views/CodexSettingsView.swift:93`). |
| Default | „Unknown", weil `@State private var codexVersion = "Unknown"` gesetzt ist (`WhisperM8/Views/CodexSettingsView.swift:9`). |
| Persistenz | Keine Persistenz; der Wert lebt nur in `@State` und wird über `CodexStatusProbe().version()` gesetzt (`WhisperM8/Views/CodexSettingsView.swift:9`, `WhisperM8/Views/CodexSettingsView.swift:134`). |
| Gelesen von | `WhisperM8/Views/CodexSettingsView.swift:90`, `WhisperM8/Views/CodexSettingsView.swift:134`, `WhisperM8/Services/Dictation/CodexSupport.swift:163`. |
| Wirkung | Zeigt entweder „Not installed" oder die getrimmte Ausgabe von `codex --version`; der Wert steuert zusätzlich die GPT-5.5-Kompatibilitätswarnung (`WhisperM8/Services/Dictation/CodexSupport.swift:163`, `WhisperM8/Services/Dictation/CodexSupport.swift:164`, `WhisperM8/Services/Dictation/CodexSupport.swift:165`, `WhisperM8/Views/CodexSettingsView.swift:27`). |
| Abhängigkeiten | Die Binary-Auflösung bevorzugt `/Applications/Codex.app/Contents/Resources/codex` und fällt sonst auf `AgentCommandBuilder.commandPath` zurück (`WhisperM8/Services/Dictation/CodexSupport.swift:220`, `WhisperM8/Services/Dictation/CodexSupport.swift:221`, `WhisperM8/Services/Dictation/CodexSupport.swift:227`). |

### GPT-5.5-Codex-CLI-Warnung

| Aspekt | Wert |
|---|---|
| Control | Bedingt sichtbarer orangefarbener Caption-Text unter der Codex-CLI-Zeile (`WhisperM8/Views/CodexSettingsView.swift:95`, `WhisperM8/Views/CodexSettingsView.swift:96`, `WhisperM8/Views/CodexSettingsView.swift:98`). |
| Default | Unsichtbar, solange nicht gleichzeitig GPT-5.5 gewählt ist und `codexVersion.contains("0.120.")` zutrifft (`WhisperM8/Views/CodexSettingsView.swift:27`, `WhisperM8/Views/CodexSettingsView.swift:28`, `WhisperM8/Views/CodexSettingsView.swift:95`). |
| Persistenz | Keine Persistenz; die Sichtbarkeit ist aus UserDefaults-Key `codexPostProcessingModel` und lokalem `@State` `codexVersion` abgeleitet (`WhisperM8/Views/CodexSettingsView.swift:4`, `WhisperM8/Views/CodexSettingsView.swift:9`, `WhisperM8/Views/CodexSettingsView.swift:27`). |
| Gelesen von | `WhisperM8/Views/CodexSettingsView.swift:27`, `WhisperM8/Views/CodexSettingsView.swift:95`. |
| Wirkung | Warnt, dass GPT-5.5 bei zu alter Codex-CLI mit „requires a newer version of Codex" fehlschlagen kann, und nennt Update oder temporär GPT-5.2 als Ausweichpfad (`WhisperM8/Views/CodexSettingsView.swift:96`). |
| Abhängigkeiten | Der Text hängt am Modell-Picker und an der Versionsprobe; er verhindert den fehlerhaften Lauf nicht, weil `CodexInvocation.arguments` weiterhin das gewählte Modell übergibt (`WhisperM8/Views/CodexSettingsView.swift:57`, `WhisperM8/Views/CodexSettingsView.swift:134`, `WhisperM8/Services/Dictation/CodexSupport.swift:64`). |

### Screen clips

| Aspekt | Wert |
|---|---|
| Control | Picker „Screen clips" über `CodexVisualInputMode.allCases` mit Auto, Frames und Video (`WhisperM8/Views/CodexSettingsView.swift:103`, `WhisperM8/Views/CodexSettingsView.swift:104`, `WhisperM8/Models/CodexVisualInputMode.swift:3`, `WhisperM8/Models/CodexVisualInputMode.swift:10`). |
| Default | `auto`, weil `@AppStorage("codexVisualInputMode")` auf `CodexVisualInputMode.defaultMode.rawValue` fällt und `defaultMode = .auto` ist (`WhisperM8/Views/CodexSettingsView.swift:7`, `WhisperM8/Models/CodexVisualInputMode.swift:32`). |
| Persistenz | UserDefaults-Key `codexVisualInputMode`; der zentrale Key ist `PreferenceKeys.codexVisualInputMode = "codexVisualInputMode"` (`WhisperM8/Views/CodexSettingsView.swift:7`, `WhisperM8/Support/AppPreferences.swift:160`, `WhisperM8/Support/AppPreferences.swift:382`). |
| Gelesen von | `WhisperM8/Views/CodexSettingsView.swift:23`, `WhisperM8/Services/Dictation/CodexSupport.swift:97`, `WhisperM8/Models/PostProcessingTemplate.swift:25`, `WhisperM8/Services/Dictation/TranscriptRunReportStore.swift:81`, `WhisperM8/Views/TranscriptReportDetailView.swift:62`. |
| Wirkung | Auto und Frames senden visuelle Attachments als `--image`; Video behält ebenfalls Frames als `--image` und markiert `usesFrameFallback`, während Screen-Clip-Pfade als Video-URLs im Report landen (`WhisperM8/Services/Dictation/CodexSupport.swift:102`, `WhisperM8/Services/Dictation/CodexSupport.swift:103`, `WhisperM8/Services/Dictation/CodexSupport.swift:104`, `WhisperM8/Services/Dictation/CodexSupport.swift:106`, `WhisperM8/Services/Dictation/CodexSupport.swift:107`, `WhisperM8/Services/Dictation/CodexSupport.swift:108`, `WhisperM8/Services/Dictation/TranscriptRunReportStore.swift:121`, `WhisperM8/Services/Dictation/TranscriptRunReportStore.swift:122`). |
| Abhängigkeiten | Der Prompt-Template-Platzhalter `{visualInputMode}` rendert den Displaynamen dieses globalen Werts, und History zeigt „Visual Input", „Images Sent", „Video Paths" sowie den Fallback-Hinweis an (`WhisperM8/Models/PostProcessingTemplate.swift:25`, `WhisperM8/Views/TranscriptReportDetailView.swift:62`, `WhisperM8/Views/TranscriptReportDetailView.swift:63`, `WhisperM8/Views/TranscriptReportDetailView.swift:64`, `WhisperM8/Views/TranscriptReportDetailView.swift:65`). |

### Screen-clips-Hilfetext

| Aspekt | Wert |
|---|---|
| Control | Dynamischer Caption-Text `Text(selectedVisualInputMode.detail)` unter dem Screen-clips-Picker (`WhisperM8/Views/CodexSettingsView.swift:109`, `WhisperM8/Views/CodexSettingsView.swift:110`). |
| Default | Bei Auto lautet der Text, dass heute der stabile Codex-CLI-Image-Pfad genutzt wird und später auf direkte Videoübergabe gewechselt werden kann (`WhisperM8/Models/CodexVisualInputMode.swift:23`, `WhisperM8/Models/CodexVisualInputMode.swift:24`, `WhisperM8/Models/CodexVisualInputMode.swift:32`). |
| Persistenz | Keine eigene Persistenz; abgeleitet aus UserDefaults-Key `codexVisualInputMode` (`WhisperM8/Views/CodexSettingsView.swift:7`, `WhisperM8/Views/CodexSettingsView.swift:109`). |
| Gelesen von | `WhisperM8/Views/CodexSettingsView.swift:109`, `WhisperM8/Models/CodexVisualInputMode.swift:21`. |
| Wirkung | Rein informativ; die Attachments werden durch `CodexVisualInputSelection` gewählt und später als `--image`-Argumente an `CodexInvocation.arguments` übergeben (`WhisperM8/Services/Dictation/CodexSupport.swift:91`, `WhisperM8/Services/Dictation/CodexSupport.swift:82`, `WhisperM8/Services/Dictation/CodexSupport.swift:83`). |
| Abhängigkeiten | Output Templates listen `{visualInputMode}` als Platzhalter, der von diesem globalen Wert abhängt (`WhisperM8/Views/OutputTemplatesView.swift:132`, `WhisperM8/Models/PostProcessingTemplate.swift:25`). |

### Video-/Image-CLI-Hinweis

| Aspekt | Wert |
|---|---|
| Control | Immer sichtbarer orangefarbener Caption-Text in der Visual-Input-Section (`WhisperM8/Views/CodexSettingsView.swift:113`, `WhisperM8/Views/CodexSettingsView.swift:114`, `WhisperM8/Views/CodexSettingsView.swift:115`). |
| Default | Immer sichtbar; der Text interpoliert nur `codexVersion` (`WhisperM8/Views/CodexSettingsView.swift:113`). |
| Persistenz | Keine eigene Persistenz; nutzt lokales `@State` `codexVersion` (`WhisperM8/Views/CodexSettingsView.swift:9`, `WhisperM8/Views/CodexSettingsView.swift:113`). |
| Gelesen von | `WhisperM8/Views/CodexSettingsView.swift:113`, `WhisperM8/Views/CodexSettingsView.swift:134`. |
| Wirkung | Er erklärt, warum Video-Modus den Clip-Pfad im Prompt belässt und Frames als Fallback sendet; genau dieses Verhalten wird durch `CodexVisualInputSelection` und `CodexInvocation.arguments` umgesetzt (`WhisperM8/Views/CodexSettingsView.swift:113`, `WhisperM8/Services/Dictation/CodexSupport.swift:106`, `WhisperM8/Services/Dictation/CodexSupport.swift:108`, `WhisperM8/Services/Dictation/CodexSupport.swift:82`). |
| Abhängigkeiten | Der Hinweis kann fachlich veralten, sobald `codex exec` direkte Video-Flags unterstützt; der aktuelle Code hängt die Video-URLs nicht als eigenes CLI-Flag an, sondern nur Bilder per `--image` (`WhisperM8/Services/Dictation/CodexSupport.swift:82`, `WhisperM8/Services/Dictation/CodexSupport.swift:83`, `WhisperM8/Services/Dictation/CodexSupport.swift:86`). |

### Privacy-Hinweis

| Aspekt | Wert |
|---|---|
| Control | Sekundärer Caption-Text in Section „Privacy" (`WhisperM8/Views/CodexSettingsView.swift:118`, `WhisperM8/Views/CodexSettingsView.swift:119`, `WhisperM8/Views/CodexSettingsView.swift:120`). |
| Default | Immer sichtbar (`WhisperM8/Views/CodexSettingsView.swift:118`, `WhisperM8/Views/CodexSettingsView.swift:119`). |
| Persistenz | Keine Persistenz; statischer View-Text (`WhisperM8/Views/CodexSettingsView.swift:119`). |
| Gelesen von | `WhisperM8/Views/CodexSettingsView.swift:119`. |
| Wirkung | Der Text beschreibt den tatsächlichen Guard: `CodexPostProcessor` bricht Post-Processing ab, wenn der Status nicht `.signedIn` ist, und `RecordingCoordinator` fällt bei aktiviertem Raw-Fallback auf rohen Text zurück (`WhisperM8/Services/Dictation/CodexPostProcessor.swift:25`, `WhisperM8/Services/Dictation/CodexPostProcessor.swift:26`, `WhisperM8/Services/Dictation/CodexPostProcessor.swift:27`, `WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:236`, `WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:245`). |
| Abhängigkeiten | Der Fallback ist nicht auf dieser Seite konfigurierbar, sondern auf der Modes-Seite über UserDefaults-Key `fallbackToRawOnProcessingError` (`WhisperM8/Views/OutputModesView.swift:12`, `WhisperM8/Views/OutputModesView.swift:101`, `WhisperM8/Support/AppPreferences.swift:94`, `WhisperM8/Support/AppPreferences.swift:370`). |

## 4. Datenfluss & Persistenz

Die vier echten Einstellungen der Seite sind SwiftUI-`@AppStorage`-Bindings und schreiben daher sofort in `UserDefaults.standard`: `codexPostProcessingModel`, `codexReasoningEffort`, `codexServiceTier` und `codexVisualInputMode` (`WhisperM8/Views/CodexSettingsView.swift:4`, `WhisperM8/Views/CodexSettingsView.swift:5`, `WhisperM8/Views/CodexSettingsView.swift:6`, `WhisperM8/Views/CodexSettingsView.swift:7`). `AppPreferences` kapselt dieselben Keys für Services und nicht-View-Code; die Defaultwerte kommen aus den jeweiligen Enum-Defaults und nicht aus einer Migrationsroutine (`WhisperM8/Support/AppPreferences.swift:145`, `WhisperM8/Support/AppPreferences.swift:150`, `WhisperM8/Support/AppPreferences.swift:155`, `WhisperM8/Support/AppPreferences.swift:160`, `WhisperM8/Support/AppPreferences.swift:379`).

Die Settings-UI liest Status und Version live beim `onAppear` über `refresh()` und schreibt diese Werte nur in lokalen `@State`; ein Neustart ist für die Anzeige nicht nötig, aber ein externer Login im Terminal wird erst nach `Check Again` oder erneutem Öffnen sichtbar (`WhisperM8/Views/CodexSettingsView.swift:126`, `WhisperM8/Views/CodexSettingsView.swift:131`, `WhisperM8/Views/CodexSettingsView.swift:133`, `WhisperM8/Views/CodexSettingsView.swift:134`). Der Diktat-Hot-Path verwendet dagegen `CodexStatusCache` mit 300 Sekunden TTL für `.signedIn` und 5 Sekunden Mini-TTL für negative Zustände, damit nicht jeder Post-Processing-Lauf `codex login status` spawnt (`WhisperM8/Services/Dictation/CodexStatusCache.swift:3`, `WhisperM8/Services/Dictation/CodexStatusCache.swift:23`, `WhisperM8/Services/Dictation/CodexStatusCache.swift:24`, `WhisperM8/Services/Dictation/CodexStatusCache.swift:25`, `WhisperM8/Services/Dictation/CodexStatusCache.swift:35`, `WhisperM8/Services/Dictation/CodexPostProcessor.swift:13`).

Beim Diktat-Post-Processing werden Model, Thinking und Speed erst zum Laufzeitpunkt aus dem aktuellen Output-Mode aufgelöst; Mode-Overrides gewinnen, sonst greifen die globalen Codex-/ChatGPT-Defaults (`WhisperM8/Models/OutputMode.swift:101`, `WhisperM8/Models/OutputMode.swift:109`, `WhisperM8/Models/OutputMode.swift:117`, `WhisperM8/Services/Dictation/CodexPostProcessor.swift:67`). Die resultierenden Werte werden in `codex exec` übersetzt: Modell über `-m`, Thinking über `-c model_reasoning_effort=...`, Speed über `CodexServiceTier.configArguments`, Read-only-Sandbox über `--sandbox read-only`, Output-Datei über `--output-last-message` und Bilder über wiederholtes `--image` (`WhisperM8/Services/Dictation/CodexSupport.swift:62`, `WhisperM8/Services/Dictation/CodexSupport.swift:64`, `WhisperM8/Services/Dictation/CodexSupport.swift:65`, `WhisperM8/Services/Dictation/CodexSupport.swift:67`, `WhisperM8/Services/Dictation/CodexSupport.swift:69`, `WhisperM8/Services/Dictation/CodexSupport.swift:71`, `WhisperM8/Services/Dictation/CodexSupport.swift:82`).

Visuelle Eingaben werden beim Lauf aus dem aktuellen Kontextbundle und UserDefaults-Key `codexVisualInputMode` ausgewählt; Auto/Frames senden `visualAttachments`, Video sendet dieselben Frames und markiert den Frame-Fallback, während Screen-Clip-Pfade im Report als Video-Pfade auftauchen (`WhisperM8/Services/Dictation/CodexSupport.swift:97`, `WhisperM8/Services/Dictation/CodexSupport.swift:102`, `WhisperM8/Services/Dictation/CodexSupport.swift:106`, `WhisperM8/Services/Dictation/TranscriptRunReportStore.swift:95`, `WhisperM8/Services/Dictation/TranscriptRunReportStore.swift:111`, `WhisperM8/Services/Dictation/TranscriptRunReportStore.swift:123`). Es gibt keine Keychain-Persistenz auf dieser Seite; Keychain-Schreibzugriffe für Transcription-API-Keys liegen auf der API-Seite und im CLI-Transcribe-Pfad, nicht in `CodexSettingsView` (`WhisperM8/Views/Settings/APISettingsView.swift:39`, `WhisperM8/Views/Settings/APISettingsView.swift:89`, `WhisperM8/CLI/CLITranscribe.swift:316`).

## 5. Querverweise

- **Settings-Navigation:** Die Seite heißt in der Sidebar „Codex / ChatGPT", sitzt in der Gruppe „Accounts" und öffnet `CodexSettingsView()` (`WhisperM8/Views/SettingsView.swift:5`, `WhisperM8/Views/SettingsView.swift:98`, `WhisperM8/Views/SettingsView.swift:127`, `WhisperM8/Views/SettingsView.swift:207`).
- **Onboarding:** Der optionale Codex-Schritt wiederholt Status, Sign-in/Reconnect und Check Again, erklärt aber zusätzlich, dass Enrichment-Modi Codex nutzen und ohne Codex auf Raw zurückfallen (`WhisperM8/Views/OnboardingView.swift:297`, `WhisperM8/Views/OnboardingView.swift:313`, `WhisperM8/Views/OnboardingView.swift:318`, `WhisperM8/Views/OnboardingView.swift:328`, `WhisperM8/Views/OnboardingView.swift:333`, `WhisperM8/Views/OnboardingView.swift:338`).
- **Output Overview:** Die Overview-Seite hat eine eigene Codex-Section mit Status, Check Again und „Set up Codex"-Link zur Codex-CLI-Dokumentation (`WhisperM8/Views/OutputOverviewView.swift:26`, `WhisperM8/Views/OutputOverviewView.swift:30`, `WhisperM8/Views/OutputOverviewView.swift:35`, `WhisperM8/Views/OutputOverviewView.swift:39`, `WhisperM8/Views/OutputOverviewView.swift:40`).
- **Modes:** Die Modes-Seite liest dieselben globalen Codex-Defaults, zeigt sie in der Mode-spezifischen „Codex settings"-Gruppe und kann Model, Thinking sowie Speed pro Modus über JSON-Felder überschreiben (`WhisperM8/Views/OutputModesView.swift:13`, `WhisperM8/Views/OutputModesView.swift:14`, `WhisperM8/Views/OutputModesView.swift:15`, `WhisperM8/Views/OutputModesView.swift:169`, `WhisperM8/Views/OutputModesView.swift:174`, `WhisperM8/Views/OutputModesView.swift:192`, `WhisperM8/Views/OutputModesView.swift:210`, `WhisperM8/Models/OutputMode.swift:78`).
- **Agent Chats:** Neue Codex-Sessions übernehmen Model und Thinking aus den globalen Defaults, und der Agent-Command-Builder verwendet den aktuellen globalen Service-Tier beim Starten oder Resumen von Codex-Chats (`WhisperM8/Views/AgentChatsView+SessionLifecycle.swift:47`, `WhisperM8/Views/AgentChatsView+SessionLifecycle.swift:48`, `WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:54`, `WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:115`, `WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:124`).
- **Agent-Chats-Settings:** `AgentChatsAccessView` bietet zusätzlich `codexExtraArguments` für jeden `codex`-Aufruf; diese Option liegt nicht auf der Codex-/ChatGPT-Seite, beeinflusst aber interaktive Codex-Agent-Chats über `AgentCommandBuilder.extraArgumentsResolver` (`WhisperM8/Views/Settings/AgentChatsAccessView.swift:7`, `WhisperM8/Views/Settings/AgentChatsAccessView.swift:72`, `WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:43`, `WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:48`, `WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:114`).
- **Templates und History:** Templates können `{visualInputMode}` verwenden, und History zeigt Codex Model, Thinking, Visual Input, Images Sent, Video Paths und Frame-Fallback an (`WhisperM8/Models/PostProcessingTemplate.swift:25`, `WhisperM8/Views/OutputTemplatesView.swift:132`, `WhisperM8/Views/TranscriptReportDetailView.swift:60`, `WhisperM8/Views/TranscriptReportDetailView.swift:61`, `WhisperM8/Views/TranscriptReportDetailView.swift:62`, `WhisperM8/Views/TranscriptReportDetailView.swift:65`).

## 6. UX-Beobachtungen (Rohmaterial fürs Redesign)

1. **Redundanz bei Status/Login:** Codex-Status und „Check Again" existieren in `CodexSettingsView`, `OutputOverviewView` und `CodexConnectStep`; die Einstiegspunkte unterscheiden sich leicht, obwohl sie dieselbe Probe verwenden (`WhisperM8/Views/CodexSettingsView.swift:34`, `WhisperM8/Views/CodexSettingsView.swift:46`, `WhisperM8/Views/OutputOverviewView.swift:26`, `WhisperM8/Views/OutputOverviewView.swift:35`, `WhisperM8/Views/OnboardingView.swift:318`, `WhisperM8/Views/OnboardingView.swift:333`).
2. **Globale Defaults vs. Mode-Overrides sind schwer durchschaubar:** Die Codex-Seite wirkt wie die zentrale Wahrheit, aber die Modes-Seite kann Model, Thinking und Speed pro Modus überschreiben; dort heißen die Toggles „Use global Codex model", „Use global Thinking level" und „Use global Fast mode" (`WhisperM8/Views/CodexSettingsView.swift:56`, `WhisperM8/Views/OutputModesView.swift:174`, `WhisperM8/Views/OutputModesView.swift:181`, `WhisperM8/Views/OutputModesView.swift:192`, `WhisperM8/Views/OutputModesView.swift:199`, `WhisperM8/Views/OutputModesView.swift:210`, `WhisperM8/Views/OutputModesView.swift:217`).
3. **Benennungen mischen Konzepte:** Die Sidebar sagt „Codex / ChatGPT", der View-Titel sagt nur „Codex", die erste Section sagt „ChatGPT Subscription via Codex", und der Picker „Speed" steuert intern `service_tier` plus `features.fast_mode` (`WhisperM8/Views/SettingsView.swift:5`, `WhisperM8/Views/CodexSettingsView.swift:33`, `WhisperM8/Views/CodexSettingsView.swift:77`, `WhisperM8/Views/CodexSettingsView.swift:125`, `WhisperM8/Models/CodexServiceTier.swift:31`, `WhisperM8/Models/CodexServiceTier.swift:32`).
4. **Sprachmix ist sehr stark:** Fast alle sichtbaren Texte dieser Seite sind Englisch, während andere Settings-Bereiche bereits deutsche Labels enthalten, zum Beispiel „Standard-Provider", „Chat-Verhalten" und „Chats automatisch umbenennen" (`WhisperM8/Views/CodexSettingsView.swift:33`, `WhisperM8/Views/CodexSettingsView.swift:42`, `WhisperM8/Views/CodexSettingsView.swift:57`, `WhisperM8/Views/CodexSettingsView.swift:67`, `WhisperM8/Views/CodexSettingsView.swift:77`, `WhisperM8/Views/Settings/AgentChatsAccessView.swift:33`, `WhisperM8/Views/Settings/AgentChatsAccessView.swift:46`, `WhisperM8/Views/Settings/AgentChatsAccessView.swift:47`).
5. **Fehlende Erklärung zu Kosten/Plan-Auswirkung:** Der Speed-Hilfetext erwähnt „Fast-mode credit multiplier" nur im Enum-Text für Standard und „supported ChatGPT plans" für Fast; die Seite erklärt nicht, welche ChatGPT-Pläne betroffen sind oder was der Multiplikator praktisch bedeutet (`WhisperM8/Models/CodexServiceTier.swift:21`, `WhisperM8/Models/CodexServiceTier.swift:23`, `WhisperM8/Views/CodexSettingsView.swift:83`).
6. **Video-Setting wirkt stärker als die Implementierung:** Der Picker bietet „Video", aber der UI-Hinweis sagt selbst, dass `codex exec` kein `--video` hat, und der Code sendet weiterhin Frames als `--image`; das kann Nutzer erwarten lassen, dass echte Video-Dateien an Codex angehängt werden (`WhisperM8/Models/CodexVisualInputMode.swift:17`, `WhisperM8/Views/CodexSettingsView.swift:113`, `WhisperM8/Services/Dictation/CodexSupport.swift:82`, `WhisperM8/Services/Dictation/CodexSupport.swift:106`).
7. **Privacy-Section ist abstrakt und nicht konfigurierbar:** Der Text erklärt Raw-Fallback, aber der zugehörige Schalter „Fallback to Fast on processing errors" liegt auf der Modes-Seite und heißt dort nicht „Raw", sondern „Fast" (`WhisperM8/Views/CodexSettingsView.swift:118`, `WhisperM8/Views/CodexSettingsView.swift:119`, `WhisperM8/Views/OutputModesView.swift:101`, `WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:236`).
8. **Agent-Chat-Wirkung ist nicht sichtbar:** Model und Thinking beeinflussen nicht nur Diktat-Post-Processing, sondern auch neue Codex-Agent-Sessions; die Codex-Seite nennt diese zweite Wirkung nicht (`WhisperM8/Views/CodexSettingsView.swift:56`, `WhisperM8/Views/AgentChatsView+SessionLifecycle.swift:47`, `WhisperM8/Views/AgentChatsView+SessionLifecycle.swift:48`, `WhisperM8/Models/AgentChat.swift:476`, `WhisperM8/Models/AgentChat.swift:479`).

## 7. Offene Fragen

1. **Codex-CLI-Version-Gating ist heuristisch:** Die Warnung prüft nur `codexVersion.contains("0.120.")`; aus dem Code geht nicht hervor, ob andere alte Versionen GPT-5.5 ebenfalls blockieren oder ob es eine zentrale Mindestversion geben sollte (`WhisperM8/Views/CodexSettingsView.swift:27`, `WhisperM8/Views/CodexSettingsView.swift:28`, `WhisperM8/Views/CodexSettingsView.swift:96`).
2. **„Video" bleibt Produktfrage:** Der Code dokumentiert und implementiert Frame-Fallback, aber es bleibt offen, ob der Picker nach außen „Video" heißen soll, solange `codex exec` keinen direkten Video-Anhang erhält (`WhisperM8/Models/CodexVisualInputMode.swift:17`, `WhisperM8/Models/CodexVisualInputMode.swift:28`, `WhisperM8/Views/CodexSettingsView.swift:113`).
3. **Zuständigkeit der Seite ist uneindeutig:** Dieselben globalen Codex-Werte betreffen Diktat-Post-Processing und neue Codex-Agent-Chats, während `codexExtraArguments` auf der Agent-Chats-Seite liegt; aus dem Code ist keine klare Produktentscheidung ersichtlich, ob „Codex / ChatGPT" nur Diktat-Enrichment oder alle Codex-Flows erklären soll (`WhisperM8/Services/Dictation/CodexPostProcessor.swift:67`, `WhisperM8/Views/AgentChatsView+SessionLifecycle.swift:47`, `WhisperM8/Views/Settings/AgentChatsAccessView.swift:72`).
